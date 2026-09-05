import AppKit
import Foundation
import LocaCore
import Observation

enum TunnelError: Error, LocalizedError {
    case binaryMissing(TunnelProvider)
    case alreadyOpen(port: Int)
    case couldNotLaunch(TunnelProvider, String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let provider):
            return "\(provider.binaryName) is not installed. Run `\(provider.installCommand)`."
        case .alreadyOpen(let port):
            return "Port \(String(port)) already has a tunnel open."
        case .couldNotLaunch(let provider, let reason):
            return "\(provider.binaryName) would not start: \(reason)"
        }
    }
}

/// One tunnel's state, as the UI needs to see it.
struct TunnelSession: Identifiable, Sendable {
    enum State: Equatable, Sendable {
        case starting
        case live(String)
        case failed(String)
    }

    let port: Int
    let provider: TunnelProvider
    /// What to call this in the UI: a domain, or a bare port from the
    /// inspector.
    let label: String
    var state: State

    var id: Int { port }

    var url: String? {
        if case .live(let url) = state { return url }
        return nil
    }
}

/// The tunnels this app has open, and the child processes behind them.
///
/// Children of the app, deliberately, rather than `launchd` agents like the
/// runners. A runner is something the user wants to survive; a tunnel is a
/// hole in the boundary between their machine and the internet, and the
/// property worth guaranteeing is the opposite one — quitting Loca closes it.
/// Nothing on disk records that a tunnel was open, so nothing can reopen one.
@MainActor
@Observable
final class TunnelController {
    private(set) var sessions: [Int: TunnelSession] = [:]

    /// The tail of each provider's output, for when a tunnel fails and the
    /// reason is three lines above the failure.
    private(set) var output: [Int: [String]] = [:]

    @ObservationIgnored private var processes: [Int: Process] = [:]
    @ObservationIgnored private var partialLines: [Int: String] = [:]
    @ObservationIgnored private var timeouts: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    /// How long a provider gets to produce a URL before the wait is called a
    /// failure. cloudflared takes about six seconds; ngrok about one.
    private let startupTimeout: Duration = .seconds(45)
    private let keptOutputLines = 40

    init() {
        // A tunnel must not outlive the app that opened it. This is the only
        // hook that fires for Quit, the menu bar item, and a Dock quit alike.
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    // MARK: - Reading

    func session(forPort port: Int) -> TunnelSession? {
        sessions[port]
    }

    var active: [TunnelSession] {
        sessions.values.sorted { $0.port < $1.port }
    }

    func isInstalled(_ provider: TunnelProvider) -> Bool {
        TunnelBinary.locate(provider) != nil
    }

    /// The providers this machine can actually run, in the enum's order.
    var installedProviders: [TunnelProvider] {
        TunnelProvider.allCases.filter(isInstalled)
    }

    // MARK: - Commands

    func start(port: Int, provider: TunnelProvider, label: String) throws {
        guard sessions[port] == nil else { throw TunnelError.alreadyOpen(port: port) }
        guard let binary = TunnelBinary.locate(provider) else {
            throw TunnelError.binaryMissing(provider)
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = TunnelCommand.arguments(for: provider, port: port)

        // Both providers are read the same way. cloudflared writes its banner
        // to stderr and ngrok its logfmt to stdout, and merging the two means
        // neither has to be treated as the special one.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.absorb(data, port: port, provider: provider)
            }
        }

        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor [weak self] in
                self?.processEnded(port: port, status: status)
            }
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            throw TunnelError.couldNotLaunch(provider, error.localizedDescription)
        }

        processes[port] = process
        partialLines[port] = ""
        output[port] = []
        sessions[port] = TunnelSession(
            port: port, provider: provider, label: label, state: .starting)

        let timeout = startupTimeout
        timeouts[port] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.startupTimedOut(port: port, provider: provider)
        }
    }

    func stop(port: Int) {
        timeouts[port]?.cancel()
        timeouts[port] = nil

        if let process = processes[port], process.isRunning {
            // SIGTERM, which both providers handle by closing the tunnel
            // cleanly. The termination handler does the bookkeeping.
            process.terminate()
        }
        clear(port: port)
    }

    /// Closes every tunnel. Called on quit, and safe to call twice.
    func stopAll() {
        for port in Array(processes.keys) {
            timeouts[port]?.cancel()
            let process = processes[port]
            if let process, process.isRunning {
                process.terminate()
                // Quitting is the one moment worth blocking for: the alternative
                // is leaving a public URL pointing at this machine after the app
                // is gone. A provider that ignores SIGTERM gets killed.
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < deadline {
                    usleep(50_000)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            clear(port: port)
        }
        timeouts.removeAll()
    }

    // MARK: - Output

    private func absorb(_ data: Data, port: Int, provider: TunnelProvider) {
        guard sessions[port] != nil else { return }

        var buffer = (partialLines[port] ?? "") + String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[buffer.startIndex..<newline]))
            buffer = String(buffer[buffer.index(after: newline)...])
        }
        partialLines[port] = buffer

        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            record(line, port: port)
            guard let event = TunnelOutputParser.event(in: line, from: provider) else { continue }
            switch event {
            case .url(let url):
                timeouts[port]?.cancel()
                timeouts[port] = nil
                sessions[port]?.state = .live(url)
            case .failure(let reason):
                // Only the first failure. Both providers keep retrying and
                // narrating, and the tenth message is never the useful one.
                if case .failed = sessions[port]?.state {} else {
                    sessions[port]?.state = .failed(reason)
                }
            }
        }
    }

    private func record(_ line: String, port: Int) {
        var kept = output[port] ?? []
        kept.append(line)
        if kept.count > keptOutputLines {
            kept.removeFirst(kept.count - keptOutputLines)
        }
        output[port] = kept
    }

    // MARK: - Endings

    private func processEnded(port: Int, status: Int32) {
        processes[port] = nil
        timeouts[port]?.cancel()
        timeouts[port] = nil

        guard var session = sessions[port] else { return }

        // A tunnel that ends on its own has failed, whatever its exit status:
        // the URL it handed out no longer reaches anything, and a row still
        // showing it would be a lie.
        if case .failed = session.state {
            sessions[port] = session
            return
        }
        session.state = .failed(
            status == 0
                ? "\(session.provider.binaryName) exited and the tunnel is closed."
                : "\(session.provider.binaryName) exited with status \(String(status)).")
        sessions[port] = session
    }

    private func startupTimedOut(port: Int, provider: TunnelProvider) {
        guard let session = sessions[port], case .starting = session.state else { return }
        sessions[port]?.state = .failed(
            "\(provider.binaryName) did not produce a URL within 45 seconds.")
    }

    private func clear(port: Int) {
        if let process = processes[port], let pipe = process.standardOutput as? Pipe {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        processes[port] = nil
        sessions[port] = nil
        partialLines[port] = nil
        output[port] = nil
    }
}
