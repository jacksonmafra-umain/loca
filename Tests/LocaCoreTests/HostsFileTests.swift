import Foundation
import Testing

@testable import LocaCore

@Suite("HostsFile")
struct HostsFileTests {
    /// The shape of a real `/etc/hosts`, including the line that prompted this
    /// feature: one entry carrying a whole family of names.
    private let sample = """
        ##
        # Host Database
        #
        127.0.0.1	localhost
        255.255.255.255	broadcasthost
        ::1             localhost
        127.0.0.1 admin.linshare.local user.linshare.local linshare.local traefik.linshare.local
        127.0.0.1 shop.local
        ::1 ipv6app.local
        192.168.1.40 printer.local
        # 127.0.0.1 disabled.local
        127.0.0.1 api.example.com  # a trailing comment
        """

    // MARK: - Parsing

    @Test func commentsAndBlankLinesAreSkipped() {
        let entries = HostsFile.parse(sample)
        #expect(!entries.contains { $0.names.contains("disabled.local") })
        #expect(entries.allSatisfy { !$0.address.hasPrefix("#") })
    }

    @Test func aMultiNameLineKeepsEveryName() {
        let entry = HostsFile.parse(sample).first { $0.names.count == 4 }
        #expect(entry?.names == [
            "admin.linshare.local", "user.linshare.local", "linshare.local",
            "traefik.linshare.local",
        ])
    }

    /// A trailing comment is legal, and the names before it still count.
    @Test func aTrailingCommentIsStrippedWithoutLosingTheNames() {
        let entry = HostsFile.parse(sample).first { $0.names.contains("api.example.com") }
        #expect(entry?.names == ["api.example.com"])
    }

    @Test func lineNumbersAreOneBasedSoTheyCanBeQuoted() {
        let entry = HostsFile.parse(sample).first { $0.names.contains("linshare.local") }
        #expect(entry?.lineNumber == 7)
    }

    @Test func theRawLineIsKeptForShowingTheUser() {
        let entry = HostsFile.parse(sample).first { $0.names.contains("shop.local") }
        #expect(entry?.rawLine == "127.0.0.1 shop.local")
    }

    @Test(arguments: [("127.0.0.1", true), ("::1", true), ("192.168.1.40", false)])
    func loopbackIsRecognized(address: String, expected: Bool) {
        let entry = HostsFile.Entry(
            address: address, names: ["x.local"], lineNumber: 1, rawLine: "")
        #expect(entry.isLoopback == expected)
    }

    // MARK: - Candidates

    /// The insight the whole feature rests on: one Loca domain covers a family,
    /// because of the wildcard. Four hosts names collapse into one candidate.
    @Test func aFamilyOfNamesBecomesOneCandidate() {
        let candidates = HostsFile.candidates(in: sample)
        let linshare = try! #require(candidates.first { $0.base == "linshare" })

        #expect(linshare.names.count == 4)
        #expect(linshare.replacements.contains("admin.linshare.test"))
        #expect(linshare.replacements.contains("linshare.test"))
        #expect(linshare.lineNumbers == [7])
    }

    @Test func eachDistinctBaseIsItsOwnCandidate() {
        let bases = HostsFile.candidates(in: sample).map(\.base)
        #expect(bases == ["ipv6app", "linshare", "shop"])
    }

    /// A `.local` name pointed at a LAN address is a device on the network, not
    /// a local development domain, and replacing it with loopback would be
    /// wrong.
    @Test func aNonLoopbackEntryIsNeverACandidate() {
        #expect(!HostsFile.candidates(in: sample).contains { $0.base == "printer" })
    }

    @Test func aCommentedEntryIsNeverACandidate() {
        #expect(!HostsFile.candidates(in: sample).contains { $0.base == "disabled" })
    }

    @Test func namesOutsideDotLocalAreIgnored() {
        #expect(!HostsFile.candidates(in: sample).contains { $0.base == "example" })
        #expect(!HostsFile.candidates(in: sample).contains { $0.base == "localhost" })
    }

    @Test func candidatesAreSortedSoTheListIsStable() {
        let bases = HostsFile.candidates(in: sample).map(\.base)
        #expect(bases == bases.sorted())
    }

    @Test func aFileWithNothingRelevantYieldsNoCandidates() {
        #expect(HostsFile.candidates(in: "127.0.0.1 localhost\n::1 localhost\n").isEmpty)
        #expect(HostsFile.candidates(in: "").isEmpty)
    }

    /// Names spread over several lines still collapse into one candidate, and
    /// every line is recorded so all of them can be shown as redundant.
    @Test func namesSpreadAcrossLinesCollapseAndKeepEveryLineNumber() {
        let contents = """
            127.0.0.1 app.local
            127.0.0.1 api.app.local
            ::1 admin.app.local
            """
        let candidate = try! #require(HostsFile.candidates(in: contents).first)
        #expect(candidate.base == "app")
        #expect(candidate.names.count == 3)
        #expect(candidate.lineNumbers == [1, 2, 3])
    }

    // MARK: - Base labels

    @Test(
        arguments: [
            ("linshare.local", "linshare"),
            ("admin.linshare.local", "linshare"),
            ("a.b.c.myapp.local", "myapp"),
            ("My_App.local", "my-app"),
        ])
    func theBaseLabelIsTheOneBeforeDotLocal(name: String, expected: String) {
        #expect(HostsFile.baseLabel(of: name) == expected)
    }

    @Test(arguments: ["local", "example.com", "app.test", ".local"])
    func namesThatCannotYieldABaseAreRejected(name: String) {
        #expect(HostsFile.baseLabel(of: name) == nil)
    }

    // MARK: - Never writing

    /// The command is printed, never run. `sudo` on a file the whole machine
    /// shares is the user's to type.
    @Test func theEditCommandIsAdviceRatherThanAnAction() {
        #expect(HostsFile.editCommand == "sudo nano /etc/hosts")
        #expect(HostsFile.path == "/etc/hosts")
    }

    @Test func theLinesForACandidateCanBeLookedUp() {
        let entries = HostsFile.parse(sample)
        let lines = HostsFile.lines([7], in: entries)
        #expect(lines.count == 1)
        #expect(lines[0].names.contains("traefik.linshare.local"))
    }
}
