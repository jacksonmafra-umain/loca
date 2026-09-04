import Foundation

public enum LaunchAgentPlistError: Error, Equatable, Sendable {
    case missingRunner
}

/// Renders the per-project `launchd` agent.
///
/// One agent per project, in the `gui/$UID` domain — not a child of the app or
/// the helper. That is what gives the dev server the graphical session, the
/// login environment, and the user's Keychain, and what makes `RunAtLoad` mean
/// "at my login". It is also why stopping a project is `bootout`, which tears
/// down the whole process group instead of leaving an orphan on the port.
public enum LaunchAgentPlist {
    public static func dictionary(
        for project: Project, runner: Runner, paths: Paths
    ) -> [String: Any] {
        var plist: [String: Any] = [
            "Label": project.agentLabel,
            // A login shell is the only thing that resolves nvm and PATH; a
            // GUI-spawned process inherits neither.
            "ProgramArguments": ["/bin/zsh", "-lc", runner.command],
            "WorkingDirectory": project.folder.path(percentEncoded: false),
            "StandardOutPath": paths.runnerLog(slug: project.slug).path(percentEncoded: false),
            "StandardErrorPath": paths.runnerLog(slug: project.slug).path(percentEncoded: false),
            "RunAtLoad": runner.autoStart,
            "ProcessType": "Interactive",
            "EnvironmentVariables": [
                "LOCA_SLUG": project.slug,
                "PORT": String(project.port),
            ],
        ]

        // Restart on a crash, never on a clean exit — otherwise launchd fights
        // a user who stopped the server on purpose. Omitted rather than set to
        // false, since launchd treats the missing key the same way and an
        // absent key is the clearer statement of intent.
        if runner.keepAlive {
            plist["KeepAlive"] = ["SuccessfulExit": false]
        }

        return plist
    }

    public static func data(for project: Project, runner: Runner, paths: Paths) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: dictionary(for: project, runner: runner, paths: paths),
            format: .xml,
            options: 0)
    }

    /// Convenience for the common case where the runner is the project's own.
    public static func data(for project: Project, paths: Paths) throws -> Data {
        guard let runner = project.runner else { throw LaunchAgentPlistError.missingRunner }
        return try data(for: project, runner: runner, paths: paths)
    }
}
