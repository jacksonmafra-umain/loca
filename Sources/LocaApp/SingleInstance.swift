import AppKit
import Foundation

/// Keeps exactly one copy of Loca running.
///
/// LaunchServices reuses a running app for a normal open, but `open -n`, a
/// second copy in another folder, and running the executable directly all
/// bypass that. For most apps a duplicate is untidy. Here it is a correctness
/// problem: two instances poll the same helper, drive the same `launchd`
/// agents, and write the same `config.json` — and the last writer wins, so a
/// domain added in one window can vanish when the other saves.
///
/// The check matches on bundle identifier rather than path, because the two
/// instances most likely to collide are a build folder and `/Applications`,
/// which are different paths and the same app.
enum SingleInstance {
    /// Hands over to the copy already running, and does not return if one is.
    ///
    /// Called after the command-line surface, never before: `--helper-status`
    /// and its neighbours have to work while the window is open.
    static func enforceOrHandOver() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }

        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .filter { $0 != .current && !$0.isTerminated }

        guard let existing = others.first else { return }

        // Bring the copy that was already there to the front, so the click that
        // started this one still ends with Loca in front of the user rather
        // than nothing visibly happening.
        existing.activate(options: [.activateAllWindows])

        let message =
            "loca: already running (pid \(existing.processIdentifier)); "
            + "bringing that copy forward\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(0)
    }
}
