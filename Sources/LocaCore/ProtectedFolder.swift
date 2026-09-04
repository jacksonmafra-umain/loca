import Foundation

/// Detects project folders macOS will not let a background agent work in.
///
/// `~/Downloads`, `~/Documents`, `~/Desktop`, and iCloud Drive are guarded by
/// TCC. A `launchd` agent has no window to show a consent prompt in, so it does
/// not get asked and does not get access — it cannot even resolve its own
/// working directory there, which surfaces in the log as:
///
///     shell-init: error retrieving current directory: getcwd:
///     cannot access parent directories: Operation not permitted
///
/// The server may limp along or may fail outright, depending on whether it
/// touches the filesystem. Either way the cause is invisible unless it is said
/// out loud, so the app warns at the point the folder is chosen.
///
/// This is a warning and never a rejection: a user who has granted the relevant
/// permission, or whose server never reads a file, is entitled to carry on.
public enum ProtectedFolder {
    /// Directory names under the home folder that TCC guards.
    private static let guardedHomeDirectories = [
        "Downloads", "Documents", "Desktop",
        // iCloud Drive, which is where "Documents in iCloud" actually lives.
        "Library/Mobile Documents",
    ]

    /// The guarded location containing `folder`, in a form fit to show a user,
    /// or `nil` when the folder is somewhere agents can work freely.
    public static func guardedLocation(
        of folder: URL, home: URL = URL(filePath: NSHomeDirectory())
    ) -> String? {
        let path = folder.path(percentEncoded: false)
        let homePath = home.path(percentEncoded: false)

        for directory in guardedHomeDirectories {
            let guarded = homePath.hasSuffix("/") ? homePath + directory : homePath + "/" + directory
            // Match the directory itself or anything beneath it, but never a
            // sibling whose name merely starts the same way: "/Downloads2"
            // is not inside "/Downloads".
            if path == guarded || path.hasPrefix(guarded + "/") {
                return "~/" + directory
            }
        }

        return nil
    }

    public static func isGuarded(
        _ folder: URL, home: URL = URL(filePath: NSHomeDirectory())
    ) -> Bool {
        guardedLocation(of: folder, home: home) != nil
    }
}
