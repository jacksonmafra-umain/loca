import Foundation

/// Every well-known location and identifier, in one place.
///
/// User-session paths hang off an injectable `home`, which is what lets the
/// tests assert exact strings without touching the real home directory.
/// System paths and identifiers are static, because they are not negotiable.
public struct Paths: Sendable {
    public let home: URL

    public init(home: URL = URL(filePath: NSHomeDirectory())) {
        self.home = home
    }

    // MARK: - User session

    public var supportDirectory: URL {
        home.appending(path: "Library/Application Support/dev.loca")
    }

    public var configFile: URL {
        supportDirectory.appending(path: "config.json")
    }

    public var logDirectory: URL {
        home.appending(path: "Library/Logs/dev.loca")
    }

    public func runnerLog(slug: String) -> URL {
        logDirectory.appending(path: "\(slug).log")
    }

    public var launchAgentsDirectory: URL {
        home.appending(path: "Library/LaunchAgents")
    }

    public func runnerPlist(slug: String) -> URL {
        launchAgentsDirectory.appending(path: "\(Paths.runnerLabel(slug: slug)).plist")
    }

    // MARK: - System, owned by the helper

    public static let resolverDirectory = URL(filePath: "/etc/resolver")
    public static let resolverFile = resolverDirectory.appending(path: "test")

    public static let helperStateDirectory = URL(
        filePath: "/Library/Application Support/dev.loca")
    public static let caddyfile = helperStateDirectory.appending(path: "Caddyfile")

    /// Caddy's own storage, including the internal CA. Kept under a
    /// helper-owned directory so root's `XDG_DATA_HOME` never lands in a
    /// user-writable place.
    public static let caddyDataDirectory = helperStateDirectory.appending(path: "caddy-data")

    /// Unprivileged on purpose: `/etc/resolver` accepts a custom port, so the
    /// responder never needs to bind 53 and no second bundled binary is needed.
    public static let dnsPort: UInt16 = 53531

    /// Loopback only. Anything that can reach this address can reconfigure the
    /// proxy, so only the helper talks to it.
    public static let caddyAdmin = "127.0.0.1:2019"

    // MARK: - Identifiers

    public static let bundleIdentifier = "dev.loca"
    public static let helperLabel = "dev.loca.helper"

    public static func runnerLabel(slug: String) -> String {
        "dev.loca.run.\(slug)"
    }
}
