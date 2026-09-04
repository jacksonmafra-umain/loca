import LocaCore
import SwiftUI

/// The right-hand pane: what the selected domain is, and what its server is
/// doing.
struct ProjectDetailPane: View {
    let project: Project?
    let store: AppStore
    let runners: RunnerController
    var onRemove: (Project) -> Void

    @State private var tailer = LogTailer()
    @State private var runnerError: String?
    @State private var showingLog = true

    private let paths = Paths()

    var body: some View {
        ScrollView {
            if let project {
                VStack(alignment: .leading, spacing: 12) {
                    identity(project)
                    if project.runner != nil {
                        runnerCard(project)
                        if runners.unstable.contains(project.id) {
                            unstableCard(project)
                        }
                        logCard(project)
                    } else {
                        noRunner
                    }
                    mapping(project)
                    conflicts(project)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 8)
                .onChange(of: project.id) { _, _ in followLog(project) }
                .task(id: project.id) { followLog(project) }
            } else {
                Text("Select a domain")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
            }
        }
        .scrollIndicators(.never)
        .onDisappear { tailer.stop() }
    }

    // MARK: - Identity

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

    // MARK: - Runner

    private func runnerCard(_ project: Project) -> some View {
        let status = runners.status(for: project)

        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("RUNNER")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    statusBadge(status, project: project)
                }

                HStack(spacing: 8) {
                    if status.isRunning {
                        Button("Stop") { act(project) { try runners.stop(project) } }
                            .buttonStyle(.quiet)
                        Button("Restart") { act(project) { try runners.restart(project) } }
                            .buttonStyle(.quiet)
                    } else {
                        Button("Start") { act(project) { try runners.start(project) } }
                            .buttonStyle(.accent)
                    }
                }

                if let runner = project.runner {
                    detailRow("Command", runner.command, monospaced: true)
                    Toggle("Start at login", isOn: autoStartBinding(project))
                        .toggleStyle(.checkbox)
                        .tint(Theme.accent)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Toggle("Restart if it crashes", isOn: keepAliveBinding(project))
                        .toggleStyle(.checkbox)
                        .tint(Theme.accent)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }

                if let pid = status.pid {
                    detailRow("Process", "pid \(pid)", monospaced: true)
                }
                // A zero exit is a clean stop and says nothing worth a row.
                if let exit = status.lastExitStatus, exit != 0 {
                    detailRow("Last exit", "status \(exit)", monospaced: true)
                }

                if let guarded = ProtectedFolder.guardedLocation(of: project.folder) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.accentSoft)
                        Text(
                            "The folder is inside \(guarded), which macOS protects. Background agents get no access there, so the log may show a getcwd failure and the server may not start."
                        )
                        .foregroundStyle(Theme.accentSoft)
                    }
                    .font(.system(size: 11))
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let runnerError {
                    Text(runnerError)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func statusBadge(_ status: LaunchctlStatus, project: Project) -> some View {
        if runners.unstable.contains(project.id) {
            Badge(text: "unstable", tone: .danger, systemImage: "exclamationmark.triangle")
        } else {
            switch status.state {
            case .running:
                Badge(text: "running", tone: .good)
            case .notRunning:
                Badge(text: "stopped", tone: .neutral)
            case .notLoaded:
                Badge(text: "not loaded", tone: .neutral)
            }
        }
    }

    /// A broken command plus `keepAlive` restarts forever, and launchd's
    /// ten-second throttle is pacing rather than protection. This offers the
    /// one action that ends it.
    private func unstableCard(_ project: Project) -> some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                    Text("This command keeps crashing")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                }
                Text(
                    "It restarted three times within a minute, so launchd will keep relaunching it indefinitely. The log below should say why."
                )
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

                Button("Stop it and turn off restarting") {
                    Task {
                        var changed = project
                        changed.runner?.keepAlive = false
                        changed.runner?.autoStart = false
                        try? await store.update(changed)
                        try? runners.stop(changed)
                    }
                }
                .buttonStyle(.accent)
            }
        }
    }

    private func logCard(_ project: Project) -> some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("LOG")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button(showingLog ? "Hide" : "Show") { showingLog.toggle() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                if showingLog {
                    Divider().overlay(Theme.stroke)
                    logBody(project)
                }
            }
        }
    }

    @ViewBuilder
    private func logBody(_ project: Project) -> some View {
        if tailer.missingFile {
            Text("No output yet. The log appears once the server writes something.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(14)
        } else if tailer.lines.isEmpty {
            Text("The log file is empty.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .padding(14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(tailer.lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .frame(height: 180)
                .onChange(of: tailer.lines.count) { _, count in
                    // Follow the tail, which is the only part anyone is
                    // reading.
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
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

    // MARK: - Mapping and conflicts

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

    // MARK: - Behaviour

    private func followLog(_ project: Project) {
        guard project.runner != nil else {
            tailer.stop()
            return
        }
        tailer.follow(paths.runnerLog(slug: project.slug))
    }

    private func act(_ project: Project, _ body: () throws -> Void) {
        do {
            try body()
            runnerError = nil
            followLog(project)
        } catch {
            runnerError = error.localizedDescription
        }
    }

    private func autoStartBinding(_ project: Project) -> Binding<Bool> {
        Binding(
            get: { current(project)?.runner?.autoStart ?? false },
            set: { value in
                Task {
                    var changed = project
                    changed.runner?.autoStart = value
                    try? await store.update(changed)
                    // The plist carries RunAtLoad, so it has to be rewritten
                    // for the change to mean anything.
                    if runners.status(for: changed).isRunning {
                        try? runners.start(changed)
                    }
                }
            })
    }

    private func keepAliveBinding(_ project: Project) -> Binding<Bool> {
        Binding(
            get: { current(project)?.runner?.keepAlive ?? false },
            set: { value in
                Task {
                    var changed = project
                    changed.runner?.keepAlive = value
                    try? await store.update(changed)
                    if runners.status(for: changed).isRunning {
                        try? runners.start(changed)
                    }
                }
            })
    }

    private func current(_ project: Project) -> Project? {
        store.projects.first { $0.id == project.id }
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
