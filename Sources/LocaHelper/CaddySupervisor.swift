import Foundation
import LocaCore

enum CaddySupervisorError: Error, LocalizedError {
    case binaryMissing(String)
    case portHeld(port: Int, by: String)
    case notRunning
    case adminRequestFailed(status: Int, body: String)
    case adminUnreachable(String)

    var errorDescription: String? {
        switch self {
        case .binaryMissing(let path):
            return "the bundled Caddy binary is missing at \(path)"
        case .portHeld(let port, let by):
            return "port \(port) is already in use by \(by)"
        case .notRunning:
            return "Caddy is not running"
        case .adminRequestFailed(let status, let body):
            return "Caddy rejected the configuration (HTTP \(status)): \(body)"
        case .adminUnreachable(let reason):
            return "Caddy's admin API is unreachable: \(reason)"
        }
    }
}

/// Runs and configures the bundled Caddy.
///
/// Domain changes are applied as a config load over the admin API rather than a
/// restart, so open connections survive: enabling a domain must not interrupt a
/// download or a websocket somebody is using.
final class CaddySupervisor: @unchecked Sendable {
    private let binary: URL
    private let caddyfile: URL
    private let dataDirectory: URL
    private let adminAddress: String

    private let queue = DispatchQueue(label: "dev.loca.caddy")
    private var process: Process?
    private var wantsToRun = false
    private var backoff: TimeInterval = 1
    private var lastExit: Int32?

    private let maximumBackoff: TimeInterval = 30

    init(
        binary: URL,
        caddyfile: URL = Paths.caddyfile,
        dataDirectory: URL = Paths.caddyDataDirectory,
        adminAddress: String = Paths.caddyAdmin
    ) {
        self.binary = binary
        self.caddyfile = caddyfile
        self.dataDirectory = dataDirectory
        self.adminAddress = adminAddress
    }

    var isRunning: Bool {
        queue.sync { process?.isRunning ?? false }
    }

    var lastExitStatus: Int32? {
        queue.sync { lastExit }
    }

    // MARK: - Lifecycle

    /// Starts Caddy with the given configuration, or reloads it if already up.
    func apply(projects: [Project]) throws {
        let config = CaddyfileBuilder.build(
            projects: projects, adminAddress: adminAddress, dataDirectory: dataDirectory)
        try write(config)

        if isRunning {
            try load(config)
        } else {
            try start()
        }
    }

    func start() throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path(percentEncoded: false))
        else {
            throw CaddySupervisorError.binaryMissing(binary.path(percentEncoded: false))
        }

        // Probe before launching. Caddy's own bind error names nothing, and
        // "something is on 443" is the failure that costs an afternoon.
        try refuseIfPortsAreHeld()

        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true)

        // Caddy must exist before it is launched with --config.
        if !FileManager.default.fileExists(atPath: caddyfile.path(percentEncoded: false)) {
            try write(
                CaddyfileBuilder.build(
                    projects: [], adminAddress: adminAddress, dataDirectory: dataDirectory))
        }

        try queue.sync {
            wantsToRun = true
            try launch()
        }
    }

    func stop() {
        queue.sync {
            wantsToRun = false
            process?.terminate()
            process = nil
        }
    }

    private func launch() throws {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "run",
            "--config", caddyfile.path(percentEncoded: false),
            "--adapter", "caddyfile",
        ]

        // Caddy keeps its internal CA under XDG_DATA_HOME. Pointing both at a
        // helper-owned directory keeps root's state out of anywhere a
        // user-session process could write to it.
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_DATA_HOME"] = dataDirectory.path(percentEncoded: false)
        environment["XDG_CONFIG_HOME"] = dataDirectory.path(percentEncoded: false)
        // A launchd daemon has no HOME, and Caddy warns that some assets will
        // land in ./caddy relative to the working directory — which for a
        // daemon is /. Pointing HOME at the same helper-owned directory keeps
        // everything it writes in one place.
        environment["HOME"] = dataDirectory.path(percentEncoded: false)
        process.environment = environment

        process.terminationHandler = { [weak self] finished in
            self?.handleTermination(status: finished.terminationStatus)
        }

        try process.run()
        self.process = process
        NSLog("loca: caddy started (pid %d)", process.processIdentifier)
    }

    private func handleTermination(status: Int32) {
        queue.async { [self] in
            lastExit = status
            process = nil

            guard wantsToRun else {
                NSLog("loca: caddy exited (status %d) as asked", status)
                return
            }

            let delay = backoff
            backoff = min(backoff * 2, maximumBackoff)
            NSLog("loca: caddy exited (status %d), restarting in %.0fs", status, delay)

            queue.asyncAfter(deadline: .now() + delay) { [self] in
                guard wantsToRun else { return }
                do {
                    try launch()
                    // Only reset once a launch actually succeeded, or a
                    // permanently broken binary would retry every second
                    // forever.
                    backoff = 1
                } catch {
                    NSLog("loca: caddy relaunch failed: %@", String(describing: error))
                }
            }
        }
    }

    /// Refuses to start when :80 or :443 belongs to something that is not us.
    private func refuseIfPortsAreHeld() throws {
        for port in [80, 443] {
            let owners = PortProbe.owners(ofPort: port).filter { $0.command != "caddy" }
            guard let owner = owners.first else { continue }
            throw CaddySupervisorError.portHeld(
                port: port, by: "\(owner.command) (pid \(owner.pid))")
        }
    }

    // MARK: - Configuration

    private func write(_ config: String) throws {
        let directory = caddyfile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporary = directory.appending(path: ".Caddyfile-\(UUID().uuidString)")
        do {
            try Data(config.utf8).write(to: temporary)
            if FileManager.default.fileExists(atPath: caddyfile.path(percentEncoded: false)) {
                _ = try FileManager.default.replaceItemAt(caddyfile, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: caddyfile)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// POSTs the Caddyfile to the admin API.
    ///
    /// A rejection carries Caddy's own error body, which is the only useful
    /// thing to show a user when a generated config is refused — a generic
    /// "reload failed" leaves them with nowhere to look.
    private func load(_ config: String) throws {
        let request = CaddyAdminRequest.load(caddyfile: config, address: adminAddress)
        guard let url = request.url else {
            throw CaddySupervisorError.adminUnreachable("bad admin URL \(request.urlString)")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.setValue(request.contentType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 15

        let outcome = URLSession.shared.synchronousData(for: urlRequest)

        switch outcome {
        case .failure(let error):
            throw CaddySupervisorError.adminUnreachable(error.localizedDescription)
        case .success(let (data, response)):
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw CaddySupervisorError.adminRequestFailed(
                    status: status, body: String(decoding: data, as: UTF8.self))
            }
            NSLog("loca: caddy configuration loaded")
        }
    }
}

extension URLSession {
    /// A blocking request, for the helper only.
    ///
    /// The helper answers XPC calls on a background queue and has no main-actor
    /// context to await in, so a synchronous round trip is the honest shape
    /// here rather than an async one bolted onto a run loop that is not there.
    func synchronousData(for request: URLRequest) -> Result<(Data, URLResponse), any Error> {
        final class Box: @unchecked Sendable {
            var result: Result<(Data, URLResponse), any Error>?
        }

        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)

        let task = dataTask(with: request) { data, response, error in
            if let error {
                box.result = .failure(error)
            } else if let data, let response {
                box.result = .success((data, response))
            } else {
                box.result = .failure(
                    URLError(.badServerResponse, userInfo: [:]))
            }
            semaphore.signal()
        }
        task.resume()

        guard semaphore.wait(timeout: .now() + 20) == .success else {
            task.cancel()
            return .failure(URLError(.timedOut))
        }
        return box.result ?? .failure(URLError(.unknown))
    }
}
