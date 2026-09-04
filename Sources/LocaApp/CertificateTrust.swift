import Foundation
import Security
import LocaCore

enum CertificateTrustError: Error, LocalizedError {
    case noCertificate(String)
    case commandFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noCertificate(let detail):
            return "the helper has no root certificate yet: \(detail)"
        case .commandFailed(let detail):
            return "changing certificate trust in your keychain failed: \(detail)"
        case .cancelled:
            return "the authorization prompt was dismissed, so nothing was trusted"
        }
    }
}

/// Installs and evaluates trust for Caddy's internal root, in the user's
/// keychain.
///
/// Trust goes in the **user** domain, not the admin one, and this is not a
/// compromise — it is the only combination that works, and the better one.
///
/// The helper cannot install trust: writing System keychain trust settings
/// calls `SecTrustSettingsSetTrustSettings`, which needs an authorization no
/// daemon can obtain, even as root ("the authorization was denied since no user
/// interaction was possible"). The app cannot write the System keychain either:
/// that needs root ("SecCertificateAddToKeychain: Write permissions error").
/// The user's own login keychain is writable by the user and its trust settings
/// are honoured for TLS, so that is where this belongs.
///
/// It also scopes the decision correctly. A root certificate is real power —
/// whoever holds its private key can mint a certificate for any name the
/// browser will accept — so trusting it for one user rather than for the whole
/// machine is the smaller claim, and the right one for a local development
/// tool.
enum CertificateTrust {
    /// Writes the DER the helper handed over to a temporary file and asks
    /// `security` to trust it as a root in the user domain.
    ///
    /// The file is temporary because `security` takes a path, and the
    /// certificate's permanent home is the helper's storage — copying it
    /// somewhere lasting would just create a second copy to go stale.
    static func install(rootCertificateDER der: Data) throws {
        try withTemporaryCertificate(der) { path in
            // No -d: that would target the admin domain and the System
            // keychain, which this process cannot write.
            let result = run(["add-trusted-cert", "-r", "trustRoot", path])

            guard result.exitCode == 0 else {
                let detail = result.standardError.isEmpty
                    ? result.standardOutput : result.standardError
                // Dismissing the prompt is a decision, not a fault, so it reads
                // differently from a real failure.
                if detail.contains("User canceled") || detail.contains("-128") {
                    throw CertificateTrustError.cancelled
                }
                throw CertificateTrustError.commandFailed(detail)
            }
        }
    }

    static func remove(rootCertificateDER der: Data) throws {
        try withTemporaryCertificate(der) { path in
            let result = run(["remove-trusted-cert", path])
            guard result.exitCode == 0 else {
                throw CertificateTrustError.commandFailed(
                    result.standardError.isEmpty ? result.standardOutput : result.standardError)
            }
        }
    }

    /// Evaluates the certificate as this user sees it.
    ///
    /// Evaluated here, not in the helper: user-domain trust settings are
    /// invisible to root, so the helper would always report untrusted. And
    /// evaluating rather than looking the certificate up in a keychain is what
    /// distinguishes "installed once" from "trusted right now" — a user can
    /// revoke it by hand in Keychain Access, and the app should notice and
    /// offer to reinstall instead of leaving browsers failing silently.
    static func isTrusted(rootCertificateDER der: Data) -> Bool {
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            return false
        }

        var trust: SecTrust?
        guard
            SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust)
                == errSecSuccess,
            let trust
        else { return false }

        return SecTrustEvaluateWithError(trust, nil)
    }

    private static func withTemporaryCertificate(
        _ der: Data, _ body: (String) throws -> Void
    ) throws {
        let temporary = URL(filePath: NSTemporaryDirectory())
            .appending(path: "loca-root-\(UUID().uuidString).cer")
        try der.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(temporary.path(percentEncoded: false))
    }

    private struct Result {
        var exitCode: Int32
        var standardOutput: String
        var standardError: String
    }

    private static func run(_ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return Result(
                exitCode: -1, standardOutput: "",
                standardError: "could not run /usr/bin/security: \(error)")
        }

        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self))
    }
}
