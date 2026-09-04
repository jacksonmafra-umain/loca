import Foundation
import Testing

@testable import LocaCore

@Suite("Models")
struct ModelsTests {
    @Test func projectRoundTripsThroughJSON() throws {
        let project = Project(
            slug: "projeto1",
            folder: URL(filePath: "/tmp/p1"),
            port: 2020,
            runner: Runner(command: "pnpm dev", autoStart: true, keepAlive: true)
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == project)
    }

    @Test func derivedNamesFollowTheSpec() {
        let project = Project(slug: "projeto1", folder: URL(filePath: "/tmp/p1"), port: 2020)
        #expect(project.domain == "projeto1.test")
        #expect(project.wildcardDomain == "*.projeto1.test")
        #expect(project.agentLabel == "dev.loca.run.projeto1")
    }

    @Test func aProjectWithoutARunnerStaysDecodable() throws {
        let project = Project(slug: "api", folder: URL(filePath: "/tmp/api"), port: 8080)
        #expect(project.runner == nil)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.runner == nil)
    }

    @Test func runnerDefaultsToSupervisedButNotAutoStarted() {
        let runner = Runner(command: "npm run dev")
        #expect(runner.autoStart == false)
        #expect(runner.keepAlive == true)
    }

    @Test func configDefaultsToCurrentVersionAndNoProjects() {
        let config = LocaConfig()
        #expect(config.version == 1)
        #expect(config.version == LocaConfig.currentVersion)
        #expect(config.projects.isEmpty)
    }

    @Test func configRoundTripsThroughJSON() throws {
        let config = LocaConfig(projects: [
            Project(slug: "a", folder: URL(filePath: "/tmp/a"), port: 3000),
            Project(slug: "b", folder: URL(filePath: "/tmp/b"), port: 3001, enabled: false),
        ])
        let decoded = try JSONDecoder().decode(
            LocaConfig.self, from: JSONEncoder().encode(config))
        #expect(decoded == config)
    }

    /// The folder is stored as a plain path, not a `file://` URL, so that
    /// `config.json` stays readable and no stale URL encoding creeps in.
    @Test func folderEncodesAsAPathNotAFileURL() throws {
        let project = Project(slug: "a", folder: URL(filePath: "/Users/me/code/a"), port: 3000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let json = String(decoding: try encoder.encode(project), as: UTF8.self)
        #expect(json.contains("\"folder\":\"/Users/me/code/a\""))
        #expect(!json.contains("file://"))
    }
}
