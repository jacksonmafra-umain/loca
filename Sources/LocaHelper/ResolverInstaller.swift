import Foundation
import LocaCore

enum ResolverInstallerError: Error, LocalizedError {
    case notOurs(String)

    var errorDescription: String? {
        switch self {
        case .notOurs(let path):
            return "\(path) was not written by Loca, so it was left alone"
        }
    }
}

/// Owns `/etc/resolver/test`.
///
/// This is the one file that makes every `.test` name resolve to the local
/// responder, and it is also a file other tools write. A pre-existing foreign
/// copy is moved aside and reported rather than overwritten — someone whose
/// dnsmasq setup stopped working because we clobbered a file would have no way
/// to find out what happened.
enum ResolverInstaller {
    private static let backupPrefix = "test.loca-backup-"

    /// Returns the backup path when a foreign file had to be moved aside.
    static func install(port: UInt16 = Paths.dnsPort) throws -> String? {
        try FileManager.default.createDirectory(
            at: Paths.resolverDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755])

        var backupPath: String?
        let existing = current()

        if let existing, !ResolverFile.isManagedByLoca(existing) {
            let backup = Paths.resolverDirectory.appending(path: backupPrefix + timestamp())
            try Data(existing.utf8).write(to: backup)
            backupPath = backup.path(percentEncoded: false)
            NSLog("loca: backed up a foreign /etc/resolver/test to %@", backupPath!)
        }

        try Data(ResolverFile.content(port: port).utf8).write(to: Paths.resolverFile)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: Paths.resolverFile.path(percentEncoded: false))

        NSLog("loca: wrote %@", Paths.resolverFile.path(percentEncoded: false))
        return backupPath
    }

    /// Removes our file, then restores the most recent backup if there is one.
    ///
    /// A file the marker does not claim is left exactly where it is: uninstall
    /// undoes what Loca did, not what it found.
    static func remove() throws {
        guard let existing = current() else { return }
        guard ResolverFile.isManagedByLoca(existing) else {
            throw ResolverInstallerError.notOurs(Paths.resolverFile.path(percentEncoded: false))
        }

        try FileManager.default.removeItem(at: Paths.resolverFile)

        if let backup = mostRecentBackup() {
            try FileManager.default.moveItem(at: backup, to: Paths.resolverFile)
            NSLog("loca: restored %@", backup.lastPathComponent)
        }
    }

    static func status() -> (exists: Bool, managedByLoca: Bool, content: String?) {
        guard let content = current() else { return (false, false, nil) }
        return (true, ResolverFile.isManagedByLoca(content), content)
    }

    // MARK: - Helpers

    private static func current() -> String? {
        try? String(contentsOf: Paths.resolverFile, encoding: .utf8)
    }

    private static func mostRecentBackup() -> URL? {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: Paths.resolverDirectory, includingPropertiesForKeys: nil)) ?? []
        // The timestamp is ISO 8601 with fixed width, so lexical order is
        // chronological order.
        return contents
            .filter { $0.lastPathComponent.hasPrefix(backupPrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last
    }

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        // Colons are legal in a macOS filename but read badly in a shell, so
        // they come out.
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "")
    }
}
