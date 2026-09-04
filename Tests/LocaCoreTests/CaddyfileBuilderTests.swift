import Foundation
import Testing

@testable import LocaCore

@Suite("CaddyfileBuilder")
struct CaddyfileBuilderTests {
    private func project(
        _ slug: String, port: Int, enabled: Bool = true
    ) -> Project {
        Project(
            slug: slug, folder: URL(filePath: "/Users/me/code/\(slug)"), port: port,
            enabled: enabled)
    }

    private let globalBlock = """
        {
        \tadmin 127.0.0.1:2019
        \tstorage file_system {
        \t\troot "/Library/Application Support/dev.loca/caddy-data"
        \t}
        }

        """

    @Test func oneEnabledProjectProducesTheExpectedFile() {
        let output = CaddyfileBuilder.build(projects: [project("projeto1", port: 2020)])
        #expect(
            output == globalBlock + """

                projeto1.test, *.projeto1.test {
                \ttls internal
                \treverse_proxy 127.0.0.1:2020

                \thandle_errors {
                \t\trespond "Loca: projeto1.test is registered, but nothing is listening on 127.0.0.1:2020." {err.status_code}
                \t}
                }

                """)
    }

    @Test func noProjectsStillProducesAValidGlobalBlock() {
        #expect(CaddyfileBuilder.build(projects: []) == globalBlock)
    }

    @Test func aDisabledProjectProducesNoBlock() {
        let output = CaddyfileBuilder.build(projects: [
            project("off", port: 3000, enabled: false)
        ])
        #expect(output == globalBlock)
        #expect(!output.contains("off.test"))
    }

    /// Blocks are emitted in slug order so the generated file is stable, which
    /// is what makes a diff between two reloads readable.
    @Test func blocksAreEmittedInSlugOrder() {
        let output = CaddyfileBuilder.build(projects: [
            project("zeta", port: 3002),
            project("alpha", port: 3000),
            project("mid", port: 3001),
        ])
        let alpha = try! #require(output.range(of: "alpha.test"))
        let mid = try! #require(output.range(of: "mid.test"))
        let zeta = try! #require(output.range(of: "zeta.test"))
        #expect(alpha.lowerBound < mid.lowerBound)
        #expect(mid.lowerBound < zeta.lowerBound)
    }

    /// The apex and the wildcard share one block, so the internal CA issues the
    /// wildcard certificate alongside the apex one and subdomains just work.
    @Test func theApexAndWildcardShareOneBlock() {
        let output = CaddyfileBuilder.build(projects: [project("api", port: 4000)])
        #expect(output.contains("api.test, *.api.test {"))
        #expect(output.components(separatedBy: "reverse_proxy").count == 2)
    }

    @Test func everyEnabledProjectGetsItsOwnUpstream() {
        let output = CaddyfileBuilder.build(projects: [
            project("a", port: 3000),
            project("b", port: 3001),
            project("c", port: 3002, enabled: false),
        ])
        #expect(output.contains("reverse_proxy 127.0.0.1:3000"))
        #expect(output.contains("reverse_proxy 127.0.0.1:3001"))
        #expect(!output.contains("reverse_proxy 127.0.0.1:3002"))
    }

    /// The storage root contains spaces, so it has to be quoted or Caddy reads
    /// it as three separate arguments.
    @Test func theStorageRootIsQuoted() {
        #expect(
            CaddyfileBuilder.build(projects: []).contains(
                #"root "/Library/Application Support/dev.loca/caddy-data""#))
    }

    @Test func theAdminAndStorageAddressesAreInjectable() {
        let output = CaddyfileBuilder.build(
            projects: [],
            adminAddress: "127.0.0.1:9999",
            dataDirectory: URL(filePath: "/tmp/caddy"))
        #expect(output.contains("admin 127.0.0.1:9999"))
        #expect(output.contains(#"root "/tmp/caddy""#))
    }
}
