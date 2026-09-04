import Foundation
import LocaCore

/// The helper's view of `/etc/resolver/test`.
///
/// The logic lives in `LocaCore.ResolverInstaller`, against an injectable
/// directory, so the backup and ownership rules are covered by tests that need
/// neither root nor a real `/etc`. This is only the binding to the real path,
/// plus the logging that makes a support question answerable.
enum SystemResolver {
    private static let installer = ResolverInstaller()

    static func install() throws -> String? {
        let backup = try installer.install()
        if let backup {
            NSLog("loca: backed up a foreign /etc/resolver/test to %@", backup)
        }
        NSLog("loca: wrote %@", installer.file.path(percentEncoded: false))
        return backup
    }

    static func remove() throws {
        try installer.remove()
        NSLog("loca: removed %@", installer.file.path(percentEncoded: false))
    }

    static func status() -> ResolverInstaller.Status {
        installer.status()
    }
}
