import LocaCore
import SwiftUI

@main
struct LocaAppMain: App {
    @State private var helper = HelperClient()

    /// `SMAppService` can only be called from inside the signed bundle, so
    /// registering the helper has to go through this binary. Handling a couple
    /// of flags here means the install and uninstall steps in the README are
    /// shell commands rather than a list of buttons to click.
    init() {
        CommandLineMode.runIfRequested()
    }

    var body: some Scene {
        Window("Loca", id: "main") {
            RootView(helper: helper)
                .frame(minWidth: 620, minHeight: 460)
                .task { await helper.refreshState() }
        }
    }
}

/// Replaced by the project list in milestone 3. Until then it is the surface
/// that installs the helper and reports what it says back, which is how
/// milestone 1 gets verified at all.
struct RootView: View {
    let helper: HelperClient
    @State private var diagnostics: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Loca")
                .font(.largeTitle)
            Text("core \(LocaCoreVersion.current), helper protocol \(locaHelperProtocolVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            LabeledContent("Helper") { Text(statusText).foregroundStyle(statusColor) }
            if let build = helper.helperBuild {
                LabeledContent("Reported build") { Text(build).monospaced() }
            }
            if let error = helper.lastError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Button("Install helper") { helper.register() }
                Button("Open Login Items") { helper.openLoginItemsSettings() }
                Button("Refresh") { Task { await helper.refreshState() } }
                Button("Diagnostics") {
                    Task { diagnostics = await helper.diagnostics() }
                }
                Button("Remove helper") { Task { await helper.unregister() } }
            }

            if !diagnostics.isEmpty {
                Divider()
                ForEach(diagnostics.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) { Text(diagnostics[key] ?? "").monospaced() }
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private var statusText: String {
        switch helper.state {
        case .notInstalled: "not installed"
        case .requiresApproval: "waiting for approval in Login Items"
        case .installed: "installed"
        case .versionSkew(let version): "version skew — helper speaks \(version)"
        case .unreachable(let reason): "unreachable — \(reason)"
        }
    }

    private var statusColor: Color {
        switch helper.state {
        case .installed: .green
        case .requiresApproval: .orange
        default: .red
        }
    }
}
