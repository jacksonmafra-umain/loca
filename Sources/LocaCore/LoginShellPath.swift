import Foundation

/// The `PATH` a dev server needs, and how to get it out of the user's shell.
///
/// `launchd` hands a GUI agent `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else,
/// so every project command runs through `zsh -ilc`. The `-l` alone is not
/// enough: a non-interactive shell never reads `~/.zshrc`, which is where nvm,
/// pnpm, rbenv and pyenv actually put themselves. That is why `npm` — installed
/// by Homebrew, and therefore in `/etc/paths` — runs fine from an agent while
/// `pnpm` from nvm fails with `command not found`.
///
/// `-i` fixes it, but only for a `~/.zshrc` that survives having no terminal.
/// So the app also asks the shell what its `PATH` is and writes the answer into
/// the agent, which covers the other case and keeps the resolution visible in
/// the plist instead of buried in a shell start-up file.
public enum LoginShellPath {
    /// Prefixed rather than read as bare output: a `~/.zshrc` is free to print
    /// banners, version notices and warnings, and any of that would otherwise
    /// be indistinguishable from the answer.
    public static let marker = "loca-path:"

    public static let shell = "/bin/zsh"

    /// `-i` is the whole point — see the type's note.
    public static let arguments = ["-ilc", "printf '%s%s\\n' '\(marker)' \"$PATH\""]

    /// The marked line's payload, or `nil` when the shell never printed one.
    ///
    /// The *last* marked line wins, because a `~/.zshrc` that re-execs itself
    /// prints two and only the final one describes the shell we would get.
    public static func parse(_ output: String) -> String? {
        let value =
            output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .last { $0.hasPrefix(marker) }?
            .dropFirst(marker.count)
            .trimmingCharacters(in: .whitespaces)

        // A shell that answered with nothing is not an answer. Writing an empty
        // PATH into the agent would be strictly worse than leaving launchd's
        // default in place.
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
