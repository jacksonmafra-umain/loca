import Foundation
import Testing

@testable import LocaCore

@Suite("ResolverInstaller")
struct ResolverInstallerTests {
    private func withInstaller(_ body: (ResolverInstaller) throws -> Void) throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "loca-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(ResolverInstaller(directory: directory))
    }

    private func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    @Test func installCreatesTheDirectoryAndTheFile() throws {
        try withInstaller { installer in
            let backup = try installer.install()
            #expect(backup == nil)
            #expect(read(installer.file) == ResolverFile.content())
        }
    }

    @Test func theInstalledFileIsWorldReadable() throws {
        try withInstaller { installer in
            try installer.install()
            let attributes = try FileManager.default.attributesOfItem(
                atPath: installer.file.path(percentEncoded: false))
            #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o644)
        }
    }

    /// The whole point of the marker. Someone whose dnsmasq setup stopped
    /// working because we clobbered this file would have no way to find out
    /// what happened.
    @Test func aForeignFileIsBackedUpNotOverwritten() throws {
        try withInstaller { installer in
            try FileManager.default.createDirectory(
                at: installer.directory, withIntermediateDirectories: true)
            try Data("nameserver 9.9.9.9\n".utf8).write(to: installer.file)

            let backup = try installer.install()
            let backupPath = try #require(backup)
            #expect(backupPath.contains(ResolverInstaller.backupPrefix))
            #expect(read(URL(filePath: backupPath)) == "nameserver 9.9.9.9\n")
            #expect(read(installer.file) == ResolverFile.content())
        }
    }

    /// Backing up our own file on every install would pile up copies of
    /// something already reproducible.
    @Test func ourOwnFileIsRewrittenWithoutABackup() throws {
        try withInstaller { installer in
            try installer.install()
            let backup = try installer.install(port: 5300)
            #expect(backup == nil)
            #expect(read(installer.file) == ResolverFile.content(port: 5300))
            #expect(installer.status().backups.isEmpty)
        }
    }

    @Test func removeDeletesOurFile() throws {
        try withInstaller { installer in
            try installer.install()
            try installer.remove()
            #expect(read(installer.file) == nil)
        }
    }

    /// Uninstall undoes what Loca did, never what it found.
    @Test func removeRefusesAFileItDoesNotOwn() throws {
        try withInstaller { installer in
            try FileManager.default.createDirectory(
                at: installer.directory, withIntermediateDirectories: true)
            try Data("nameserver 9.9.9.9\n".utf8).write(to: installer.file)

            #expect(
                throws: ResolverInstallerError.notManagedByLoca(
                    installer.file.path(percentEncoded: false))
            ) {
                try installer.remove()
            }
            #expect(read(installer.file) == "nameserver 9.9.9.9\n")
        }
    }

    @Test func removeRestoresTheMostRecentBackup() throws {
        try withInstaller { installer in
            try FileManager.default.createDirectory(
                at: installer.directory, withIntermediateDirectories: true)
            try Data("nameserver 9.9.9.9\n".utf8).write(to: installer.file)

            try installer.install()
            try installer.remove()
            #expect(read(installer.file) == "nameserver 9.9.9.9\n")
        }
    }

    @Test func removeOnAnAbsentFileIsHarmless() throws {
        try withInstaller { installer in
            try installer.remove()
            #expect(installer.status().exists == false)
        }
    }

    @Test func statusDistinguishesAbsentForeignAndOurs() throws {
        try withInstaller { installer in
            #expect(installer.status() == ResolverInstaller.Status(
                exists: false, managedByLoca: false, content: nil, backups: []))

            try FileManager.default.createDirectory(
                at: installer.directory, withIntermediateDirectories: true)
            try Data("nameserver 9.9.9.9\n".utf8).write(to: installer.file)
            #expect(installer.status().exists)
            #expect(!installer.status().managedByLoca)

            try installer.install()
            #expect(installer.status().managedByLoca)
            #expect(installer.status().backups.count == 1)
        }
    }

    /// Lexical order has to equal chronological order, because that is how the
    /// most recent backup is picked.
    @Test func backupTimestampsSortChronologically() {
        let earlier = ResolverInstaller.timestamp(Date(timeIntervalSince1970: 1_000_000))
        let later = ResolverInstaller.timestamp(Date(timeIntervalSince1970: 2_000_000))
        #expect(earlier < later)
        #expect(!earlier.contains(":"))
        #expect(earlier.count == later.count)
    }

    @Test func theMostRecentOfSeveralBackupsIsRestored() throws {
        try withInstaller { installer in
            try FileManager.default.createDirectory(
                at: installer.directory, withIntermediateDirectories: true)

            try Data("first\n".utf8).write(to: installer.file)
            try installer.install(now: Date(timeIntervalSince1970: 1_000_000))
            try installer.remove()

            try Data("second\n".utf8).write(to: installer.file)
            try installer.install(now: Date(timeIntervalSince1970: 2_000_000))

            // The first backup was consumed by its own remove(), so the only
            // one left is the newer file.
            try installer.remove()
            #expect(read(installer.file) == "second\n")
        }
    }
}
