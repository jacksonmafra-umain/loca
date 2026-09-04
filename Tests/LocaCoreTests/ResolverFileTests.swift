import Foundation
import Testing

@testable import LocaCore

@Suite("ResolverFile")
struct ResolverFileTests {
    @Test func theDefaultContentIsExact() {
        #expect(
            ResolverFile.content() == """
                # managed by Loca (dev.loca)
                nameserver 127.0.0.1
                port 53531

                """)
    }

    @Test func thePortIsInjectable() {
        #expect(ResolverFile.content(port: 5300).contains("port 5300"))
        #expect(!ResolverFile.content(port: 5300).contains("53531"))
    }

    /// The marker is how the helper tells its own file from a hand-written one
    /// it must back up instead of overwrite.
    @Test func ourOwnContentIsRecognized() {
        #expect(ResolverFile.isManagedByLoca(ResolverFile.content()))
        #expect(ResolverFile.isManagedByLoca(ResolverFile.content(port: 1234)))
    }

    @Test func aHandWrittenFileIsNotClaimed() {
        #expect(!ResolverFile.isManagedByLoca("nameserver 127.0.0.1\nport 53531\n"))
        #expect(!ResolverFile.isManagedByLoca("nameserver 9.9.9.9\n"))
        #expect(!ResolverFile.isManagedByLoca(""))
    }

    /// Someone may well have reformatted the file by hand while keeping the
    /// marker; that still counts as ours.
    @Test func theMarkerIsRecognizedAnywhereInTheFile() {
        #expect(
            ResolverFile.isManagedByLoca("nameserver 127.0.0.1\n# managed by Loca (dev.loca)\n"))
    }

    @Test func theContentPointsAtTheLoopbackResponder() {
        #expect(ResolverFile.content().contains("nameserver 127.0.0.1"))
    }

    /// resolver(5) needs each directive on its own line, and the file must end
    /// with a newline or the last directive is ignored.
    @Test func theContentIsNewlineTerminated() {
        #expect(ResolverFile.content().hasSuffix("\n"))
        #expect(ResolverFile.content().split(separator: "\n").count == 3)
    }
}
