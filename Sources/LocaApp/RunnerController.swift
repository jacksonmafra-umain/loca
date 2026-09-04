import Foundation
import LocaCore
import Observation

/// Observable state over `RunnerAgent`.
///
/// One `launchd` agent per project, in the `gui/$UID` domain — not children of
/// the app or the helper, on purpose. An agent there gets the graphical
/// session, the login environment, and the user's Keychain; a root daemon has
/// none of the three. It is also what makes "start at login" mean the user's
/// login rather than the machine's boot.
@MainActor
@Observable
final class RunnerController {
    private(set) var statuses: [UUID: LaunchctlStatus] = [:]
    /// Projects whose command has restarted often enough to call broken.
    private(set) var unstable: Set<UUID> = []

    private let paths: Paths
    private var trackers: [UUID: RestartTracker] = [:]
    /// The `runs` counter last observed per project.
    ///
    /// `launchctl` reports `runs` as a monotonic count of launches, which is
    /// the right signal. Watching the pid instead does not work: a crash loop
    /// spends most of its time between relaunches, so a poll usually lands
    /// while there is no pid at all, and a nil reading loses the thread.
    private var lastSeenRuns: [UUID: Int] = [:]
    private var pollingTask: Task<Void, Never>?

    private let pollInterval: Duration = .seconds(3)

    init(paths: Paths = Paths()) {
        self.paths = paths
    }

    // MARK: - Reading status

    func status(for project: Project) -> LaunchctlStatus {
        statuses[project.id] ?? LaunchctlStatus(state: .notLoaded)
    }

    func refresh(_ project: Project) {
        let status = RunnerAgent.status(for: project)
        statuses[project.id] = status
        noteRestart(of: project, status: status)
    }

    func refreshAll(_ projects: [Project]) {
        for project in projects where project.runner != nil {
            refresh(project)
        }
    }

    /// Polls while the pane is visible, and stops when it is not. An idle app
    /// spawning `launchctl` every three seconds forever is a bill nobody asked
    /// for.
    func startPolling(_ projects: @escaping @MainActor () -> [Project]) {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refreshAll(projects())
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Commands

    func start(_ project: Project) throws {
        try RunnerAgent.start(project, paths: paths)
        // A deliberate start is a fresh slate: whatever crashed before should
        // not count against the new attempt.
        trackers[project.id] = RestartTracker()
        unstable.remove(project.id)
        refresh(project)
    }

    func stop(_ project: Project) throws {
        try RunnerAgent.stop(project)
        trackers[project.id] = nil
        unstable.remove(project.id)
        refresh(project)
    }

    func restart(_ project: Project) throws {
        try RunnerAgent.restart(project, paths: paths)
        refresh(project)
    }

    func removeAgent(_ project: Project) {
        RunnerAgent.remove(project, paths: paths)
        statuses[project.id] = nil
        trackers[project.id] = nil
        lastSeenRuns[project.id] = nil
        unstable.remove(project.id)
    }

    // MARK: - Crash loops

    /// launchd's own throttle paces a broken command at roughly one relaunch
    /// every ten seconds, forever. Watching `runs` climb is how that gets
    /// noticed; the rules for what a change in the counter means live in
    /// `RestartTracker`, where they are tested.
    private func noteRestart(of project: Project, status: LaunchctlStatus) {
        guard let runs = status.runs else { return }

        var tracker = trackers[project.id] ?? RestartTracker()
        if tracker.record(runs: runs, previousRuns: lastSeenRuns[project.id], at: Date()) {
            unstable.insert(project.id)
        }
        if !tracker.isUnstable {
            unstable.remove(project.id)
        }

        trackers[project.id] = tracker
        lastSeenRuns[project.id] = runs
    }
}
