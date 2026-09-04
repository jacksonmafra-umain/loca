import LocaCore
import SwiftUI

/// What the window can show.
enum Section: String, Hashable, CaseIterable, Identifiable {
    case domains
    case inspector
    case setup

    var id: String { rawValue }

    var title: String {
        switch self {
        case .domains: "Domains"
        case .inspector: "Port Inspector"
        case .setup: "Setup"
        }
    }

    var icon: String {
        switch self {
        case .domains: "globe"
        case .inspector: "dot.radiowaves.left.and.right"
        case .setup: "gearshape"
        }
    }

    var group: String {
        switch self {
        case .domains, .inspector: "Local"
        case .setup: "System"
        }
    }
}

/// The navigation column.
///
/// Deliberately the recessed plane in the window — darker in dark mode, greyer
/// in light — so the content pane reads as nearer without needing a border to
/// say so.
struct SidebarView: View {
    @Binding var selection: Section
    let store: AppStore
    let helper: HelperClient

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .tracking(0.6)
                                .padding(.horizontal, 20)
                                .padding(.bottom, 4)

                            ForEach(group.sections) { section in
                                row(for: section)
                            }
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            helperStatus
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebar)
    }

    // MARK: - Pieces

    private var brand: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Theme.accent)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onAccent))

            VStack(alignment: .leading, spacing: 0) {
                Text("Loca")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text("local https domains")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    private func row(for section: Section) -> some View {
        let isSelected = selection == section

        return Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                // The accent bar, not just a tint. It survives being glanced
                // at, which a background wash at this contrast does not.
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? Theme.accent : .clear)
                    .frame(width: 3, height: 18)

                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)

                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)

                Spacer(minLength: 0)

                if section == .domains, !store.projects.isEmpty {
                    Text("\(store.projects.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                if section == .setup, needsSetup {
                    Circle().fill(Theme.accentSoft).frame(width: 6, height: 6)
                }
            }
            .padding(.trailing, 16)
            .padding(.vertical, 7)
            .background(
                isSelected ? Theme.text.opacity(0.07) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var helperStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.stroke)

            HStack(spacing: 8) {
                Circle()
                    .fill(helper.state == .installed ? Theme.running : Theme.accentSoft)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Helper")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    Text(helperSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var helperSummary: String {
        switch helper.state {
        case .installed: "running"
        case .requiresApproval: "needs approval"
        case .notInstalled: "not installed"
        case .versionSkew: "version mismatch"
        case .unreachable: "unreachable"
        }
    }

    private var needsSetup: Bool {
        helper.state != .installed
    }

    private var groups: [(name: String, sections: [Section])] {
        var ordered: [(String, [Section])] = []
        for section in Section.allCases {
            if let index = ordered.firstIndex(where: { $0.0 == section.group }) {
                ordered[index].1.append(section)
            } else {
                ordered.append((section.group, [section]))
            }
        }
        return ordered.map { (name: $0.0, sections: $0.1) }
    }
}
