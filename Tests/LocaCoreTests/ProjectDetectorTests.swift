import Foundation
import Testing

@testable import LocaCore

@Suite("ProjectDetector")
struct ProjectDetectorTests {
    private func detect(_ fixture: String) throws -> DetectionResult {
        ProjectDetector.detect(folder: try Fixture.url("Projects/\(fixture)"))
    }

    // MARK: - On-disk fixtures

    /// Next has no port in its config, so the framework default stands, and the
    /// lockfile picks the package manager.
    @Test func aNextProjectProposesTheNextDefaultAndPnpm() throws {
        let result = try detect("next")
        #expect(result.port == 3000)
        #expect(result.command == "pnpm dev")
        #expect(result.packageManager == "pnpm")
        #expect(!result.sources.isEmpty)
    }

    /// An explicit `server.port` beats the Vite default.
    @Test func aViteProjectReadsItsConfiguredPort() throws {
        let result = try detect("vite")
        #expect(result.port == 5174)
        #expect(result.command == "yarn dev")
        #expect(result.packageManager == "yarn")
        #expect(result.sources.contains { $0.contains("vite.config") })
    }

    @Test func aComposeProjectProposesItsFirstPublishedPort() throws {
        let result = try detect("compose")
        #expect(result.port == 8080)
        #expect(result.command == "docker compose up")
        #expect(result.sources.contains { $0.contains("docker-compose.yml") })
    }

    /// No `dev` script, so `start` is used; no lockfile, so npm.
    @Test func aPlainNodeProjectFallsBackToTheStartScript() throws {
        let result = try detect("node-start")
        #expect(result.command == "npm run start")
        #expect(result.packageManager == "npm")
        #expect(result.port == nil)
    }

    /// Nothing to go on. The sheet then asks the user, rather than proposing a
    /// port that happens to be free.
    @Test func aBareFolderProposesNothing() throws {
        let result = try detect("bare")
        #expect(result.port == nil)
        #expect(result.command == nil)
        #expect(result.sources.isEmpty)
    }

    @Test func aMissingFolderProposesNothing() {
        let result = ProjectDetector.detect(folder: URL(filePath: "/nonexistent/\(UUID())"))
        #expect(result.port == nil)
        #expect(result.command == nil)
    }

    // MARK: - Built at runtime

    /// `.env` cases are written into a temporary folder rather than committed:
    /// a real `.env` in the repository is a file no one should have to think
    /// about, and tooling tends to treat it as a secret.
    private func withProject(
        _ files: [String: String], _ body: (URL) throws -> Void
    ) throws {
        let folder = URL(filePath: NSTemporaryDirectory())
            .appending(path: "loca-detect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        for (name, contents) in files {
            try Data(contents.utf8).write(to: folder.appending(path: name))
        }
        try body(folder)
    }

    /// `.env` is consulted before anything else, because a port written there
    /// is the one the server will actually use.
    @Test func aPortInDotEnvWinsOverEveryFrameworkDefault() throws {
        try withProject([
            ".env": "NODE_ENV=development\nPORT=4321\n",
            "package.json": #"{"scripts":{"dev":"next dev"}}"#,
            "next.config.js": "module.exports = {};",
        ]) { folder in
            let result = ProjectDetector.detect(folder: folder)
            #expect(result.port == 4321)
            #expect(result.command == "npm run dev")
            #expect(result.sources.contains { $0.contains(".env") })
        }
    }

    @Test func dotEnvLocalIsConsultedToo() throws {
        try withProject([".env.local": "PORT=7777"]) { folder in
            #expect(ProjectDetector.detect(folder: folder).port == 7777)
        }
    }

    @Test func aCommentedOutPortIsIgnored() throws {
        try withProject([".env": "# PORT=1111\nPORT=2222\n"]) { folder in
            #expect(ProjectDetector.detect(folder: folder).port == 2222)
        }
    }

    @Test func quotesAndSpacesAroundAnEnvPortAreTolerated() throws {
        try withProject([".env": #"PORT = "3456""#]) { folder in
            #expect(ProjectDetector.detect(folder: folder).port == 3456)
        }
    }

    /// A port baked into the dev script is as authoritative as one in `.env`,
    /// and far more common in a Vite or Next project.
    @Test func aPortFlagInsideTheDevScriptIsRead() throws {
        try withProject(["package.json": #"{"scripts":{"dev":"vite --port 4000"}}"#]) { folder in
            let result = ProjectDetector.detect(folder: folder)
            #expect(result.port == 4000)
            #expect(result.command == "npm run dev")
        }
    }

    @Test func theShortPortFlagIsReadToo() throws {
        try withProject(["package.json": #"{"scripts":{"dev":"next dev -p 4100"}}"#]) { folder in
            #expect(ProjectDetector.detect(folder: folder).port == 4100)
        }
    }

    @Test func anEqualsFormPortFlagIsReadToo() throws {
        try withProject(["package.json": #"{"scripts":{"dev":"vite --port=4200"}}"#]) { folder in
            #expect(ProjectDetector.detect(folder: folder).port == 4200)
        }
    }

    @Test(
        arguments: [
            ("pnpm-lock.yaml", "pnpm", "pnpm dev"),
            ("yarn.lock", "yarn", "yarn dev"),
            ("bun.lockb", "bun", "bun run dev"),
            ("package-lock.json", "npm", "npm run dev"),
        ])
    func theLockfilePicksThePackageManager(
        lockfile: String, manager: String, command: String
    ) throws {
        try withProject([
            "package.json": #"{"scripts":{"dev":"vite"}}"#,
            lockfile: "",
        ]) { folder in
            let result = ProjectDetector.detect(folder: folder)
            #expect(result.packageManager == manager)
            #expect(result.command == command)
        }
    }

    @Test func aViteConfigWithNoPortFallsBackToTheViteDefault() throws {
        try withProject([
            "package.json": #"{"scripts":{"dev":"vite"}}"#,
            "vite.config.js": "export default { plugins: [] };",
        ]) { folder in
            #expect(ProjectDetector.detect(folder: folder).port == 5173)
        }
    }

    @Test func malformedPackageJSONDoesNotDerailDetection() throws {
        try withProject([
            "package.json": "{ not json",
            "docker-compose.yml": "services:\n  web:\n    ports:\n      - \"9090:80\"\n",
        ]) { folder in
            let result = ProjectDetector.detect(folder: folder)
            #expect(result.port == 9090)
            #expect(result.command == "docker compose up")
        }
    }

    /// A compose file with only container-internal ports publishes nothing, so
    /// there is no host port to propose.
    @Test func composeWithNoPublishedPortProposesNoPort() throws {
        try withProject(["compose.yml": "services:\n  web:\n    expose:\n      - \"80\"\n"]) {
            folder in
            let result = ProjectDetector.detect(folder: folder)
            #expect(result.port == nil)
            #expect(result.command == "docker compose up")
        }
    }

    // MARK: - A committed .loca.json

    /// Explicit intent beats inference. Somebody writing the answer down
    /// should never be overruled by a guess from package.json.
    @Test func aSharedFileWinsOverEveryHeuristic() throws {
        try withProject([
            ".loca.json": #"{"version":1,"slug":"agreed","port":4242,"runner":{"command":"make dev","keepAlive":true}}"#,
            ".env": "PORT=1111",
            "package.json": #"{"scripts":{"dev":"vite --port 2222"}}"#,
            "vite.config.ts": "export default { server: { port: 3333 } };",
        ]) { folder in
            let result = ProjectDetector.detect(folder: folder)
            #expect(result.port == 4242)
            #expect(result.command == "make dev")
            #expect(result.suggestedSlug == "agreed")
            #expect(result.fromSharedFile)
            #expect(result.sources == [".loca.json (shared by the project)"])
        }
    }

    @Test func aSharedFileStillReportsThePackageManager() throws {
        try withProject([
            ".loca.json": #"{"version":1,"slug":"agreed","port":4242}"#,
            "pnpm-lock.yaml": "",
        ]) { folder in
            #expect(ProjectDetector.detect(folder: folder).packageManager == "pnpm")
        }
    }

    /// A typo in a file somebody else committed must not stop the folder from
    /// being registered — detection falls back to guessing.
    @Test func anUnusableSharedFileFallsBackToTheHeuristics() throws {
        try withProject([
            ".loca.json": #"{"version":1,"slug":"Bad Slug","port":4242}"#,
            "package.json": #"{"scripts":{"dev":"vite --port 2222"}}"#,
        ]) { folder in
            let result = ProjectDetector.detect(folder: folder)
            #expect(result.port == 2222)
            #expect(!result.fromSharedFile)
            #expect(result.suggestedSlug == nil)
        }
    }

    @Test func withoutASharedFileNothingIsSuggested() throws {
        let result = try detect("vite")
        #expect(result.suggestedSlug == nil)
        #expect(!result.fromSharedFile)
    }

    @Test func everyProposedValueNamesTheFileItCameFrom() throws {
        try withProject([
            ".env": "PORT=4321",
            "package.json": #"{"scripts":{"dev":"vite"}}"#,
            "pnpm-lock.yaml": "",
        ]) { folder in
            let sources = ProjectDetector.detect(folder: folder).sources
            #expect(sources.contains { $0.contains(".env") })
            #expect(sources.contains { $0.contains("package.json") })
        }
    }
}
