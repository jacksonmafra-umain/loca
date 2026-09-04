import LocaCore
import SwiftUI

@main
struct LocaAppMain: App {
    var body: some Scene {
        Window("Loca", id: "main") {
            RootView()
                .frame(minWidth: 620, minHeight: 420)
        }
        .windowResizability(.contentSize)
    }
}

/// Replaced by the project list in milestone 3. Until then it is the surface
/// that installs the helper and reports what it says back, which is how
/// milestone 1 gets verified at all.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Loca")
                .font(.largeTitle)
            Text("core \(LocaCoreVersion.current), helper protocol \(locaHelperProtocolVersion)")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(40)
    }
}
