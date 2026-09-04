import Foundation
import LocaCore
import ServiceManagement

/// A tiny command-line surface on the app binary.
///
/// `SMAppService` refuses to register a daemon unless it is called from inside
/// the signed bundle, so registration has to go through this executable. Giving
/// it flags keeps the install and uninstall steps in the README as shell
/// commands, and makes the whole flow scriptable instead of a list of buttons
/// to click.
enum CommandLineMode {
    static func runIfRequested() {
        let arguments = Set(CommandLine.arguments.dropFirst())

        if arguments.contains("--register-helper") {
            register()
            exit(0)
        }
        if arguments.contains("--unregister-helper") {
            unregister()
            exit(0)
        }
        if arguments.contains("--helper-status") {
            print(statusDescription)
            exit(0)
        }
        if arguments.contains("--bundle-info") {
            printBundleInfo()
            exit(0)
        }
        if arguments.contains("--install-resolver") {
            installResolver()
            exit(0)
        }
        if arguments.contains("--remove-resolver") {
            removeResolver()
            exit(0)
        }
        if arguments.contains("--diagnostics") {
            printDiagnostics()
            exit(0)
        }
        if arguments.contains("--trust-ca") {
            trustCertificateAuthority()
            exit(0)
        }
        if let spec = value(of: "--apply-domains", in: CommandLine.arguments) {
            applyDomains(spec)
            exit(0)
        }
        if let slug = value(of: "--start-runner", in: CommandLine.arguments) {
            runner(slug) { try RunnerAgent.start($0, paths: Paths()) }
            exit(0)
        }
        if let slug = value(of: "--stop-runner", in: CommandLine.arguments) {
            runner(slug) { try RunnerAgent.stop($0) }
            exit(0)
        }
        if let slug = value(of: "--runner-status", in: CommandLine.arguments) {
            runner(slug) { project in
                let status = RunnerAgent.status(for: project)
                switch status.state {
                case .running(let pid): print("running, pid \(pid)")
                case .notRunning: print("loaded but not running")
                case .notLoaded: print("not loaded")
                }
                if let exit = status.lastExitStatus { print("last exit status: \(exit)") }
                if let runs = status.runs { print("runs: \(runs)") }
            }
            exit(0)
        }
    }

    // MARK: - Runner

    /// Looks the project up in the saved config, so a runner started from the
    /// shell uses exactly the command and folder the UI would.
    private static func runner(_ slug: String, _ body: (Project) throws -> Void) {
        do {
            let config = try ConfigStore(paths: Paths()).load()
            guard let project = config.projects.first(where: { $0.slug == slug }) else {
                let known = config.projects.map(\.slug).joined(separator: ", ")
                let message =
                    "no project with slug \"\(slug)\""
                    + (known.isEmpty ? "" : " (known: \(known))") + "\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(1)
            }
            try body(project)
        } catch {
            FileHandle.standardError.write(
                Data("runner command failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Reads `--flag value` or `--flag=value`.
    private static func value(of flag: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix(flag + "=") {
                return String(argument.dropFirst(flag.count + 1))
            }
        }
        return nil
    }

    // MARK: - Helper operations

    private static func installResolver() {
        run("install resolver") { proxy, finish in
            proxy.installDNSResolver { ok, detail in finish(Reply(ok: ok, detail: detail)) }
        } onSuccess: { detail in
            if let detail {
                print("installed \(Paths.resolverFile.path()) (backed up an existing file to \(detail))")
            } else {
                print("installed \(Paths.resolverFile.path())")
            }
        }
    }

    private static func removeResolver() {
        run("remove resolver") { proxy, finish in
            proxy.removeDNSResolver { ok, detail in finish(Reply(ok: ok, detail: detail)) }
        } onSuccess: { _ in
            print("removed \(Paths.resolverFile.path())")
        }
    }

    /// `--apply-domains slug:port[,slug:port…]`
    ///
    /// A stand-in for the project list until milestone 3 owns the config. It
    /// exists so the proxy can be exercised end to end from a shell rather than
    /// waiting on a UI.
    private static func applyDomains(_ spec: String) {
        var projects: [Project] = []
        let home = URL(filePath: NSHomeDirectory())

        for entry in spec.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard parts.count == 2, let port = Int(parts[1]) else {
                FileHandle.standardError.write(
                    Data("expected slug:port, got \"\(entry)\"\n".utf8))
                exit(2)
            }
            projects.append(
                Project(slug: String(parts[0]), folder: home, port: port))
        }

        run("apply domains") { proxy, finish in
            proxy.applyDomains(DomainPayload.encode(projects)) { ok, detail in
                finish(Reply(ok: ok, detail: detail))
            }
        } onSuccess: { _ in
            for project in projects {
                print("serving https://\(project.domain) -> 127.0.0.1:\(project.port)")
            }
        }
    }

    /// Fetches the root from the helper, then trusts it here.
    ///
    /// macOS shows its authorization prompt during the second step, because
    /// this process is in the user's session. That prompt is the point: the
    /// helper cannot obtain the authorization at all.
    private static func trustCertificateAuthority() {
        struct Root: Sendable {
            let der: Data?
            let detail: String?
        }

        do {
            let root: Root = try SyncHelperCall.call { proxy, finish in
                proxy.certificateAuthorityRoot { der, detail in
                    finish(Root(der: der, detail: detail))
                }
            }
            guard let der = root.der else {
                throw CertificateTrustError.noCertificate(root.detail ?? "no detail")
            }

            if CertificateTrust.isTrusted(rootCertificateDER: der) {
                print("the Caddy root certificate is already trusted")
                return
            }

            print("asking macOS to trust the Caddy root certificate; approve the prompt")
            try CertificateTrust.install(rootCertificateDER: der)

            guard CertificateTrust.isTrusted(rootCertificateDER: der) else {
                throw CertificateTrustError.commandFailed(
                    "the certificate was added but does not evaluate as trusted")
            }
            print("the Caddy root certificate is trusted for this user")
        } catch {
            FileHandle.standardError.write(
                Data("trust failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func printDiagnostics() {
        do {
            let report: [String: String] = try SyncHelperCall.call { proxy, finish in
                proxy.diagnostics { raw in finish(raw.mapValues { String(describing: $0) }) }
            }
            for key in report.keys.sorted() {
                print("\(key): \(report[key] ?? "")")
            }
        } catch {
            FileHandle.standardError.write(
                Data("diagnostics failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private struct Reply: Sendable {
        let ok: Bool
        let detail: String?
    }

    private static func run(
        _ label: String,
        _ body: (any LocaHelperProtocol, @escaping @Sendable (Reply) -> Void) -> Void,
        onSuccess: (String?) -> Void
    ) {
        do {
            let reply: Reply = try SyncHelperCall.call(body)
            guard reply.ok else {
                FileHandle.standardError.write(
                    Data("\(label) failed: \(reply.detail ?? "no detail")\n".utf8))
                exit(1)
            }
            onSuccess(reply.detail)
        } catch {
            FileHandle.standardError.write(
                Data("\(label) failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Prints which bundle `SMAppService` is looking at and what it contains.
    ///
    /// Worth having, because the failure this diagnoses looks like nothing:
    /// `.notFound` covers both "the plist is missing" and "the plist is
    /// invalid", and on macOS 26 it is also what an unregistered item reports
    /// instead of `.notRegistered`. Seeing the bundle path and the actual
    /// directory listing separates the three.
    private static func printBundleInfo() {
        let bundle = Bundle.main
        print("bundlePath: \(bundle.bundlePath)")
        print("bundleIdentifier: \(bundle.bundleIdentifier ?? "nil")")
        print("executablePath: \(bundle.executablePath ?? "nil")")

        let daemons = URL(filePath: bundle.bundlePath)
            .appending(path: "Contents/Library/LaunchDaemons")
        let contents =
            (try? FileManager.default.contentsOfDirectory(atPath: daemons.path())) ?? []
        print("LaunchDaemons: \(contents)")
        print("status: \(statusDescription)")
    }

    private static var daemon: SMAppService {
        SMAppService.daemon(plistName: "\(Paths.helperLabel).plist")
    }

    private static func register() {
        let thrown: (any Error)?
        do {
            try daemon.register()
            thrown = nil
        } catch {
            thrown = error
        }

        // `register()` throws "Operation not permitted" on the normal path
        // where the item is recorded but not yet approved: launchd refuses to
        // bootstrap a disallowed job, and that comes back as an error even
        // though the registration itself succeeded. The status afterwards is
        // the honest signal.
        let status = daemon.status
        guard status == .enabled || status == .requiresApproval else {
            let reason = thrown?.localizedDescription ?? statusDescription
            FileHandle.standardError.write(Data("register failed: \(reason)\n".utf8))
            exit(1)
        }

        print("registered \(Paths.helperLabel): \(statusDescription)")
        if status == .requiresApproval {
            // macOS will not start a registered daemon until the user enables
            // it here. Saying so is the difference between "it does not work"
            // and one click.
            print("approve it in System Settings > General > Login Items")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    /// Holds the async result across the semaphore wait. A captured `var`
    /// cannot cross into the task under strict concurrency checking.
    private final class Box: @unchecked Sendable {
        var failure: (any Error)?
    }

    private static func unregister() {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box()

        Task {
            do { try await daemon.unregister() } catch { box.failure = error }
            semaphore.signal()
        }
        semaphore.wait()

        if let failure = box.failure {
            FileHandle.standardError.write(
                Data("unregister failed: \(failure.localizedDescription)\n".utf8))
            exit(1)
        }
        print("unregistered \(Paths.helperLabel)")
    }

    private static var statusDescription: String {
        switch daemon.status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in Login Items"
        case .notFound: "not found in the app bundle"
        @unknown default: "unknown"
        }
    }
}
