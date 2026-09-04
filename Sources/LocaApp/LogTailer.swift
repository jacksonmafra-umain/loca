import Foundation
import Observation

/// Follows a runner's log file.
///
/// Opens at the end rather than the beginning: a dev server that has been up
/// for a day has a log nobody wants to scroll, and the interesting part is
/// always the last screenful.
///
/// It stops when the view disappears. An unbounded tail on a hidden view is a
/// slow leak, and the file descriptor it holds is one the user cannot see.
@MainActor
@Observable
final class LogTailer {
    /// The tail, newest last.
    private(set) var lines: [String] = []
    private(set) var isFollowing = false
    private(set) var missingFile = false

    /// How much of the end of the file to read on open.
    private let window = 64 * 1024
    /// Kept bounded so a chatty server cannot grow this without limit.
    private let maximumLines = 800

    private var url: URL?
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?

    func follow(_ url: URL) {
        guard self.url != url || !isFollowing else { return }
        stop()
        self.url = url

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            missingFile = true
            // A log file appears only once the runner has produced output, so
            // its absence is a normal state and not an error to shout about.
            lines = []
            return
        }

        missingFile = false
        self.handle = handle
        readInitialWindow(from: handle)
        watch(handle)
        isFollowing = true
    }

    func stop() {
        source?.cancel()
        source = nil
        // The source's cancel handler closes the descriptor, so this must not
        // close it again.
        handle = nil
        isFollowing = false
    }

    func clear() {
        lines = []
    }

    // MARK: - Reading

    private func readInitialWindow(from handle: FileHandle) {
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        try? handle.seek(toOffset: start)

        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)

        // A window that starts mid-line would show a fragment as if it were a
        // whole entry.
        if start > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        append(text)
    }

    private func watch(_ handle: FileHandle) {
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data

            // A rename or delete means the file was rotated or truncated out
            // from under us, so the only correct move is to reopen the path.
            if events.contains(.delete) || events.contains(.rename) {
                if let url = self.url {
                    self.stop()
                    self.follow(url)
                }
                return
            }

            let data = (try? handle.readToEnd()) ?? Data()
            guard !data.isEmpty else { return }
            self.append(String(decoding: data, as: UTF8.self))
        }

        source.setCancelHandler { try? handle.close() }
        source.resume()
        self.source = source
    }

    private func append(_ text: String) {
        guard !text.isEmpty else { return }
        let incoming = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.append(contentsOf: incoming.filter { !$0.isEmpty })

        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }
}
