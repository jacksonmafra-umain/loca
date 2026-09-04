import Foundation
import Testing

@testable import LocaCore

@Suite("Paths")
struct PathsTests {
    private let paths = Paths(home: URL(filePath: "/Users/test"))

    private func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    @Test func userPathsDeriveFromTheInjectedHome() {
        #expect(path(paths.supportDirectory) == "/Users/test/Library/Application Support/dev.loca")
        #expect(
            path(paths.configFile)
                == "/Users/test/Library/Application Support/dev.loca/config.json")
        #expect(path(paths.logDirectory) == "/Users/test/Library/Logs/dev.loca")
        #expect(path(paths.launchAgentsDirectory) == "/Users/test/Library/LaunchAgents")
    }

    @Test func perProjectPathsUseTheSlug() {
        #expect(
            path(paths.runnerLog(slug: "projeto1"))
                == "/Users/test/Library/Logs/dev.loca/projeto1.log")
        #expect(
            path(paths.runnerPlist(slug: "projeto1"))
                == "/Users/test/Library/LaunchAgents/dev.loca.run.projeto1.plist")
    }

    @Test func systemPathsAreFixed() {
        #expect(path(Paths.resolverFile) == "/etc/resolver/test")
        #expect(path(Paths.resolverDirectory) == "/etc/resolver")
        #expect(path(Paths.helperStateDirectory) == "/Library/Application Support/dev.loca")
        #expect(path(Paths.caddyfile) == "/Library/Application Support/dev.loca/Caddyfile")
        #expect(path(Paths.caddyDataDirectory) == "/Library/Application Support/dev.loca/caddy-data")
    }

    /// The DNS port is deliberately unprivileged: `/etc/resolver` accepts a
    /// custom port, so the responder never needs to bind 53.
    @Test func theDNSPortIsUnprivileged() {
        #expect(Paths.dnsPort == 53531)
        #expect(Paths.dnsPort > 1024)
    }

    @Test func theCaddyAdminAddressIsLoopbackOnly() {
        #expect(Paths.caddyAdmin == "127.0.0.1:2019")
        #expect(Paths.caddyAdmin.hasPrefix("127.0.0.1:"))
    }

    @Test func identifiersMatchTheSpec() {
        #expect(Paths.bundleIdentifier == "dev.loca")
        #expect(Paths.helperLabel == "dev.loca.helper")
        #expect(Paths.runnerLabel(slug: "projeto1") == "dev.loca.run.projeto1")
    }

    @Test func defaultingToTheRealHomeStillProducesAbsolutePaths() {
        #expect(path(Paths().configFile).hasPrefix("/"))
    }
}
