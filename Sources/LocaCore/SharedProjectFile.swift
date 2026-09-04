import Foundation

/// A `.loca.json` committed alongside a project, so a team shares the slug,
/// port, and start command instead of each person registering by hand.
///
/// The design document deferred this over two questions. Both are answered
/// conservatively here, and the answers are the whole design:
///
/// **What wins when this file and the local config disagree?** The local config,
/// always. This file is a *proposal*, read when a project is registered and
/// never re-read to override what is already there. A `git pull` that silently
/// moved which port your domain points at would be a bad surprise, and the
/// local config is what the running proxy actually reflects. Drift is reported
/// so a deliberate update is one click, not silent.
///
/// **May a repository name the domain it gets on someone else's machine?** It
/// may suggest, never claim. The slug is a suggestion, and local uniqueness is
/// enforced with the same rules as any other slug, so a repository cannot take
/// a domain that is already yours. Nothing auto-registers either: cloning a
/// repository must not make `admin.test` resolve on your machine without you
/// looking at it.
public struct SharedProjectFile: Codable, Equatable, Sendable {
    public static let fileName = ".loca.json"
    public static let currentVersion = 1

    public var version: Int
    /// A suggestion. Uniqueness is still enforced locally.
    public var slug: String
    public var port: Int
    public var runner: SharedRunner?

    public init(
        version: Int = SharedProjectFile.currentVersion,
        slug: String,
        port: Int,
        runner: SharedRunner? = nil
    ) {
        self.version = version
        self.slug = slug
        self.port = port
        self.runner = runner
    }

    /// The shareable half of a runner.
    ///
    /// `autoStart` is deliberately absent. "Start at login" is a statement
    /// about how somebody wants their own machine to behave, not a property of
    /// the project, and a repository has no business deciding it.
    public struct SharedRunner: Codable, Equatable, Sendable {
        public var command: String
        public var keepAlive: Bool

        public init(command: String, keepAlive: Bool = true) {
            self.command = command
            self.keepAlive = keepAlive
        }
    }

    public init(from project: Project) {
        self.init(
            slug: project.slug,
            port: project.port,
            runner: project.runner.map {
                SharedRunner(command: $0.command, keepAlive: $0.keepAlive)
            })
    }
}

public enum SharedProjectFileError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidSlug(String)
    case portOutOfRange(Int)
}

extension SharedProjectFile {
    public static func url(in folder: URL) -> URL {
        folder.appending(path: fileName)
    }

    /// Reads the file, or `nil` when the project does not have one.
    ///
    /// Malformed content also reads as `nil` rather than throwing. This file
    /// comes from a repository somebody else may have written, and a typo in it
    /// must not stop the folder from being registered at all — the detector
    /// simply falls back to guessing.
    public static func read(from folder: URL) -> SharedProjectFile? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        guard let file = try? JSONDecoder().decode(SharedProjectFile.self, from: data) else {
            return nil
        }
        guard (try? file.validated()) != nil else { return nil }
        return file
    }

    /// The same gate every other value passes, because this one arrives from a
    /// file anyone could have written.
    public func validated() throws -> SharedProjectFile {
        guard version <= Self.currentVersion else {
            throw SharedProjectFileError.unsupportedVersion(version)
        }
        guard Slug.isValid(slug) else { throw SharedProjectFileError.invalidSlug(slug) }
        guard Validation.portRange.contains(port) else {
            throw SharedProjectFileError.portOutOfRange(port)
        }
        return self
    }

    /// Writes the file, formatted to be readable in a diff — it is going into
    /// somebody's repository.
    ///
    /// Including the trailing newline `JSONEncoder` does not add. Without it
    /// every diff of this file carries a "\\ No newline at end of file"
    /// marker, which is noise in a review of somebody else's change.
    public func write(to folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        var data = try encoder.encode(self)
        data.append(0x0A)
        try data.write(to: Self.url(in: folder))
    }

    // MARK: - Drift

    /// A difference between what the repository proposes and what is
    /// registered locally.
    public struct Difference: Equatable, Sendable {
        public var field: String
        public var shared: String
        public var local: String
    }

    /// Reported rather than acted on. The point is to make a deliberate update
    /// easy, not to let a pull change what the proxy serves.
    public func differences(from project: Project) -> [Difference] {
        var differences: [Difference] = []

        if slug != project.slug {
            differences.append(Difference(field: "slug", shared: slug, local: project.slug))
        }
        if port != project.port {
            differences.append(
                Difference(field: "port", shared: String(port), local: project.portText))
        }

        let localCommand = project.runner?.command
        if runner?.command != localCommand {
            differences.append(
                Difference(
                    field: "command",
                    shared: runner?.command ?? "none",
                    local: localCommand ?? "none"))
        }

        if let shared = runner, let local = project.runner, shared.keepAlive != local.keepAlive {
            differences.append(
                Difference(
                    field: "restart on crash",
                    shared: String(shared.keepAlive),
                    local: String(local.keepAlive)))
        }

        return differences
    }

    /// Applies this file to a project, keeping everything the file has no
    /// business deciding: the identifier, the folder, whether the domain is
    /// enabled, and the autoStart preference.
    public func applied(to project: Project) -> Project {
        var updated = project
        updated.slug = slug
        updated.port = port

        if let runner {
            updated.runner = Runner(
                command: runner.command,
                autoStart: project.runner?.autoStart ?? false,
                keepAlive: runner.keepAlive)
        }

        return updated
    }
}
