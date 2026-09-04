import LocaCore
import SwiftUI

@main
struct LocaAppMain: App {
    @State private var helper: HelperClient
    @State private var store: AppStore

    /// `SMAppService` can only be called from inside the signed bundle, so
    /// registering the helper has to go through this binary. Handling a couple
    /// of flags here means the install and uninstall steps in the README are
    /// shell commands rather than a list of buttons to click.
    init() {
        CommandLineMode.runIfRequested()

        let helper = HelperClient()
        _helper = State(initialValue: helper)
        _store = State(initialValue: AppStore(helper: helper))
    }

    var body: some Scene {
        Window("Loca", id: "main") {
            RootView(helper: helper, store: store)
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}

struct RootView: View {
    let helper: HelperClient
    let store: AppStore

    /// Onboarding is shown until the gates are met, and can be reopened from
    /// the toolbar afterwards — its warnings and diagnostics stay useful long
    /// after first run.
    @State private var showingSetup = false
    @State private var checkedGates = false

    var body: some View {
        NavigationStack {
            ProjectListView(store: store, helper: helper)
                .navigationTitle("Loca")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            showingSetup = true
                        } label: {
                            Label("Setup", systemImage: "gearshape")
                        }
                        .help("Helper, resolver, and certificate status")
                    }
                }
        }
        .sheet(isPresented: $showingSetup) {
            OnboardingView(helper: helper, store: store) { showingSetup = false }
                .frame(width: 640, height: 620)
        }
        .task {
            store.load()
            await helper.refreshState()

            guard !checkedGates else { return }
            checkedGates = true

            let diagnostics = await helper.diagnostics()
            let ready =
                helper.state == .installed && diagnostics["resolverManagedByLoca"] == "1"
            if ready {
                // The proxy holds no state across a reboot, so the saved list
                // is pushed again on every launch.
                await store.resync()
            } else {
                showingSetup = true
            }
        }
    }
}
