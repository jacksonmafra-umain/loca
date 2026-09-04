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

    // MARK: - Driven by launchctl's runs counter

    /// The first observation infers nothing: a service that ran forty times
    /// before the app opened is not evidence of a loop happening now.
    @Test func theFirstObservationRecordsNothing() {
        var tracker = RestartTracker()
        #expect(tracker.record(runs: 40, previousRuns: nil, at: start) == false)
        #expect(tracker.recentCount == 0)
        #expect(!tracker.isUnstable)
    }

    @Test func anUnchangedCounterRecordsNothing() {
        var tracker = RestartTracker()
        _ = tracker.record(runs: 3, previousRuns: nil, at: start)
        #expect(tracker.record(runs: 3, previousRuns: 3, at: start) == false)
        #expect(tracker.recentCount == 0)
    }

    /// launchd relaunches a broken command about every ten seconds, so three
    /// polls three seconds apart see the counter step up.
    @Test func aClimbingCounterTripsAtTheThirdRelaunch() {
        var tracker = RestartTracker()
        #expect(tracker.record(runs: 2, previousRuns: 1, at: start) == false)
        #expect(
            tracker.record(runs: 3, previousRuns: 2, at: start.addingTimeInterval(10)) == false)
        #expect(
            tracker.record(runs: 4, previousRuns: 3, at: start.addingTimeInterval(20)) == true)
        #expect(tracker.isUnstable)
    }

    /// A jump larger than one means several relaunches happened between polls.
    /// Dropping them would make a fast loop look calmer than a slow one.
    @Test func aJumpRecordsEveryRelaunchItImplies() {
        var tracker = RestartTracker()
        #expect(tracker.record(runs: 4, previousRuns: 1, at: start) == true)
        #expect(tracker.recentCount == 3)
    }

    /// A lower count means the service was booted out and started afresh.
    @Test func aFallingCounterResetsRatherThanCounting() {
        var tracker = RestartTracker()
        _ = tracker.record(runs: 4, previousRuns: 1, at: start)
        #expect(tracker.isUnstable)

        #expect(tracker.record(runs: 1, previousRuns: 4, at: start.addingTimeInterval(1)) == false)
        #expect(!tracker.isUnstable)
        #expect(tracker.recentCount == 0)
    }

    /// Relaunches spread wider than the window are a server that occasionally
    /// dies, not a loop.
    @Test func aSlowlyClimbingCounterNeverTrips() {
        var tracker = RestartTracker()
        var previous = 1
        for step in 1...8 {
            let runs = previous + 1
            let tripped = tracker.record(
                runs: runs, previousRuns: previous, at: start.addingTimeInterval(Double(step) * 45))
            #expect(tripped == false)
            previous = runs
        }
        #expect(!tracker.isUnstable)
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
