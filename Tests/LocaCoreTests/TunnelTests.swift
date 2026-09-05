import Foundation
import Testing

@testable import LocaCore

@Suite("TunnelCommand")
struct TunnelCommandTests {
    @Test func cloudflaredPointsAtTheUpstreamAndNeverUpdatesItself() {
        let arguments = TunnelCommand.arguments(for: .cloudflared, port: 3001)
        #expect(arguments == ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:3001"])
    }

    @Test func ngrokIsAskedForLogfmtOnStdout() {
        let arguments = TunnelCommand.arguments(for: .ngrok, port: 8080)
        #expect(arguments == ["http", "8080", "--log", "stdout", "--log-format", "logfmt"])
    }

    /// The port reaches the command line as digits. An `Int` interpolated
    /// somewhere that formats numbers becomes "2 020", and a tunnel to port
    /// "2 020" fails in a way nobody would guess from the UI.
    @Test func thePortIsPlainDigits() {
        #expect(TunnelCommand.arguments(for: .ngrok, port: 2020).contains("2020"))
        #expect(
            TunnelCommand.arguments(for: .cloudflared, port: 2020)
                .contains("http://127.0.0.1:2020"))
    }
}

@Suite("TunnelBinary")
struct TunnelBinaryTests {
    @Test func pathIsSearchedBeforeTheHomebrewFallbacks() {
        let found = TunnelBinary.locate(
            .cloudflared,
            path: "/somewhere/bin:/elsewhere/bin",
            extraDirectories: ["/opt/homebrew/bin"],
            isExecutable: { $0 == "/elsewhere/bin/cloudflared" || $0 == "/opt/homebrew/bin/cloudflared" })
        #expect(found?.path() == "/elsewhere/bin/cloudflared")
    }

    /// An app launched from Finder inherits launchd's PATH, which holds none
    /// of the places a developer installs things. Without the fallbacks the
    /// feature would look broken to everyone who did not launch from a shell.
    @Test func homebrewIsFoundWhenThePathHasNothing() {
        let found = TunnelBinary.locate(
            .ngrok,
            path: "/usr/bin:/bin:/usr/sbin:/sbin",
            isExecutable: { $0 == "/opt/homebrew/bin/ngrok" })
        #expect(found?.path() == "/opt/homebrew/bin/ngrok")
    }

    @Test func nothingInstalledIsNil() {
        #expect(TunnelBinary.locate(.ngrok, path: "/usr/bin", isExecutable: { _ in false }) == nil)
    }

    @Test func anEmptyPathStillChecksTheFallbacks() {
        let found = TunnelBinary.locate(
            .cloudflared, path: nil, isExecutable: { $0 == "/usr/local/bin/cloudflared" })
        #expect(found?.path() == "/usr/local/bin/cloudflared")
    }
}

@Suite("TunnelOutputParser")
struct TunnelOutputParserTests {
    // MARK: - cloudflared

    /// The real banner: the URL sits inside pipes and padding, so anything
    /// that reads to the end of the line picks up the frame with it.
    @Test func cloudflaredURLIsReadOutOfItsBanner() {
        let line =
            "2026-09-05T10:57:43Z INF |  https://trustee-regard-largely-dakota.trycloudflare.com                    |"
        #expect(
            TunnelOutputParser.event(in: line, from: .cloudflared)
                == .url("https://trustee-regard-largely-dakota.trycloudflare.com"))
    }

    @Test func cloudflaredChatterIsNotAnEvent() {
        let lines = [
            "2026-09-05T10:57:37Z INF Requesting new quick Tunnel on trycloudflare.com...",
            "2026-09-05T10:57:43Z INF Version 2026.8.2",
            "2026-09-05T10:57:43Z INF Initial protocol quic",
        ]
        for line in lines {
            #expect(TunnelOutputParser.event(in: line, from: .cloudflared) == nil)
        }
    }

    /// The terms-of-use paragraph mentions cloudflare.com URLs. None of them
    /// is the tunnel, and announcing one as the address would send the user
    /// somewhere unrelated.
    @Test func aLinkThatIsNotTheTunnelIsIgnored() {
        let line =
            "2026-09-05T10:57:29Z INF ... subject to the Cloudflare Online Services Terms of Use (https://www.cloudflare.com/website-terms/) ..."
        #expect(TunnelOutputParser.event(in: line, from: .cloudflared) == nil)
    }

    @Test func cloudflaredFailureIsReportedWithoutItsTimestamp() {
        let line = "2026-09-05T10:57:43Z ERR failed to request quick Tunnel error=timeout"
        #expect(
            TunnelOutputParser.event(in: line, from: .cloudflared)
                == .failure("failed to request quick Tunnel error=timeout"))
    }

    // MARK: - ngrok

    @Test func ngrokURLComesFromTheStartedTunnelLine() {
        let line =
            "t=2026-09-05T12:57:56+0200 lvl=info msg=\"started tunnel\" obj=tunnels name=command_line addr=http://localhost:9 url=https://0e00-213-89-130-65.ngrok-free.app"
        #expect(
            TunnelOutputParser.event(in: line, from: .ngrok)
                == .url("https://0e00-213-89-130-65.ngrok-free.app"))
    }

    @Test func ngrokInfoLinesAreNotEvents() {
        let line =
            "t=2026-09-05T12:57:55+0200 lvl=info msg=\"client session established\" obj=tunnels.session"
        #expect(TunnelOutputParser.event(in: line, from: .ngrok) == nil)
    }

    /// `err=<nil>` rides along on ordinary info lines. Treating it as an error
    /// would fail every tunnel the moment it started.
    @Test func aNilErrorOnAnInfoLineIsNotAFailure() {
        let line =
            "t=2026-09-05T12:57:55+0200 lvl=info msg=\"open config file\" path=\"/x/ngrok.yml\" err=<nil>"
        #expect(TunnelOutputParser.event(in: line, from: .ngrok) == nil)
    }

    @Test func theAuthtokenRefusalIsSurfacedVerbatim() {
        let line =
            "t=2026-09-05T12:58:00+0200 lvl=eror msg=\"failed to auth\" obj=tunnels.session err=\"authentication failed: Usage of ngrok requires a verified account and authtoken.\\r\\n\\r\\nERR_NGROK_4018\\r\\n\""
        #expect(
            TunnelOutputParser.event(in: line, from: .ngrok)
                == .failure(
                    "authentication failed: Usage of ngrok requires a verified account and authtoken.\r\n\r\nERR_NGROK_4018\r\n"
                ))
    }

    @Test func anErrorLineWithNoErrorFieldFallsBackToItsMessage() {
        let line = "t=2026-09-05T12:58:00+0200 lvl=crit msg=\"could not start\" obj=app"
        #expect(
            TunnelOutputParser.event(in: line, from: .ngrok) == .failure("could not start"))
    }

    // MARK: - logfmt

    /// `stopReq=` ends in `Req=`, and a naive search for `req=` finds it. The
    /// key has to start a token.
    @Test func aKeyIsOnlyReadWhenItStartsAToken() {
        let line = "lvl=info msg=\"received stop request\" stopReq=\"{err:<nil>}\" req=wanted"
        #expect(TunnelOutputParser.logfmt(line, key: "req") == "wanted")
    }

    @Test func quotedValuesKeepTheirSpacesAndEscapes() {
        let line = #"lvl=eror msg="it said \"no\" twice" obj=x"#
        #expect(TunnelOutputParser.logfmt(line, key: "msg") == #"it said "no" twice"#)
    }

    @Test func aMissingKeyIsNil() {
        #expect(TunnelOutputParser.logfmt("lvl=info msg=hello", key: "url") == nil)
    }
}

@Suite("TunnelProvider")
struct TunnelProviderTests {
    /// Both are offered, and the UI iterates the enum rather than listing them
    /// again somewhere it can drift.
    @Test func bothProvidersAreOffered() {
        #expect(TunnelProvider.allCases == [.cloudflared, .ngrok])
    }

    @Test func onlyNgrokNeedsAnAccount() {
        #expect(TunnelProvider.cloudflared.needsAccount == false)
        #expect(TunnelProvider.cloudflared.accountHint == nil)
        #expect(TunnelProvider.ngrok.needsAccount)
        #expect(TunnelProvider.ngrok.accountHint != nil)
    }

    /// The raw value reaches `config.json`, so renaming a case silently
    /// invalidates every file already written.
    @Test func rawValuesArePersisted() {
        #expect(TunnelProvider.cloudflared.rawValue == "cloudflared")
        #expect(TunnelProvider.ngrok.rawValue == "ngrok")
    }
}
