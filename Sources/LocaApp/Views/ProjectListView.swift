import LocaCore
import SwiftUI

/// The registered domains.
///
/// A folder dropped anywhere on the list starts a registration, which is the
/// shortest path from "I have a project" to "it has a domain".
struct ProjectListView: View {
    let store: AppStore
    let helper: HelperClient

    @State private var droppedFolder: URL?
    @State private var selection: Project.ID?
    @State private var isTargeted = false
    @State private var removalCandidate: Project?

    var body: some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        chooseFolder()
                    } label: {
                        Label("Add a domain", systemImage: "plus")
                    }
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first(where: isDirectory) else { return false }
                droppedFolder = folder
                return true
            } isTargeted: { isTargeted = $0 }
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(6)
                }
            }
            .sheet(item: $droppedFolder) { folder in
                AddProjectSheet(folder: folder, store: store) {
                    Task { await helper.refreshState() }
                }
            }
            .confirmationDialog(
                removalCandidate.map { "Remove \($0.domain)?" } ?? "",
                isPresented: .init(
                    get: { removalCandidate != nil },
                    set: { if !$0 { removalCandidate = nil } })
            ) {
                Button("Remove", role: .destructive) {
                    if let project = removalCandidate {
                        Task { try? await store.remove(project) }
                    }
                    removalCandidate = nil
                }
                Button("Cancel", role: .cancel) { removalCandidate = nil }
            } message: {
                Text("The folder and its contents are left alone. Only the domain is removed.")
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = store.loadError {
            // A config we could not read is reported, never silently replaced.
            ContentUnavailableView {
                Label("The configuration could not be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else if store.projects.isEmpty {
            ContentUnavailableView {
                Label("No domains yet", systemImage: "globe")
            } description: {
                Text("Drop a project folder here, and it gets an https://….test address.")
            }
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if let error = store.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            ForEach(store.projects) { project in
                row(for: project)
            }
        }
    }

    private func row(for project: Project) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Link(project.domain, destination: URL(string: "https://\(project.domain)")!)
                        .font(.body.weight(.medium))
                        .disabled(!project.enabled)

                    if !store.portConflicts(for: project).isEmpty {
                        // Allowed, but only one of them can be listening.
                        Label("shares port \(project.port)", systemImage: "exclamationmark.2")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Text("127.0.0.1:\(project.port) · \(project.folder.lastPathComponent)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Enabled", isOn: enabledBinding(for: project))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 4)
        .tag(project.id)
        .contextMenu {
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
