import Foundation
import Testing

@testable import LocaCore

@Suite("ProtectedFolder")
struct ProtectedFolderTests {
    private let home = URL(filePath: "/Users/test")

    @Test(
        arguments: [
            ("/Users/test/Downloads", "~/Downloads"),
            ("/Users/test/Downloads/Projects/app", "~/Downloads"),
            ("/Users/test/Documents/work/api", "~/Documents"),
            ("/Users/test/Desktop/scratch", "~/Desktop"),
            ("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/app",
             "~/Library/Mobile Documents"),
        ])
    func guardedLocationsAreNamed(path: String, expected: String) {
        #expect(
            ProtectedFolder.guardedLocation(of: URL(filePath: path), home: home) == expected)
    }

    @Test(
        arguments: [
            "/Users/test/code/app",
            "/Users/test/Developer/app",
            "/Users/test",
            "/opt/projects/app",
            "/private/tmp/app",
        ])
    func ordinaryLocationsAreNotGuarded(path: String) {
        #expect(ProtectedFolder.guardedLocation(of: URL(filePath: path), home: home) == nil)
        #expect(!ProtectedFolder.isGuarded(URL(filePath: path), home: home))
    }

    /// A sibling whose name merely starts the same way is not inside the
    /// guarded directory. Matching on a bare prefix would flag it.
    @Test func aSimilarlyNamedSiblingIsNotGuarded() {
        #expect(
            ProtectedFolder.guardedLocation(
                of: URL(filePath: "/Users/test/Downloads2/app"), home: home) == nil)
        #expect(
            ProtectedFolder.guardedLocation(
                of: URL(filePath: "/Users/test/DesktopStuff"), home: home) == nil)
    }

    /// Another user's Downloads is not this user's problem to warn about.
    @Test func anotherUsersGuardedFolderIsNotMatched() {
        #expect(
            ProtectedFolder.guardedLocation(
                of: URL(filePath: "/Users/other/Downloads/app"), home: home) == nil)
    }

    @Test func aHomePathWithATrailingSlashStillMatches() {
        #expect(
            ProtectedFolder.guardedLocation(
                of: URL(filePath: "/Users/test/Downloads/app"),
                home: URL(filePath: "/Users/test/")) == "~/Downloads")
    }
}
