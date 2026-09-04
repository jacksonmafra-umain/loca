import Foundation

/// A request to Caddy's admin API, described without performing it.
///
/// Keeping the description pure is what lets the method, path, content type,
/// and body be asserted in a test that never opens a socket. The helper is the
/// only thing that turns one of these into an actual request.
public struct CaddyAdminRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var contentType: String
    public var body: Data
    public var address: String

    public init(method: String, path: String, contentType: String, body: Data, address: String) {
        self.method = method
        self.path = path
        self.contentType = contentType
        self.body = body
        self.address = address
    }

    /// Loads a Caddyfile as the whole running config.
    ///
    /// This is a config load, not a restart: Caddy swaps the config in place,
    /// so open connections survive and enabling a domain does not interrupt a
    /// download or a websocket someone is using.
    public static func load(
        caddyfile: String, address: String = Paths.caddyAdmin
    ) -> CaddyAdminRequest {
        CaddyAdminRequest(
            method: "POST",
            path: "/load",
            contentType: "text/caddyfile",
            body: Data(caddyfile.utf8),
            address: address)
    }

    public var urlString: String { "http://\(address)\(path)" }

    public var url: URL? { URL(string: urlString) }
}
