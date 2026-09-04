import Foundation

/// The payload of `/etc/resolver/test`.
///
/// `resolver(5)` accepting a `port` directive is the reason the DNS responder
/// can live on an unprivileged port inside the helper, rather than needing to
/// bind 53 or ship a second daemon.
public enum ResolverFile {
    /// Written into the file so the helper can tell its own from a
    /// hand-written one it must back up rather than overwrite.
    public static let marker = "# managed by Loca (dev.loca)"

    public static func content(port: UInt16 = Paths.dnsPort) -> String {
        """
        \(marker)
        nameserver 127.0.0.1
        port \(port)

        """
    }

    public static func isManagedByLoca(_ content: String) -> Bool {
        content.contains(marker)
    }
}
