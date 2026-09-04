import Foundation

/// What the detector managed to work out about a folder.
///
/// `sources` names every file that contributed, so the add sheet can show the
/// user *why* it is proposing 5174 rather than asking them to trust it.
public struct DetectionResult: Equatable, Sendable {
    public var port: Int?
    public var command: String?
    public var sources: [String]
    public var packageManager: String?

    public init(
        port: Int? = nil, command: String? = nil, sources: [String] = [],
        packageManager: String? = nil
    ) {
        self.port = port
        self.command = command
        self.sources = sources
        self.packageManager = packageManager
    }
}

/// Proposes a port and a start command by reading a project's own files.
///
/// The folder is the source of detection: the app works out the port and
/// command instead of asking for them. Everything here is a guess presented for
/// confirmation — the add sheet cross-checks the port against what is actually
/// listening before anything is saved.
public enum ProjectDetector {
    private static let viteDefaultPort = 5173
    private static let nextDefaultPort = 3000

    public static func detect(folder: URL) -> DetectionResult {
        var result = DetectionResult()

        // Order matters. An explicitly configured port beats a framework
        // default, and a port in .env beats one in a script, because .env is
        // what the process will actually read at startup.
        detectEnvPort(folder: folder, into: &result)
        detectPackageJSON(folder: folder, into: &result)
        detectViteConfig(folder: folder, into: &result)
        detectNextConfig(folder: folder, into: &result)
        detectCompose(folder: folder, into: &result)

        return result
    }

    // MARK: - .env

    private static func detectEnvPort(folder: URL, into result: inout DetectionResult) {
        for name in [".env", ".env.local"] {
            guard let contents = read(folder.appending(path: name)) else { continue }
            guard let port = envPort(in: contents) else { continue }
            result.port = port
            result.sources.append("\(name) PORT")
            return
        }
    }

    /// Reads `PORT=3000`, `PORT = "3000"`, and `PORT='3000'`. A commented line
    /// is skipped, since a port someone deliberately turned off is not the one
    /// to propose.
    private static func envPort(in contents: String) -> Int? {
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }

            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespaces) == "PORT" else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let port = Int(value), Validation.portRange.contains(port) { return port }
        }
        return nil
    }

    // MARK: - package.json

    private static func detectPackageJSON(folder: URL, into result: inout DetectionResult) {
        let manager = packageManager(folder: folder)

        guard let data = try? Data(contentsOf: folder.appending(path: "package.json")),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // A malformed package.json must not stop compose or a config file
            // from being consulted, so this returns quietly.
            return
        }

        result.packageManager = manager.name

        let scripts = json["scripts"] as? [String: String] ?? [:]
        guard let scriptName = ["dev", "start"].first(where: { scripts[$0] != nil }) else { return }

        result.command = manager.invocation(script: scriptName)
        result.sources.append("package.json scripts.\(scriptName)")

        // A port baked into the dev script is as authoritative as one in .env,
        // and much more common in a Vite or Next project.
        if result.port == nil, let port = flagPort(in: scripts[scriptName] ?? "") {
            result.port = port
            result.sources.append("package.json scripts.\(scriptName) port flag")
        }
    }

    private struct PackageManager {
        let name: String
        let runPrefix: String

        func invocation(script: String) -> String { "\(runPrefix) \(script)" }
    }

    /// The lockfile is the only reliable signal. A `packageManager` field in
    /// `package.json` would be better still, but it is far from universal.
    private static func packageManager(folder: URL) -> PackageManager {
        let candidates: [(String, PackageManager)] = [
            ("pnpm-lock.yaml", PackageManager(name: "pnpm", runPrefix: "pnpm")),
            ("yarn.lock", PackageManager(name: "yarn", runPrefix: "yarn")),
            ("bun.lockb", PackageManager(name: "bun", runPrefix: "bun run")),
            ("bun.lock", PackageManager(name: "bun", runPrefix: "bun run")),
        ]

        for (lockfile, manager) in candidates
        where FileManager.default.fileExists(
            atPath: folder.appending(path: lockfile).path(percentEncoded: false)) {
            return manager
        }

        return PackageManager(name: "npm", runPrefix: "npm run")
    }

    /// Matches `--port 4000`, `--port=4000`, and `-p 4000`.
    private static func flagPort(in script: String) -> Int? {
        let tokens = script.split(separator: " ").map(String.init)
        for (index, token) in tokens.enumerated() {
            if token == "--port" || token == "-p" {
                if index + 1 < tokens.count, let port = Int(tokens[index + 1]) { return port }
            } else if token.hasPrefix("--port=") {
                if let port = Int(token.dropFirst("--port=".count)) { return port }
            }
        }
        return nil
    }

    // MARK: - Framework configs

    private static func detectViteConfig(folder: URL, into result: inout DetectionResult) {
        guard let (name, contents) = firstMatch(
            folder: folder, names: ["vite.config.ts", "vite.config.js", "vite.config.mjs"])
        else { return }

        if let port = configuredPort(in: contents) {
            result.port = port
            result.sources.append("\(name) server.port")
        } else if result.port == nil {
            result.port = viteDefaultPort
            result.sources.append("\(name) (Vite default)")
        }
    }

    private static func detectNextConfig(folder: URL, into result: inout DetectionResult) {
        guard let (name, _) = firstMatch(
            folder: folder,
            names: ["next.config.js", "next.config.mjs", "next.config.ts"])
        else { return }

        // Next takes its port from the CLI, never from the config file, so the
        // only thing this file tells us is which default applies.
        guard result.port == nil else { return }
        result.port = nextDefaultPort
        result.sources.append("\(name) (Next default)")
    }

    /// Looks for `port: 5174` anywhere in the file.
    ///
    /// This is a text scan, not a parse: these configs are JavaScript, and the
    /// value can be behind a variable, a spread, or an environment lookup.
    /// A wrong guess here is cheap — the user confirms it in the add sheet.
    private static func configuredPort(in contents: String) -> Int? {
        guard let range = contents.range(of: #"port\s*:\s*\d+"#, options: .regularExpression)
        else { return nil }
        let digits = contents[range].filter(\.isNumber)
        guard let port = Int(digits), Validation.portRange.contains(port) else { return nil }
        return port
    }

    // MARK: - Compose

    private static func detectCompose(folder: URL, into result: inout DetectionResult) {
        guard let (name, contents) = firstMatch(
            folder: folder,
            names: ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"])
        else { return }

        if result.command == nil {
            result.command = "docker compose up"
            result.sources.append(name)
        }

        guard result.port == nil, let port = firstPublishedPort(in: contents) else { return }
        result.port = port
        result.sources.append("\(name) ports")
    }

    /// Reads the first `"<public>:<private>"` entry under a `ports:` key.
    ///
    /// Only a published mapping counts: a bare `- "80"` or an `expose:` entry
    /// is reachable inside the Docker network only, so it can never be the host
    /// port the user browses to.
    private static func firstPublishedPort(in contents: String) -> Int? {
        var insidePorts = false

        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasSuffix(":"), !trimmed.hasPrefix("-") {
                insidePorts = trimmed == "ports:"
                continue
            }

            guard insidePorts, trimmed.hasPrefix("-") else { continue }

            let value = trimmed.dropFirst()
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let parts = value.split(separator: ":")
            guard parts.count >= 2, let port = Int(parts[0]),
                Validation.portRange.contains(port)
            else { continue }
            return port
        }

        return nil
    }

    // MARK: - Helpers

    private static func firstMatch(
        folder: URL, names: [String]
    ) -> (name: String, contents: String)? {
        for name in names {
            if let contents = read(folder.appending(path: name)) { return (name, contents) }
        }
        return nil
    }

    private static func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }
}
