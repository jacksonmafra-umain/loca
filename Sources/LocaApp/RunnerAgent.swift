import Foundation
import LocaCore

/// The `launchctl` mechanics, with no observable state.
///
/// Kept separate from `RunnerController` for the same reason `SystemResolver`
/// is separate from `ResolverInstaller`: the controller is `@MainActor` and
/// exists to drive a UI, while these calls are synchronous and are also needed
/// from the command line, which runs before the main actor has an executor.
enum RunnerAgent {
    static var domainTarget: String { "gui/\(getuid())" }

    static func serviceTarget(for project: Project) -> String {
        "\(domainTarget)/\(project.agentLabel)"
    }

    // MARK: - Status

    static func status(for project: Project) -> LaunchctlStatus {
        let result = launchctl(["print", serviceTarget(for: project)])
        return LaunchctlStatusParser.parse(result.output, exitCode: result.status)
    }

    // MARK: - Commands

    /// Writes the agent plist, then loads it — booting the old one out first
    /// whenever the file changed.
    ///
    /// `kickstart` restarts the definition launchd already holds; it does not
    /// re-read the plist. Reusing it after an edit is how a project keeps
    /// running its previous command, port or folder until the next login, with
    /// the file on disk saying otherwise the whole time.
    static func start(_ project: Project, paths: Paths) throws {
        guard let runner = project.runner else { throw RunnerError.missingRunner }

        // Refuse before launchd gets involved. Starting anyway produces a
        // working-directory failure in the log that names the symptom and not
        // the cause, and `KeepAlive` then retries it every ten seconds
        // forever.
        if let problem = FolderCheck.problem(with: project.folder) {
            throw RunnerError.folderUnusable(problem)
        }

        try FileManager.default.createDirectory(
            at: paths.logDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.launchAgentsDirectory, withIntermediateDirectories: true)

        let plist = paths.runnerPlist(slug: project.slug)
        let data = try LaunchAgentPlist.data(
            for: project, runner: runner, paths: paths,
            loginPath: LoginShellPathProbe.capture())
        let unchanged = (try? Data(contentsOf: plist)) == data
        try data.write(to: plist)

        let loaded = status(for: project).state != .notLoaded
        if loaded && unchanged {
            try run("kickstart", ["kickstart", "-k", serviceTarget(for: project)])
            return
        }
        if loaded {
            try stop(project)
        }
        try bootstrap(plist)

        // `bootstrap` loads the label; whether it also *runs* it is up to
        // RunAtLoad and KeepAlive, so a project with both off would come back
        // loaded and idle from a button that says Start. Kickstart says run it
        // — without `-k`, which would restart what bootstrap already started.
        try run("kickstart", ["kickstart", serviceTarget(for: project)])
    }

    /// `bootout` tears down the whole process group.
    ///
    /// That is the difference between stopping a server and leaving an orphan
    /// holding the port — killing the parent alone routinely leaves a child
    /// listening, and the next start then fails for a reason that looks
    /// unrelated.
    static func stop(_ project: Project) throws {
        let result = launchctl(["bootout", serviceTarget(for: project)])
        // Already gone is a success: the caller wanted it stopped.
        guard result.status == 0 || result.output.contains("Could not find service") else {
            throw RunnerError.launchctlFailed(
                command: "bootout", status: result.status, output: result.output)
        }
    }

    static func restart(_ project: Project, paths: Paths) throws {
        guard status(for: project).state != .notLoaded else {
            try start(project, paths: paths)
            return
        }
        try run("kickstart", ["kickstart", "-k", serviceTarget(for: project)])
    }

    /// Removes the agent entirely, for a project being deleted.
    static func remove(_ project: Project, paths: Paths) {
        _ = launchctl(["bootout", serviceTarget(for: project)])
        try? FileManager.default.removeItem(at: paths.runnerPlist(slug: project.slug))
    }

    // MARK: - Plumbing

    /// `bootout` returns before launchd has finished unloading the label, and a
    /// `bootstrap` that lands in that window fails with "service already
    /// loaded". Retrying is the documented way through it; there is no wait-for
    /// verb to use instead.
    private static func bootstrap(_ plist: URL) throws {
        let arguments = ["bootstrap", domainTarget, plist.path(percentEncoded: false)]
        for attempt in 0..<10 {
            let result = launchctl(arguments)
            if result.status == 0 { return }
            guard attempt < 9, result.output.contains("already loaded") else {
                throw RunnerError.launchctlFailed(
                    command: "bootstrap", status: result.status, output: result.output)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private static func run(_ label: String, _ arguments: [String]) throws {
        let result = launchctl(arguments)
        guard result.status == 0 else {
            throw RunnerError.launchctlFailed(
                command: label, status: result.status, output: result.output)
        }
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, "could not run launchctl: \(error)")
        }

        // Read before waiting: `launchctl print` is long enough to fill a pipe
        // buffer, and a child blocked on a full pipe against a parent sitting
        // in waitUntilExit hangs forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

enum RunnerError: Error, LocalizedError {
    case missingRunner
    case folderUnusable(String)
    case launchctlFailed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .missingRunner:
            return "this project has no start command configured"
        case .folderUnusable(let problem):
            return problem
        case .launchctlFailed(let command, let status, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "launchctl \(command) failed (\(status))"
                + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}
