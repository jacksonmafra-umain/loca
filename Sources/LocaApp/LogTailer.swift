import Foundation
import Observation

/// One line of a runner's log, with when the tailer saw it.
///
/// `arrived` is nil for everything read at open. launchd writes the server's
/// output straight to the file and records no per-line time, so the only lines
/// Loca can honestly date are the ones that reach it while it is watching.
/// Inventing a time for the rest would make old output look current, which is
/// the exact confusion timestamps are here to prevent.
struct LogLine: Identifiable {
    let id: Int
    let text: String
    let arrived: Date?
}

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
    private(set) var lines: [LogLine] = []
    private(set) var isFollowing = false
    private(set) var missingFile = false

    /// When the file was last written to, as the filesystem records it.
    ///
    /// The one date that covers the undated backlog: a log whose last write was
    /// half an hour ago is not describing what just happened, however current
    /// its last line reads.
    private(set) var lastWrite: Date?

    /// How much of the end of the file to read on open.
    private let window = 64 * 1024
    /// Kept bounded so a chatty server cannot grow this without limit.
    private let maximumLines = 800

    private var url: URL?
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    /// Monotonic across a clear, so SwiftUI never reuses a row's identity for a
    /// different line.
    private var nextID = 0

    func follow(_ url: URL) {
        guard self.url != url || !isFollowing else { return }
        stop()
        self.url = url

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            missingFile = true
            // A log file appears only once the runner has produced output, so
            // its absence is a normal state and not an error to shout about.
            lines = []
            lastWrite = nil
            return
        }

        missingFile = false
        self.handle = handle
        lastWrite = modificationDate(of: url)
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

    /// Empties the log file itself, not just the view.
    ///
    /// Clearing only what is on screen would be a lie the next open corrects:
    /// the tail is read back from the file, so the output would return. The
    /// file is truncated instead, and the tail restarted against it — launchd
    /// holds the descriptor in append mode, so a running server keeps writing
    /// from the new beginning rather than into a hole.
    func clear() throws {
        guard let url else {
            lines = []
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)

        stop()
        lines = []
        follow(url)
    }

    // MARK: - Reading

    private func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

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

        append(text, arrived: nil)
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
            self.append(String(decoding: data, as: UTF8.self), arrived: Date())
        }

        source.setCancelHandler { try? handle.close() }
        source.resume()
        self.source = source
    }

    private func append(_ text: String, arrived: Date?) {
        guard !text.isEmpty else { return }
        let incoming = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }

        for line in incoming {
            lines.append(LogLine(id: nextID, text: String(line), arrived: arrived))
            nextID += 1
        }
        if let arrived {
            lastWrite = arrived
        }

        if lines.count > maximumLines {
            lines.removeFirst(lines.count - maximumLines)
        }
    }
}
