import AppKit
import Foundation
import LocaCore
import Observation

enum InspectorError: Error, LocalizedError {
    case notPermitted(pid: Int32)
    case stillAlive(pid: Int32)

    var errorDescription: String? {
        switch self {
        case .notPermitted(let pid):
            return
                "pid \(pid) belongs to another user, so Loca cannot signal it. Stop it from a terminal with sudo."
        case .stillAlive(let pid):
            return "pid \(pid) ignored both signals and is still running."
        }
    }
}

/// The live list of listening TCP ports.
///
/// Polls every 2 seconds *while the tab is visible*, and not at all otherwise.
/// That is not an optimization — it is the difference between an idle app and
/// one that spawns `lsof` forever.
@MainActor
@Observable
final class InspectorController {
    private(set) var rows: [InspectorRow] = []
    private(set) var isPolling = false
    private(set) var dockerAvailable = false
    private(set) var lastError: String?
    var filter = ""

    private let docker: DockerSocketClient
    private var pollingTask: Task<Void, Never>?
    private let pollInterval: Duration = .seconds(2)

    /// A domain lookup, supplied by the caller so the controller does not need
    /// to know about `AppStore`.
    private let domainForPort: @MainActor (Int) -> String?

    init(
        docker: DockerSocketClient = DockerSocketClient(),
        domainForPort: @escaping @MainActor (Int) -> String?
    ) {
        self.docker = docker
        self.domainForPort = domainForPort
    }

    var visibleRows: [InspectorRow] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            row.owner.lowercased().contains(needle)
                || String(row.port).contains(needle)
                || (row.domain?.lowercased().contains(needle) ?? false)
                || (row.detail?.lowercased().contains(needle) ?? false)
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollingTask == nil else { return }
        isPolling = true
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(2))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    /// One `lsof` for the whole machine, enriched with Docker, then
    /// cross-referenced with the registered projects.
    ///
    /// Both the `lsof` call and the socket read happen off the main actor:
    /// they are synchronous and slow enough to drop frames if run on it.
    func refresh() async {
        let client = docker
        let listening = await Task.detached { PortLookup.allListening() }.value
        let containers = await Task.detached { client.containers() }.value

        dockerAvailable = client.isAvailable

        rows = DockerPortMapper.enrich(listening, with: containers).map { row in
            var row = row
            row.domain = domainForPort(row.port)
            return row
        }
    }

    // MARK: - Actions

    func revealFolder(_ row: InspectorRow) {
        guard let path = folderPath(forPID: row.pid) else {
            lastError = "could not work out where pid \(row.pid) is running from"
            return
        }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// SIGTERM, then SIGKILL after five seconds.
    ///
    /// Killing a process owned by this user needs no privilege, which is why
    /// the helper is not involved: it is only needed when the target belongs to
    /// another uid, and that case is reported rather than escalated, because a
    /// root daemon that will kill any pid on request is a worse thing to own
    /// than a missing feature.
    func kill(_ row: InspectorRow) async throws {
        guard Darwin.kill(row.pid, SIGTERM) == 0 else {
            throw errno == EPERM
                ? InspectorError.notPermitted(pid: row.pid)
                : InspectorError.stillAlive(pid: row.pid)
        }

        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(500))
            guard Darwin.kill(row.pid, 0) == 0 else {
                await refresh()
                return
            }
        }

        guard Darwin.kill(row.pid, SIGKILL) == 0 else {
            throw InspectorError.stillAlive(pid: row.pid)
        }
        await refresh()
    }

    // MARK: - Helpers

    /// `lsof -a -d cwd` is the only reliable way to ask where a process is
    /// running from; `ps` reports the command, not the directory.
    private func folderPath(forPID pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // -F output is one field per line, prefixed by its letter; `n` is the
        // name.
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .first { $0.hasPrefix("n/") }
            .map { String($0.dropFirst()) }
    }
}
