import Foundation
import LocaCore

/// Answers "who holds this port?" by name.
///
/// The spec is blunt about why this exists: something else already bound to 80
/// or 443 — another Caddy, nginx, Herd, a container publishing 443 — is the
/// failure that costs an afternoon, because Caddy's own bind error names
/// nothing. Reporting the process and its pid turns that into a sentence the
/// user can act on.
enum PortProbe {
    static func owners(ofPort port: Int) -> [ListeningPort] {
        let output = Shell.run("/usr/sbin/lsof", ["+c", "0", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"])
        return LsofParser.parse(output.standardOutput)
    }

    static func owner(ofPort port: Int) -> ListeningPort? {
        owners(ofPort: port).first
    }

    /// A short human-readable description, or `nil` when the port is free.
    static func describeOwner(ofPort port: Int) -> String? {
        guard let owner = owner(ofPort: port) else { return nil }
        return "\(owner.command) (pid \(owner.pid))"
    }
}

/// A minimal synchronous process runner.
///
/// The helper shells out in only a handful of places — `lsof`, and Caddy in
/// milestone 2 — so this stays deliberately small rather than growing into a
/// general-purpose abstraction.
enum Shell {
    struct Result {
        var exitCode: Int32
        var standardOutput: String
        var standardError: String
    }

    static func run(_ executable: String, _ arguments: [String]) -> Result {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return Result(
                exitCode: -1, standardOutput: "",
                standardError: "could not run \(executable): \(error)")
        }

        // Read before waiting. A child that fills the pipe buffer blocks
        // forever if the parent is sitting in waitUntilExit, and `lsof` on a
        // busy machine produces plenty of output.
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self))
    }
}
