import Foundation

/// What `launchctl print` says about one runner agent.
public struct LaunchctlStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Loaded and has a live process.
        case running(pid: Int32)
        /// Loaded but nothing is running right now.
        case notRunning
        /// Not in the domain at all — never started, or booted out.
        case notLoaded
    }

    public var state: State
    public var lastExitStatus: Int32?
    public var runs: Int?

    public init(state: State, lastExitStatus: Int32? = nil, runs: Int? = nil) {
        self.state = state
        self.lastExitStatus = lastExitStatus
        self.runs = runs
    }

    public var pid: Int32? {
        if case .running(let pid) = state { return pid }
        return nil
    }

    public var isRunning: Bool { pid != nil }
}

/// Parses `launchctl print gui/$UID/<label>`.
///
/// `launchctl` has no machine-readable output, so this reads its human one. The
/// keys it looks for are narrow and anchored, because the surrounding block
/// carries dozens of other `key = value` lines that must not be mistaken for
/// the service's own.
public enum LaunchctlStatusParser {
    private static let notFoundMarker = "Could not find service"

    public static func parse(_ output: String, exitCode: Int32) -> LaunchctlStatus {
        // A non-zero exit is authoritative, and the message is checked too:
        // reporting "running with no pid" because a failure arrived with a zero
        // exit would be worse than reporting nothing.
        guard exitCode == 0, !output.contains(notFoundMarker), !output.isEmpty else {
            return LaunchctlStatus(state: .notLoaded)
        }

        let pid = value(forKey: "pid", in: output).flatMap(Int32.init)

        // macOS 26 prints "last exit code"; earlier releases printed
        // "last exit status". Accepting both keeps the status panel working
        // across an OS update.
        let exitStatus =
            (value(forKey: "last exit code", in: output)
            ?? value(forKey: "last exit status", in: output)).flatMap(Int32.init)

        return LaunchctlStatus(
            state: pid.map { State.running(pid: $0) } ?? .notRunning,
            lastExitStatus: exitStatus,
            runs: value(forKey: "runs", in: output).flatMap(Int.init))
    }

    private typealias State = LaunchctlStatus.State

    /// Matches a whole-line `<key> = <value>`, so `spid = 999` never satisfies
    /// a lookup for `pid`.
    private static func value(forKey key: String, in output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.range(of: " = ") else { continue }
            guard trimmed[trimmed.startIndex..<separator.lowerBound] == key else { continue }
            return String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}
