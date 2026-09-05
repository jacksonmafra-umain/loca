import LocaCore
import SwiftUI

/// The menu bar item's content.
///
/// This is what makes closing the window sensible: with a way back and
/// per-project actions a click away, the window stops being the app and
/// becomes one view of it. Which is the right shape for something whose job is
/// to sit there and keep domains working.
struct MenuBarView: View {
    let store: AppStore
    let helper: HelperClient
    let runners: RunnerController
    let tunnels: TunnelController

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if store.projects.isEmpty {
                Text("No domains registered")
            } else {
                ForEach(store.projects) { project in
                    projectMenu(project)
                }
            }

            Divider()

            Button("Open Loca") { openWindow(id: "main") }

            Text(helperSummary)
            Text("Loca \(AboutCard.version) · \(AboutCard.author)")

            Divider()

            Button("Quit Loca") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .task { runners.refreshAll(store.projects) }
    }

    /// One submenu per project, titled with the status dot and the domain.
    private func projectMenu(_ project: Project) -> some View {
        Menu("\(statusDot(project))  \(project.domain)") {
            Button("Open https://\(project.domain)") {
                if let url = URL(string: "https://\(project.domain)") {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(!project.enabled)

            Divider()

            Button(project.enabled ? "Disable domain" : "Enable domain") {
                Task { try? await store.setEnabled(!project.enabled, for: project) }
            }

            if project.runner != nil {
                if runners.status(for: project).isRunning {
                    Button("Stop server") { try? runners.stop(project) }
                    Button("Restart server") { try? runners.restart(project) }
                } else {
                    Button("Start server") { try? runners.start(project) }
                }
            }

            // A tunnel can be closed from here but never opened: opening one
            // publishes this machine, and that asks first, in the window where
            // the warning is readable.
            if let session = tunnels.session(forPort: project.port) {
                Divider()
                if let url = session.url {
                    Button("Copy \(url)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                }
                Button("Close public tunnel") { tunnels.stop(port: project.port) }
            }

            Divider()

            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(
                    nil, inFileViewerRootedAtPath: project.folder.path(percentEncoded: false))
            }
        }
    }

    /// A glyph rather than a coloured shape, because a menu bar menu renders
    /// its titles as plain text and a `Circle` would not survive.
    private func statusDot(_ project: Project) -> String {
        // A public tunnel outranks every other state: it is the one thing a
        // glance at the menu bar should never miss.
        if tunnels.session(forPort: project.port)?.url != nil { return "◉" }
        if !project.enabled { return "○" }
        if runners.unstable.contains(project.id) { return "✕" }
        guard project.runner != nil else { return "●" }
        return runners.status(for: project).isRunning ? "●" : "◐"
    }

    private var helperSummary: String {
        switch helper.state {
        case .installed: "Helper running"
        case .requiresApproval: "Helper needs approval in Login Items"
        case .notInstalled: "Helper not installed"
        case .versionSkew: "Helper version mismatch — reinstall it"
        case .unreachable: "Helper unreachable"
        }
    }
}
