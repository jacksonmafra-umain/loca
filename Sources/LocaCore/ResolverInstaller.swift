import Foundation

public enum ResolverInstallerError: Error, Equatable, Sendable {
    /// The file exists but the marker does not claim it, so it is left alone.
    case notManagedByLoca(String)
}

/// Creates, backs up, and removes the resolver file.
///
/// The directory is a parameter rather than a constant so this logic can be
/// tested against a temporary directory. It is the part worth testing: the
/// difference between rewriting our own file and destroying someone's existing
/// dnsmasq configuration is a single branch, and getting it wrong is the kind
/// of bug a user discovers days later when their other tooling stops working.
public struct ResolverInstaller: Sendable {
    public static let backupPrefix = "test.loca-backup-"

    public let directory: URL
    public let fileName: String

    public init(directory: URL = Paths.resolverDirectory, fileName: String = "test") {
        self.directory = directory
        self.fileName = fileName
    }

    public var file: URL { directory.appending(path: fileName) }

    public struct Status: Equatable, Sendable {
        public var exists: Bool
        public var managedByLoca: Bool
        public var content: String?
        public var backups: [String]
    }

    /// Writes our resolver file, moving a foreign one aside first.
    ///
    /// - Returns: the backup path, when a foreign file had to be moved.
    @discardableResult
    public func install(port: UInt16 = Paths.dnsPort, now: Date = Date()) throws -> String? {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        var backupPath: String?

        // A file we wrote is rewritten in place: backing up our own file on
        // every install would pile up copies of something already reproducible.
        if let existing = currentContent(), !ResolverFile.isManagedByLoca(existing) {
            let backup = directory.appending(path: Self.backupPrefix + Self.timestamp(now))
            try Data(existing.utf8).write(to: backup)
            backupPath = backup.path(percentEncoded: false)
        }

        try Data(ResolverFile.content(port: port).utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: file.path(percentEncoded: false))

        return backupPath
    }

    /// Removes our file, then restores the most recent backup if there is one.
    ///
    /// A file the marker does not claim throws instead: uninstall undoes what
    /// Loca did, never what it found.
    public func remove() throws {
        guard let existing = currentContent() else { return }
        guard ResolverFile.isManagedByLoca(existing) else {
            throw ResolverInstallerError.notManagedByLoca(file.path(percentEncoded: false))
        }

        try FileManager.default.removeItem(at: file)

        if let backup = mostRecentBackup() {
            try FileManager.default.moveItem(at: backup, to: file)
        }
    }

    public func status() -> Status {
        Status(
            exists: currentContent() != nil,
            managedByLoca: currentContent().map(ResolverFile.isManagedByLoca) ?? false,
            content: currentContent(),
            backups: backups().map(\.lastPathComponent))
    }

    // MARK: - Helpers

    private func currentContent() -> String? {
        try? String(contentsOf: file, encoding: .utf8)
    }

    private func backups() -> [URL] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        // The timestamp is fixed-width, so lexical order is chronological order.
        return contents
            .filter { $0.lastPathComponent.hasPrefix(Self.backupPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func mostRecentBackup() -> URL? { backups().last }

    /// Fixed-width and sortable. Colons are legal in a macOS filename but read
    /// badly in a shell, so they come out.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
