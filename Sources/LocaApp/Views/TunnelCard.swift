import LocaCore
import SwiftUI

/// The switch that puts a project on the public internet, and everything the
/// user needs to know before flipping it.
struct TunnelCard: View {
    let project: Project
    let store: AppStore
    let tunnels: TunnelController

    @State private var error: String?
    @State private var confirming = false
    @State private var copied = false

    private var session: TunnelSession? { tunnels.session(forPort: project.port) }

    /// The project's own choice, or the first provider this machine can
    /// actually run.
    private var provider: TunnelProvider {
        project.tunnelProvider ?? tunnels.installedProviders.first ?? .cloudflared
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header
                providerPicker
                body(for: session)
                if let error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(
            "Put \(project.domain) on the public internet?",
            isPresented: $confirming
        ) {
            Button("Open the tunnel") { open() }
            Button("Cancel", role: .cancel) { confirming = false }
        } message: {
            Text(
                "\(provider.displayName) will hand out an address that anyone can reach, and every request to it goes to \(project.upstream) on this machine. It closes when you turn this off or quit Loca."
            )
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("TUNNEL")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            badge
            Toggle("", isOn: toggleBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.accent)
                .disabled(tunnels.installedProviders.isEmpty)
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch session?.state {
        case .live: Badge(text: "public", tone: .danger, systemImage: "globe")
        case .starting: Badge(text: "opening", tone: .warning)
        case .failed: Badge(text: "failed", tone: .danger)
        case nil: Badge(text: "off", tone: .neutral)
        }
    }

    /// Only shown when there is a choice to make. One installed provider is
    /// not a decision, and no installed provider is a different problem.
    @ViewBuilder
    private var providerPicker: some View {
        if tunnels.installedProviders.count > 1 {
            Picker("", selection: providerBinding) {
                ForEach(tunnels.installedProviders, id: \.self) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Changing provider mid-tunnel would mean closing one and opening
            // another behind the user's back.
            .disabled(session != nil)
        }
    }

    @ViewBuilder
    private func body(for session: TunnelSession?) -> some View {
        if tunnels.installedProviders.isEmpty {
            missingProviders
        } else {
            switch session?.state {
            case .live(let url): live(url)
            case .starting: opening
            case .failed(let reason): failed(reason)
            case nil: offExplanation
            }
        }
    }

    private var offExplanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Turning this on asks \(provider.displayName) for a public address that reaches \(project.upstream). Nothing is exposed until you do."
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if provider.needsAccount, let hint = provider.accountHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var opening: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Asking \(provider.displayName) for an address…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func live(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(url)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.accent)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(copied ? "Copied" : "Copy") { copy(url) }
                    .buttonStyle(.quiet)
                Button("Open") {
                    if let link = URL(string: url) { NSWorkspace.shared.open(link) }
                }
                .buttonStyle(.quiet)
            }

            // The tunnel reaches the port, not the proxy, so the origin sees
            // the provider's hostname. Anything routing by vhost — most
            // frameworks with a host allowlist — notices immediately, and this
            // is cheaper to read than to debug.
            Text(
                "Requests arrive with the provider's hostname in Host, not \(project.domain). A server that routes by hostname or checks allowed hosts needs that address added."
            )
            .font(.system(size: 11))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reason)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.danger)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if provider.needsAccount, let hint = provider.accountHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Dismiss") { tunnels.stop(port: project.port) }
                .buttonStyle(.quiet)
        }
    }

    private var missingProviders: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Neither tunnel program is installed.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            ForEach(TunnelProvider.allCases, id: \.self) { candidate in
                Text(candidate.installCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Behaviour

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { session != nil },
            set: { wanted in
                if wanted {
                    // Publishing a local server is not a thing to do on a
                    // stray click, so the switch asks first.
                    confirming = true
                } else {
                    tunnels.stop(port: project.port)
                    error = nil
                }
            })
    }

    private var providerBinding: Binding<TunnelProvider> {
        Binding(
            get: { provider },
            set: { chosen in
                Task {
                    var changed = project
                    changed.tunnelProvider = chosen
                    try? await store.update(changed)
                }
            })
    }

    private func open() {
        confirming = false
        do {
            try tunnels.start(port: project.port, provider: provider, label: project.domain)
            error = nil
            // A project that has never chosen keeps using whatever was first
            // available, so record what it actually opened with.
            if project.tunnelProvider == nil {
                Task {
                    var changed = project
                    changed.tunnelProvider = provider
                    try? await store.update(changed)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func copy(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
