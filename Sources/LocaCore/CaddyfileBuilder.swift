import Foundation

/// Renders the Caddyfile the helper hands to Caddy's admin API.
///
/// Output is deterministic — enabled projects only, in slug order — because
/// this string is compared and diffed across reloads, and an unstable
/// generator would make every reload look like a change.
public enum CaddyfileBuilder {
    public static func build(
        projects: [Project],
        adminAddress: String = Paths.caddyAdmin,
        dataDirectory: URL = Paths.caddyDataDirectory
    ) -> String {
        var output = """
            {
            \tadmin \(adminAddress)
            \tstorage file_system {
            \t\troot \(quote(dataDirectory.path(percentEncoded: false)))
            \t}
            }

            """

        for project in projects.filter(\.enabled).sorted(by: { $0.slug < $1.slug }) {
            output += "\n" + siteBlock(for: project)
        }

        return output
    }

    /// The apex and the wildcard share one block, so the internal CA issues the
    /// wildcard certificate alongside the apex one and subdomains work without
    /// any further configuration.
    ///
    /// `handle_errors` exists because the common failure is not a proxy
    /// misconfiguration but an upstream that simply is not running yet. A bare
    /// 502 tells the user nothing; naming the domain and the port they
    /// registered tells them exactly what to start.
    private static func siteBlock(for project: Project) -> String {
        let upstream = "127.0.0.1:\(project.port)"
        let message =
            "Loca: \(project.domain) is registered, but nothing is listening on \(upstream)."
        return """
            \(project.domain), \(project.wildcardDomain) {
            \ttls internal
            \treverse_proxy \(upstream)

            \thandle_errors {
            \t\trespond \(quote(message)) {err.status_code}
            \t}
            }

            """
    }

    /// The storage root lives under "Application Support", so it always needs
    /// quoting: unquoted, Caddy reads the spaces as argument separators.
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
