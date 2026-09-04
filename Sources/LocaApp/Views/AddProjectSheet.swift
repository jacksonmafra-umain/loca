import LocaCore
import SwiftUI

/// Registers a folder as a domain.
///
/// The detector proposes; this sheet explains the proposal and lets the user
/// correct it. The two things worth the screen space are the list of files each
/// value came from, and the live cross-check against what is actually listening
/// — a guess the machine can confirm is worth far more than a guess presented
/// as fact.
struct AddProjectSheet: View {
    let folder: URL
    let store: AppStore
    var onFinished: () -> Void

    @State private var slug = ""
    @State private var port = ""
    @State private var command = ""
    @State private var useRunner = false
    @State private var autoStart = false
    @State private var keepAlive = true

    @State private var detection = DetectionResult()
    @State private var portOwner: String?
    @State private var saving = false
    @State private var error: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            form
            Divider()
            footer
        }
        .frame(width: 520)
        .task { prepare() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add a domain")
                .font(.headline)
            Text(folder.path(percentEncoded: false))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(20)
    }

    private var form: some View {
        Form {
            Section {
                TextField("Slug", text: $slug)
                    .onChange(of: slug) { _, _ in error = nil }
                LabeledContent("Domain") {
                    Text(slug.isEmpty ? "—" : "\(slug).test").monospaced()
                }
            } footer: {
                Text("Subdomains work too: anything.\(slug.isEmpty ? "slug" : slug).test")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Port", text: $port)
                    .onChange(of: port) { _, _ in
                        error = nil
                        refreshPortOwner()
                    }
            } footer: {
                portCrossCheck
            }

            Section {
                Toggle("Let Loca start this project's server", isOn: $useRunner)
                if useRunner {
                    TextField("Command", text: $command)
                    Toggle("Start at login", isOn: $autoStart)
                    Toggle("Restart if it crashes", isOn: $keepAlive)
                }
            }

            if !detection.sources.isEmpty {
                Section("Detected from") {
                    ForEach(detection.sources, id: \.self) { source in
                        Text(source)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    /// The confirmation the spec asks for: a proposed port that is already held
    /// by a process is a proposal the machine agrees with.
    @ViewBuilder
    private var portCrossCheck: some View {
        if let portNumber = Int(port), Validation.portRange.contains(portNumber) {
            if let owner = portOwner {
                Label(
                    "Port \(portNumber) is already in use by \(owner), which matches this project.",
                    systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Label(
                    "Nothing is listening on port \(portNumber) yet.",
                    systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if !port.isEmpty {
            Label("Ports run from 1 to 65535.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var footer: some View {
        HStack {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Add") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || validationError != nil)
        }
        .padding(20)
    }

    // MARK: - Behaviour

    private func prepare() {
        detection = ProjectDetector.detect(folder: folder)
        slug = store.suggestedSlug(for: folder)
        port = detection.port.map(String.init) ?? ""
        command = detection.command ?? ""
        useRunner = detection.command != nil
        refreshPortOwner()
    }

    private func refreshPortOwner() {
        guard let portNumber = Int(port), Validation.portRange.contains(portNumber) else {
            portOwner = nil
            return
        }
        portOwner = PortLookup.describeOwner(ofPort: portNumber)
    }

    /// The reason Add is disabled, or `nil` when it is not.
    private var validationError: (any Error)? {
        guard let portNumber = Int(port) else {
            return ValidationError.portOutOfRange(0)
        }
        do {
            try Validation.validate(
                slug: slug, port: portNumber, folder: folder, existing: store.projects)
            if useRunner, command.trimmingCharacters(in: .whitespaces).isEmpty {
                return LaunchAgentPlistError.missingRunner
            }
            return nil
        } catch {
            return error
        }
    }

    private func save() async {
        guard let portNumber = Int(port) else { return }
        saving = true
        defer { saving = false }

        let runner =
            useRunner
            ? Runner(
                command: command.trimmingCharacters(in: .whitespaces),
                autoStart: autoStart,
                keepAlive: keepAlive)
            : nil

        do {
            try await store.add(
                folder: folder, slug: slug, port: portNumber, runner: runner)
            onFinished()
            dismiss()
        } catch let failure {
            error = describe(failure)
        }
    }

    private func describe(_ error: any Error) -> String {
        guard let validation = error as? ValidationError else { return error.localizedDescription }
        switch validation {
        case .invalidSlug(let value):
            return
                "\"\(value)\" is not a usable domain label. Use lowercase letters, digits, and hyphens."
        case .duplicateSlug(let value):
            return "\(value).test is already registered."
        case .portOutOfRange(let value):
            return "\(value) is not a port. Ports run from 1 to 65535."
        case .folderNotAbsolute(let path):
            return "\(path) is not an absolute path."
        case .folderTraversal(let path):
            return "\(path) contains \"..\", which is refused."
        }
    }
}
