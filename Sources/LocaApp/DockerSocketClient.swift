import Foundation
import LocaCore

/// Reads the container list from the Docker Engine over its unix socket.
///
/// Every failure path returns an empty list. A machine without Docker is the
/// normal case, not an error worth showing, and the spec is explicit that this
/// degrades silently — the inspector still works, container rows just keep
/// their raw process name.
///
/// Written by hand rather than with `URLSession` because Foundation has no
/// unix-socket transport. It is a small amount of HTTP/1.1: one request, read
/// to EOF, split on the header terminator.
struct DockerSocketClient: Sendable {
    let socketPath: String

    init(socketPath: String = "/var/run/docker.sock") {
        self.socketPath = socketPath
    }

    /// Published container ports, or an empty list when Docker is not there.
    func containers() -> [DockerContainerPort] {
        guard let body = get("/containers/json") else { return [] }
        return (try? DockerPortMapper.decode(body)) ?? []
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: - Minimal HTTP over AF_UNIX

    private func get(_ path: String) -> Data? {
        guard isAvailable else { return nil }
        guard let descriptor = connect() else { return nil }
        defer { close(descriptor) }

        // Connection: close is what makes "read to EOF" a valid framing
        // strategy, so no chunk parsing is needed for the common case.
        let request = """
            GET \(path) HTTP/1.1\r
            Host: docker\r
            Accept: application/json\r
            Connection: close\r
            \r

            """
        guard send(Data(request.utf8), to: descriptor) else { return nil }

        let response = readToEnd(from: descriptor)
        return body(of: response)
    }

    private func connect() -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        // The path field is a fixed-size C array, so an over-long path has to
        // be refused rather than truncated into a different path.
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        guard pathBytes.count <= capacity else {
            close(descriptor)
            return nil
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connected == 0 else {
            close(descriptor)
            return nil
        }

        // Without a timeout a stalled daemon would hang the caller's queue
        // indefinitely.
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(
            descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        return descriptor
    }

    private func send(_ data: Data, to descriptor: Int32) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            guard written > 0 else { return false }
            remaining.removeFirst(written)
        }
        return true
    }

    private func readToEnd(from descriptor: Int32) -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { break }
            response.append(contentsOf: buffer[0..<count])
        }

        return response
    }

    /// Splits headers from body, de-chunking when the daemon insists.
    private func body(of response: Data) -> Data? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: terminator) else { return nil }

        let headers = String(decoding: response[..<range.lowerBound], as: UTF8.self)
        let payload = response[range.upperBound...]

        guard headers.lowercased().contains("transfer-encoding: chunked") else {
            return Data(payload)
        }
        return dechunk(Data(payload))
    }

    private func dechunk(_ data: Data) -> Data {
        var remaining = data
        var body = Data()
        let newline = Data("\r\n".utf8)

        while let lineEnd = remaining.range(of: newline) {
            let sizeLine = String(decoding: remaining[..<lineEnd.lowerBound], as: UTF8.self)
            // A chunk header may carry extensions after a semicolon.
            let hex = sizeLine.split(separator: ";").first.map(String.init) ?? sizeLine
            guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16) else {
                break
            }
            // A zero-length chunk ends the body.
            guard size > 0 else { break }

            remaining = remaining[lineEnd.upperBound...]
            guard remaining.count >= size else { break }

            body.append(remaining.prefix(size))
            remaining = remaining.dropFirst(size)
            if let next = remaining.range(of: newline), next.lowerBound == remaining.startIndex {
                remaining = remaining[next.upperBound...]
            }
        }

        return body
    }
}
