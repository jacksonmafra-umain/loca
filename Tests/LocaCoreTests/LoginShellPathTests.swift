import Foundation
import Testing

@testable import LocaCore

@Suite("LoginShellPath")
struct LoginShellPathTests {
    /// `-i` is the fix. Without it the shell never reads `~/.zshrc` and nvm
    /// never runs, which is the whole reason the probe exists.
    @Test func theProbeAsksAnInteractiveLoginShell() {
        #expect(LoginShellPath.shell == "/bin/zsh")
        #expect(LoginShellPath.arguments.first == "-ilc")
    }

    @Test func theProbeMarksItsAnswer() {
        #expect(LoginShellPath.arguments.last?.contains(LoginShellPath.marker) == true)
    }

    @Test func theMarkedLineIsTheAnswer() {
        #expect(
            LoginShellPath.parse("loca-path:/opt/homebrew/bin:/usr/bin\n")
                == "/opt/homebrew/bin:/usr/bin")
    }

    /// A `~/.zshrc` prints whatever it likes — nvm notices, `compinit` warnings,
    /// a company banner. None of that is a PATH.
    @Test func startUpChatterAroundTheAnswerIsIgnored() {
        let output = """
            nvm is not compatible with the npm config "prefix" option
            Last login: Tue Sep  9
            loca-path:/opt/homebrew/bin:/usr/bin
            """
        #expect(LoginShellPath.parse(output) == "/opt/homebrew/bin:/usr/bin")
    }

    /// A `~/.zshrc` that re-execs the shell answers twice, and only the shell we
    /// would actually get is worth writing down.
    @Test func theLastAnswerWins() {
        let output = "loca-path:/usr/bin\nloca-path:/opt/homebrew/bin:/usr/bin\n"
        #expect(LoginShellPath.parse(output) == "/opt/homebrew/bin:/usr/bin")
    }

    @Test func unmarkedOutputIsNoAnswer() {
        #expect(LoginShellPath.parse("/opt/homebrew/bin:/usr/bin\n") == nil)
        #expect(LoginShellPath.parse("") == nil)
    }

    /// An empty answer is not one. The caller leaves PATH out of the agent
    /// rather than writing a PATH with nothing in it.
    @Test func anEmptyAnswerIsNoAnswer() {
        #expect(LoginShellPath.parse("loca-path:\n") == nil)
        #expect(LoginShellPath.parse("loca-path:   \n") == nil)
    }
}
