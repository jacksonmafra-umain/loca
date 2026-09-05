import LocaCore
import SwiftUI

@main
struct LocaAppMain: App {
    @State private var helper: HelperClient
    @State private var store: AppStore
    @State private var runners = RunnerController()
    @State private var tunnels = TunnelController()

    /// `SMAppService` can only be called from inside the signed bundle, so
    /// registering the helper has to go through this binary. Handling a couple
    /// of flags here means the install and uninstall steps in the README are
    /// shell commands rather than a list of buttons to click.
    init() {
        CommandLineMode.runIfRequested()
        // After the flags, never before: --helper-status and its neighbours
        // have to keep working while a window is open.
        SingleInstance.enforceOrHandOver()

        let helper = HelperClient()
        _helper = State(initialValue: helper)
        _store = State(initialValue: AppStore(helper: helper))
    }

    var body: some Scene {
        Window("Loca", id: "main") {
            RootView(helper: helper, store: store, runners: runners, tunnels: tunnels)
                .frame(minWidth: 960, minHeight: 640)
        }
        // No title bar, so the sidebar runs to the top edge. The close,
        // minimise, and zoom buttons then float over the content, which is why
        // every pane starts below Theme.titleBarInset.
        .windowStyle(.hiddenTitleBar)
        // A first launch should not open at whatever size the display allows.
        // A saved frame still wins, so this only shapes the first impression.
        .defaultSize(width: 1000, height: 700)

        // The menu bar item is what makes closing the window sensible: with a
        // way back and per-project actions a click away, the window stops
        // being the app and becomes one view of it.
        MenuBarExtra {
            MenuBarView(store: store, helper: helper, runners: runners, tunnels: tunnels)
        } label: {
            Image(systemName: "lock.fill")
        }
    }
}

struct RootView: View {
    let helper: HelperClient
    let store: AppStore
    let runners: RunnerController
    let tunnels: TunnelController

    @State private var section: Section = Section.lastSelected
    @State private var checkedGates = false
    @State private var inspector: InspectorController?
    /// A port the inspector handed to the domains pane.
    @State private var pendingPort: Int?
    /// A slug the setup pane handed over, migrating a hosts entry.
    @State private var pendingSlug: String?

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $section, store: store, helper: helper)
            content
        }
        .background(Theme.surface)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: section) { _, selected in Section.lastSelected = selected }
        .task {
            store.load()
            await helper.refreshState()

            // Built here rather than as a stored property because it needs to
            // ask the store for a port's domain, and the store is injected.
            if inspector == nil {
                inspector = InspectorController { port in store.domain(forPort: port) }
            }

            guard !checkedGates else { return }
            checkedGates = true

            let diagnostics = await helper.diagnostics()
            let ready = helper.state == .installed && diagnostics["resolverManagedByLoca"] == "1"
            if ready {
                // The proxy holds no state across a reboot, so the saved list
                // is pushed again on every launch.
                await store.resync()
            } else {
                // Nothing else in the window can work until setup is done, so
                // it opens there rather than showing a list that cannot serve.
                section = .setup
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .domains:
            ProjectListView(
                store: store, helper: helper, runners: runners, tunnels: tunnels,
                pendingPort: $pendingPort, pendingSlug: $pendingSlug)
        case .inspector:
            if let inspector {
                InspectorView(inspector: inspector, store: store, tunnels: tunnels) { port in
                    // The inspector knows the port; the domains pane asks for
                    // the folder.
                    pendingPort = port
                    section = .domains
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .setup:
            OnboardingView(helper: helper, store: store) {
                section = .domains
            } onMigrate: { slug in
                // The hosts file records neither a folder nor a port, so the
                // domains pane finishes the job by asking for them.
                pendingSlug = slug
                section = .domains
            }
        }
    }
}

/// A pane for a section whose milestone has not landed yet.
///
/// Better than hiding the row: it says what is coming and keeps the navigation
/// stable between releases.
struct ComingSoonPane: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Badge(text: "not in this release", tone: .neutral)
            }
            .padding(.horizontal, 24)
            .padding(.top, Theme.titleBarInset)
            .padding(.bottom, 16)

            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Theme.accentSoft)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surface)
    }
}
