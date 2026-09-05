import LocaCore
import SwiftUI

/// Who made this, what it is, and where to find it.
///
/// Lives at the bottom of the Setup pane rather than behind a menu item,
/// because Setup is already the place people go when they want to know what
/// Loca is doing to their machine — and the version is the first thing worth
/// knowing there.
struct AboutCard: View {
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.accent)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: "lock.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.onAccent))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Loca \(Self.version)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        Text("Local HTTPS domains for macOS")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }

                    Spacer()
                }

                Divider().overlay(Theme.stroke)

                HStack(spacing: 4) {
                    Text("Built by")
                        .foregroundStyle(Theme.textTertiary)
                    Link(Self.author, destination: Self.authorURL)
                        .foregroundStyle(Theme.accent)
                    Text("·")
                        .foregroundStyle(Theme.textTertiary)
                    Link("source", destination: Self.repositoryURL)
                        .foregroundStyle(Theme.accent)
                    Text("·")
                        .foregroundStyle(Theme.textTertiary)
                    Text("MIT")
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 11))

                Text(
                    "Uses Caddy for TLS and proxying, bundled under its Apache 2.0 licence."
                )
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    static let author = "Jackson Mafra"
    static let authorURL = URL(string: "https://github.com/jacksonmafra-umain")!
    static let repositoryURL = URL(string: "https://github.com/jacksonmafra-umain/loca")!

    /// Read from the bundle so it can never drift from the released version.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
    }
}
