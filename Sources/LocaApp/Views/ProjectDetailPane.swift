import LocaCore
import SwiftUI

/// The right-hand pane: what the selected domain actually is.
///
/// Milestone 4 fills the runner half — status, play and stop, and the live log.
/// Until then it shows the mapping and the runner as configured, which is
/// already the answer to "what did I register?".
struct ProjectDetailPane: View {
    let project: Project?
    let store: AppStore
    var onRemove: (Project) -> Void

    var body: some View {
        ScrollView {
            if let project {
                VStack(alignment: .leading, spacing: 12) {
                    identity(project)
                    mapping(project)
                    if let runner = project.runner {
                        self.runner(runner)
                    } else {
                        noRunner
                    }
                    conflicts(project)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 8)
            } else {
                Text("Select a domain")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
            }
        }
        .scrollIndicators(.never)
    }

    // MARK: - Cards

    private func identity(_ project: Project) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(project.enabled ? Theme.running : Theme.idle)
                        .frame(width: 8, height: 8)
                    Text(project.domain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Badge(
                        text: project.enabled ? "serving" : "disabled",
                        tone: project.enabled ? .good : .neutral)
                }

                Text(project.wildcardDomain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)

                HStack(spacing: 8) {
                    Button("Open") {
                        if let url = URL(string: "https://\(project.domain)") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.quiet)
                    .disabled(!project.enabled)

                    Button("Remove") { onRemove(project) }
                        .buttonStyle(.quiet)
                }
            }
        }
    }

    private func mapping(_ project: Project) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("MAPPING")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)

                detailRow("Upstream", "127.0.0.1:\(project.port)", monospaced: true)
                detailRow("Folder", project.folder.path(percentEncoded: false), monospaced: true)
                detailRow("Certificate", "issued locally, apex and wildcard")
            }
        }
    }

    private func runner(_ runner: Runner) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RUNNER")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    // The controls arrive with the launchd agent in milestone 4.
                    Badge(text: "controls in the next release", tone: .neutral)
                }

                detailRow("Command", runner.command, monospaced: true)
                detailRow("At login", runner.autoStart ? "starts automatically" : "manual")
                detailRow(
                    "On crash", runner.keepAlive ? "restarts" : "stays stopped")
            }
        }
    }

    private var noRunner: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                Text("RUNNER")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(Theme.textTertiary)
                Text("You start this project's server yourself. Loca only proxies the port.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func conflicts(_ project: Project) -> some View {
        let others = store.portConflicts(for: project)
        if !others.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.2")
                            .foregroundStyle(Theme.accentSoft)
                        Text("Shares port \(project.port)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text)
                    }
                    Text(
                        "Also mapped to this port: \(others.map(\.domain).joined(separator: ", ")). That is allowed, but only one process can be listening, so the others will show the no-upstream page."
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func detailRow(_ label: String, _ value: String, monospaced: Bool = false)
        -> some View
    {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: monospaced ? .monospaced : .default))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
