import Foundation
import Testing

@testable import LocaCore

@Suite("LaunchAgentPlist")
struct LaunchAgentPlistTests {
    private let paths = Paths(home: URL(filePath: "/Users/test"))
    private let project = Project(
        slug: "projeto1", folder: URL(filePath: "/Users/test/code/projeto1"), port: 2020)

    private func dictionary(
        command: String = "pnpm dev", autoStart: Bool = false, keepAlive: Bool = true
    ) -> [String: Any] {
        LaunchAgentPlist.dictionary(
            for: project,
            runner: Runner(command: command, autoStart: autoStart, keepAlive: keepAlive),
            paths: paths)
    }

    @Test func theLabelMatchesTheProjectAgentLabel() {
        #expect(dictionary()["Label"] as? String == "dev.loca.run.projeto1")
        #expect(dictionary()["Label"] as? String == project.agentLabel)
    }

    /// The login shell is what resolves nvm and PATH. A GUI-spawned process
    /// inherits neither, so the command has to go through `zsh -lc`.
    @Test func theCommandRunsThroughALoginShell() {
        #expect(
            dictionary(command: "pnpm dev")["ProgramArguments"] as? [String] == [
                "/bin/zsh", "-lc", "pnpm dev",
            ])
    }

    @Test func theWorkingDirectoryIsTheProjectFolder() {
        #expect(dictionary()["WorkingDirectory"] as? String == "/Users/test/code/projeto1")
    }

    @Test func bothStreamsGoToTheSameLogFile() {
        let expected = "/Users/test/Library/Logs/dev.loca/projeto1.log"
        #expect(dictionary()["StandardOutPath"] as? String == expected)
        #expect(dictionary()["StandardErrorPath"] as? String == expected)
    }

    @Test func autoStartMapsToRunAtLoad() {
        #expect(dictionary(autoStart: true)["RunAtLoad"] as? Bool == true)
        #expect(dictionary(autoStart: false)["RunAtLoad"] as? Bool == false)
    }

    /// KeepAlive restarts on a crash but not on a clean exit, which is the
    /// difference between supervising a dev server and fighting a user who
    /// stopped it on purpose.
    @Test func keepAliveMapsToRestartOnFailureOnly() {
        let keepAlive = dictionary(keepAlive: true)["KeepAlive"] as? [String: Bool]
        #expect(keepAlive == ["SuccessfulExit": false])
    }

    /// Absent rather than false: launchd treats `KeepAlive: false` and a
    /// missing key the same, and an absent key is the clearer statement.
    @Test func keepAliveIsAbsentWhenNotWanted() {
        #expect(dictionary(keepAlive: false)["KeepAlive"] == nil)
    }

    @Test func theProcessTypeIsInteractive() {
        #expect(dictionary()["ProcessType"] as? String == "Interactive")
    }

    @Test func theEnvironmentCarriesTheSlugAndPort() {
        let environment = dictionary()["EnvironmentVariables"] as? [String: String]
        #expect(environment == ["LOCA_SLUG": "projeto1", "PORT": "2020"])
    }

    @Test func serializedDataDecodesBackToTheSameKeys() throws {
        let data = try LaunchAgentPlist.data(
            for: project, runner: Runner(command: "pnpm dev", autoStart: true), paths: paths)
        let decoded =
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let plist = try #require(decoded)
        #expect(plist["Label"] as? String == "dev.loca.run.projeto1")
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["ProgramArguments"] as? [String] == ["/bin/zsh", "-lc", "pnpm dev"])
        #expect(plist["KeepAlive"] as? [String: Bool] == ["SuccessfulExit": false])
    }

    @Test func serializedDataIsAnXMLPlist() throws {
        let data = try LaunchAgentPlist.data(
            for: project, runner: Runner(command: "pnpm dev"), paths: paths)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("<?xml"))
    }

    @Test func aProjectWithNoRunnerCannotProduceAPlist() {
        #expect(throws: LaunchAgentPlistError.missingRunner) {
            _ = try LaunchAgentPlist.data(for: project, paths: paths)
        }
    }

    @Test func aProjectWithARunnerProducesAPlistFromItsOwnRunner() throws {
        var withRunner = project
        withRunner.runner = Runner(command: "yarn dev", autoStart: true)
        let data = try LaunchAgentPlist.data(for: withRunner, paths: paths)
        let plist =
            try #require(
                PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == ["/bin/zsh", "-lc", "yarn dev"])
    }
}
