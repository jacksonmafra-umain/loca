import Foundation

/// Which program opens the tunnel.
///
/// Both are asked for the same thing — a public URL that reaches a port on
/// this machine — and both are treated as programs on the user's `PATH`
/// rather than something Loca ships. ngrok's licence does not allow
/// redistribution, and bundling cloudflared would put roughly fifty megabytes
/// into a nineteen megabyte disk image for a feature most projects never turn
/// on.
public enum TunnelProvider: String, Codable, CaseIterable, Sendable {
    case cloudflared
    case ngrok

    public var displayName: String {
        switch self {
        case .cloudflared: "Cloudflare"
        case .ngrok: "ngrok"
        }
    }

    public var binaryName: String {
        rawValue
    }

    /// What to run to get the missing binary.
    public var installCommand: String {
        switch self {
        case .cloudflared: "brew install cloudflared"
        case .ngrok: "brew install ngrok"
        }
    }

    /// Whether the provider works without the user signing up first.
    ///
    /// cloudflared's quick tunnels need no account. ngrok refuses to start
    /// until an authtoken is stored, which is a wall worth naming before
    /// somebody hits it.
    public var needsAccount: Bool {
        switch self {
        case .cloudflared: false
        case .ngrok: true
        }
    }

    public var accountHint: String? {
        switch self {
        case .cloudflared: nil
        case .ngrok:
            "ngrok needs an authtoken once: sign in at dashboard.ngrok.com and run "
                + "`ngrok config add-authtoken <token>`."
        }
    }
}

/// The command line for a tunnel to a local port.
public enum TunnelCommand {
    /// The arguments that follow the binary's own path.
    ///
    /// The target is the upstream itself, `http://127.0.0.1:<port>`, not the
    /// `.test` domain through Caddy. Going through Caddy would need the
    /// provider to accept a certificate issued by a local authority it has
    /// never heard of, and the flag for that is the flag that stops it
    /// checking certificates at all.
    ///
    /// The cost is that the origin sees the provider's hostname in `Host`
    /// rather than the domain, which matters to anything routing by vhost. The
    /// UI says so.
    public static func arguments(for provider: TunnelProvider, port: Int) -> [String] {
        switch provider {
        case .cloudflared:
            // --no-autoupdate because a tunnel that replaces its own binary
            // mid-session is not something a dev tool should arrange.
            return ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
        case .ngrok:
            // Asking for logfmt on stdout is the difference between parsing a
            // progress-drawing terminal UI and parsing key=value pairs.
            return ["http", String(port), "--log", "stdout", "--log-format", "logfmt"]
        }
    }
}

/// Finds a provider's binary.
public enum TunnelBinary {
    /// Where Homebrew puts things, on both architectures.
    ///
    /// Searched after `PATH` because an app launched from Finder inherits
    /// `launchd`'s environment, whose `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin`
    /// — so the tool the user installed is invisible unless it is looked for
    /// where it actually lives.
    public static let fallbackDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    public static func locate(
        _ provider: TunnelProvider,
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        extraDirectories: [String] = fallbackDirectories,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let fromPath = (path ?? "").split(separator: ":").map(String.init)
        for directory in fromPath + extraDirectories where !directory.isEmpty {
            let candidate = directory.hasSuffix("/")
                ? directory + provider.binaryName
                : directory + "/" + provider.binaryName
            if isExecutable(candidate) {
                return URL(filePath: candidate)
            }
        }
        return nil
    }
}

/// What a line of a provider's output means, when it means anything.
public enum TunnelEvent: Equatable, Sendable {
    /// The tunnel is up at this address.
    case url(String)
    /// The provider reported something it cannot continue past.
    case failure(String)
}

/// Reads a provider's own output, because neither provider offers a better
/// channel for a one-shot tunnel.
///
/// cloudflared prints its URL inside an ASCII banner on stderr. ngrok is asked
/// for logfmt, so its URL arrives as a `url=` pair. Both are parsed by looking
/// for the smallest thing that identifies the line, rather than by matching
/// the surrounding decoration, which changes between versions.
public enum TunnelOutputParser {
    public static func event(in line: String, from provider: TunnelProvider) -> TunnelEvent? {
        switch provider {
        case .cloudflared: cloudflaredEvent(in: line)
        case .ngrok: ngrokEvent(in: line)
        }
    }

    // MARK: - cloudflared

    private static func cloudflaredEvent(in line: String) -> TunnelEvent? {
        if let url = firstURL(in: line, host: ".trycloudflare.com") {
            return .url(url)
        }
        // A quick tunnel that cannot be created says so once and then keeps
        // retrying, so the first mention is the one worth surfacing.
        if line.contains("ERR ") || line.contains("failed to request quick Tunnel") {
            return .failure(cleaned(line))
        }
        return nil
    }

    // MARK: - ngrok

    private static func ngrokEvent(in line: String) -> TunnelEvent? {
        if line.contains("msg=\"started tunnel\""), let url = logfmt(line, key: "url") {
            return .url(url)
        }
        guard let level = logfmt(line, key: "lvl"), level == "eror" || level == "crit" else {
            return nil
        }
        // `err=<nil>` appears on perfectly ordinary lines; only a real message
        // is worth showing.
        if let error = logfmt(line, key: "err"), error != "<nil>", !error.isEmpty {
            return .failure(error)
        }
        if let message = logfmt(line, key: "msg"), !message.isEmpty {
            return .failure(message)
        }
        return .failure(cleaned(line))
    }

    // MARK: - Pieces

    /// The first `https://…` in a line whose host ends in `host`.
    ///
    /// cloudflared frames its URL in pipes and padding, so the address is
    /// taken up to the first space rather than to the end of the line.
    static func firstURL(in line: String, host: String) -> String? {
        guard let start = line.range(of: "https://") else { return nil }
        let rest = line[start.lowerBound...]
        let url = rest.prefix { !$0.isWhitespace && $0 != "|" && $0 != "\"" }
        return url.hasSuffix(host) ? String(url) : nil
    }

    /// The value of `key=` in a logfmt line, quoted or bare.
    static func logfmt(_ line: String, key: String) -> String? {
        var searchStart = line.startIndex
        while let range = line.range(of: "\(key)=", range: searchStart..<line.endIndex) {
            // Only a pair at the start of a token, so `stopReq=` is never read
            // as `req=` and `obj=` never matches inside a word.
            let isTokenStart =
                range.lowerBound == line.startIndex
                || line[line.index(before: range.lowerBound)].isWhitespace
            guard isTokenStart else {
                searchStart = range.upperBound
                continue
            }

            let rest = line[range.upperBound...]
            if rest.first == "\"" {
                let quoted = rest.dropFirst()
                var value = ""
                var escaped = false
                for character in quoted {
                    if escaped {
                        // logfmt quotes the way Go does, so `\r\n` in the file
                        // is a line break in the message rather than the two
                        // letters r and n.
                        switch character {
                        case "n": value.append("\n")
                        case "r": value.append("\r")
                        case "t": value.append("\t")
                        default: value.append(character)
                        }
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        return value
                    } else {
                        value.append(character)
                    }
                }
                return value
            }
            return String(rest.prefix { !$0.isWhitespace })
        }
        return nil
    }

    /// Strips a leading timestamp and level so a raw line can be shown to a
    /// person without the noise it carries for a log file.
    private static func cleaned(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        // cloudflared: "2026-09-05T10:57:29Z INF the message"
        if let range = text.range(of: " INF ") ?? text.range(of: " ERR ")
            ?? text.range(of: " WRN ")
        {
            text = String(text[range.upperBound...])
        }
        return text
    }
}
