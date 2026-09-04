import Foundation
import Testing

@testable import LocaCore

@Suite("LsofParser")
struct LsofParserTests {
    private func rows() throws -> [ListeningPort] {
        LsofParser.parse(try Fixture.text("lsof-listen.txt"))
    }

    /// The fixture holds nine data lines: one is an exact duplicate, one is
    /// ESTABLISHED rather than LISTEN, and both are dropped.
    @Test func theHeaderDuplicatesAndNonListeningRowsAreDropped() throws {
        let parsed = try rows()
        #expect(parsed.count == 7)
        #expect(!parsed.contains { $0.command == "COMMAND" })
        #expect(!parsed.contains { $0.port == 11434 })
    }

    @Test func rowsAreSortedByPortThenPID() throws {
        let ports = try rows().map(\.port)
        #expect(ports == ports.sorted())
    }

    @Test func anIPv4RowParsesCompletely() throws {
        let row = try #require(try rows().first { $0.port == 3000 && $0.family == .ipv4 })
        #expect(row.command == "node")
        #expect(row.pid == 12313)
        #expect(row.user == "jackson.mafra")
        #expect(row.address == "*")
        #expect(!row.isDockerBackend)
    }

    /// The same process listening on both families is two rows, because a
    /// user looking for what holds a port wants to see both.
    @Test func bothAddressFamiliesSurviveAsSeparateRows() throws {
        let onPort3000 = try rows().filter { $0.port == 3000 }
        #expect(onPort3000.count == 2)
        #expect(Set(onPort3000.map(\.family)) == [.ipv4, .ipv6])
        #expect(Set(onPort3000.map(\.id)).count == 2)
    }

    @Test func aBracketedIPv6AddressParses() throws {
        let row = try #require(try rows().first { $0.port == 8099 })
        #expect(row.command == "Python")
        #expect(row.address == "::1")
        #expect(row.family == .ipv6)
    }

    /// Published container ports all surface as com.docker.backend, which is
    /// why the flag exists: the row is useless until a container name is
    /// resolved for it.
    @Test func theDockerBackendIsFlagged() throws {
        let row = try #require(try rows().first { $0.port == 5432 })
        #expect(row.command == "com.docker.backend")
        #expect(row.isDockerBackend)
        #expect(row.pid == 17571)
    }

    /// lsof escapes spaces in a command name as \x20, so the name has to be
    /// unescaped or it reaches the UI looking like a parser bug.
    @Test func escapedSpacesInACommandNameAreDecoded() throws {
        let row = try #require(try rows().first { $0.port == 49190 })
        #expect(row.command == "Vysor Helper (Renderer)")
    }

    @Test func aLoopbackAddressIsKept() throws {
        let row = try #require(try rows().first { $0.port == 3845 })
        #expect(row.address == "127.0.0.1")
        #expect(row.command == "Figma")
    }

    @Test func emptyInputYieldsNoRows() {
        #expect(LsofParser.parse("").isEmpty)
        #expect(LsofParser.parse("\n\n").isEmpty)
    }

    @Test func aMalformedLineIsSkippedRatherThanCrashing() {
        let output = """
            COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            garbage
            node 1 me 1u IPv4 0x1 0t0 TCP *:80 (LISTEN)
            node notanumber me 1u IPv4 0x1 0t0 TCP *:81 (LISTEN)
            node 2 me 1u IPv4 0x1 0t0 TCP *:notaport (LISTEN)
            """
        let parsed = LsofParser.parse(output)
        #expect(parsed.count == 1)
        #expect(parsed[0].port == 80)
    }

    /// The command name is the first field precisely because `+c 0` makes the
    /// column width variable, so no parsing may depend on column positions.
    @Test func theCommandFlagNeededForFullNamesIsDocumented() {
        #expect(LsofParser.arguments == ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN"])
    }
}
