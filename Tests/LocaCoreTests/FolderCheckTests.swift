import Foundation
import Testing

@testable import LocaCore

@Suite("FolderCheck")
struct FolderCheckTests {
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "loca-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    @Test func aDirectoryThatExistsIsPresent() throws {
        try withTemporaryDirectory { directory in
            #expect(FolderCheck.check(directory) == .present)
            #expect(FolderCheck.check(directory).isUsable)
            #expect(FolderCheck.problem(with: directory) == nil)
        }
    }

    @Test func anAbsentPathIsMissing() throws {
        let gone = URL(filePath: NSTemporaryDirectory()).appending(path: "loca-gone-\(UUID())")
        #expect(FolderCheck.check(gone) == .missing)
        #expect(!FolderCheck.check(gone).isUsable)
        #expect(FolderCheck.problem(with: gone)?.contains("no longer at") == true)
    }

    /// A file where a folder was means the path was replaced, not deleted —
    /// which is a different thing to tell the user, and relocating is the wrong
    /// offer to make.
    @Test func aFileWhereAFolderShouldBeIsNotADirectory() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "notafolder")
            try Data("x".utf8).write(to: file)

            #expect(FolderCheck.check(file) == .notADirectory)
            #expect(!FolderCheck.check(file).isUsable)
            #expect(FolderCheck.problem(with: file)?.contains("is a file") == true)
        }
    }

    @Test func aMovedFolderIsDetectedAtItsOldPath() throws {
        try withTemporaryDirectory { directory in
            let original = directory.appending(path: "before")
            let moved = directory.appending(path: "after")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            #expect(FolderCheck.check(original) == .present)

            try FileManager.default.moveItem(at: original, to: moved)
            #expect(FolderCheck.check(original) == .missing)
            #expect(FolderCheck.check(moved) == .present)
        }
    }

    /// The problem sentence names the path, because "the folder is missing" is
    /// not actionable when several projects are registered.
    @Test func theProblemSentenceNamesThePath() throws {
        let gone = URL(filePath: "/nonexistent/loca-test-path")
        #expect(FolderCheck.problem(with: gone)?.contains("/nonexistent/loca-test-path") == true)
    }
}
