import Foundation
import Testing

@testable import LocaCore

@Suite("SharedProjectFile")
struct SharedProjectFileTests {
    /// Built at runtime rather than committed: `.loca.json` is a dotfile, and
    /// SwiftPM's resource copying is not a thing to bet a test on.
    private func withFolder(_ contents: String?, _ body: (URL) throws -> Void) throws {
        let folder = URL(filePath: NSTemporaryDirectory())
            .appending(path: "loca-shared-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        if let contents {
            try Data(contents.utf8).write(to: SharedProjectFile.url(in: folder))
        }
        try body(folder)
    }

    private func project(
        slug: String = "app", port: Int = 3000, command: String? = "pnpm dev",
        autoStart: Bool = false, keepAlive: Bool = true
    ) -> Project {
        Project(
            slug: slug,
            folder: URL(filePath: "/Users/me/code/app"),
            port: port,
            runner: command.map { Runner(command: $0, autoStart: autoStart, keepAlive: keepAlive) })
    }

    // MARK: - Reading

    @Test func aWellFormedFileReads() throws {
        try withFolder(
            #"{"version":1,"slug":"api","port":4000,"runner":{"command":"pnpm dev","keepAlive":true}}"#
        ) { folder in
            let file = try #require(SharedProjectFile.read(from: folder))
            #expect(file.slug == "api")
            #expect(file.port == 4000)
            #expect(file.runner?.command == "pnpm dev")
            #expect(file.runner?.keepAlive == true)
        }
    }

    @Test func aFolderWithNoFileReadsAsNil() throws {
        try withFolder(nil) { folder in
            #expect(SharedProjectFile.read(from: folder) == nil)
        }
    }

    /// This file comes from a repository somebody else may have written, and a
    /// typo in it must not stop the folder from being registered at all — the
    /// detector just falls back to guessing.
    @Test(
        arguments: [
            "not json at all",
            #"{"version":99,"slug":"api","port":4000}"#,
            #"{"version":1,"slug":"Bad Slug","port":4000}"#,
            #"{"version":1,"slug":"api","port":0}"#,
            #"{"version":1,"slug":"api","port":99999}"#,
            #"{"version":1,"port":4000}"#,
        ])
    func unusableContentReadsAsNilRatherThanThrowing(contents: String) throws {
        try withFolder(contents) { folder in
            #expect(SharedProjectFile.read(from: folder) == nil)
        }
    }

    @Test func validationNamesWhatIsWrong() {
        #expect(throws: SharedProjectFileError.unsupportedVersion(99)) {
            try SharedProjectFile(version: 99, slug: "api", port: 4000).validated()
        }
        #expect(throws: SharedProjectFileError.invalidSlug("Bad Slug")) {
            try SharedProjectFile(slug: "Bad Slug", port: 4000).validated()
        }
        #expect(throws: SharedProjectFileError.portOutOfRange(0)) {
            try SharedProjectFile(slug: "api", port: 0).validated()
        }
    }

    // MARK: - Writing

    @Test func writeThenReadRoundTrips() throws {
        try withFolder(nil) { folder in
            let file = SharedProjectFile(from: project(slug: "api", port: 4000))
            try file.write(to: folder)
            #expect(SharedProjectFile.read(from: folder) == file)
        }
    }

    /// It is going into somebody's repository, so it has to be readable in a
    /// diff.
    @Test func theWrittenFileIsFormattedForADiff() throws {
        try withFolder(nil) { folder in
            try SharedProjectFile(from: project()).write(to: folder)
            let text = try String(
                contentsOf: SharedProjectFile.url(in: folder), encoding: .utf8)
            #expect(text.contains("\"slug\" : \"app\""))
            // Without the trailing newline every diff of this file carries a
            // "no newline at end of file" marker, which is noise in a review.
            #expect(text.hasSuffix("}\n"))
        }
    }

    /// "Start at login" is a statement about how somebody wants their own
    /// machine to behave, not a property of the project.
    @Test func autoStartIsNeverShared() throws {
        try withFolder(nil) { folder in
            try SharedProjectFile(from: project(autoStart: true)).write(to: folder)
            let text = try String(
                contentsOf: SharedProjectFile.url(in: folder), encoding: .utf8)
            #expect(!text.contains("autoStart"))
        }
    }

    @Test func aProjectWithNoRunnerSharesNoRunner() {
        let file = SharedProjectFile(from: project(command: nil))
        #expect(file.runner == nil)
    }

    // MARK: - Drift

    @Test func anIdenticalProjectHasNoDifferences() {
        let local = project()
        #expect(SharedProjectFile(from: local).differences(from: local).isEmpty)
    }

    @Test func aChangedPortIsReportedBothWays() {
        let file = SharedProjectFile(slug: "app", port: 4000)
        let differences = file.differences(from: project(slug: "app", port: 3000, command: nil))
        let port = differences.first { $0.field == "port" }
        #expect(port?.shared == "4000")
        #expect(port?.local == "3000")
    }

    @Test func aChangedSlugAndCommandAreBothReported() {
        let file = SharedProjectFile(
            slug: "api", port: 3000,
            runner: .init(command: "yarn dev", keepAlive: true))
        let fields = Set(file.differences(from: project()).map(\.field))
        #expect(fields == ["slug", "command"])
    }

    @Test func aRunnerAppearingOrDisappearingIsReported() {
        let withRunner = SharedProjectFile(
            slug: "app", port: 3000, runner: .init(command: "pnpm dev"))
        #expect(
            withRunner.differences(from: project(command: nil)).contains {
                $0.field == "command" && $0.local == "none"
            })

        let withoutRunner = SharedProjectFile(slug: "app", port: 3000)
        #expect(
            withoutRunner.differences(from: project()).contains {
                $0.field == "command" && $0.shared == "none"
            })
    }

    // MARK: - Applying

    /// The file may set the slug, the port, and the command. It has no business
    /// deciding the identifier, the folder, whether the domain is enabled, or
    /// the autoStart preference.
    @Test func applyingKeepsWhatTheFileHasNoBusinessSetting() {
        var local = project(slug: "app", port: 3000, autoStart: true)
        local.enabled = false
        let identifier = local.id
        let folder = local.folder

        let updated = SharedProjectFile(
            slug: "api", port: 4000,
            runner: .init(command: "yarn dev", keepAlive: false)
        ).applied(to: local)

        #expect(updated.slug == "api")
        #expect(updated.port == 4000)
        #expect(updated.runner?.command == "yarn dev")
        #expect(updated.runner?.keepAlive == false)

        #expect(updated.id == identifier)
        #expect(updated.folder == folder)
        #expect(updated.enabled == false)
        #expect(updated.runner?.autoStart == true)
    }

    @Test func applyingAFileWithNoRunnerLeavesTheLocalRunnerAlone() {
        let local = project(command: "pnpm dev")
        let updated = SharedProjectFile(slug: "app", port: 3000).applied(to: local)
        #expect(updated.runner?.command == "pnpm dev")
    }
}
