import Foundation

/// Whether a registered project's folder is still where it was registered.
///
/// A project whose folder has moved keeps proxying its domain quite happily —
/// the proxy only needs a port — but its runner fails with a working-directory
/// error that names the symptom rather than the cause. Checking explicitly is
/// what lets the app say "the folder moved" instead of leaving the user to
/// decode `chdir` failing.
public enum FolderCheck {
    public enum Outcome: Equatable, Sendable {
        /// The folder is where it should be.
        case present
        /// Nothing at that path.
        case missing
        /// Something is there, but it is a file rather than a directory.
        ///
        /// Distinguished from `missing` because it means something different:
        /// the path was not deleted, it was replaced, and relocating is the
        /// wrong offer to make.
        case notADirectory

        public var isUsable: Bool { self == .present }
    }

    public static func check(
        _ folder: URL, using fileManager: FileManager = .default
    ) -> Outcome {
        var isDirectory: ObjCBool = false
        let path = folder.path(percentEncoded: false)

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .present : .notADirectory
    }

    /// A sentence for the UI, or `nil` when there is nothing wrong.
    public static func problem(
        with folder: URL, using fileManager: FileManager = .default
    ) -> String? {
        switch check(folder, using: fileManager) {
        case .present:
            return nil
        case .missing:
            return "The folder is no longer at \(folder.path(percentEncoded: false))."
        case .notADirectory:
            return
                "\(folder.path(percentEncoded: false)) is a file, not a folder. Something replaced it."
        }
    }
}
