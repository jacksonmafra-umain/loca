import Foundation

/// Derivation and validation of the leftmost DNS label of a `.test` domain.
///
/// The slug is proposed from a folder name, which means it arrives with
/// spaces, capitals, diacritics, and punctuation. Everything here exists to
/// turn that into something a resolver will accept, and `isValid` is the gate
/// the rest of the code trusts.
public enum Slug {
    /// The DNS limit on a single label.
    public static let maxLength = 63

    /// Fallback for input that reduces to nothing, so the caller never has to
    /// handle an empty slug.
    public static let fallback = "project"

    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789")

    /// Lowercased, diacritics folded, every run of unsupported characters
    /// collapsed to a single hyphen, then trimmed of leading and trailing
    /// hyphens and clipped to the DNS label limit.
    public static func slugify(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US")
        ).lowercased()

        var result = ""
        var pendingHyphen = false
        for character in folded {
            if character.unicodeScalars.count == 1, allowed.contains(character) {
                if pendingHyphen, !result.isEmpty { result.append("-") }
                pendingHyphen = false
                result.append(character)
            } else {
                pendingHyphen = true
            }
        }

        // Clipping can strand a trailing hyphen, so trim after clipping too.
        if result.count > maxLength {
            result = String(result.prefix(maxLength))
        }
        while result.hasSuffix("-") { result.removeLast() }

        return result.isEmpty ? fallback : result
    }

    /// True only for a string `slugify` would leave untouched. Anything else is
    /// rejected at the boundary rather than silently rewritten, so the user
    /// sees why their input was refused.
    public static func isValid(_ slug: String) -> Bool {
        !slug.isEmpty && slug.count <= maxLength && slugify(slug) == slug
    }

    /// Normalizes `candidate`, then appends `-2`, `-3`, … until the result is
    /// free. Slugs must be unique because two projects cannot share a domain.
    public static func unique(_ candidate: String, taken: Set<String>) -> String {
        let base = slugify(candidate)
        guard taken.contains(base) else { return base }

        var counter = 2
        while true {
            let suffix = "-\(counter)"
            let trimmed = String(base.prefix(maxLength - suffix.count))
            let attempt = trimmed + suffix
            if !taken.contains(attempt) { return attempt }
            counter += 1
        }
    }
}
