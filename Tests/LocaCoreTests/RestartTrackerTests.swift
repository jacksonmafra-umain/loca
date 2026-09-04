import Foundation
import Testing

@testable import LocaCore

@Suite("RestartTracker")
struct RestartTrackerTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test func threeRestartsInsideTheWindowTripAtTheThird() {
        var tracker = RestartTracker()
        #expect(tracker.record(at: start) == false)
        #expect(tracker.record(at: start.addingTimeInterval(5)) == false)
        #expect(tracker.record(at: start.addingTimeInterval(10)) == true)
        #expect(tracker.isUnstable)
    }

    /// launchd's own 10-second throttle means a broken command restarts roughly
    /// six times a minute forever. Spacing wider than the window is a server
    /// that occasionally dies, not a crash loop, and must not be flagged.
    @Test func restartsSpreadWiderThanTheWindowNeverTrip() {
        var tracker = RestartTracker()
        for step in 0..<10 {
            let trippedNow = tracker.record(at: start.addingTimeInterval(Double(step) * 40))
            #expect(trippedNow == false)
        }
        #expect(!tracker.isUnstable)
    }

    @Test func timestampsOlderThanTheWindowAreDropped() {
        var tracker = RestartTracker()
        _ = tracker.record(at: start)
        _ = tracker.record(at: start.addingTimeInterval(1))
        // The first two have aged out by now, so this is the only one counted.
        #expect(tracker.record(at: start.addingTimeInterval(120)) == false)
        #expect(tracker.recentCount == 1)
    }

    @Test func resetClearsTheState() {
        var tracker = RestartTracker()
        _ = tracker.record(at: start)
        _ = tracker.record(at: start.addingTimeInterval(1))
        _ = tracker.record(at: start.addingTimeInterval(2))
        #expect(tracker.isUnstable)
        tracker.reset()
        #expect(!tracker.isUnstable)
        #expect(tracker.recentCount == 0)
    }

    /// Once tripped, it stays tripped until the user acts. Letting it clear on
    /// its own would make the banner flicker while the loop is still running.
    @Test func stayingUnstableSurvivesLaterQuietPeriods() {
        var tracker = RestartTracker()
        _ = tracker.record(at: start)
        _ = tracker.record(at: start.addingTimeInterval(1))
        _ = tracker.record(at: start.addingTimeInterval(2))
        _ = tracker.record(at: start.addingTimeInterval(600))
        #expect(tracker.isUnstable)
    }

    @Test func trueIsReturnedOnlyOnTheTransition() {
        var tracker = RestartTracker()
        _ = tracker.record(at: start)
        _ = tracker.record(at: start.addingTimeInterval(1))
        #expect(tracker.record(at: start.addingTimeInterval(2)) == true)
        #expect(tracker.record(at: start.addingTimeInterval(3)) == false)
    }

    @Test func thresholdAndWindowAreInjectable() {
        var tracker = RestartTracker(threshold: 2, window: 5)
        #expect(tracker.record(at: start) == false)
        #expect(tracker.record(at: start.addingTimeInterval(1)) == true)

        var loose = RestartTracker(threshold: 2, window: 5)
        _ = loose.record(at: start)
        #expect(loose.record(at: start.addingTimeInterval(6)) == false)
    }
}
