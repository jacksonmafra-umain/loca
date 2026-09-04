import Foundation
import LocaCore
import Security

enum CATrustError: Error, LocalizedError {
    case rootCertificateMissing(String)
    case commandFailed(String)
    case unreadableCertificate(String)

    var errorDescription: String? {
        switch self {
        case .rootCertificateMissing(let path):
            return "Caddy has not issued its root certificate yet (expected at \(path))"
        case .commandFailed(let detail):
            return "could not change the System keychain: \(detail)"
        case .unreadableCertificate(let path):
            return "the root certificate at \(path) could not be parsed"
        }
    }
}

/// Reads and evaluates Caddy's internal root certificate.
///
/// Installing trust is deliberately *not* here. Writing trust settings to the
/// System keychain calls `SecTrustSettingsSetTrustSettings`, which needs an
/// authorization a daemon cannot obtain — it fails with "the authorization was
/// denied since no user interaction was possible" even as root. That is also
/// why `caddy trust` fails inside a LaunchDaemon: it shells out to `sudo` and
/// has no terminal.
///
/// So the helper exports the certificate and the app installs the trust in the
/// user's session, where macOS can ask them for it. That is the better story
/// anyway: trusting a new root is the user's decision to make, once, with a
/// prompt they recognise.
enum CATrust {
    /// Caddy's local CA lives under the storage root configured in the
    /// Caddyfile, not under `XDG_DATA_HOME`, once `storage file_system` is set.
    static func rootCertificate(dataDirectory: URL = Paths.caddyDataDirectory) -> URL {
        dataDirectory.appending(path: "pki/authorities/local/root.crt")
    }

    /// The root certificate in DER form, ready to cross XPC.
    ///
    /// Safe to hand out: a root certificate is public by definition, and the
    /// private key stays in the helper's storage.
    static func rootCertificateDER(dataDirectory: URL = Paths.caddyDataDirectory) throws -> Data {
        let path = rootCertificate(dataDirectory: dataDirectory).path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else {
            throw CATrustError.rootCertificateMissing(path)
        }
        guard let certificate = loadCertificate(dataDirectory: dataDirectory) else {
            throw CATrustError.unreadableCertificate(path)
        }
        return SecCertificateCopyData(certificate) as Data
    }

    private static func loadCertificate(dataDirectory: URL) -> SecCertificate? {
        let url = rootCertificate(dataDirectory: dataDirectory)
        guard let pem = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        // SecCertificateCreateWithData wants raw DER, so the PEM armour and its
        // line breaks come off first.
        let base64 = pem
            .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
            .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()

        guard let der = Data(base64Encoded: base64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }
}
