import Foundation
import Testing

@testable import LocaCore

@Suite("DockerPortMapper")
struct DockerPortMapperTests {
    private func containers() throws -> [DockerContainerPort] {
        try DockerPortMapper.decode(try Fixture.data("docker-containers.json"))
    }

    /// Docker reports a dual-stack publish twice, once for 0.0.0.0 and once for
    /// `::`. Both describe one mapping, so they collapse to one row.
    @Test func aDualStackPublishCollapsesToOneMapping() throws {
        let mapped = try containers()
        #expect(mapped.filter { $0.publicPort == 8080 }.count == 1)
    }

    @Test func aContainerWithNoPublishedPortIsSkipped() throws {
        #expect(!(try containers()).contains { $0.containerName == "app-worker-1" })
    }

    /// Only TCP matters: the inspector reads listening TCP sockets.
    @Test func nonTCPPublishesAreSkipped() throws {
        #expect(!(try containers()).contains { $0.publicPort == 6380 })
    }

    /// Docker prefixes every name with a slash, which has to come off or the
    /// UI shows "/app-web-1".
    @Test func theLeadingSlashIsStrippedFromTheName() throws {
        let row = try #require(try containers().first { $0.publicPort == 8080 })
        #expect(row.containerName == "app-web-1")
        #expect(row.image == "app-web")
        #expect(row.privatePort == 80)
    }

    @Test func decodingYieldsOneRowPerPublishedTCPPort() throws {
        #expect(try containers().count == 3)
    }

    @Test func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            _ = try DockerPortMapper.decode(Data("not json".utf8))
        }
    }

    @Test func anEmptyContainerListDecodesToNothing() throws {
        #expect(try DockerPortMapper.decode(Data("[]".utf8)).isEmpty)
    }

    // MARK: - Enrichment

    private let dockerRow = ListeningPort(
        command: "com.docker.backend", pid: 17571, user: "me", port: 8080, address: "*",
        family: .ipv6)
    private let nodeRow = ListeningPort(
        command: "node", pid: 12313, user: "me", port: 3000, address: "*", family: .ipv4)

    @Test func aDockerRowGetsItsContainerName() throws {
        let rows = DockerPortMapper.enrich([dockerRow], with: try containers())
        #expect(rows.count == 1)
        #expect(rows[0].owner == "app-web-1")
        #expect(rows[0].detail == "app-web → 80")
        #expect(rows[0].isContainer)
        #expect(rows[0].port == 8080)
        #expect(rows[0].pid == 17571)
    }

    @Test func aPlainProcessRowIsLeftAlone() throws {
        let rows = DockerPortMapper.enrich([nodeRow], with: try containers())
        #expect(rows[0].owner == "node")
        #expect(rows[0].detail == nil)
        #expect(!rows[0].isContainer)
    }

    /// A published port with no matching container — Docker restarted, or the
    /// socket answered a moment too late — keeps the raw process name rather
    /// than inventing one.
    @Test func anUnmatchedDockerRowKeepsTheRawCommand() throws {
        let unmatched = ListeningPort(
            command: "com.docker.backend", pid: 17571, user: "me", port: 9999, address: "*",
            family: .ipv4)
        let rows = DockerPortMapper.enrich([unmatched], with: try containers())
        #expect(rows[0].owner == "com.docker.backend")
        #expect(!rows[0].isContainer)
    }

    @Test func enrichmentPreservesRowOrderAndIdentity() throws {
        let rows = DockerPortMapper.enrich([nodeRow, dockerRow], with: try containers())
        #expect(rows.map(\.port) == [3000, 8080])
        #expect(rows.map(\.id) == [nodeRow.id, dockerRow.id])
    }

    @Test func withNoContainersEveryRowStaysAsItWas() {
        let rows = DockerPortMapper.enrich([nodeRow, dockerRow], with: [])
        #expect(rows.map(\.owner) == ["node", "com.docker.backend"])
        #expect(rows.allSatisfy { !$0.isContainer })
    }

    /// The domain column is the caller's to fill from Project.port, so
    /// enrichment must leave it empty rather than guess.
    @Test func theDomainIsLeftForTheCallerToFill() throws {
        #expect(DockerPortMapper.enrich([nodeRow], with: try containers())[0].domain == nil)
    }
}
