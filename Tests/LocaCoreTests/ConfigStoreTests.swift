import Foundation
import Testing

@testable import LocaCore

@Suite("ConfigStore")
struct ConfigStoreTests {
    /// Each test gets its own directory, removed on the way out, so nothing
    /// leaks between runs and nothing touches the real support directory.
    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "loca-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    private func sampleConfig() -> LocaConfig {
        LocaConfig(projects: [
            Project(
                slug: "projeto1", folder: URL(filePath: "/Users/me/code/p1"), port: 2020,
                runner: Runner(command: "pnpm dev", autoStart: true, keepAlive: true)),
            Project(
                slug: "projeto2", folder: URL(filePath: "/Users/me/code/p2"), port: 2021,
                enabled: false),
        ])
    }

    @Test func aMissingFileLoadsAsAnEmptyConfig() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(file: directory.appending(path: "config.json"))
            let config = try store.load()
            #expect(config.version == LocaConfig.currentVersion)
            #expect(config.projects.isEmpty)
        }
    }

    @Test func saveThenLoadRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(file: directory.appending(path: "config.json"))
            let config = sampleConfig()
            try store.save(config)
            #expect(try store.load() == config)
        }
    }

    @Test func saveCreatesMissingParentDirectories() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "a/b/c/config.json")
            let store = ConfigStore(file: file)
            try store.save(sampleConfig())
            #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        }
    }

    /// The write is a temp file plus a rename, so a crash mid-write can never
    /// leave a half-written config behind. Nothing temporary may survive it.
    @Test func saveLeavesNoTemporaryFileBehind() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(file: directory.appending(path: "config.json"))
            try store.save(sampleConfig())
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path())
            #expect(contents == ["config.json"])
        }
    }

    @Test func overwritingAnExistingConfigKeepsOnlyTheNewOne() throws {
        try withTemporaryDirectory { directory in
            let store = ConfigStore(file: directory.appending(path: "config.json"))
            try store.save(sampleConfig())
            let replacement = LocaConfig(projects: [
                Project(slug: "only", folder: URL(filePath: "/tmp/only"), port: 9000)
            ])
            try store.save(replacement)
            #expect(try store.load() == replacement)
        }
    }

    /// A config written by a newer build is refused rather than silently
    /// misread, which is what keeps a downgrade from quietly dropping fields.
    @Test func aFutureVersionIsRefused() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "config.json")
            try Data(#"{"version":99,"projects":[]}"#.utf8).write(to: file)
            let store = ConfigStore(file: file)
            #expect(throws: ConfigStoreError.unsupportedVersion(99)) {
                _ = try store.load()
            }
        }
    }

    @Test func malformedJSONSurfacesAsAnError() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "config.json")
            try Data("not json".utf8).write(to: file)
            #expect(throws: (any Error).self) {
                _ = try ConfigStore(file: file).load()
            }
        }
    }

    /// A user may well open this file. Sorted keys and unescaped slashes keep
    /// it readable and keep diffs small.
    @Test func theWrittenFileIsHumanReadable() throws {
        try withTemporaryDirectory { directory in
            let file = directory.appending(path: "config.json")
            try ConfigStore(file: file).save(sampleConfig())
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(text.contains("\"folder\" : \"/Users/me/code/p1\""))
            #expect(text.contains("\n"))
            #expect(!text.contains("\\/"))
        }
    }
}
