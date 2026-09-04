import LocaCore
import SwiftUI

/// Setup: install the helper, install the resolver, trust the certificate
/// authority, and say the two things that otherwise read as bugs.
///
/// Both warnings are here because the spec insists on them, and it is right to.
/// Firefox ignoring the macOS keychain and a stale `.local` entry in
/// `/etc/hosts` produce symptoms that look exactly like Loca being broken.
///
/// It stays reachable after first run, because its diagnostics are the answer
/// to "why is this not working?" at any point later.
struct OnboardingView: View {
    let helper: HelperClient
    let store: AppStore
    var onDone: () -> Void

    @State private var resolverBackup: String?
    @State private var caTrusted = false
    @State private var diagnostics: [String: String] = [:]
    @State private var hostsLocalEntries: [String] = []
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    helperStep
                    resolverStep
                    certificateStep
                    if let error { errorCard(error) }
                    notes
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.never)

            footer
        }
        .background(Theme.surface)
        .task { await refresh() }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Setup")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Badge(
                    text: ready ? "ready" : "\(remainingSteps) step\(remainingSteps == 1 ? "" : "s") left",
                    tone: ready ? .good : .accent)
            }
            Text(
                "Three steps, once. Loca needs a privileged helper to bind ports 80 and 443, a resolver entry so .test names reach it, and your trust for the certificate authority it issues from."
            )
            .font(.system(size: 12))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, Theme.titleBarInset)
        .padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            Text(ready ? "Everything Loca needs is in place" : "Finish the steps above to serve domains")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button("Refresh") { Task { await refresh() } }
                .buttonStyle(.quiet)
            Button("Done") { onDone() }
                .buttonStyle(.accent)
                .disabled(!ready)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.sidebar.opacity(0.6))
        .overlay(alignment: .top) { Divider().overlay(Theme.stroke) }
    }

    // MARK: - Steps

    private var helperStep: some View {
        StepCard(
            number: 1,
            title: "Install the privileged helper",
            detail: helperDetail,
            state: helperState
        ) {
            switch helper.state {
            case .requiresApproval:
                Button("Open Login Items") { helper.openLoginItemsSettings() }
                    .buttonStyle(.accent)
                Button("Check again") { Task { await refresh() } }
                    .buttonStyle(.quiet)
            case .installed:
                Button("Reinstall") { install() }
                    .buttonStyle(.quiet)
            default:
                Button("Install") { install() }
                    .buttonStyle(.accent)
            }
        }
    }

    private var resolverStep: some View {
        StepCard(
            number: 2,
            title: "Point .test at Loca",
            detail: resolverDetail,
            state: resolverInstalled ? .done : .pending
        ) {
            Button(resolverInstalled ? "Reinstall" : "Install") {
                Task { await installResolver() }
            }
            .buttonStyle(resolverInstalled ? AnyButtonStyle(.quiet) : AnyButtonStyle(.accent))
            .disabled(helper.state != .installed || busy)
        }
    }

    private var certificateStep: some View {
        StepCard(
            number: 3,
            title: "Trust the certificate authority",
            detail: certificateDetail,
            state: caTrusted ? .done : .pending
        ) {
            Button(caTrusted ? "Re-trust" : "Trust") { Task { await trust() } }
                .buttonStyle(caTrusted ? AnyButtonStyle(.quiet) : AnyButtonStyle(.accent))
                .disabled(helper.state != .installed || busy)
        }
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let backup = resolverBackup {
                NoteCard(
                    icon: "arrow.down.doc",
                    tone: Theme.accentSoft,
                    title: "An existing resolver entry was backed up",
                    message:
                        "Loca found an /etc/resolver/test it did not write and copied it to \(backup) before replacing it. Nothing was lost."
                )
            }

            if let owner = foreignPortOwner {
                NoteCard(
                    icon: "exclamationmark.triangle",
                    tone: Theme.danger,
                    title: "Something else is using a port Loca needs",
                    message:
                        "\(owner) currently holds it. Loca cannot serve HTTPS until that process releases port 80 or 443."
                )
            }

            // Firefox keeps its own trust store, so this reads as an app bug
            // unless it is said out loud.
            NoteCard(
                icon: "globe",
                tone: Theme.accentSoft,
                title: "Firefox needs one extra setting",
                message:
                    "Firefox does not use the macOS keychain. Open about:config and set security.enterprise_roots.enabled to true, or .test sites will show a certificate warning there while working everywhere else."
            )

            if !hostsLocalEntries.isEmpty {
                NoteCard(
                    icon: "doc.text",
                    tone: Theme.accentSoft,
                    title: "You have .local entries in /etc/hosts",
                    message:
                        "\(hostsLocalEntries.joined(separator: ", ")). Loca will not touch them. Worth knowing that .local collides with mDNS and gives you no HTTPS, which is exactly what .test avoids."
                )
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        NoteCard(
            icon: "exclamationmark.octagon",
            tone: Theme.danger,
            title: "That did not work",
            message: message)
    }

    // MARK: - Derived

    private var ready: Bool {
        helper.state == .installed && resolverInstalled
    }

    private var remainingSteps: Int {
        var remaining = 0
        if helper.state != .installed { remaining += 1 }
        if !resolverInstalled { remaining += 1 }
        if !caTrusted { remaining += 1 }
        return remaining
    }

    private var helperState: StepState {
        switch helper.state {
        case .installed: .done
        case .requiresApproval: .waiting
        default: .pending
        }
    }

    private var helperDetail: String {
        switch helper.state {
        case .notInstalled:
            "The helper is the only part of Loca that runs as root. It binds ports 80 and 443, answers DNS for .test, and nothing else."
        case .requiresApproval:
            "Registered. macOS needs you to enable it in System Settings › General › Login Items before it can start."
        case .installed:
            "Installed and answering." + (helper.helperBuild.map { " \($0)." } ?? "")
        case .versionSkew(let version):
            "The running helper speaks protocol \(version); this app speaks \(locaHelperProtocolVersion). Reinstall it."
        case .unreachable(let reason):
            "Unreachable: \(reason)"
        }
    }

    private var resolverDetail: String {
        resolverInstalled
            ? "/etc/resolver/test is in place, so every .test name resolves to this machine — including subdomains, at any depth."
            : "Loca writes /etc/resolver/test so macOS sends .test lookups to it. An existing file it did not write is backed up, never overwritten."
    }

    private var certificateDetail: String {
        caTrusted
            ? "Trusted for your user account. Certificates are issued locally; nothing leaves this machine."
            : "Loca issues certificates from a local authority. macOS will ask you to approve it — once. Trust is added for your user account only, not machine-wide."
    }

    private var resolverInstalled: Bool {
        diagnostics["resolverManagedByLoca"] == "1"
    }

    /// Only report an owner of 80 or 443 that is not our own Caddy.
    private var foreignPortOwner: String? {
        for key in ["port80Owner", "port443Owner"] {
            guard let owner = diagnostics[key], !owner.hasPrefix("caddy") else { continue }
            return owner
        }
        return nil
    }

    // MARK: - Behaviour

    private func install() {
        helper.register()
        Task { await refresh() }
    }

    private func installResolver() async {
        busy = true
        defer { busy = false }
        do {
            resolverBackup = try await helper.installResolver()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    private func trust() async {
        busy = true
        defer { busy = false }
        do {
            try await helper.trustCertificateAuthority()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    private func refresh() async {
        await helper.refreshState()
        diagnostics = await helper.diagnostics()
        caTrusted = await helper.certificateAuthorityIsTrusted()
        hostsLocalEntries = HostsFile.dotLocalEntries()
    }
}

// MARK: - Pieces

enum StepState {
    case pending, waiting, done
}

private struct StepCard<Actions: View>: View {
    let number: Int
    let title: String
    let detail: String
    let state: StepState
    @ViewBuilder var actions: Actions

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                marker

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) { actions }
                        .padding(.top, 4)
                }
            }
        }
    }

    private var marker: some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.running))
            case .waiting:
                Image(systemName: "clock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.accentSoft))
            case .pending:
                Text("\(number)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.accent.opacity(0.16)))
            }
        }
    }
}

private struct NoteCard: View {
    let icon: String
    let tone: Color
    let title: String
    let message: String

    var body: some View {
        Card(padding: 14) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(tone)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Lets a `?:` pick between two button styles, which SwiftUI's generic
/// `buttonStyle(_:)` otherwise refuses.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { configuration in AnyView(style.makeBody(configuration: configuration)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// Reads the user's `/etc/hosts` looking for the workaround Loca replaces.
///
/// Read-only, always. The spec is explicit: warn once, never touch it.
enum HostsFile {
    static func dotLocalEntries() -> [String] {
        guard let contents = try? String(contentsOf: URL(filePath: "/etc/hosts"), encoding: .utf8)
        else { return [] }

        var names: [String] = []
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            for field in trimmed.split(separator: " ", omittingEmptySubsequences: true).dropFirst()
            where field.hasSuffix(".local") {
                names.append(String(field))
            }
        }
        return names
    }
}
