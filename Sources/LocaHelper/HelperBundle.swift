import Foundation

/// Locates resources next to the helper inside the app bundle.
///
/// The helper is launched by launchd through `BundleProgram`, so it cannot rely
/// on `Bundle.main` resolving to the app: it derives the layout from its own
/// executable path instead, which is the one thing always true.
///
///     Loca.app/Contents/MacOS/LocaHelper      ← this executable
///     Loca.app/Contents/Resources/caddy       ← what it needs
enum HelperBundle {
    static var caddyBinary: URL {
        contentsDirectory.appending(path: "Resources/caddy")
    }

    static var contentsDirectory: URL {
        executable
            .deletingLastPathComponent()  // MacOS
            .deletingLastPathComponent()  // Contents
    }

    private static var executable: URL {
        // Bundle.main.executableURL is right when it resolves; the argv[0]
        // fallback covers a launch context where it does not.
        Bundle.main.executableURL
            ?? URL(filePath: CommandLine.arguments.first ?? "/")
    }
}
