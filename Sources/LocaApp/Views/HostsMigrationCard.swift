import LocaCore
import SwiftUI

/// Offers to replace a family of hand-written `/etc/hosts` names with one Loca
/// domain — and never touches the file.
///
/// The trade is worth showing plainly, because it is a good one: `.local`
/// collides with mDNS and gives no HTTPS, and every subdomain needs its own
/// line. One `.test` registration covers the whole family through the wildcard,
/// with a trusted certificate, including subdomains nobody has thought of yet.
///
/// Once the domain exists, the card shows which line has become redundant and
/// the command to edit the file. It stops there. A tool that edits a file every
/// other tool on the machine also edits, on its own initiative, is a tool you
/// cannot trust with root.
struct HostsMigrationCard: View {
    let candidate: HostsFile.Candidate
    let store: AppStore
    /// Hands the slug to whoever can ask for a folder and register it.
    var onMigrate: (String) -> Void

    private var alreadyRegistered: Bool {
        store.project(withSlug: candidate.base) != nil
    }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                header

                if alreadyRegistered {
                    redundantLines
                } else {
                    proposal
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: alreadyRegistered ? "checkmark.seal" : "arrow.triangle.swap")
                .font(.system(size: 13))
                .foregroundStyle(alreadyRegistered ? Theme.running : Theme.accentSoft)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(
                    alreadyRegistered
                        ? "\(candidate.base).test has replaced your hosts entries"
                        : "\(candidate.names.count) hosts \(candidate.names.count == 1 ? "entry" : "entries") Loca can replace"
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)

                Text(candidate.names.joined(separator: ", "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// What one registration buys, spelled out rather than claimed.
    private var proposal: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "Registering \(candidate.base) gives you all of these over HTTPS, with a trusted certificate — and any other subdomain, without another line in a file:"
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(candidate.replacements, id: \.self) { name in
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Theme.running)
                    Text("https://\(name)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Text(
                ".local also collides with mDNS and Bonjour, which is the other reason those entries are worth retiring."
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)

            Button("Register \(candidate.base).test…") { onMigrate(candidate.base) }
                .buttonStyle(.accent)
        }
    }

    /// The domain exists, so the hosts line is now dead weight — but removing
    /// it is the user's call, on the user's file.
    private var redundantLines: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "\(candidate.lineNumbers.count == 1 ? "This line is" : "These lines are") now redundant. Loca will not remove \(candidate.lineNumbers.count == 1 ? "it" : "them") — \(HostsFile.path) is shared with everything else on this machine, so that edit is yours to make."
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(redundantEntries, id: \.lineNumber) { entry in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(String(entry.lineNumber)):")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    Text(entry.rawLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 8) {
                Button("Copy the command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HostsFile.editCommand, forType: .string)
                }
                .buttonStyle(.quiet)

                Text(HostsFile.editCommand)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var redundantEntries: [HostsFile.Entry] {
        HostsFile.lines(candidate.lineNumbers, in: HostsFile.read())
    }
}
