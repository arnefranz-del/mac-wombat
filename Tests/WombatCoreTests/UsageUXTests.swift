import Foundation
import Testing
@testable import WombatCore

struct UsageUXTests {
    @Test func previousPeriodsRemainAccessibleWithoutEarlierRecordings() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T10:15:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let ledger = try UsageLedger(location: .memory)
        try ledger.record(NetworkReading(state: .measuring, interval: 1, receivedDelta: 42), endingAt: now)
        for period in [UsagePeriod.hour, .day, .week, .month, .year] {
            let current = try ledger.snapshot(selection: UsageSelection(period: period), now: now, calendar: calendar)
            #expect(current.canGoBack, "Earlier \(period.label) should remain navigable, even with no older data")
            let previous = try ledger.snapshot(selection: UsageSelection(period: period, offset: -1), now: now, calendar: calendar)
            #expect(!previous.totals.hasObservations)
            #expect(previous.canGoForward)
        }
    }
}

extension UsageUXTests {
    @Test func navigationDoesNotDependOnAnAsynchronousSnapshot() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T10:15:00Z")!
        let calendar = Calendar(identifier: .gregorian)
        var selection = UsageSelection(period: .year)
        selection = try selection.moving(by: -1, now: now, calendar: calendar)
        selection = try selection.moving(by: -1, now: now, calendar: calendar)
        #expect(selection.offset == -2)
        selection = try selection.moving(by: 2, now: now, calendar: calendar)
        #expect(selection.offset == 0)
        #expect(try selection.moving(by: 1, now: now, calendar: calendar).offset == 0)
        #expect(try UsageSelection(period: .allTime).moving(by: -1, now: now, calendar: calendar).offset == 0)
    }

    @Test func navigationStopsAtSupportedCalendarFloor() throws {
        let now = ISO8601DateFormatter().date(from: "1970-01-02T10:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = try UsageSelection(period: .day).moving(by: -1, now: now, calendar: calendar)
        #expect(first.offset == -1)
        #expect(try first.moving(by: -1, now: now, calendar: calendar) == first)
    }

    @Test func hoverUsesExactBucketsAndHalfOpenBoundaries() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-27T10:15:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let ledger = try UsageLedger(location: .memory)
        try ledger.record(NetworkReading(state: .measuring, interval: 1, receivedDelta: 123, sentDelta: 45), endingAt: now)
        let snapshot = try ledger.snapshot(selection: UsageSelection(period: .hour), now: now, calendar: calendar)
        let recorded = try #require(snapshot.bucket(containing: now.addingTimeInterval(-0.5)))
        #expect(recorded.totals.received == 123 && recorded.totals.sent == 45)
        #expect(snapshot.bucket(containing: recorded.interval.end)?.id != recorded.id)
        #expect(snapshot.bucket(containing: snapshot.chartInterval.end) == nil)
        #expect(snapshot.bucket(containing: snapshot.chartInterval.start.addingTimeInterval(-1)) == nil)
    }

    @Test func longDayStillUsesDailyScaleInAllTimeView() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let ledger = try UsageLedger(location: .memory)
        try ledger.record(NetworkReading(state: .measuring, interval: 1), endingAt: now)
        let snapshot = try ledger.snapshot(selection: UsageSelection(period: .allTime), now: now, calendar: calendar)
        #expect(snapshot.buckets[0].interval.duration == 90_000)
        #expect(snapshot.bucketScale == .day)
    }
}
