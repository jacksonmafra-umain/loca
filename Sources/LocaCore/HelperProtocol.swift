import Foundation

/// The mach service the helper publishes and the app connects to.
public let locaHelperMachServiceName = "dev.loca.helper"

/// Bumped whenever this protocol changes shape.
///
/// The app compares it against what the helper reports and says "reinstall the
/// helper" rather than letting an updated app fail against a stale daemon in a
/// way nobody can diagnose.
public let locaHelperProtocolVersion = 1

/// Everything the app is allowed to ask of root.
///
/// The surface is deliberately small and field-typed. Nothing here takes a
/// file path to read as root, and nothing here takes a Caddyfile: the helper
/// generates its own configuration from validated fields, so a compromised
/// user-session process cannot hand root a config to run.
@objc public protocol LocaHelperProtocol {
    /// Replies with the protocol version and a human-readable build string.
    func helperVersion(reply: @escaping (Int, String) -> Void)

    /// Writes `/etc/resolver/test`. Replies with the backup path when a
    /// pre-existing foreign file was moved aside.
    func installDNSResolver(reply: @escaping (Bool, String?) -> Void)

    func removeDNSResolver(reply: @escaping (Bool, String?) -> Void)

    /// The only path by which configuration reaches root. Each entry is
    /// validated field by field before anything is generated or written.
    func applyDomains(_ payload: [[String: NSObject]], reply: @escaping (Bool, String?) -> Void)

    func trustCertificateAuthority(reply: @escaping (Bool, String?) -> Void)

    func certificateAuthorityIsTrusted(reply: @escaping (Bool) -> Void)

    /// Helper version, DNS listener state, resolver state, who holds :80 and
    /// :443, whether Caddy is running, and whether the CA is trusted.
    func diagnostics(reply: @escaping ([String: NSObject]) -> Void)

    /// Removes everything the helper installed: resolver file, CA trust, and
    /// its own state directory.
    func uninstall(reply: @escaping (Bool, String?) -> Void)
}

/// Translates projects to and from the XPC wire shape.
///
/// `id` and `runner` are deliberately absent. The helper proxies domains; it
/// has no business knowing which UUID the app filed a project under or what
/// command the user runs, and the smallest surface that works is the one worth
/// exposing to root.
public enum DomainPayload {
    private enum Key {
        static let slug = "slug"
        static let port = "port"
        static let folder = "folder"
        static let enabled = "enabled"
    }

    public static func encode(_ projects: [Project]) -> [[String: NSObject]] {
        projects.map { project in
            [
                Key.slug: project.slug as NSString,
                Key.port: NSNumber(value: project.port),
                Key.folder: project.folder.path(percentEncoded: false) as NSString,
                Key.enabled: NSNumber(value: project.enabled),
            ]
        }
    }

    /// Validates every field before returning anything.
    ///
    /// This runs as root against a payload from a user-session process. Without
    /// it, any local process that got past the code-signature check could ask a
    /// root daemon to proxy arbitrary domains or write a path of its choosing.
    public static func decode(_ payload: [[String: NSObject]]) throws -> [Project] {
        var projects: [Project] = []

        for entry in payload {
            guard let slug = entry[Key.slug] as? String else {
                throw ValidationError.invalidSlug("<missing>")
            }
            guard let port = (entry[Key.port] as? NSNumber)?.intValue else {
                throw ValidationError.portOutOfRange(0)
            }
            guard let folderPath = entry[Key.folder] as? String else {
                throw ValidationError.folderNotAbsolute("<missing>")
            }
            let enabled = (entry[Key.enabled] as? NSNumber)?.boolValue ?? true

            guard Slug.isValid(slug) else { throw ValidationError.invalidSlug(slug) }
            guard Validation.portRange.contains(port) else {
                throw ValidationError.portOutOfRange(port)
            }
            try Validation.validateFolderPath(folderPath)

            if projects.contains(where: { $0.slug == slug }) {
                throw ValidationError.duplicateSlug(slug)
            }

            projects.append(
                Project(
                    slug: slug,
                    folder: URL(filePath: folderPath),
                    port: port,
                    enabled: enabled))
        }

        return projects
    }
}
