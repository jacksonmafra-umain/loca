import Foundation
import LocaCore
import Network

/// Answers DNS on `127.0.0.1:53531`, over UDP and TCP.
///
/// The port is unprivileged because `/etc/resolver/test` accepts a `port`
/// directive, so this never binds 53 and no second daemon is needed. It listens
/// on loopback only: nothing outside this machine has any business asking us
/// about `.test`.
///
/// Both transports are served because a resolver falls back to TCP whenever a
/// UDP answer would be truncated or a query is retried, and a responder that
/// only speaks UDP fails in exactly the cases that are hardest to diagnose.
///
/// `@unchecked Sendable` is accurate here rather than a shortcut: every mutable
/// field below is read and written only on `queue`, and Network.framework
/// delivers all of its callbacks there, because that is the queue the listeners
/// are started on.
final class DNSListener: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "dev.loca.dns")

    private var udpListener: NWListener?
    private var tcpListener: NWListener?

    /// Grows on repeated failure and resets on a clean start. A listener can
    /// fail after sleep and wake, and retrying instantly forever would spin.
    private var udpBackoff: TimeInterval = 1
    private var tcpBackoff: TimeInterval = 1
    private var stopped = false

    private let maximumBackoff: TimeInterval = 30

    init(port: UInt16 = Paths.dnsPort) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 53_531
    }

    func start() {
        queue.async { [self] in
            stopped = false
            startUDP()
            startTCP()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            udpListener?.cancel()
            tcpListener?.cancel()
            udpListener = nil
            tcpListener = nil
        }
    }

    // MARK: - UDP

    private func startUDP() {
        guard !stopped else { return }

        let parameters = NWParameters.udp
        // The port has to be passed to the initializer. requiredLocalEndpoint
        // does not bind a listener's port — set on its own it leaves the
        // listener on an ephemeral port while every log line still reports the
        // port that was asked for, which is a failure that looks like success.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [self] state in
                handleState(state, transport: "udp", boundPort: listener.port) {
                    self.startUDP()
                }
            }
            listener.newConnectionHandler = { [self] connection in
                serveUDP(connection)
            }
            listener.start(queue: queue)
            udpListener = listener
        } catch {
            NSLog("loca: dns udp listener failed to create: %@", String(describing: error))
            scheduleRetry(transport: "udp") { self.startUDP() }
        }
    }

    private func serveUDP(_ connection: NWConnection) {
        connection.start(queue: queue)
        // One datagram per flow. A resolver that asks again gets a new flow, so
        // there is nothing to keep alive here.
        connection.receiveMessage { [self] data, _, _, error in
            if let error {
                NSLog("loca: dns udp receive failed: %@", String(describing: error))
                connection.cancel()
                return
            }
            guard let data, let response = answer(to: data) else {
                connection.cancel()
                return
            }

            // Cancel only once the datagram has actually been handed to the
            // stack. Sending with `.idempotent` and cancelling straight
            // afterwards drops the reply — the send is asynchronous, so the
            // flow disappears from under it. That failure is invisible: the
            // listener reports ready, TCP works, and UDP queries just time out.
            connection.send(
                content: response,
                completion: .contentProcessed { sendError in
                    if let sendError {
                        NSLog("loca: dns udp send failed: %@", String(describing: sendError))
                    }
                    connection.cancel()
                })
        }
    }

    // MARK: - TCP

    private func startTCP() {
        guard !stopped else { return }

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [self] state in
                handleState(state, transport: "tcp", boundPort: listener.port) {
                    self.startTCP()
                }
            }
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                readTCPQuery(on: connection)
            }
            listener.start(queue: queue)
            tcpListener = listener
        } catch {
            NSLog("loca: dns tcp listener failed to create: %@", String(describing: error))
            scheduleRetry(transport: "tcp") { self.startTCP() }
        }
    }

    /// DNS over TCP frames each message with a two-byte length, and a client
    /// may send several down one connection, so this reads the prefix, then
    /// exactly that many bytes, then waits for the next one.
    private func readTCPQuery(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [self] prefix, _, _, error in
            guard error == nil, let prefix, prefix.count == 2 else {
                connection.cancel()
                return
            }

            let length = Int(prefix[prefix.startIndex]) << 8 | Int(prefix[prefix.startIndex + 1])
            guard length > 0 else {
                connection.cancel()
                return
            }

            connection.receive(minimumIncompleteLength: length, maximumLength: length) {
                [self] payload, _, _, error in
                guard error == nil, let payload else {
                    connection.cancel()
                    return
                }

                if let response = answer(to: payload) {
                    connection.send(
                        content: DNSCodec.prefixedForTCP(response), completion: .idempotent)
                }

                // Keep the connection open for a second query rather than
                // forcing the resolver to reconnect.
                readTCPQuery(on: connection)
            }
        }
    }

    // MARK: - Answering

    /// A malformed packet is logged and dropped, never fatal.
    ///
    /// This is a root daemon that any local process can send bytes to, so a
    /// parse failure has to cost one dropped datagram and nothing more.
    private func answer(to data: Data) -> Data? {
        do {
            let query = try DNSCodec.decode(data)
            return DNSCodec.encode(DNSResponder.respond(to: query))
        } catch {
            NSLog("loca: dropped malformed dns query (%d bytes): %@",
                  data.count, String(describing: error))
            return nil
        }
    }

    // MARK: - Lifecycle

    private func handleState(
        _ state: NWListener.State,
        transport: String,
        boundPort: NWEndpoint.Port?,
        restart: @escaping @Sendable () -> Void
    ) {
        switch state {
        case .ready:
            // The port actually bound, not the one requested. Logging the
            // request instead hid a listener sitting on an ephemeral port
            // behind a line that read exactly right.
            NSLog(
                "loca: dns %@ listening on loopback:%d", transport,
                Int(boundPort?.rawValue ?? 0))
            resetBackoff(transport: transport)
        case .failed(let error):
            NSLog("loca: dns %@ listener failed: %@", transport, String(describing: error))
            scheduleRetry(transport: transport, restart: restart)
        case .cancelled:
            // Only re-arm a cancellation we did not ask for. `stop()` sets the
            // flag first, so a deliberate teardown does not restart itself.
            if !stopped { scheduleRetry(transport: transport, restart: restart) }
        default:
            break
        }
    }

    private func scheduleRetry(transport: String, restart: @escaping @Sendable () -> Void) {
        guard !stopped else { return }

        let delay = backoff(transport: transport)
        NSLog("loca: dns %@ retrying in %.0fs", transport, delay)
        growBackoff(transport: transport)

        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard !stopped else { return }
            restart()
        }
    }

    private func backoff(transport: String) -> TimeInterval {
        transport == "udp" ? udpBackoff : tcpBackoff
    }

    private func growBackoff(transport: String) {
        if transport == "udp" {
            udpBackoff = min(udpBackoff * 2, maximumBackoff)
        } else {
            tcpBackoff = min(tcpBackoff * 2, maximumBackoff)
        }
    }

    private func resetBackoff(transport: String) {
        if transport == "udp" { udpBackoff = 1 } else { tcpBackoff = 1 }
    }
}
