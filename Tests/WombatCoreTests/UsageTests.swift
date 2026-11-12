import Foundation
import SQLite3
import Testing
@testable import WombatCore

struct UsageTests {
    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func reading(_ received: UInt64, _ sent: UInt64 = 0, interval: Double = 2) -> NetworkReading {
        NetworkReading(download: Double(received) / interval, upload: Double(sent) / interval,
                       state: .measuring, interval: interval, receivedDelta: received, sentDelta: sent)
    }

    @Test func splitAcrossMidnightPreservesEveryByte() throws {
        let parts = try UsageIntervalSplitter.split(reading(101, 51), endingAt: date("2026-10-27T23:00:01Z"))
        #expect(parts.count == 2)
        #expect(parts.reduce(UInt64(0)) { $0 + $1.totals.received } == 101)
        #expect(parts.reduce(UInt64(0)) { $0 + $1.totals.sent } == 51)
        #expect(parts.reduce(0.0) { $0 + $1.totals.observedSeconds } == 2)
        #expect(parts[0].totals.received == 50)
        #expect(parts[1].totals.received == 51)
    }

    @Test func reopenPreservesLifetimeAndCalendarTotals() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("usage.sqlite")
        let now = date("2026-10-27T10:00:02Z")
        do {
            let ledger = try UsageLedger(location: .file(url))
            try ledger.record(reading(12_000_000, 500_000), endingAt: now)
            try ledger.flush()
        }
        let reopened = try UsageLedger(location: .file(url))
        let day = try reopened.snapshot(selection: UsageSelection(period: .day), now: now, calendar: berlin)
        let all = try reopened.snapshot(selection: UsageSelection(period: .allTime), now: now, calendar: berlin)
        #expect(day.totals.received == 12_000_000)
        #expect(day.totals.sent == 500_000)
        #expect(day.totals == all.totals)
        #expect(all.recordingSince == now.addingTimeInterval(-2))
    }

    @Test func calendarHandlesBothDaylightSavingTransitions() throws {
        let spring = try UsagePeriod.day.interval(containing: date("2026-03-29T12:00:00Z"), calendar: berlin)
        let autumn = try UsagePeriod.day.interval(containing: date("2026-10-25T12:00:00Z"), calendar: berlin)
        #expect(spring.duration == 23 * 3_600)
        #expect(autumn.duration == 25 * 3_600)
    }

    @Test func invalidReadingsDoNotBecomeConsumption() throws {
        let ledger = try UsageLedger(location: .memory)
        let now = date("2026-10-27T10:00:00Z")
        for state in [ReadingState.warmingUp, .offline, .resynchronizing, .sleeping, .unavailable] {
            try ledger.record(NetworkReading(state: state, interval: 1, receivedDelta: 999_999), endingAt: now)
        }
        let snapshot = try ledger.snapshot(selection: UsageSelection(period: .allTime), now: now, calendar: berlin)
        #expect(snapshot.totals == .zero)
        #expect(snapshot.recordingSince == nil)
    }
}

extension UsageTests {
    @Test func unknownSchemaVersionIsLeftUnchanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("future.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version=99; CREATE TABLE original(value TEXT); INSERT INTO original VALUES('keep');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let before = try Data(contentsOf: file)
        #expect(throws: (any Error).self) { try UsageLedger(location: .file(file)) }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func pendingFlushAndRepeatedFlushNeverDoubleCount() throws {
        let ledger = try UsageLedger(location: .memory)
        let now = date("2026-10-27T10:00:02Z")
        try ledger.record(reading(100, 25), endingAt: now)
        let before = try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin)
        try ledger.flush()
        let after = try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin)
        try ledger.flush()
        let again = try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin)
        #expect(before.totals == after.totals)
        #expect(after.totals == again.totals)
        try ledger.record(reading(50, 10), endingAt: now.addingTimeInterval(2))
        #expect(try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin).totals.received == 150)
        try ledger.flush()
        #expect(try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin).totals.received == 150)
    }

    @Test func calendarDaySplitsAtLocalMidnight() throws {
        let ledger = try UsageLedger(location: .memory)
        let midnight = date("2026-10-27T23:00:00Z")
        try ledger.record(reading(101, 51), endingAt: midnight.addingTimeInterval(1))
        try ledger.flush()
        let yesterday = try ledger.snapshot(selection: UsageSelection(period: .day, offset: -1),
            now: midnight.addingTimeInterval(2), calendar: berlin)
        let today = try ledger.snapshot(selection: UsageSelection(period: .day),
            now: midnight.addingTimeInterval(2), calendar: berlin)
        #expect(yesterday.totals.received == 50)
        #expect(today.totals.received == 51)
        #expect(yesterday.totals.sent + today.totals.sent == 51)
    }

    @Test func fallBackHourIsRepresentedTwiceWithoutDoubleCounting() throws {
        let ledger = try UsageLedger(location: .memory)
        try ledger.record(reading(100), endingAt: date("2026-10-25T00:30:02Z"))
        try ledger.record(reading(200), endingAt: date("2026-10-25T01:30:02Z"))
        try ledger.flush()
        let snapshot = try ledger.snapshot(selection: UsageSelection(), now: date("2026-10-25T12:00:00Z"), calendar: berlin)
        #expect(snapshot.buckets.count == 25)
        #expect(snapshot.totals.received == 300)
        let recorded = snapshot.buckets.filter { $0.totals.hasObservations }
        #expect(recorded.count == 2)
        #expect(recorded[0].interval.start != recorded[1].interval.start)
        #expect(berlin.component(.hour, from: recorded[0].interval.start) == 2)
        #expect(berlin.component(.hour, from: recorded[1].interval.start) == 2)
    }

    @Test func springDayHas23BucketsAndWeekStartsMonday() throws {
        let now = date("2026-03-29T12:00:00Z")
        let plan = try UsagePlan(selection: UsageSelection(), now: now, first: nil, last: nil, calendar: berlin)
        #expect(plan.bucketIntervals.count == 23)
        let week = try UsagePeriod.week.interval(containing: now, calendar: berlin)
        #expect(berlin.component(.weekday, from: week.start) == 2)
        #expect(berlin.component(.weekday, from: week.end) == 2)
    }

    @Test func nonWholeHourTimezoneUsesMinuteEdgesCorrectly() throws {
        var kathmandu = berlin
        kathmandu.timeZone = TimeZone(identifier: "Asia/Kathmandu")!
        let ledger = try UsageLedger(location: .memory)
        let midnight = date("2026-10-27T18:15:00Z")
        try ledger.record(reading(101), endingAt: midnight.addingTimeInterval(1))
        try ledger.flush()
        let earlier = try ledger.snapshot(selection: UsageSelection(period: .day, offset: -1),
            now: midnight.addingTimeInterval(2), calendar: kathmandu)
        let later = try ledger.snapshot(selection: UsageSelection(), now: midnight.addingTimeInterval(2), calendar: kathmandu)
        #expect(earlier.totals.received == 50)
        #expect(later.totals.received == 51)
    }

    @Test func seriesAndSummaryAgreeAcrossAllSixPeriods() throws {
        let ledger = try UsageLedger(location: .memory)
        let now = date("2026-10-27T10:01:02Z")
        try ledger.record(reading(1_001, 501), endingAt: now)
        try ledger.record(reading(2_001, 301), endingAt: now.addingTimeInterval(120))
        try ledger.flush()
        for period in UsagePeriod.allCases {
            let snapshot = try ledger.snapshot(selection: UsageSelection(period: period), now: now, calendar: berlin)
            #expect(snapshot.totals.received == 3_002)
            #expect(snapshot.totals.sent == 802)
            #expect(snapshot.buckets.reduce(UInt64(0)) { $0 + $1.totals.received } == snapshot.totals.received)
            #expect(snapshot.buckets.reduce(UInt64(0)) { $0 + $1.totals.sent } == snapshot.totals.sent)
        }
    }

    @Test func allTimeIncludesPreviousYearsAndUnrecordedPeriodsRemainNavigable() throws {
        let ledger = try UsageLedger(location: .memory)
        let now = date("2026-10-27T10:00:02Z")
        try ledger.record(reading(500), endingAt: date("2025-12-15T10:00:02Z"))
        try ledger.record(reading(100), endingAt: now)
        try ledger.flush()
        let current = try ledger.snapshot(selection: UsageSelection(period: .year), now: now, calendar: berlin)
        let previous = try ledger.snapshot(selection: UsageSelection(period: .year, offset: -1), now: now, calendar: berlin)
        let all = try ledger.snapshot(selection: UsageSelection(period: .allTime), now: now, calendar: berlin)
        #expect(current.totals.received == 100)
        #expect(previous.totals.received == 500)
        #expect(all.totals.received == 600)
        #expect(current.canGoBack)
        #expect(!current.canGoForward)
        #expect(previous.canGoBack)
        #expect(previous.canGoForward)
        #expect(!all.canGoBack && !all.canGoForward)
    }

    @Test func absentRecordingAndMeasuredZeroStayDistinguishable() throws {
        let ledger = try UsageLedger(location: .memory)
        let now = date("2026-10-27T10:00:02Z")
        #expect(try !ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin).totals.hasObservations)
        try ledger.record(reading(0), endingAt: now)
        try ledger.flush()
        let result = try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin)
        #expect(result.totals.hasObservations)
        #expect(result.totals.bytes == 0)
        #expect(result.recordingSince != nil)
    }

    @Test func gapsAreNotRecordedAsZeroTrafficOrElapsedCoverage() throws {
        let ledger = try UsageLedger(location: .memory)
        try ledger.record(reading(100), endingAt: date("2026-10-27T03:00:02Z"))
        try ledger.record(reading(100), endingAt: date("2026-10-27T06:00:02Z"))
        let result = try ledger.snapshot(selection: UsageSelection(), now: date("2026-10-27T12:00:00Z"), calendar: berlin)
        #expect(result.totals.received == 200)
        #expect(result.totals.observedSeconds == 4)
        #expect(result.buckets.filter { $0.totals.hasObservations }.count == 2)
    }

    @Test func bytesComeFromDeltasRatherThanDisplayedRates() throws {
        let ledger = try UsageLedger(location: .memory)
        let now = date("2026-10-27T10:00:02Z")
        try ledger.record(NetworkReading(download: 9_000_000, upload: 8_000_000, state: .measuring,
            interval: 1, receivedDelta: 17, sentDelta: 9), endingAt: now)
        let result = try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin)
        #expect(result.totals.received == 17 && result.totals.sent == 9)
    }

    @Test func clockJumpsAreRejectedWithoutInventingAttribution() {
        let end = date("2026-10-27T10:00:02Z")
        let sample = reading(1_000)
        #expect(UsageAttribution.accepts(sample, endingAt: end, previousEnd: end.addingTimeInterval(-2)))
        #expect(!UsageAttribution.accepts(sample, endingAt: end, previousEnd: nil))
        #expect(!UsageAttribution.accepts(sample, endingAt: end, previousEnd: end.addingTimeInterval(-3_600)))
        #expect(!UsageAttribution.accepts(sample, endingAt: end, previousEnd: end.addingTimeInterval(3_600)))
    }

    @Test func splitterConservesBytesAtFractionalBoundaries() throws {
        for milliseconds in [1, 50, 249, 501, 999] {
            for length in [0.25, 1.0, 2.5, 3.5] {
                let end = date("2026-10-27T10:01:00Z").addingTimeInterval(Double(milliseconds) / 1_000)
                let parts = try UsageIntervalSplitter.split(reading(103, 53, interval: length), endingAt: end)
                #expect(parts.reduce(UInt64(0)) { $0 + $1.totals.received } == 103)
                #expect(parts.reduce(UInt64(0)) { $0 + $1.totals.sent } == 53)
                #expect(abs(parts.reduce(0.0) { $0 + $1.totals.observedSeconds } - length) < 0.000_001)
            }
        }
    }

    @Test func invalidSamplesAreAtomicAndDoNotReachStorage() throws {
        let ledger = try UsageLedger(location: .memory)
        let now = date("2026-10-27T10:00:02Z")
        for interval in [0.0, 0.001, 4.0, Double.nan, .infinity] {
            #expect(throws: (any Error).self) { try ledger.record(reading(100, interval: interval), endingAt: now) }
        }
        #expect(throws: (any Error).self) { try ledger.record(reading(.max), endingAt: now) }
        #expect(try ledger.snapshot(selection: UsageSelection(), now: now, calendar: berlin).totals == .zero)
    }

    @Test func corruptFileIsPreservedInsteadOfBeingReset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.sqlite")
        let content = Data("existing data; not a database".utf8)
        try content.write(to: file)
        #expect(throws: (any Error).self) { try UsageLedger(location: .file(file)) }
        #expect(try Data(contentsOf: file) == content)
    }

    @Test func failedTransactionRollsBackRollupsAndLifetimeTogether() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.sqlite")
        let ledger = try UsageLedger(location: .file(file))
        try ledger.record(reading(UInt64(Int64.max)), endingAt: date("2026-10-26T10:00:02Z"))
        try ledger.flush()
        let now = date("2026-10-27T10:00:02Z")
        try ledger.record(reading(1), endingAt: now)
        #expect(throws: (any Error).self) { try ledger.flush() }
        let reopened = try UsageLedger(location: .file(file))
        let lifetime = try reopened.snapshot(selection: UsageSelection(period: .allTime), now: now, calendar: berlin)
        let day = try reopened.snapshot(selection: UsageSelection(), now: now, calendar: berlin)
        #expect(lifetime.totals.received == UInt64(Int64.max))
        #expect(day.totals == .zero)
    }

    @Test func newDatabaseIsPrivateToTheCurrentUser() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("usage.sqlite")
        let ledger = try UsageLedger(location: .file(file))
        _ = ledger
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
        let parent = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((parent[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }
}
