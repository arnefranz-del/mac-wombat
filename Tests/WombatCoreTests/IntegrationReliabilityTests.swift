import Darwin
import Foundation
import Testing
@testable import WombatCore

struct IntegrationReliabilityTests {
    @Test func instanceLockExcludesSecondOwnerAndCanBeReacquired() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("instance.lock")
        var first: SingleInstanceLock? = try SingleInstanceLock(url: path)
        withExtendedLifetime(first) {
            do {
                let unexpected = try SingleInstanceLock(url: path)
                withExtendedLifetime(unexpected) { Issue.record("A second owner acquired the held lock") }
            } catch InstanceLockError.alreadyRunning {
                // The expected exclusion, not merely an unrelated filesystem error.
            } catch {
                Issue.record("Unexpected lock failure: \(error)")
            }
        }
        first = nil
        // Other parallel tests spawn child processes. A just-forked child can
        // briefly hold an inherited descriptor until exec closes O_CLOEXEC.
        // Still fail if the lock does not become available within the deadline.
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        var reacquired: SingleInstanceLock?
        while reacquired == nil {
            do { reacquired = try SingleInstanceLock(url: path) }
            catch InstanceLockError.alreadyRunning {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw InstanceLockError.alreadyRunning }
                usleep(5_000)
            }
        }
        let next = try #require(reacquired)
        withExtendedLifetime(next) { #expect(FileManager.default.fileExists(atPath: path.path)) }
        _ = first
    }

    @Test func lockRejectsSymlinkWithoutChangingTarget() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("precious")
        try Data("untouched".utf8).write(to: target)
        let link = folder.appendingPathComponent("instance.lock")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: InstanceLockError.self) { try SingleInstanceLock(url: link) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "untouched")
    }

    @Test func partialHourAndObservedZeroAreNotCompleteZeroUsage() throws {
        let now = Date(timeIntervalSince1970: 1_800)
        let ledger = try UsageLedger(location: .memory)
        try ledger.record(NetworkReading(state: .measuring, interval: 1), endingAt: now)
        let snapshot = try ledger.snapshot(selection: .init(period: .hour), now: now, calendar: utc)
        #expect(snapshot.totals.hasObservations && snapshot.totals.bytes == 0)
        #expect(snapshot.coverage.isPartial && snapshot.coverage.isOngoing)
        #expect(snapshot.coverage.observedSeconds == 1 && snapshot.coverage.expectedSeconds == 1800)
        #expect(snapshot.coverage.label.contains("Teilweise"))
    }

    @Test func missingHourIsUnknownAndFutureIsNotAMeasurementGap() throws {
        let now = Date(timeIntervalSince1970: 7_200)
        let ledger = try UsageLedger(location: .memory)
        let empty = try ledger.snapshot(selection: .init(period: .hour, offset: -1), now: now, calendar: utc)
        #expect(!empty.coverage.hasObservations)
        #expect(empty.coverage.label == "Keine Aufzeichnung")
        let future = UsageCoverage(interval: DateInterval(start: now.addingTimeInterval(60), duration: 300), observedSeconds: 0, asOf: now)
        #expect(future.isFuture && future.expectedSeconds == 0 && !future.isPartial)
        let overall = try ledger.snapshot(selection: .init(period: .allTime), now: now, calendar: utc)
        #expect(overall.coverage.label == "Keine Aufzeichnung")
    }

    @Test func partialPastPeriodAndContinuousMeasuredZeroDiffer() {
        let interval = DateInterval(start: Date(timeIntervalSince1970: 0), duration: 3600)
        let past = Date(timeIntervalSince1970: 7200)
        let partial = UsageCoverage(interval: interval, observedSeconds: 600, asOf: past)
        #expect(partial.isPartial && !partial.isOngoing && partial.missingSeconds == 3000)
        let complete = UsageCoverage(interval: interval, observedSeconds: 3600, asOf: past)
        #expect(complete.hasObservations && !complete.isPartial)
        #expect(complete.label.contains("Vollständig"))
    }

    @Test func overallCoverageStartsAtFirstObservationAndIncludesLaterGaps() throws {
        let ledger = try UsageLedger(location: .memory)
        let end = Date(timeIntervalSince1970: 1000)
        try ledger.record(NetworkReading(state: .measuring, interval: 1, receivedDelta: 7), endingAt: end)
        try ledger.record(NetworkReading(state: .measuring, interval: 1, sentDelta: 3), endingAt: end.addingTimeInterval(61))
        try ledger.flush()
        let snapshot = try ledger.snapshot(selection: .init(period: .allTime), now: end.addingTimeInterval(121), calendar: utc)
        #expect(snapshot.coverage.expectedSeconds == 122)
        #expect(snapshot.coverage.observedSeconds == 2 && snapshot.coverage.isPartial)
        #expect(snapshot.totals.received == 7 && snapshot.totals.sent == 3)
    }

    @Test func coverageUsesActualDstDayLengthAndExcludesFutureHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        for (text, hours) in [("2026-03-29T12:00:00Z", 23.0), ("2026-10-25T12:00:00Z", 25.0)] {
            let date = ISO8601DateFormatter().date(from: text)!
            let interval = calendar.dateInterval(of: .day, for: date)!
            let past = UsageCoverage(interval: interval, observedSeconds: 100, asOf: interval.end.addingTimeInterval(1))
            #expect(past.expectedSeconds == hours * 3600 && past.isPartial)
            let ongoing = UsageCoverage(interval: interval, observedSeconds: 100, asOf: interval.start.addingTimeInterval(300))
            #expect(ongoing.expectedSeconds == 300 && ongoing.isOngoing)
        }
    }

    @Test func overlappingOrClockShiftedDurationDoesNotClaimCompleteCoverage() {
        let start = Date(timeIntervalSince1970: 1000)
        let coverage = UsageCoverage(interval: DateInterval(start: start, duration: 60), observedSeconds: 120,
            asOf: start.addingTimeInterval(61))
        #expect(coverage.hasInconsistentDuration && coverage.fraction == nil)
        #expect(!coverage.label.contains("Vollständig"))
    }

    @Test func missingHourCannotBeHiddenByOverlappingDurationElsewhere() {
        let start = Date(timeIntervalSince1970: 0), now = Date(timeIntervalSince1970: 7200)
        let interval = DateInterval(start: start, duration: 86400)
        let buckets = [UsageBucket(interval: DateInterval(start: start, duration: 3600), totals: .zero),
            UsageBucket(interval: DateInterval(start: start.addingTimeInterval(3600), duration: 3600),
                totals: UsageTotals(observedSeconds: 7200))]
        let snapshot = UsageSnapshot(capturedAt: now, selection: .init(period: .day), interval: interval,
            chartInterval: interval, totals: UsageTotals(observedSeconds: 7200), buckets: buckets,
            recordingSince: start, canGoBack: false, bucketScale: .hour)
        #expect(snapshot.coverage.isPartial)
        #expect(snapshot.coverage.fraction == nil)
        #expect(!snapshot.coverage.label.contains("Vollständig"))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
