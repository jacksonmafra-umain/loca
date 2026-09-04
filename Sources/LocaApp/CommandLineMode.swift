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
