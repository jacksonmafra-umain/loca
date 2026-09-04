import Foundation

public enum ValidationError: Error, Equatable, Sendable {
    case invalidSlug(String)
    case duplicateSlug(String)
    case portOutOfRange(Int)
    case folderNotAbsolute(String)
    case folderTraversal(String)
}

/// The single gate every project field passes through before it is persisted or
/// sent to the helper.
///
/// This matters most on the privileged side: the helper decodes an XPC payload
/// straight from a user-session process, and without this check any local
/// process could ask a root daemon to write `/etc/resolver` and proxy arbitrary
/// domains.
public enum Validation {
    public static let portRange = 1...65535

    public static func validate(
        slug: String,
        port: Int,
        folder: URL,
        existing: [Project],
        ignoring id: UUID? = nil
    ) throws {
        guard Slug.isValid(slug) else { throw ValidationError.invalidSlug(slug) }
        guard portRange.contains(port) else { throw ValidationError.portOutOfRange(port) }
        try validateFolder(folder)

        // A duplicate port is allowed — the UI flags it, since running two
        // projects against one port can be deliberate. A duplicate slug is not:
        // two projects cannot own one domain.
        if existing.contains(where: { $0.slug == slug && $0.id != id }) {
            throw ValidationError.duplicateSlug(slug)
        }
    }

    public static func validateFolder(_ folder: URL) throws {
        try validateFolderPath(folder.path(percentEncoded: false))
    }

    /// Rejects a relative path and any `..` component.
    ///
    /// The string form is the one that matters. `URL(filePath:)` resolves a
    /// relative path against the current directory, so by the time a folder is
    /// a URL it is always absolute — but a folder arriving over XPC is a raw
    /// string, and that is exactly where a relative or traversing path must be
    /// refused.
    ///
    /// `..` is refused rather than resolved: the app hands this path to
    /// `launchctl` as a working directory, and a path that means something
    /// different after normalization is a path worth refusing outright.
    public static func validateFolderPath(_ path: String) throws {
        guard path.hasPrefix("/") else { throw ValidationError.folderNotAbsolute(path) }
        guard !path.split(separator: "/").contains("..") else {
            throw ValidationError.folderTraversal(path)
        }
    }
}
