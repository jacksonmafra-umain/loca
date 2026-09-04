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
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    domainCard
                    portCard
                    runnerCard
                    if !detection.sources.isEmpty { detectionCard }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)

            footer
        }
        .frame(width: 540, height: 620)
        .background(Theme.surface)
        .task { prepare() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Add a domain")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(folder.path(percentEncoded: false))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reason = validationReason {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .buttonStyle(.quiet)
                .keyboardShortcut(.cancelAction)
            Button(saving ? "Adding…" : "Add") { Task { await save() } }
                .buttonStyle(.accent)
                .keyboardShortcut(.defaultAction)
                .disabled(saving || validationReason != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.sidebar.opacity(0.6))
        .overlay(alignment: .top) { Divider().overlay(Theme.stroke) }
    }

    // MARK: - Cards

    private var domainCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("DOMAIN")
                Field(text: $slug, placeholder: "slug")
                    .onChange(of: slug) { _, _ in error = nil }

                HStack(spacing: 6) {
                    Text(slug.isEmpty ? "slug.test" : "\(slug).test")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(slug.isEmpty ? Theme.textTertiary : Theme.accent)
                    Text("and")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    Text("*.\(slug.isEmpty ? "slug" : slug).test")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }

                Text("Subdomains work at any depth, with the same certificate.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var portCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("UPSTREAM PORT")
                Field(text: $port, placeholder: "3000")
                    .onChange(of: port) { _, _ in
                        error = nil
                        refreshPortOwner()
                    }
                portCrossCheck
            }
        }
    }

    /// The confirmation the spec asks for: a proposed port that is already held
    /// by a process is a proposal the machine agrees with.
    @ViewBuilder
    private var portCrossCheck: some View {
        if let portNumber = Int(port), Validation.portRange.contains(portNumber) {
            if let owner = portOwner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.running)
                    Text("Port \(portNumber) is already in use by \(owner), which matches this project.")
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(.system(size: 11))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.textTertiary)
                    Text("Nothing is listening on port \(portNumber) yet.")
                        .foregroundStyle(Theme.textTertiary)
                }
                .font(.system(size: 11))
            }
        } else if !port.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.accentSoft)
                Text("Ports run from 1 to 65535.")
                    .foregroundStyle(Theme.accentSoft)
            }
            .font(.system(size: 11))
        }
    }

    private var runnerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("RUNNER")
                    Spacer()
                    Toggle("", isOn: $useRunner)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.accent)
                        .controlSize(.small)
                }

                if useRunner {
                    Field(text: $command, placeholder: "pnpm dev")
                    Toggle("Start at login", isOn: $autoStart)
                        .toggleStyle(.checkbox)
                        .tint(Theme.accent)
                    Toggle("Restart if it crashes", isOn: $keepAlive)
                        .toggleStyle(.checkbox)
                        .tint(Theme.accent)
                    Text("The command runs through a login shell, so nvm and PATH resolve.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)

                    if let guarded = ProtectedFolder.guardedLocation(of: folder) {
                        // A launchd agent has no window to show a consent
                        // prompt in, so macOS never asks and never grants. The
                        // symptom is a getcwd failure in the log and a server
                        // that may or may not limp along — invisible unless it
                        // is said here.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.accentSoft)
                            Text(
                                "This folder is inside \(guarded), which macOS protects. Background agents cannot get access there, so the runner may fail. Proxying the port is unaffected."
                            )
                            .foregroundStyle(Theme.accentSoft)
                        }
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Off means you start the server yourself and Loca only proxies the port.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
        }
    }

    private var detectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("DETECTED FROM")
                ForEach(detection.sources, id: \.self) { source in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textTertiary)
                        Text(source)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
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

    /// Why Add is disabled, in the user's terms, or `nil` when it is enabled.
    private var validationReason: String? {
        guard let portNumber = Int(port) else { return "Enter a port" }
        if useRunner, command.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Enter a command, or turn the runner off"
        }
        do {
            try Validation.validate(
                slug: slug, port: portNumber, folder: folder, existing: store.projects)
            return nil
        } catch {
            return describe(error)
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
            try await store.add(folder: folder, slug: slug, port: portNumber, runner: runner)
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
            return value.isEmpty
                ? "Enter a domain label"
                : "\"\(value)\" will not work as a domain label — use lowercase letters, digits, and hyphens"
        case .duplicateSlug(let value):
            return "\(value).test is already registered"
        case .portOutOfRange(let value):
            return "\(value) is not a port — they run from 1 to 65535"
        case .folderNotAbsolute(let path):
            return "\(path) is not an absolute path"
        case .folderTraversal(let path):
            return "\(path) contains \"..\", which is refused"
        }
    }

    // MARK: - Small pieces

    private func Label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A text field that matches the rest of the window.
///
/// `.textFieldStyle(.plain)` plus an explicit background, because the stock
/// bordered field keeps its own light chrome and reads as pasted onto a dark
/// card.
private struct Field: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Theme.inset, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}
