import LocaCore
import SwiftUI

/// Every listening TCP port, with who owns it.
///
/// The one thing this has to get right is telling a plain process from a
/// container. Under `lsof` every published container port belongs to
/// `com.docker.backend` with one shared pid, which answers nothing — the useful
/// answer is which of your containers is holding 5432.
struct InspectorView: View {
    let inspector: InspectorController
    let store: AppStore
    /// Opens the add sheet prefilled with a port.
    var onCreateDomain: (Int) -> Void

    @State private var killCandidate: InspectorRow?
    @State private var actionError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            banner
            table
            footer
        }
        .background(Theme.surface)
        .onAppear { inspector.startPolling() }
        .onDisappear { inspector.stopPolling() }
        .confirmationDialog(
            killCandidate.map { "Stop \($0.owner)?" } ?? "",
            isPresented: .init(
                get: { killCandidate != nil },
                set: { if !$0 { killCandidate = nil } })
        ) {
            Button("Stop it", role: .destructive) {
                if let row = killCandidate { kill(row) }
                killCandidate = nil
            }
            Button("Cancel", role: .cancel) { killCandidate = nil }
        } message: {
            if let row = killCandidate {
                Text(
                    "pid \(row.pid) gets SIGTERM, then SIGKILL five seconds later if it is still running. Unsaved work in that process is lost."
                )
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack {
            Text("Port Inspector")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            SearchField(text: Binding(
                get: { inspector.filter },
                set: { inspector.filter = $0 }))
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)
    }

    private var banner: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)

                Group {
                    Text("\(inspector.rows.count) ")
                        .foregroundStyle(Theme.text)
                        + Text(inspector.rows.count == 1 ? "port listening" : "ports listening")
                        .foregroundStyle(Theme.textSecondary)
                        + Text(containerSummary)
                        .foregroundStyle(Theme.accent)
                }
                .font(.system(size: 13, weight: .medium))

                Spacer()

                if inspector.dockerAvailable {
                    Badge(text: "docker connected", tone: .good)
                } else {
                    // Absence is the normal case on a machine without Docker,
                    // so this is stated plainly rather than as a warning.
                    Badge(text: "docker not running", tone: .neutral)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            Text(
                inspector.isPolling
                    ? "Refreshing every 2 seconds while this tab is open"
                    : "Paused")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)

            if let actionError {
                Text(actionError)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.danger)
            }

            Spacer()
            Button("Refresh now") { Task { await inspector.refresh() } }
                .buttonStyle(.quiet)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Theme.sidebar.opacity(0.6))
        .overlay(alignment: .top) { Divider().overlay(Theme.stroke) }
    }

    // MARK: - Table

    @ViewBuilder
    private var table: some View {
        if inspector.rows.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accentSoft)
                Text("Nothing is listening")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text("No process on this machine currently holds a TCP port open.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    columnHeadings
                    ForEach(inspector.visibleRows) { row in
                        self.row(row)
                        Divider().overlay(Theme.stroke)
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .scrollIndicators(.never)
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
    }

    private var columnHeadings: some View {
        HStack(spacing: 12) {
            heading("PORT", width: 58)
            heading("OWNER", width: nil)
            heading("DETAIL", width: 200)
            heading("DOMAIN", width: 150)
            heading("PID", width: 60)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.cardRaised.opacity(0.5))
    }

    private func heading(_ text: String, width: CGFloat?) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private func row(_ row: InspectorRow) -> some View {
        HStack(spacing: 12) {
            Text(String(row.port))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text)
                .frame(width: 58, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: row.isContainer ? "shippingbox.fill" : "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(row.isContainer ? Theme.accentSoft : Theme.textTertiary)
                Text(row.owner)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if row.family == .ipv6 {
                    Badge(text: "v6", tone: .neutral)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(row.detail ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 200, alignment: .leading)

            Group {
                if let domain = row.domain {
                    Text(domain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 150, alignment: .leading)

            Text(String(row.pid))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 60, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            if row.domain == nil {
                Button("Create a domain for port \(row.port)") { onCreateDomain(row.port) }
            } else {
                Button("Open \(row.domain ?? "")") {
                    if let domain = row.domain, let url = URL(string: "https://\(domain)") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            Button("Reveal working folder") { inspector.revealFolder(row) }
            Button("Copy pid") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(row.pid), forType: .string)
            }
            Divider()
            Button("Stop this process…", role: .destructive) { killCandidate = row }
        }
    }

    // MARK: - Behaviour

    private func kill(_ row: InspectorRow) {
        Task {
            do {
                try await inspector.kill(row)
                actionError = nil
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private var containerSummary: String {
        let containers = inspector.rows.filter(\.isContainer).count
        return containers == 0 ? "" : " · \(containers) in containers"
    }
}

/// A search field that matches the rest of the window.
private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .frame(width: 150)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}
