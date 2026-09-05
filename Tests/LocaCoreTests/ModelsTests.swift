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

    /// Ports are rendered as digits, never as formatted numbers. Interpolating
    /// an Int into SwiftUI's Text goes through LocalizedStringKey, which
    /// formats it — port 2020 came out as "2 020" on screen until these
    /// existed.
    @Test func theUpstreamCarriesNoThousandsSeparator() {
        let project = Project(slug: "a", folder: URL(filePath: "/tmp/a"), port: 2020)
        #expect(project.upstream == "127.0.0.1:2020")
        #expect(project.portText == "2020")
        #expect(!project.upstream.contains(" "))
        #expect(!project.upstream.contains(","))
    }

    @Test(arguments: [1, 80, 2020, 8080, 54623, 65535])
    func everyPortRendersAsPlainDigits(port: Int) {
        let project = Project(slug: "a", folder: URL(filePath: "/tmp/a"), port: port)
        #expect(project.portText == String(port))
        #expect(project.upstream == "127.0.0.1:" + String(port))
    }

    @Test func aProjectWithoutARunnerStaysDecodable() throws {
        let project = Project(slug: "api", folder: URL(filePath: "/tmp/api"), port: 8080)
        #expect(project.runner == nil)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.runner == nil)
    }

    /// A config written before tunnels existed has no such key, and refusing
    /// to read it would lose every registration the user has.
    @Test func aProjectFromBeforeTunnelsStillDecodes() throws {
        let json = """
            {"id":"6BC1D7FE-2B2E-4E3E-9A1C-9E0B4D4B0F11","slug":"api",
             "folder":"/tmp/api","port":8080,"enabled":true}
            """
        let decoded = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(decoded.tunnelProvider == nil)
        #expect(decoded.slug == "api")
    }

    @Test func theChosenProviderSurvivesARoundTrip() throws {
        let project = Project(
            slug: "api", folder: URL(filePath: "/tmp/api"), port: 8080,
            tunnelProvider: .ngrok)
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.tunnelProvider == .ngrok)
        #expect(decoded == project)
    }

    /// Nothing in the file says a tunnel was open, because nothing may reopen
    /// one without being asked.
    @Test func noProviderMeansNoKeyInTheFile() throws {
        let project = Project(slug: "api", folder: URL(filePath: "/tmp/api"), port: 8080)
        let json = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        #expect(!json.contains("tunnel"))
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
