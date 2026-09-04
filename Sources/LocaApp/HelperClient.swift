import Foundation
import LocaCore
import ServiceManagement

/// The app's side of the XPC link, plus registration of the daemon itself.
///
/// Expanded in milestone 3; for now it is enough to install the helper and ask
/// it what it is, which is what makes milestone 1 verifiable at all.
@MainActor
@Observable
final class HelperClient {
    enum State: Equatable {
        case notInstalled
        /// Registered, but the user has not approved it in Login Items yet.
        case requiresApproval
        case installed
        /// The helper answers, but speaks a different protocol version.
        case versionSkew(Int)
        case unreachable(String)
    }

    private(set) var state: State = .notInstalled
    private(set) var helperBuild: String?
    private(set) var lastError: String?

    private let daemon = SMAppService.daemon(plistName: "\(Paths.helperLabel).plist")
    private var connection: NSXPCConnection?

    // MARK: - Registration

    func register() {
        lastError = nil
        let thrown: (any Error)?
        do {
            try daemon.register()
            thrown = nil
        } catch {
            thrown = error
        }
        refreshRegistrationState()

        // `register()` throws "Operation not permitted" on the normal path
        // where the item is recorded but not yet approved — launchd refuses to
        // bootstrap it, and that surfaces as an error. The status is the honest
        // signal, so an error is only worth showing when the status did not
        // move.
        if let thrown, state != .requiresApproval, state != .installed {
            lastError = "could not register the helper: \(thrown.localizedDescription)"
        }
    }

    func unregister() async {
        lastError = nil
        do {
            try await daemon.unregister()
        } catch {
            lastError = "could not unregister the helper: \(error.localizedDescription)"
        }
        invalidateConnection()
        refreshRegistrationState()
    }

    /// Opens the Login Items pane, the only place a registered daemon can be
    /// approved.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refreshRegistrationState() {
        switch daemon.status {
        case .notRegistered: state = .notInstalled
        case .requiresApproval: state = .requiresApproval
        case .enabled: state = .installed
        case .notFound: state = .unreachable("the helper is not in the app bundle")
        @unknown default: state = .unreachable("unknown registration status")
        }
    }

    // MARK: - Calls

    /// The version handshake. A helper left behind by an older build still
    /// answers, but not in a shape this app understands — reporting that as
    /// version skew turns an inexplicable XPC failure into "reinstall the
    /// helper".
    func refreshState() async {
        refreshRegistrationState()
        guard state == .installed else { return }

        do {
            let reported = try await withProxy { proxy, finish in
                proxy.helperVersion { version, build in
                    finish(.success(HelperIdentity(version: version, build: build)))
                }
            }
            helperBuild = reported.build
            state =
                reported.version == locaHelperProtocolVersion
                ? .installed : .versionSkew(reported.version)
        } catch {
            state = .unreachable(error.localizedDescription)
        }
    }

    // MARK: - Domains

    /// Pushes the enabled set to the proxy.
    ///
    /// Throws rather than reporting, so `AppStore` can roll its in-memory
    /// change back: the UI must never show a domain as enabled that the proxy
    /// is not actually serving.
    func applyDomains(_ projects: [Project]) async throws {
        let reply = try await withProxy { proxy, finish in
            proxy.applyDomains(DomainPayload.encode(projects)) { ok, detail in
                finish(.success(BoolReply(ok: ok, detail: detail)))
            }
        }
        guard reply.ok else {
            throw HelperClientError.rejected(reply.detail ?? "no detail")
        }
    }

    // MARK: - Resolver

    /// - Returns: the path a pre-existing foreign resolver file was backed up
    ///   to, when there was one.
    @discardableResult
    func installResolver() async throws -> String? {
        let reply = try await withProxy { proxy, finish in
            proxy.installDNSResolver { ok, detail in
                finish(.success(BoolReply(ok: ok, detail: detail)))
            }
        }
        guard reply.ok else {
            throw HelperClientError.rejected(reply.detail ?? "no detail")
        }
        return reply.detail
    }

    func removeResolver() async throws {
        let reply = try await withProxy { proxy, finish in
            proxy.removeDNSResolver { ok, detail in
                finish(.success(BoolReply(ok: ok, detail: detail)))
            }
        }
        guard reply.ok else {
            throw HelperClientError.rejected(reply.detail ?? "no detail")
        }
    }

    // MARK: - Certificate authority

    /// The root certificate, or `nil` when Caddy has not issued one yet —
    /// which is the case until the first domain is applied.
    func certificateAuthorityRoot() async throws -> Data? {
        let reply = try await withProxy { proxy, finish in
            proxy.certificateAuthorityRoot { der, detail in
                finish(.success(RootReply(der: der, detail: detail)))
            }
        }
        return reply.der
    }

    /// Trust lives in the user's keychain, so it is installed and evaluated
    /// here rather than by the helper. See `CertificateTrust` for why neither
    /// side can do both halves.
    func trustCertificateAuthority() async throws {
        guard let der = try await certificateAuthorityRoot() else {
            throw HelperClientError.rejected(
                "Caddy has not issued its root certificate yet — add a domain first")
        }
        guard !CertificateTrust.isTrusted(rootCertificateDER: der) else { return }
        try CertificateTrust.install(rootCertificateDER: der)
    }

    func certificateAuthorityIsTrusted() async -> Bool {
        // `try?` on a throwing call that already returns an optional flattens
        // to a single level, so one binding is all this needs.
        guard let der = try? await certificateAuthorityRoot() else { return false }
        return CertificateTrust.isTrusted(rootCertificateDER: der)
    }

    // MARK: - Diagnostics

    /// Values are flattened to strings inside the reply block, on the queue XPC
    /// delivers them on, so nothing non-`Sendable` crosses back to the main
    /// actor.
    ///
    /// The flattening itself lives in a file-scope function on purpose. A
    /// closure written inline here would inherit this type's `@MainActor`
    /// isolation, Swift would insert an isolation check into it, and the check
    /// would fail — XPC reply blocks do not run on the main queue. That fails
    /// as a dispatch assertion at launch, not a compile error.
    func diagnostics() async -> [String: String] {
        do {
            return try await withProxy { proxy, finish in
                proxy.diagnostics { raw in
                    finish(.success(flattenDiagnostics(raw)))
                }
            }
        } catch {
            lastError = error.localizedDescription
            return [:]
        }
    }

    // MARK: - Connection plumbing

    private func makeConnection() -> NSXPCConnection {
        if let connection { return connection }

        let connection = NSXPCConnection(
            machServiceName: locaHelperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LocaHelperProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    /// Wraps one XPC round trip in a continuation.
    ///
    /// The reply block and the error handler can both fire — a reply landing
    /// just as the connection drops, say — and resuming a continuation twice
    /// traps, so `finish` is one-shot. A helper that dies mid-call otherwise
    /// leaves the caller awaiting forever, which in a UI reads as the app
    /// hanging.
    private func withProxy<T: Sendable>(
        _ body: (any LocaHelperProtocol, @escaping @Sendable (Result<T, any Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = makeConnection()

        return try await withCheckedThrowingContinuation { continuation in
            let once = OneShot()
            let finish: @Sendable (Result<T, any Error>) -> Void = { result in
                guard once.claim() else { return }
                continuation.resume(with: result)
            }

            guard
                let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                    finish(.failure(error))
                }) as? any LocaHelperProtocol
            else {
                finish(.failure(HelperClientError.noProxy))
                return
            }

            body(proxy, finish)
        }
    }
}

/// Deliberately at file scope, which makes it non-isolated.
///
/// Anything that runs inside an XPC reply block has to be, because those blocks
/// arrive on a background queue.
private func flattenDiagnostics(_ raw: [String: NSObject]) -> [String: String] {
    raw.mapValues { String(describing: $0) }
}

private struct HelperIdentity: Sendable {
    let version: Int
    let build: String
}

private struct BoolReply: Sendable {
    let ok: Bool
    let detail: String?
}

private struct RootReply: Sendable {
    let der: Data?
    let detail: String?
}

enum HelperClientError: LocalizedError {
    case noProxy
    /// The helper answered, and said no. Its own words are carried through,
    /// because they are the only thing that explains a rejected config.
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .noProxy: return "the helper connection returned no proxy object"
        case .rejected(let detail): return detail
        }
    }
}

/// Lets exactly one caller through, so a continuation cannot be resumed twice.
private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}
