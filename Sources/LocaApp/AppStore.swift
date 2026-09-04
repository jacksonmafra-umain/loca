import Foundation
import LocaCore
import Observation

/// The app's project list, and the only thing that writes `config.json`.
///
/// Every mutation follows the same order: validate, save, then push the enabled
/// set to the helper. If the push fails the in-memory change is rolled back, so
/// the UI can never show a domain as enabled that the proxy is not actually
/// serving — a list that lies about what is reachable is worse than an error.
@MainActor
@Observable
final class AppStore {
    private(set) var projects: [Project] = []
    private(set) var loadError: String?
    var lastError: String?

    private let store: ConfigStore
    private let paths: Paths
    private let helper: HelperClient

    init(paths: Paths = Paths(), helper: HelperClient) {
        self.paths = paths
        self.store = ConfigStore(paths: paths)
        self.helper = helper
    }

    // MARK: - Loading

    func load() {
        do {
            projects = try store.load().projects
            loadError = nil
        } catch {
            // A config we cannot read is left strictly alone. Starting empty
            // and saving over it would destroy the user's registrations to fix
            // a problem they can probably fix themselves.
            loadError =
                "\(paths.configFile.path(percentEncoded: false)) could not be read: "
                + error.localizedDescription
        }
    }

    // MARK: - Mutation

    func add(folder: URL, slug: String, port: Int, runner: Runner?) async throws {
        try Validation.validate(slug: slug, port: port, folder: folder, existing: projects)
        let project = Project(
            slug: slug, folder: folder, port: port, enabled: true, runner: runner)
        try await commit(projects + [project])
    }

    func update(_ project: Project) async throws {
        try Validation.validate(
            slug: project.slug, port: project.port, folder: project.folder,
            existing: projects, ignoring: project.id)

        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = projects
        updated[index] = project
        try await commit(updated)
    }

    func remove(_ project: Project) async throws {
        try await commit(projects.filter { $0.id != project.id })
    }

    /// Points a project at a new folder, keeping its slug, port, and runner.
    ///
    /// A relocation is not the same as editing the folder field: the slug and
    /// port are what the user's browser and their other tooling already know,
    /// so they have to survive. Only the path changes.
    func relocate(_ project: Project, to folder: URL) async throws {
        var moved = project
        moved.folder = folder
        try await update(moved)
    }

    /// Projects whose folder is no longer where it was registered.
    func misplaced() -> [Project] {
        projects.filter { !FolderCheck.check($0.folder).isUsable }
    }

    func setEnabled(_ enabled: Bool, for project: Project) async throws {
        var changed = project
        changed.enabled = enabled
        try await update(changed)
    }

    /// Saves, then pushes. A failed push restores the previous list.
    private func commit(_ next: [Project]) async throws {
        let previous = projects
        projects = next

        do {
            try store.save(LocaConfig(projects: next))
            try await helper.applyDomains(next)
            lastError = nil
        } catch {
            projects = previous
            // Put the file back too, so a later launch does not read a state
            // the proxy never accepted.
            try? store.save(LocaConfig(projects: previous))
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Re-pushes the current list, for use after the helper is installed or
    /// restarted.
    func resync() async {
        do {
            try await helper.applyDomains(projects)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Proposals and conflicts

    func suggestedSlug(for folder: URL) -> String {
        uniqueSlug(folder.lastPathComponent)
    }

    /// Normalizes a candidate and makes it unique among what is registered.
    ///
    /// Every slug goes through here, whether it came from a folder name or
    /// from a project's own `.loca.json` — which is what keeps a repository
    /// from claiming a domain somebody already has.
    func uniqueSlug(_ candidate: String) -> String {
        Slug.unique(candidate, taken: Set(projects.map(\.slug)))
    }

    /// Other projects pointed at the same port.
    ///
    /// Allowed, not rejected — running two projects against one port can be
    /// deliberate — but worth a badge, because only one of them can actually be
    /// listening.
    func portConflicts(for project: Project) -> [Project] {
        projects.filter { $0.id != project.id && $0.port == project.port }
    }

    func project(withSlug slug: String) -> Project? {
        projects.first { $0.slug == slug }
    }

    func domain(forPort port: Int) -> String? {
        projects.first { $0.port == port }?.domain
    }
}
