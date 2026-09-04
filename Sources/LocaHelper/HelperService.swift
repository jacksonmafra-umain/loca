import Foundation
import LocaCore

/// The privileged operations, and nothing else.
///
/// Every method is small and takes only validated fields. Nothing here reads a
/// path the caller chose, and nothing here accepts a configuration file to run:
/// the helper generates its own from `DomainPayload`, which is what keeps a
/// compromised user-session process from handing root something to execute.
final class HelperService: NSObject, LocaHelperProtocol {
    private let buildDescription: String
    private let dns: DNSListener

    init(buildDescription: String, dns: DNSListener) {
        self.buildDescription = buildDescription
        self.dns = dns
    }

    func helperVersion(reply: @escaping (Int, String) -> Void) {
        reply(locaHelperProtocolVersion, buildDescription)
    }

    func installDNSResolver(reply: @escaping (Bool, String?) -> Void) {
        reply(false, "not implemented yet")
    }

    func removeDNSResolver(reply: @escaping (Bool, String?) -> Void) {
        reply(false, "not implemented yet")
    }

    func applyDomains(_ payload: [[String: NSObject]], reply: @escaping (Bool, String?) -> Void) {
        // Validate first, always. This is the only path by which configuration
        // reaches root.
        do {
            let projects = try DomainPayload.decode(payload)
            NSLog("loca: applyDomains accepted %d project(s)", projects.count)
            reply(false, "not implemented yet")
        } catch {
            NSLog("loca: applyDomains rejected: %@", String(describing: error))
            reply(false, "invalid domain payload: \(error)")
        }
    }

    func trustCertificateAuthority(reply: @escaping (Bool, String?) -> Void) {
        reply(false, "not implemented yet")
    }

    func certificateAuthorityIsTrusted(reply: @escaping (Bool) -> Void) {
        reply(false)
    }

    func diagnostics(reply: @escaping ([String: NSObject]) -> Void) {
        reply([
            "helperVersion": NSNumber(value: locaHelperProtocolVersion),
            "helperBuild": buildDescription as NSString,
        ])
    }

    func uninstall(reply: @escaping (Bool, String?) -> Void) {
        reply(false, "not implemented yet")
    }
}
