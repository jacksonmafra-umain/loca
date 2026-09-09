import Foundation
import LocaCore

/// Asks the user's shell what its `PATH` is, so the agent can be given one.
///
/// The parsing and the exact question live in `LocaCore.LoginShellPath`; this is
/// only the part that has to spawn a process, which is why it sits next to
/// `RunnerAgent` rather than in the core.
enum LoginShellPathProbe {
    /// An interactive shell can block on anything its start-up files feel like
    /// doing. Better a missing `PATH` than a start button that never returns.
    static let timeout: TimeInterval = 5

    /// The user's `PATH`, or `nil` when the shell failed, hung, or answered with
    /// nothing usable. `nil` is not an error: the agent then falls back to
    /// launchd's default, which is what it had before.
    static func capture() -> String? {
        let process = Process()
        process.executableURL = URL(filePath: LoginShellPath.shell)
        process.arguments = LoginShellPath.arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        // Discarded rather than merged: a `~/.zshrc` warning is not an answer,
        // and keeping it out of the parse is cheaper than filtering it later.
        process.standardError = FileHandle.nullDevice
        // Nothing to read from, and a start-up file that prompts would otherwise
        // sit there until the timeout.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read on another thread: the shell can outlive the timeout, and a
        // `readDataToEndOfFile` on this one would wait for it regardless.
        let output = DispatchQueue(label: "dev.loca.login-path")
        let data = Mutex<Data?>(nil)
        let finished = DispatchSemaphore(value: 0)
        output.async {
            let read = try? pipe.fileHandleForReading.readToEnd()
            data.set(read)
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0, let data = data.get() else { return nil }
        return LoginShellPath.parse(String(decoding: data, as: UTF8.self))
    }
}

/// A lock around one value, for handing a result back off the reader thread.
private final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
