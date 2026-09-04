import Foundation
import Testing

@testable import LocaCore

@Suite("LaunchctlStatus")
struct LaunchctlStatusTests {
    @Test func aRunningServiceYieldsItsPID() throws {
        let status = LaunchctlStatusParser.parse(
            try Fixture.text("launchctl-running.txt"), exitCode: 0)
        #expect(status.state == .running(pid: 35151))
        #expect(status.runs == 2)
        #expect(status.lastExitStatus == 0)
        #expect(status.pid == 35151)
        #expect(status.isRunning)
    }

    @Test func anExitedServiceYieldsItsLastExitCode() throws {
        let status = LaunchctlStatusParser.parse(
            try Fixture.text("launchctl-exited.txt"), exitCode: 0)
        #expect(status.state == .notRunning)
        #expect(status.lastExitStatus == 3)
        #expect(status.runs == 1)
        #expect(status.pid == nil)
        #expect(!status.isRunning)
    }

    /// `launchctl` on macOS 26 prints "last exit code"; older releases printed
    /// "last exit status". Both are accepted, because the alternative is a
    /// status panel that silently shows nothing after an OS update.
    @Test func theLegacyExitStatusKeyIsStillUnderstood() throws {
        let status = LaunchctlStatusParser.parse(
            try Fixture.text("launchctl-legacy-exit-status.txt"), exitCode: 0)
        #expect(status.state == .notRunning)
        #expect(status.lastExitStatus == 256)
        #expect(status.runs == 4)
    }

    @Test func anUnknownServiceIsNotLoaded() throws {
        let status = LaunchctlStatusParser.parse(
            try Fixture.text("launchctl-notfound.txt"), exitCode: 113)
        #expect(status.state == .notLoaded)
        #expect(status.lastExitStatus == nil)
        #expect(status.runs == nil)
    }

    /// A non-zero exit is authoritative on its own, but the message is checked
    /// too: `launchctl` has been known to report failure on stdout with a zero
    /// exit, and treating that as "running with no pid" would be a lie.
    @Test func theNotFoundMessageAloneIsEnough() {
        let status = LaunchctlStatusParser.parse(
            "Could not find service \"dev.loca.run.x\" in domain for user gui: 501", exitCode: 0)
        #expect(status.state == .notLoaded)
    }

    @Test func emptyOutputIsNotLoaded() {
        #expect(LaunchctlStatusParser.parse("", exitCode: 0).state == .notLoaded)
    }

    /// A `pid` key must not be matched inside another word, or a line such as
    /// "proxy pid = 1" would be read as the service's own.
    @Test func thePIDIsReadFromItsOwnKeyOnly() {
        let output = """
            gui/501/dev.loca.run.x = {
            \tstate = running
            \tspid = 999
            \tpid = 4242
            }
            """
        #expect(LaunchctlStatusParser.parse(output, exitCode: 0).state == .running(pid: 4242))
    }
}
