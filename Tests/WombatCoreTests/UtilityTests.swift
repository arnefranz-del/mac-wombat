import Foundation
import SQLite3
import Testing
@testable import WombatCore

struct UtilityTests {
    private func reading(_ received: UInt64, _ sent: UInt64, interval: Double = 1) -> NetworkReading {
        NetworkReading(download: Double(received), upload: Double(sent), state: .measuring,
                       interval: interval, receivedDelta: received, sentDelta: sent)
    }

    @Test func timerUsesOnlyAcceptedIntervalsAndShowsGaps() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var session = MeasurementSession(startedAt: start, duration: nil)
        session.ingest(reading(100, 20), previousEnd: start, endingAt: start.addingTimeInterval(1), accepted: true)
        session.ingest(.init(state: .offline), previousEnd: start.addingTimeInterval(1), endingAt: start.addingTimeInterval(2), accepted: false)
        session.ingest(reading(50, 5), previousEnd: start.addingTimeInterval(2), endingAt: start.addingTimeInterval(3), accepted: true)
        session.stop(at: start.addingTimeInterval(3))
        #expect(session.received == 150 && session.sent == 25 && session.observedSeconds == 2)
        #expect(session.hasGaps && !session.isRunning)
        session.ingest(reading(900, 900), previousEnd: start.addingTimeInterval(3), endingAt: start.addingTimeInterval(4), accepted: true)
        #expect(session.received == 150)
    }

    @Test func timerEndsOnRealSampleAndDoesNotInventPostSleepBytes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for length in [900.0, 1800.0, 3600.0] {
            var session = MeasurementSession(startedAt: start, duration: length)
            let previous = start.addingTimeInterval(length - 0.5)
            let end = start.addingTimeInterval(length + 0.5)
            session.ingest(reading(100, 20), previousEnd: previous, endingAt: end, accepted: true)
            #expect(!session.isRunning && session.endedAt == end && session.received == 100)
            var sleeping = MeasurementSession(startedAt: start, duration: length)
            sleeping.noteGap()
            sleeping.ingest(.init(state: .warmingUp), previousEnd: nil, endingAt: end, accepted: false)
            #expect(!sleeping.isRunning && sleeping.endedAt == start.addingTimeInterval(length))
            #expect(sleeping.received == 0 && sleeping.hasGaps)
        }
    }

    @Test func csvIsReadOnlyIncludesMissingIntervalsAndProtectsSource() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("usage.sqlite"), csv = folder.appendingPathComponent("usage.csv")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            let ledger = try UsageLedger(location: .file(source))
            try ledger.record(reading(123, 45), endingAt: start.addingTimeInterval(1))
            try ledger.record(reading(67, 8), endingAt: start.addingTimeInterval(121))
            try ledger.flush()
        }
        let before = try Data(contentsOf: source)
        try UsageCSV.export(source: source, destination: csv)
        let text = try String(contentsOf: csv, encoding: .utf8)
        #expect(text.contains("start_utc,end_utc,download_bytes,upload_bytes,erfasste_sekunden,status"))
        #expect(text.contains(",123,45,1.000000,teilweise"))
        #expect(text.contains(",,,,nicht_erfasst"))
        #expect(text.contains(",67,8,1.000000,teilweise"))
        #expect(try Data(contentsOf: source) == before)
        #expect(throws: UsageError.self) { try UsageCSV.export(source: source, destination: source) }
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func resetBacksUpBeforeClearingAndCanRecordAgain() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("usage.sqlite"), start = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = try UsageLedger(location: .file(source))
        try ledger.record(reading(300, 40), endingAt: start.addingTimeInterval(1))
        #expect(throws: (any Error).self) { try ledger.backupAndReset(in: URL(fileURLWithPath: "/dev/null")) }
        #expect(try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(2)).totals.received == 300)
        let backup = try ledger.backupAndReset(in: folder.appendingPathComponent("Backups"))
        let restored = try UsageLedger(location: .file(backup))
        #expect(try restored.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(2)).totals.received == 300)
        #expect(try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(2)).totals == .zero)
        try ledger.record(reading(11, 2), endingAt: start.addingTimeInterval(3)); try ledger.flush()
        #expect(try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(4)).totals.received == 11)
    }

    @Test func failedDeleteRollsBackAllTablesAndRetainsVerifiedBackup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("usage.sqlite"), backups = folder.appendingPathComponent("Backups")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = try UsageLedger(location: .file(source))
        try ledger.record(reading(99, 8), endingAt: now.addingTimeInterval(1)); try ledger.flush()
        var handle: OpaquePointer?
        #expect(sqlite3_open(source.path, &handle) == SQLITE_OK)
        #expect(sqlite3_exec(handle, "CREATE TRIGGER reject_reset BEFORE DELETE ON hour_usage BEGIN SELECT RAISE(ABORT,'test'); END", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(throws: (any Error).self) { try ledger.backupAndReset(in: backups) }
        #expect(try ledger.snapshot(selection: .init(period: .allTime), now: now.addingTimeInterval(2)).totals.received == 99)
        let saved = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        #expect(saved.count == 1)
        let backup = try UsageLedger(location: .file(try #require(saved.first)))
        #expect(try backup.snapshot(selection: .init(period: .allTime), now: now.addingTimeInterval(2)).totals.received == 99)
    }
}
