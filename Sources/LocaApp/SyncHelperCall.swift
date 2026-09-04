import Foundation
import LocaCore

/// A blocking XPC round trip, for the command-line surface only.
///
/// `CommandLineMode` runs inside `App.init()`, before the main run loop and
/// before the main actor has an executor to schedule on, so the async
/// `HelperClient` cannot be used there — awaiting on the main actor from a
/// blocked main thread deadlocks. This talks to the helper directly and waits
/// on a semaphore instead.
enum SyncHelperCall {
    enum Failure: Error, LocalizedError {
        case noProxy
        case timedOut
        case connection(String)

        var errorDescription: String? {
            switch self {
            case .noProxy: "the helper connection returned no proxy object"
            case .timedOut: "the helper did not answer in time"
            case .connection(let reason): "the helper is unreachable: \(reason)"
            }
        }
    }

    /// - Parameter body: hands the proxy and a one-shot completion. Called on
    ///   whichever queue XPC delivers the reply on.
    static func call<T: Sendable>(
        timeout: TimeInterval = 30,
        _ body: (any LocaHelperProtocol, @escaping @Sendable (T) -> Void) -> Void
    ) throws -> T {
        let connection = NSXPCConnection(
            machServiceName: locaHelperMachServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LocaHelperProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        let box = ResultBox<T>()
        let semaphore = DispatchSemaphore(value: 0)

        guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                box.fail(.connection(error.localizedDescription))
                semaphore.signal()
            }) as? any LocaHelperProtocol
        else {
            throw Failure.noProxy
        }

        body(proxy) { value in
            box.succeed(value)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw Failure.timedOut
        }
        return try box.take()
    }
}

/// Carries the reply across the semaphore. Only the first writer wins, because
/// a reply and the error handler can both fire.
private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var failure: SyncHelperCall.Failure?

    func succeed(_ value: T) {
        lock.lock()
        defer { lock.unlock() }
        guard self.value == nil, failure == nil else { return }
        self.value = value
    }

    func fail(_ failure: SyncHelperCall.Failure) {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil, self.failure == nil else { return }
        self.failure = failure
    }

    func take() throws -> T {
        lock.lock()
        defer { lock.unlock() }
        if let failure { throw failure }
        guard let value else { throw SyncHelperCall.Failure.timedOut }
        return value
    }
}
