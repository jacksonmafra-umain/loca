import LocaCore
import SwiftUI

/// The domains pane: a summary banner, the list of registered domains, and the
/// detail of whichever is selected.
///
/// A folder dropped anywhere here starts a registration, which is the shortest
/// path from "I have a project" to "it has a domain".
struct ProjectListView: View {
    let store: AppStore
    let helper: HelperClient
    let runners: RunnerController
    /// A port handed over by the inspector, waiting for a folder to go with it.
    @Binding var pendingPort: Int?
    /// A slug handed over by the setup pane, migrating a hosts entry.
    @Binding var pendingSlug: String?

    @State private var droppedFolder: URL?
    @State private var sheetPort: Int?
    @State private var sheetSlug: String?
    @State private var selection: Project.ID?
    @State private var isTargeted = false
    @State private var removalCandidate: Project?

    var body: some View {
        VStack(spacing: 0) {
            header
            banner
            body(for: store.projects)
            actionBar
        }
        .background(Theme.surface)
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: isDirectory) else { return false }
            droppedFolder = folder
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(10)
            }
        }
        .sheet(item: $droppedFolder) { folder in
            AddProjectSheet(
                folder: folder, store: store, initialPort: sheetPort, initialSlug: sheetSlug
            ) {
                sheetPort = nil
                sheetSlug = nil
                Task { await helper.refreshState() }
            }
        }
        // The inspector knows a port but not a folder, so arriving here asks
        // for the folder and carries the port through.
        .onChange(of: pendingPort) { _, port in
            guard let port else { return }
            pendingPort = nil
            sheetPort = port
            chooseFolder()
        }
        // A hosts migration knows the name but neither a folder nor a port,
        // since /etc/hosts records neither.
        .onChange(of: pendingSlug) { _, slug in
            guard let slug else { return }
            pendingSlug = nil
            sheetSlug = slug
            chooseFolder()
        }
        .confirmationDialog(
            removalCandidate.map { "Remove \($0.domain)?" } ?? "",
            isPresented: .init(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } })
        ) {
            Button("Remove", role: .destructive) {
                if let project = removalCandidate {
                    Task {
                        // The agent goes first. Dropping the project while its
                        // launchd agent is still loaded would leave a server
                        // running with nothing in the UI to stop it.
                        runners.removeAgent(project)
                        try? await store.remove(project)
                    }
                }
                removalCandidate = nil
            }
            Button("Cancel", role: .cancel) { removalCandidate = nil }
        } message: {
            Text("The folder and its contents are left alone. Only the domain is removed.")
        }
        // Polls only while this pane is on screen. An idle app spawning
        // launchctl every three seconds forever is a bill nobody asked for.
        .onAppear { runners.startPolling { store.projects } }
        .onDisappear { runners.stopPolling() }
    }

    // MARK: - Header and banner

    private var header: some View {
        HStack {
            Text("Domains")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button("Add a domain") { chooseFolder() }
                .buttonStyle(.quiet)
        }
        .padding(.horizontal, 24)
        .padding(.top, Theme.titleBarInset)
        .padding(.bottom, 16)
    }

    /// The one line worth reading first: how many domains, and how many are
    /// actually being served.
    private var banner: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)

                if store.projects.isEmpty {
                    Text("No domains registered yet")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Group {
                        Text(String(store.projects.count) + " ")
                            .foregroundStyle(Theme.text)
                            + Text(store.projects.count == 1 ? "domain, " : "domains, ")
                            .foregroundStyle(Theme.textSecondary)
                            + Text(String(servingCount) + " serving")
                            .foregroundStyle(Theme.accent)
                    }
                    .font(.system(size: 13, weight: .medium))
                }

                Spacer()

                if let error = store.lastError {
                    Badge(text: error, tone: .danger, systemImage: "exclamationmark.triangle")
                } else if !misplacedCount.isEmpty {
                    Badge(
                        text: misplacedCount, tone: .danger,
                        systemImage: "questionmark.folder")
                } else if helper.state != .installed {
                    Badge(
                        text: "helper not ready", tone: .warning,
                        systemImage: "exclamationmark.circle")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(for projects: [Project]) -> some View {
        if let loadError = store.loadError {
            // A config we could not read is reported, never silently replaced.
            empty(
                icon: "exclamationmark.triangle",
                title: "The configuration could not be read",
                detail: loadError,
                tone: Theme.danger)
        } else if projects.isEmpty {
            empty(
                icon: "arrow.down.doc",
                title: "Drop a project folder here",
                detail:
                    "Loca reads the folder to propose a port and a start command, then gives it an https://….test address — subdomains included.",
                tone: Theme.accentSoft)
        } else {
            HStack(spacing: 14) {
                list(projects)
                    .frame(minWidth: 300)
                ProjectDetailPane(
                    project: selectedProject(in: projects),
                    store: store,
                    runners: runners,
                    onRemove: { removalCandidate = $0 })
                    .frame(minWidth: 300)
            }
            .padding(.horizontal, 24)
        }
    }

    private func list(_ projects: [Project]) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(projects) { project in
                    row(for: project)
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }

    private func row(for project: Project) -> some View {
        let isSelected = selection == project.id

        return Button {
            selection = project.id
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Theme.accent : .clear)
                    .frame(width: 3, height: 26)

                Circle()
                    .fill(project.enabled ? Theme.running : Theme.idle)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(project.domain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.text)

                        if !FolderCheck.check(project.folder).isUsable {
                            Badge(text: "folder gone", tone: .danger, systemImage: "questionmark.folder")
                        }
                        if !store.portConflicts(for: project).isEmpty {
                            // Allowed, but only one of them can be listening.
                            Badge(text: "shared port", tone: .warning)
                        }
                        if runners.unstable.contains(project.id) {
                            Badge(text: "crashing", tone: .danger)
                        } else if project.runner != nil {
                            Badge(
                                text: runners.status(for: project).isRunning
                                    ? "running" : "stopped",
                                tone: runners.status(for: project).isRunning ? .good : .neutral)
                        }
                    }

                    Text("\(project.upstream) · \(project.folder.lastPathComponent)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Toggle("", isOn: enabledBinding(for: project))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .controlSize(.small)
            }
            .padding(.trailing, 14)
            .padding(.vertical, 10)
            .background(
                isSelected ? Theme.cardRaised : Theme.card,
                in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.4) : Theme.stroke,
                                  lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open in browser") {
                if let url = URL(string: "https://\(project.domain)") {
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(
                    nil, inFileViewerRootedAtPath: project.folder.path(percentEncoded: false))
            }
            Button("Copy address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("https://\(project.domain)", forType: .string)
            }
            Divider()
            Button("Remove…", role: .destructive) { removalCandidate = project }
        }
    }

    private func empty(icon: String, title: String, detail: String, tone: Color) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tone)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 12) {
            Text(actionBarStatus)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            Spacer()

            if let project = selectedProject(in: store.projects), project.enabled {
                Button("Open \(project.domain)") {
                    if let url = URL(string: "https://\(project.domain)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.accent)
            } else {
                Button("Add a domain") { chooseFolder() }
                    .buttonStyle(.accent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.sidebar.opacity(0.6))
        .overlay(alignment: .top) { Divider().overlay(Theme.stroke) }
    }

    private var actionBarStatus: String {
        if store.projects.isEmpty { return "Drop a folder anywhere in this pane" }
        let disabled = store.projects.count - servingCount
        return disabled == 0
            ? "All \(store.projects.count) domains are being served"
            : "\(servingCount) serving · \(disabled) disabled"
    }

    // MARK: - Behaviour

    private var servingCount: Int {
        store.projects.filter(\.enabled).count
    }

    /// Worth surfacing in the banner: a folder that moved breaks the runner
    /// while the domain keeps working, so nothing else on this screen would
    /// hint at it.
    private var misplacedCount: String {
        let count = store.misplaced().count
        switch count {
        case 0: return ""
        case 1: return "1 folder missing"
        default: return "\(count) folders missing"
        }
    }

    private func selectedProject(in projects: [Project]) -> Project? {
        projects.first { $0.id == selection } ?? projects.first
    }

    /// Writes through the store, so the toggle reflects what the proxy accepted
    /// rather than what was clicked.
    private func enabledBinding(for project: Project) -> Binding<Bool> {
        Binding(
            get: { store.projects.first { $0.id == project.id }?.enabled ?? project.enabled },
            set: { enabled in
                Task { try? await store.setEnabled(enabled, for: project) }
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        droppedFolder = folder
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

/// `sheet(item:)` for a plain value, so the dropped folder can drive the sheet
/// without a wrapper type.
extension View {
    func sheet<Item: Hashable, Content: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } })
        ) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}
