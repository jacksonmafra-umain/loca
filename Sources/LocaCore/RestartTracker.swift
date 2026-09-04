import Foundation

/// Detects a runner crash loop.
///
/// A broken command plus `KeepAlive` makes launchd restart it forever, and
/// launchd's own 10-second throttle is not protection — it just paces the loop
/// at roughly six restarts a minute. This counts restarts inside a sliding
/// window so the app can say "this command is broken" instead of leaving the
/// user to notice a log scrolling past.
///
/// Time is injected rather than read from the clock, which is what makes the
/// behaviour testable without waiting a minute.
public struct RestartTracker: Sendable {
    public let threshold: Int
    public let window: TimeInterval

    private var timestamps: [Date] = []
    private var tripped = false

    public init(threshold: Int = 3, window: TimeInterval = 60) {
        self.threshold = threshold
        self.window = window
    }

    /// Records a restart. Returns `true` only on the transition into unstable,
    /// so a caller can raise the banner once instead of on every poll.
    @discardableResult
    public mutating func record(at time: Date) -> Bool {
        timestamps.removeAll { time.timeIntervalSince($0) >= window }
        timestamps.append(time)

        guard !tripped, timestamps.count >= threshold else { return false }
        tripped = true
        return true
    }

    /// Records the relaunches implied by a change in `launchctl`'s monotonic
    /// `runs` counter, and returns `true` on the transition into unstable.
    ///
    /// The counter is the right signal to watch rather than the pid: a crash
    /// loop spends most of its time *between* relaunches, so a poll usually
    /// lands while there is no pid at all, and a nil reading loses the thread.
    ///
    /// - Parameters:
    ///   - runs: the count just observed.
    ///   - previousRuns: the count observed before, or `nil` on the first
    ///     observation — which infers nothing, since a service that has run
    ///     forty times before the app opened is not evidence of a loop now.
    @discardableResult
    public mutating func record(runs: Int, previousRuns: Int?, at time: Date) -> Bool {
        guard let previousRuns else { return false }

        // A lower count means the service was booted out and started afresh,
        // which is a deliberate act and not a crash.
        if runs < previousRuns {
            reset()
            return false
        }

        // A jump larger than one means several relaunches happened between
        // polls. Each is recorded: they all fall inside the window, and
        // dropping them would make a fast loop look calmer than a slow one.
        var trippedNow = false
        for _ in 0..<(runs - previousRuns) where record(at: time) {
            trippedNow = true
        }
        return trippedNow
    }

    /// Once tripped, it stays tripped until the user acts on it. Clearing on a
    /// quiet period would make the banner flicker while the loop still runs.
    public var isUnstable: Bool { tripped }

    public var recentCount: Int { timestamps.count }

    public mutating func reset() {
        timestamps.removeAll()
        tripped = false
    }
}
