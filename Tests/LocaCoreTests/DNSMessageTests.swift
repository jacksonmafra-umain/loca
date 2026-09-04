import Foundation
import Testing

@testable import LocaCore

@Suite("DNSMessage")
struct DNSMessageTests {
    /// Builds a query the way a resolver would put it on the wire, so decoding
    /// is tested against real byte layout rather than against our own encoder.
    private func queryBytes(
        id: UInt16 = 0x1234,
        name: String = "projeto1.test",
        type: UInt16 = 1,
        recursionDesired: Bool = true
    ) -> Data {
        var bytes = Data()
        bytes.append(UInt8(id >> 8))
        bytes.append(UInt8(id & 0xFF))
        // Flags are two bytes: QR/OPCODE/AA/TC/RD in the high one, RA/Z/RCODE
        // in the low one. A standard query is 0x0100.
        bytes.append(recursionDesired ? 0x01 : 0x00)
        bytes.append(0x00)
        bytes.append(contentsOf: [0x00, 0x01])  // one question
        bytes.append(contentsOf: [0x00, 0x00])  // no answers
        bytes.append(contentsOf: [0x00, 0x00])  // no authority
        bytes.append(contentsOf: [0x00, 0x00])  // no additional
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: Array(label.utf8))
        }
        bytes.append(0x00)
        bytes.append(UInt8(type >> 8))
        bytes.append(UInt8(type & 0xFF))
        bytes.append(contentsOf: [0x00, 0x01])  // class IN
        return bytes
    }

    @Test func decodesAQueryFromRealWireBytes() throws {
        let message = try DNSCodec.decode(queryBytes())
        #expect(message.id == 0x1234)
        #expect(message.isQuery)
        #expect(message.recursionDesired)
        #expect(message.responseCode == 0)
        #expect(message.answers.isEmpty)
        #expect(message.questions.count == 1)
        #expect(message.questions[0].name == "projeto1.test")
        #expect(message.questions[0].type == .a)
        #expect(message.questions[0].klass == 1)
    }

    @Test func decodesASubdomainQuery() throws {
        let message = try DNSCodec.decode(queryBytes(name: "api.staging.projeto1.test"))
        #expect(message.questions[0].name == "api.staging.projeto1.test")
    }

    @Test func decodesAnAAAAQuestion() throws {
        #expect(try DNSCodec.decode(queryBytes(type: 28)).questions[0].type == .aaaa)
    }

    /// An unknown type keeps its number, so a response can echo the question
    /// exactly as it was asked.
    @Test func anUnknownTypeKeepsItsNumber() throws {
        let question = try DNSCodec.decode(queryBytes(type: 15)).questions[0]
        #expect(question.type == .other(15))
        #expect(question.type.rawValue == 15)
    }

    @Test func recursionDesiredIsReadFromTheFlags() throws {
        #expect(try DNSCodec.decode(queryBytes(recursionDesired: false)).recursionDesired == false)
    }

    // MARK: - Round trips

    @Test func anARecordResponseRoundTrips() throws {
        let query = try DNSCodec.decode(queryBytes())
        let response = DNSMessage(
            id: query.id,
            isQuery: false,
            recursionDesired: true,
            questions: query.questions,
            answers: [
                DNSAnswer(
                    name: "projeto1.test", type: .a, ttl: 60, data: Data([127, 0, 0, 1]))
            ],
            responseCode: 0)
        #expect(try DNSCodec.decode(DNSCodec.encode(response)) == response)
    }

    @Test func anAAAARecordResponseRoundTrips() throws {
        let loopback = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])
        let response = DNSMessage(
            id: 0xBEEF,
            isQuery: false,
            recursionDesired: false,
            questions: [DNSQuestion(name: "x.projeto1.test", type: .aaaa, klass: 1)],
            answers: [
                DNSAnswer(name: "x.projeto1.test", type: .aaaa, ttl: 60, data: loopback)
            ],
            responseCode: 0)
        #expect(try DNSCodec.decode(DNSCodec.encode(response)) == response)
    }

    @Test func anEmptyNoErrorResponseRoundTrips() throws {
        let response = DNSMessage(
            id: 1,
            isQuery: false,
            recursionDesired: true,
            questions: [DNSQuestion(name: "x.projeto1.test", type: .other(15), klass: 1)],
            answers: [],
            responseCode: 0)
        #expect(try DNSCodec.decode(DNSCodec.encode(response)) == response)
    }

    @Test func aNotImplementedResponseRoundTrips() throws {
        let response = DNSMessage(
            id: 7, isQuery: false, recursionDesired: false, questions: [], answers: [],
            responseCode: 4)
        #expect(try DNSCodec.decode(DNSCodec.encode(response)) == response)
    }

    @Test func theResponseCodeSurvivesEveryValue() throws {
        for code: UInt8 in 0...5 {
            let message = DNSMessage(
                id: 9, isQuery: false, recursionDesired: false, questions: [], answers: [],
                responseCode: code)
            #expect(try DNSCodec.decode(DNSCodec.encode(message)).responseCode == code)
        }
    }

    // MARK: - Rejection

    /// A malformed packet from any local process must be refused cleanly, not
    /// crash a root daemon.
    @Test func aTruncatedHeaderIsRejected() {
        #expect(throws: DNSCodecError.truncated) {
            _ = try DNSCodec.decode(Data([0x12, 0x34, 0x01]))
        }
    }

    @Test func anEmptyBufferIsRejected() {
        #expect(throws: DNSCodecError.truncated) {
            _ = try DNSCodec.decode(Data())
        }
    }

    @Test func aNameRunningPastTheEndIsRejected() {
        var bytes = queryBytes()
        bytes.removeLast(6)
        #expect(throws: DNSCodecError.truncated) {
            _ = try DNSCodec.decode(bytes)
        }
    }

    @Test func aLabelLongerThanSixtyThreeBytesIsRejected() {
        var bytes = Data([0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        bytes.append(0x40)  // 64, above the label limit but below the pointer marker
        bytes.append(contentsOf: Array(repeating: UInt8(0x61), count: 64))
        bytes.append(0x00)
        bytes.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        #expect(throws: DNSCodecError.unsupportedLabelLength) {
            _ = try DNSCodec.decode(bytes)
        }
    }

    /// Our own encoder never writes a pointer, and mis-parsing one would mean
    /// answering for a name the client did not ask about.
    @Test func aCompressionPointerIsRejected() {
        var bytes = Data([0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        bytes.append(contentsOf: [0xC0, 0x0C])
        bytes.append(contentsOf: [0x00, 0x01, 0x00, 0x01])
        #expect(throws: DNSCodecError.compressionPointerUnsupported) {
            _ = try DNSCodec.decode(bytes)
        }
    }

    @Test func anAnswerWithATruncatedRecordIsRejected() {
        var bytes = queryBytes()
        bytes[7] = 0x01  // claim one answer that is not there
        #expect(throws: DNSCodecError.truncated) {
            _ = try DNSCodec.decode(bytes)
        }
    }

    // MARK: - TCP framing

    @Test func theTCPLengthPrefixRoundTrips() throws {
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let framed = DNSCodec.prefixedForTCP(payload)
        #expect(framed.count == payload.count + 2)
        #expect(Array(framed.prefix(2)) == [0x00, 0x04])
        #expect(try DNSCodec.stripTCPPrefix(framed) == payload)
    }

    @Test func aShortTCPBufferIsRejected() {
        #expect(throws: DNSCodecError.truncated) {
            _ = try DNSCodec.stripTCPPrefix(Data([0x00]))
        }
        #expect(throws: DNSCodecError.truncated) {
            _ = try DNSCodec.stripTCPPrefix(Data([0x00, 0x08, 0x01, 0x02]))
        }
    }

    @Test func aTCPBufferWithTrailingBytesYieldsOnlyTheDeclaredLength() throws {
        let framed = Data([0x00, 0x02, 0xAA, 0xBB, 0xCC])
        #expect(try DNSCodec.stripTCPPrefix(framed) == Data([0xAA, 0xBB]))
    }

    @Test func aFullMessageSurvivesTCPFraming() throws {
        let query = try DNSCodec.decode(queryBytes())
        let framed = DNSCodec.prefixedForTCP(DNSCodec.encode(query))
        #expect(try DNSCodec.decode(try DNSCodec.stripTCPPrefix(framed)) == query)
    }
}
