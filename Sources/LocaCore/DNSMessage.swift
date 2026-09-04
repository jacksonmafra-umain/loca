import Foundation

/// A DNS record type, keeping the wire number for anything we do not handle so
/// a response can echo the question exactly as it was asked.
public enum DNSRecordType: Equatable, Hashable, Sendable {
    case a
    case aaaa
    case other(UInt16)

    public init(rawValue: UInt16) {
        switch rawValue {
        case 1: self = .a
        case 28: self = .aaaa
        default: self = .other(rawValue)
        }
    }

    public var rawValue: UInt16 {
        switch self {
        case .a: return 1
        case .aaaa: return 28
        case .other(let value): return value
        }
    }
}

public struct DNSQuestion: Equatable, Hashable, Sendable {
    /// No trailing dot, e.g. `api.projeto1.test`.
    public var name: String
    public var type: DNSRecordType
    /// 1 is IN, the only class in practice.
    public var klass: UInt16

    public init(name: String, type: DNSRecordType, klass: UInt16 = 1) {
        self.name = name
        self.type = type
        self.klass = klass
    }
}

public struct DNSAnswer: Equatable, Hashable, Sendable {
    public var name: String
    public var type: DNSRecordType
    public var ttl: UInt32
    /// 4 bytes for an A record, 16 for AAAA.
    public var data: Data
    public var klass: UInt16

    public init(name: String, type: DNSRecordType, ttl: UInt32, data: Data, klass: UInt16 = 1) {
        self.name = name
        self.type = type
        self.ttl = ttl
        self.data = data
        self.klass = klass
    }
}

public struct DNSMessage: Equatable, Hashable, Sendable {
    public var id: UInt16
    public var isQuery: Bool
    public var recursionDesired: Bool
    public var questions: [DNSQuestion]
    public var answers: [DNSAnswer]
    /// 0 is NOERROR, 3 NXDOMAIN, 4 NOTIMP.
    public var responseCode: UInt8

    public init(
        id: UInt16,
        isQuery: Bool,
        recursionDesired: Bool,
        questions: [DNSQuestion],
        answers: [DNSAnswer],
        responseCode: UInt8
    ) {
        self.id = id
        self.isQuery = isQuery
        self.recursionDesired = recursionDesired
        self.questions = questions
        self.answers = answers
        self.responseCode = responseCode
    }
}

public enum DNSCodecError: Error, Equatable, Sendable {
    case truncated
    case unsupportedLabelLength
    /// A name written as a pointer into an earlier part of the message.
    ///
    /// Our encoder never writes one, and mis-parsing one would mean answering
    /// for a name the client did not ask about, so it is refused rather than
    /// guessed at.
    case compressionPointerUnsupported
}

/// Minimal DNS wire-format codec: enough for a responder that only ever
/// answers A and AAAA for one TLD.
///
/// Every decode path throws rather than trapping. This runs inside a root
/// daemon reachable by any local process, so a malformed packet has to be a
/// dropped packet, never a crash.
public enum DNSCodec {
    private static let headerLength = 12
    private static let maxLabelLength = 63
    private static let pointerMask: UInt8 = 0xC0

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> DNSMessage {
        let bytes = [UInt8](data)
        guard bytes.count >= headerLength else { throw DNSCodecError.truncated }

        let id = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let flagsHigh = bytes[2]
        let flagsLow = bytes[3]

        let questionCount = Int(UInt16(bytes[4]) << 8 | UInt16(bytes[5]))
        let answerCount = Int(UInt16(bytes[6]) << 8 | UInt16(bytes[7]))

        var cursor = headerLength

        var questions: [DNSQuestion] = []
        for _ in 0..<questionCount {
            let name = try readName(bytes, &cursor)
            let type = try readUInt16(bytes, &cursor)
            let klass = try readUInt16(bytes, &cursor)
            questions.append(
                DNSQuestion(name: name, type: DNSRecordType(rawValue: type), klass: klass))
        }

        var answers: [DNSAnswer] = []
        for _ in 0..<answerCount {
            let name = try readName(bytes, &cursor)
            let type = try readUInt16(bytes, &cursor)
            let klass = try readUInt16(bytes, &cursor)
            let ttl = try readUInt32(bytes, &cursor)
            let length = Int(try readUInt16(bytes, &cursor))
            guard cursor + length <= bytes.count else { throw DNSCodecError.truncated }
            let payload = Data(bytes[cursor..<(cursor + length)])
            cursor += length
            answers.append(
                DNSAnswer(
                    name: name, type: DNSRecordType(rawValue: type), ttl: ttl, data: payload,
                    klass: klass))
        }

        return DNSMessage(
            id: id,
            isQuery: flagsHigh & 0x80 == 0,
            recursionDesired: flagsHigh & 0x01 != 0,
            questions: questions,
            answers: answers,
            responseCode: flagsLow & 0x0F)
    }

    private static func readName(_ bytes: [UInt8], _ cursor: inout Int) throws -> String {
        var labels: [String] = []

        while true {
            guard cursor < bytes.count else { throw DNSCodecError.truncated }
            let length = bytes[cursor]

            if length == 0 {
                cursor += 1
                return labels.joined(separator: ".")
            }
            guard length & pointerMask != pointerMask else {
                throw DNSCodecError.compressionPointerUnsupported
            }
            guard length <= maxLabelLength else { throw DNSCodecError.unsupportedLabelLength }

            let start = cursor + 1
            let end = start + Int(length)
            guard end <= bytes.count else { throw DNSCodecError.truncated }

            labels.append(String(decoding: bytes[start..<end], as: UTF8.self))
            cursor = end
        }
    }

    private static func readUInt16(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt16 {
        guard cursor + 2 <= bytes.count else { throw DNSCodecError.truncated }
        defer { cursor += 2 }
        return UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], _ cursor: inout Int) throws -> UInt32 {
        guard cursor + 4 <= bytes.count else { throw DNSCodecError.truncated }
        defer { cursor += 4 }
        return UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16
            | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3])
    }

    // MARK: - Encode

    /// Names are written out in full, never as pointers. The saving would be a
    /// few dozen bytes on a loopback packet, against a codec every resolver has
    /// to agree with.
    public static func encode(_ message: DNSMessage) -> Data {
        var bytes = Data()

        bytes.append(UInt8(message.id >> 8))
        bytes.append(UInt8(message.id & 0xFF))

        // QR, then AA for a response we are authoritative for, then RD as asked.
        var flagsHigh: UInt8 = message.isQuery ? 0x00 : 0x84
        if message.recursionDesired { flagsHigh |= 0x01 }
        bytes.append(flagsHigh)
        // RA is left clear: we do not recurse, and claiming otherwise would be
        // a lie a resolver could act on.
        bytes.append(message.responseCode & 0x0F)

        append(&bytes, UInt16(message.questions.count))
        append(&bytes, UInt16(message.answers.count))
        append(&bytes, UInt16(0))  // no authority records
        append(&bytes, UInt16(0))  // no additional records

        for question in message.questions {
            appendName(&bytes, question.name)
            append(&bytes, question.type.rawValue)
            append(&bytes, question.klass)
        }

        for answer in message.answers {
            appendName(&bytes, answer.name)
            append(&bytes, answer.type.rawValue)
            append(&bytes, answer.klass)
            append(&bytes, answer.ttl)
            append(&bytes, UInt16(answer.data.count))
            bytes.append(answer.data)
        }

        return bytes
    }

    private static func appendName(_ bytes: inout Data, _ name: String) {
        for label in name.split(separator: ".") {
            let encoded = Array(label.utf8.prefix(maxLabelLength))
            bytes.append(UInt8(encoded.count))
            bytes.append(contentsOf: encoded)
        }
        bytes.append(0x00)
    }

    private static func append(_ bytes: inout Data, _ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    private static func append(_ bytes: inout Data, _ value: UInt32) {
        bytes.append(UInt8((value >> 24) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8(value & 0xFF))
    }

    // MARK: - TCP framing

    /// DNS over TCP prefixes each message with its length, since a stream has
    /// no datagram boundaries.
    public static func prefixedForTCP(_ payload: Data) -> Data {
        var framed = Data()
        append(&framed, UInt16(payload.count))
        framed.append(payload)
        return framed
    }

    public static func stripTCPPrefix(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw DNSCodecError.truncated }
        let length = Int(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        guard bytes.count >= 2 + length else { throw DNSCodecError.truncated }
        return Data(bytes[2..<(2 + length)])
    }
}
