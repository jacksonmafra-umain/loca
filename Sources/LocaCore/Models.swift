import Foundation

/// How a project's dev server is supervised, when the user wants Loca to run it.
///
/// A `nil` runner on a `Project` means the user starts the server themselves and
/// Loca only proxies the port.
public struct Runner: Codable, Hashable, Sendable {
    /// Run verbatim through a login shell, so nvm and `PATH` resolve.
    public var command: String
    /// Maps to `RunAtLoad`: start at the user's login.
    public var autoStart: Bool
    /// Maps to `KeepAlive: {SuccessfulExit: false}`: restart on crash, not on clean exit.
    public var keepAlive: Bool

    public init(command: String, autoStart: Bool = false, keepAlive: Bool = true) {
        self.command = command
        self.autoStart = autoStart
        self.keepAlive = keepAlive
    }
}

/// A folder mapped to a local port and a `.test` domain.
public struct Project: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    /// The domain's leftmost label. See `Slug` for the charset it is held to.
    public var slug: String
    public var folder: URL
    public var port: Int
    /// Whether the domain is currently served by the proxy.
    public var enabled: Bool
    public var runner: Runner?
    /// Which program opens a public tunnel for this project, when one is asked
    /// for.
    ///
    /// Only the preference is stored. Whether a tunnel is *open* is not: a
    /// tunnel publishes a local server to the internet, and something that
    /// consequential should never come back on its own because it was on when
    /// the app last quit.
    public var tunnelProvider: TunnelProvider?

    public init(
        id: UUID = UUID(),
        slug: String,
        folder: URL,
        port: Int,
        enabled: Bool = true,
        runner: Runner? = nil,
        tunnelProvider: TunnelProvider? = nil
    ) {
        self.id = id
        self.slug = slug
        self.folder = folder
        self.port = port
        self.enabled = enabled
        self.runner = runner
        self.tunnelProvider = tunnelProvider
    }

    public var domain: String { "\(slug).test" }
    public var wildcardDomain: String { "*.\(slug).test" }
    public var agentLabel: String { Paths.runnerLabel(slug: slug) }

    /// `127.0.0.1:<port>`, as a `String`.
    ///
    /// Built here rather than interpolated at each use site, because
    /// interpolating an `Int` straight into SwiftUI's `Text` goes through
    /// `LocalizedStringKey`, which formats it as a *number* — port 2020 renders
    /// as "2 020". A string built first has no such problem.
    public var upstream: String { "127.0.0.1:\(port)" }

    /// The port as plain digits, for the same reason.
    public var portText: String { String(port) }

    private enum CodingKeys: String, CodingKey {
        case id, slug, folder, port, enabled, runner, tunnelProvider
    }

    /// `folder` is stored as a plain path rather than a URL so that `config.json`
    /// stays readable for a user who opens it, and so a stale `file://` encoding
    /// can never creep in.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        slug = try container.decode(String.self, forKey: .slug)
        folder = URL(filePath: try container.decode(String.self, forKey: .folder))
        port = try container.decode(Int.self, forKey: .port)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        runner = try container.decodeIfPresent(Runner.self, forKey: .runner)
        tunnelProvider = try container.decodeIfPresent(
            TunnelProvider.self, forKey: .tunnelProvider)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(slug, forKey: .slug)
        try container.encode(folder.path(percentEncoded: false), forKey: .folder)
        try container.encode(port, forKey: .port)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(runner, forKey: .runner)
        try container.encodeIfPresent(tunnelProvider, forKey: .tunnelProvider)
    }
}

/// The whole persisted state. Derived state — pid, port occupancy, run status,
/// health — is deliberately absent: it is recomputed by polling, never stored.
public struct LocaConfig: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var projects: [Project]

    public init(version: Int = LocaConfig.currentVersion, projects: [Project] = []) {
        self.version = version
        self.projects = projects
    }
}
