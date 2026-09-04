import Foundation
import LocaCore

/// Asks the machine what is listening on a port.
///
/// The add sheet uses this to cross-check a detected port before anything is
/// saved: either the port is already held by a process, which confirms the
/// guess, or nothing is listening yet. Milestone 5 builds the full inspector on
/// the same parser.
enum PortLookup {
    /// Everything currently listening. One `lsof` call, because the inspector
    /// wants the whole picture and asking per port would spawn a process per
    /// row.
    static func allListening() -> [ListeningPort] {
        LsofParser.parse(run(LsofParser.arguments))
    }

    static func owners(ofPort port: Int) -> [ListeningPort] {
        LsofParser.parse(run(["+c", "0", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]))
    }

    /// A sentence for the add sheet, or `nil` when the port is free.
    static func describeOwner(ofPort port: Int) -> String? {
        guard let owner = owners(ofPort: port).first else { return nil }
        return "\(owner.command) (pid \(owner.pid))"
    }

    private static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/lsof")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        // Read before waiting: lsof on a busy machine produces enough output to
        // fill the pipe buffer, and a child blocked on a full pipe against a
        // parent in waitUntilExit hangs forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
