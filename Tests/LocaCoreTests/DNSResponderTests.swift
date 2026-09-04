import Foundation
import Testing

@testable import LocaCore

@Suite("DNSResponder")
struct DNSResponderTests {
    private func query(
        _ name: String = "api.projeto1.test", type: DNSRecordType = .a, id: UInt16 = 0x4242
    ) -> DNSMessage {
        DNSMessage(
            id: id,
            isQuery: true,
            recursionDesired: true,
            questions: [DNSQuestion(name: name, type: type)],
            answers: [],
            responseCode: 0)
    }

    @Test func anAQuestionIsAnsweredWithLoopback() {
        let response = DNSResponder.respond(to: query(type: .a))
        #expect(!response.isQuery)
        #expect(response.responseCode == 0)
        #expect(response.answers.count == 1)
        #expect(response.answers[0].type == .a)
        #expect(Array(response.answers[0].data) == [127, 0, 0, 1])
        #expect(response.answers[0].ttl == DNSResponder.ttl)
        #expect(response.answers[0].name == "api.projeto1.test")
    }

    @Test func anAAAAQuestionIsAnsweredWithIPv6Loopback() {
        let response = DNSResponder.respond(to: query(type: .aaaa))
        #expect(response.answers.count == 1)
        #expect(response.answers[0].type == .aaaa)
        #expect(
            Array(response.answers[0].data) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
    }

    /// Any name under the resolved TLD resolves, wildcard subdomains included.
    /// Whether a domain is actually registered is the proxy's business, not
    /// the resolver's.
    @Test(arguments: [
        "projeto1.test", "api.projeto1.test", "a.b.c.projeto1.test", "unregistered.test",
    ])
    func everyNameResolves(name: String) {
        let response = DNSResponder.respond(to: query(name))
        #expect(response.answers.count == 1)
        #expect(Array(response.answers[0].data) == [127, 0, 0, 1])
    }

    /// An empty NOERROR, never NXDOMAIN. A negative answer would let the
    /// resolver fall through to the next nameserver and resolve the name
    /// somewhere else entirely.
    @Test(arguments: [DNSRecordType.other(15), .other(16), .other(33), .other(255)])
    func anythingElseIsAnEmptyNoError(type: DNSRecordType) {
        let response = DNSResponder.respond(to: query(type: type))
        #expect(response.responseCode == 0)
        #expect(response.answers.isEmpty)
        #expect(response.questions == [DNSQuestion(name: "api.projeto1.test", type: type)])
    }

    @Test func theResponseEchoesTheQueryIDAndQuestion() {
        let response = DNSResponder.respond(to: query("x.test", type: .a, id: 0xABCD))
        #expect(response.id == 0xABCD)
        #expect(response.questions == [DNSQuestion(name: "x.test", type: .a)])
        #expect(response.recursionDesired)
    }

    @Test func aQuestionWithNoQuestionsIsNotImplemented() {
        let empty = DNSMessage(
            id: 5, isQuery: true, recursionDesired: false, questions: [], answers: [],
            responseCode: 0)
        let response = DNSResponder.respond(to: empty)
        #expect(response.responseCode == 4)
        #expect(response.answers.isEmpty)
        #expect(!response.isQuery)
    }

    /// A response arriving on our listening socket is not something to answer.
    @Test func aMessageThatIsNotAQueryIsNotImplemented() {
        var notAQuery = query()
        notAQuery.isQuery = false
        #expect(DNSResponder.respond(to: notAQuery).responseCode == 4)
    }

    @Test func onlyTheFirstQuestionIsAnswered() {
        var multiple = query()
        multiple.questions.append(DNSQuestion(name: "other.test", type: .a))
        let response = DNSResponder.respond(to: multiple)
        #expect(response.answers.count == 1)
        #expect(response.answers[0].name == "api.projeto1.test")
        #expect(response.questions.count == 2)
    }

    @Test func theAnswerSurvivesAWireRoundTrip() throws {
        let response = DNSResponder.respond(to: query())
        #expect(try DNSCodec.decode(DNSCodec.encode(response)) == response)
    }
}
