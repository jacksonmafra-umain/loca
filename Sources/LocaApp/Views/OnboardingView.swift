import LocaCore
import SwiftUI

/// First run: install the helper, install the resolver, trust the certificate
/// authority, and say the two things that otherwise read as bugs.
///
/// Both warnings are here because the spec insists on them, and it is right to.
/// Firefox ignoring the System keychain and a stale `.local` entry in
/// `/etc/hosts` both produce symptoms that look exactly like Loca being broken.
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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                title
                helperStep
                resolverStep
                certificateStep
                checks
                Spacer(minLength: 0)
            }
            .padding(28)
        }
        .task { await refresh() }
    }

    // MARK: - Sections

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up Loca")
                .font(.largeTitle)
            Text(
                "Three steps, once. Loca needs a privileged helper to bind ports 80 and 443, a resolver entry so .test names reach it, and your trust for the certificate authority it issues from."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var helperStep: some View {
        Step(
            number: 1,
            title: "Install the privileged helper",
            detail: helperDetail,
            state: helperState
        ) {
            switch helper.state {
            case .requiresApproval:
                Button("Open Login Items") { helper.openLoginItemsSettings() }
                Button("Check again") { Task { await refresh() } }
            case .installed:
                Button("Reinstall") { install() }
            default:
                Button("Install") { install() }
            }
        }
    }

    private var resolverStep: some View {
        Step(
            number: 2,
            title: "Point .test at Loca",
            detail: resolverDetail,
            state: resolverInstalled ? .done : .pending
        ) {
            Button(resolverInstalled ? "Reinstall" : "Install") {
                Task { await installResolver() }
            }
            .disabled(helper.state != .installed || busy)
        }
    }

    private var certificateStep: some View {
        Step(
            number: 3,
            title: "Trust the certificate authority",
            detail:
                caTrusted
                ? "Trusted for your user account. Certificates are issued locally; nothing leaves this machine."
                : "Loca issues certificates from a local authority. macOS will ask you to approve it — once. Trust is added for your user account only, not machine-wide.",
            state: caTrusted ? .done : .pending
        ) {
            Button(caTrusted ? "Re-trust" : "Trust") { Task { await trust() } }
                .disabled(helper.state != .installed || busy)
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let backup = resolverBackup {
                Note(
                    icon: "arrow.down.doc",
                    title: "An existing resolver entry was backed up",
                    message:
                        "Loca found an /etc/resolver/test it did not write and copied it to \(backup) before replacing it. Nothing was lost."
                )
            }

            if let owner = foreignPortOwner {
                Note(
                    icon: "exclamationmark.triangle",
                    title: "Something else is using a port Loca needs",
                    message:
                        "\(owner) currently holds it. Loca cannot serve HTTPS until that process releases port 80 or 443."
                )
            }

            // Firefox keeps its own trust store, so this reads as an app bug
            // unless it is said out loud.
            Note(
                icon: "globe",
                title: "Firefox needs one extra setting",
                message:
                    "Firefox does not use the macOS keychain. Open about:config and set security.enterprise_roots.enabled to true, or .test sites will show a certificate warning there while working everywhere else."
            )

            if !hostsLocalEntries.isEmpty {
                Note(
                    icon: "doc.text",
                    title: "You have .local entries in /etc/hosts",
                    message:
                        "\(hostsLocalEntries.joined(separator: ", ")). Loca will not touch them. Worth knowing that .local collides with mDNS and gives you no HTTPS, which is what .test avoids."
                )
            }

            HStack {
                Spacer()
                Button("Done") { onDone() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(helper.state != .installed || !resolverInstalled)
            }
        }
    }

    // MARK: - Derived

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

/// Outside `Step` so callers can name it without spelling out `Step`'s generic
/// parameter.
private enum StepState {
    case pending, waiting, done
}

private struct Step<Actions: View>: View {
    let number: Int
    let title: String
    let detail: String
    let state: StepState
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            marker
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { actions }
                    .padding(.top, 2)
            }
        }
    }

    private var marker: some View {
        Group {
            switch state {
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .waiting:
                Image(systemName: "clock.fill").foregroundStyle(.orange)
            case .pending:
                Text("\(number)")
                    .font(.callout.weight(.semibold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.quaternary))
            }
        }
        .font(.title3)
        .frame(width: 24)
    }
}

private struct Note: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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
