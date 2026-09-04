import Foundation
import LocaCore
import Security

/// The code-signing requirement a client must satisfy to talk to the helper.
///
/// It is derived from the helper's *own* signature rather than hardcoded: the
/// app and the helper ship in one bundle signed by one identity, so "signed by
/// whoever signed me" is both the exact security property wanted and the only
/// form that lets a third party build this repository without editing a team
/// identifier into the source.
enum CodeSignatureRequirement {
    /// `nil` when the helper's own team cannot be established — an unsigned or
    /// ad-hoc build. Callers must then refuse every connection: a root daemon
    /// that cannot tell who is calling has no business accepting anyone.
    static func forOwnTeam() -> String? {
        guard let team = ownTeamIdentifier() else {
            NSLog("loca: no team identifier on this build; refusing all XPC clients")
            return nil
        }

        let requirement = """
            identifier "\(Paths.bundleIdentifier)" \
            and anchor apple generic \
            and certificate leaf[subject.OU] = "\(team)"
            """

        // NSXPCConnection.setCodeSigningRequirement reports nothing back, so a
        // typo in this string would silently become a requirement that never
        // matches — every client refused, with no explanation. Compiling it
        // here turns that into a log line at startup.
        var compiled: SecRequirement?
        guard
            SecRequirementCreateWithString(requirement as CFString, [], &compiled)
                == errSecSuccess
        else {
            NSLog("loca: requirement string does not compile: %@", requirement)
            return nil
        }

        return requirement
    }

    /// Reads the team identifier out of the running helper's own signature.
    ///
    /// The team identifier is the certificate's OU field. Note that it is *not*
    /// the value in parentheses in an "Apple Development: name (XXXXXXXXXX)"
    /// common name — those differ, and using the wrong one produces a
    /// requirement that silently never matches.
    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
        else { return nil }

        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let dictionary = information as NSDictionary?
        else { return nil }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
