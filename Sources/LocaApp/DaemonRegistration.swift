import Foundation
import LocaCore
import ServiceManagement

/// The one place that talks to `SMAppService`.
///
/// Deliberately a non-isolated enum with no stored state, for a concurrency
/// reason worth spelling out: `SMAppService` is not `Sendable`, so calling its
/// `async unregister()` from an isolated context — the main actor, say — sends a
/// non-`Sendable` value across an isolation boundary. Swift rejects that, and
/// rejects it *differently* depending on toolchain and optimization level: it
/// compiled locally on 6.3, passed a debug build on 6.2.4, and failed the
/// release build on the same 6.2.4.
///
/// So this uses the callback form of `unregister` and bridges it with a
/// continuation. A callback never crosses an isolation boundary, which makes
/// the question moot rather than merely answered.
enum DaemonRegistration {
    /// Rebuilt per call. It is a handle, not a connection, so this is cheap —
    /// and a fresh value has no other references to reason about.
    private static var service: SMAppService {
        SMAppService.daemon(plistName: "\(Paths.helperLabel).plist")
    }

    static var status: SMAppService.Status {
        service.status
    }

    static func register() throws {
        try service.register()
    }

    static func unregister() async throws {
        // The Void witness has to be spelled out: an empty `resume()` leaves
        // the continuation's type unconstrained.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Single-shot by contract: SMAppService calls this exactly once.
            service.unregister { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// A description fit to show a user.
    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "not registered"
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in Login Items"
        case .notFound: "not found in the app bundle"
        @unknown default: "unknown"
        }
    }
}
