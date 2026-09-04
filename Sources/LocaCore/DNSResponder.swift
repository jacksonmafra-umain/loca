import Foundation

/// The whole answering policy, as a pure function.
///
/// `/etc/resolver/test` sends every `.test` lookup here, so wildcard
/// subdomains come for free: any name under the TLD resolves to loopback, and
/// whether a domain is actually registered is the proxy's business rather than
/// the resolver's. That split is what lets a user add a subdomain without
/// touching DNS at all.
public enum DNSResponder {
    /// Short, because a project's port can change at any moment and a stale
    /// cached answer is worse than an extra loopback lookup.
    public static let ttl: UInt32 = 60

    private static let ipv4Loopback = Data([127, 0, 0, 1])
    private static let ipv6Loopback = Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])

    /// 4 is NOTIMP.
    private static let notImplemented: UInt8 = 4

    public static func respond(to query: DNSMessage) -> DNSMessage {
        guard query.isQuery, let question = query.questions.first else {
            return DNSMessage(
                id: query.id,
                isQuery: false,
                recursionDesired: query.recursionDesired,
                questions: query.questions,
                answers: [],
                responseCode: notImplemented)
        }

        var answers: [DNSAnswer] = []
        switch question.type {
        case .a:
            answers = [
                DNSAnswer(name: question.name, type: .a, ttl: ttl, data: ipv4Loopback)
            ]
        case .aaaa:
            answers = [
                DNSAnswer(name: question.name, type: .aaaa, ttl: ttl, data: ipv6Loopback)
            ]
        case .other:
            // An empty NOERROR, never NXDOMAIN. A negative answer would let the
            // resolver fall through to the next nameserver, and the name would
            // resolve somewhere else entirely.
            break
        }

        return DNSMessage(
            id: query.id,
            isQuery: false,
            recursionDesired: query.recursionDesired,
            questions: query.questions,
            answers: answers,
            responseCode: 0)
    }
}
