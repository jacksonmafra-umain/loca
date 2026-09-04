import Foundation

/// One listening TCP socket, as reported by `lsof`.
public struct ListeningPort: Equatable, Identifiable, Hashable, Sendable {
    public enum Family: String, Equatable, Hashable, Sendable {
        case ipv4, ipv6
    }

    public var command: String
    public var pid: Int32
    public var user: String
    public var port: Int
    /// `*`, a literal address, or `::1` — brackets already stripped.
    public var address: String
    public var family: Family

    public init(
        command: String, pid: Int32, user: String, port: Int, address: String, family: Family
    ) {
        self.command = command
        self.pid = pid
        self.user = user
        self.port = port
        self.address = address
        self.family = family
    }

    /// A process can hold the same port on both families, and a user looking
    /// for what holds a port wants to see both, so the family is part of the
    /// identity.
    public var id: String { "\(port)-\(pid)-\(family.rawValue)" }

    /// Every published container port surfaces under this one process name,
    /// which is why the row is useless until `DockerPortMapper` resolves a
    /// container for it.
    public var isDockerBackend: Bool { command == LsofParser.dockerBackendCommand }
}

/// Parses `lsof +c 0 -nP -iTCP -sTCP:LISTEN`.
public enum LsofParser {
    public static let dockerBackendCommand = "com.docker.backend"

    /// `+c 0` disables command-name truncation. Without it `lsof` clips the
    /// COMMAND column to nine characters, `com.docker.backend` arrives as
    /// `com.docke`, and every container row goes unrecognized.
    public static let arguments = ["+c", "0", "-nP", "-iTCP", "-sTCP:LISTEN"]

    public static func parse(_ output: String) -> [ListeningPort] {
        var seen = Set<String>()
        var rows: [ListeningPort] = []

        for line in output.split(separator: "\n") {
            guard line.hasSuffix("(LISTEN)"), let row = parseLine(String(line)) else { continue }
            guard seen.insert(row.id).inserted else { continue }
            rows.append(row)
        }

        return rows.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Fields are read from the left by index rather than by column position,
    /// because `+c 0` makes the COMMAND column's width vary with the longest
    /// process name on the machine. `lsof` escapes whitespace inside the
    /// COMMAND and USER fields as `\x20`, so splitting on whitespace stays
    /// safe.
    private static func parseLine(_ line: String) -> ListeningPort? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME (LISTEN)
        guard fields.count >= 10 else { return nil }

        guard let pid = Int32(fields[1]) else { return nil }

        let family: ListeningPort.Family
        switch fields[4] {
        case "IPv4": family = .ipv4
        case "IPv6": family = .ipv6
        default: return nil
        }

        guard let (address, port) = splitAddress(fields[8]) else { return nil }

        return ListeningPort(
            command: unescape(fields[0]),
            pid: pid,
            user: unescape(fields[2]),
            port: port,
            address: address,
            family: family)
    }

    /// Splits `*:3000`, `127.0.0.1:3000`, or `[::1]:8099` on its last colon,
    /// which is the only separator that works for all three.
    private static func splitAddress(_ value: String) -> (address: String, port: Int)? {
        guard let colon = value.lastIndex(of: ":") else { return nil }
        guard let port = Int(value[value.index(after: colon)...]) else { return nil }

        var address = String(value[..<colon])
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        return (address, port)
    }

    /// `lsof` writes a space inside a name as `\x20`. Left alone it reaches the
    /// UI looking like a parser bug.
    private static func unescape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\x20", with: " ")
    }
}
