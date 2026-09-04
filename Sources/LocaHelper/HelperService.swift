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
    private let caddy: CaddySupervisor

    init(buildDescription: String, dns: DNSListener, caddy: CaddySupervisor) {
        self.buildDescription = buildDescription
        self.dns = dns
        self.caddy = caddy
    }

    func helperVersion(reply: @escaping (Int, String) -> Void) {
        reply(locaHelperProtocolVersion, buildDescription)
    }

    // MARK: - DNS resolver

    func installDNSResolver(reply: @escaping (Bool, String?) -> Void) {
        do {
            let backup = try SystemResolver.install()
            reply(true, backup)
        } catch {
            NSLog("loca: installDNSResolver failed: %@", String(describing: error))
            reply(false, error.localizedDescription)
        }
    }

    func removeDNSResolver(reply: @escaping (Bool, String?) -> Void) {
        do {
            try SystemResolver.remove()
            reply(true, nil)
        } catch {
            NSLog("loca: removeDNSResolver failed: %@", String(describing: error))
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Domains

    func applyDomains(_ payload: [[String: NSObject]], reply: @escaping (Bool, String?) -> Void) {
        // Validate first, always. This is the only path by which configuration
        // reaches root.
        let projects: [Project]
        do {
            projects = try DomainPayload.decode(payload)
        } catch {
            NSLog("loca: applyDomains rejected: %@", String(describing: error))
            reply(false, "invalid domain payload: \(error)")
            return
        }

        do {
            try caddy.apply(projects: projects)
            NSLog("loca: applied %d domain(s)", projects.filter(\.enabled).count)
            reply(true, nil)
        } catch {
            NSLog("loca: applyDomains failed: %@", String(describing: error))
            reply(false, error.localizedDescription)
        }
    }

    // MARK: - Certificate authority

    func certificateAuthorityRoot(reply: @escaping (Data?, String?) -> Void) {
        do {
            reply(try CATrust.rootCertificateDER(), nil)
        } catch {
            NSLog("loca: certificateAuthorityRoot failed: %@", String(describing: error))
            reply(nil, error.localizedDescription)
        }
    }


    // MARK: - Diagnostics

    /// Everything the onboarding panel needs to explain why something is not
    /// working, in one round trip.
    func diagnostics(reply: @escaping ([String: NSObject]) -> Void) {
        let resolver = SystemResolver.status()

        var report: [String: NSObject] = [
            "helperVersion": NSNumber(value: locaHelperProtocolVersion),
            "helperBuild": buildDescription as NSString,
            "dnsPort": NSNumber(value: Paths.dnsPort),
            "dnsListening": NSNumber(value: PortProbe.owner(ofPort: Int(Paths.dnsPort)) != nil),
            "resolverExists": NSNumber(value: resolver.exists),
            "resolverManagedByLoca": NSNumber(value: resolver.managedByLoca),
            "caddyRunning": NSNumber(value: caddy.isRunning),
            // Whether the root is *trusted* is deliberately absent: user-domain
            // trust settings are invisible to root, so any answer from here
            // would be wrong. The app evaluates that itself.
            "caRootIssued": NSNumber(
                value: FileManager.default.fileExists(
                    atPath: CATrust.rootCertificate().path(percentEncoded: false))),
        ]

        if let exit = caddy.lastExitStatus {
            report["caddyLastExitStatus"] = NSNumber(value: exit)
        }

        // Named owners, not a boolean. "Something is on 443" sends the user
        // hunting; "nginx (pid 812) is on 443" ends the search.
        if let owner80 = PortProbe.describeOwner(ofPort: 80) {
            report["port80Owner"] = owner80 as NSString
        }
        if let owner443 = PortProbe.describeOwner(ofPort: 443) {
            report["port443Owner"] = owner443 as NSString
        }

        reply(report)
    }

    // MARK: - Uninstall

    func uninstall(reply: @escaping (Bool, String?) -> Void) {
        var problems: [String] = []

        dns.stop()
        caddy.stop()

        // Each step is attempted even if an earlier one failed: a half-removed
        // install is worse than a fully removed one with a reported problem.
        //
        // Certificate trust is not removed here — it lives in the user's
        // keychain, which only the user's own session can change, so the app
        // does that part.
        do {
            try SystemResolver.remove()
        } catch {
            problems.append(error.localizedDescription)
        }

        do {
            try FileManager.default.removeItem(at: Paths.helperStateDirectory)
        } catch CocoaError.fileNoSuchFile {
            // Nothing to remove is a clean uninstall, not a problem.
        } catch {
            problems.append(error.localizedDescription)
        }

        reply(problems.isEmpty, problems.isEmpty ? nil : problems.joined(separator: "; "))
    }
}
