import Foundation
import SQLite3
import Testing
@testable import WombatCore

struct SavedMeasurementTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func reading(_ rx: UInt64 = 123, _ tx: UInt64 = 45) -> NetworkReading {
        .init(download: Double(rx), upload: Double(tx), state: .measuring, interval: 1,
              receivedDelta: rx, sentDelta: tx)
    }
    private func finished(gaps: Bool = false) -> MeasurementSession {
        var result = MeasurementSession(startedAt: start, duration: nil)
        result.ingest(reading(), previousEnd: start, endingAt: start.addingTimeInterval(1), accepted: true)
        if gaps { result.noteGap() }
        result.stop(at: start.addingTimeInterval(gaps ? 10 : 1))
        return result
    }
    private func folder() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }
    private func sql(_ source: URL, _ query: String) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK)
    }
    private func scalar(_ source: URL, _ query: String) throws -> String {
        var db: OpaquePointer?, statement: OpaquePointer?
        #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
        defer { sqlite3_finalize(statement); sqlite3_close(db) }
        #expect(sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        return String(cString: sqlite3_column_text(statement, 0))
    }

    @Test func namesAreBoundAsDataAndBlankNamesUseLocalDateAndTime() throws {
        let ledger = try UsageLedger(location: .memory)
        let session = finished()
        let name = "  Urlaub 🦔 '); DELETE FROM recording; --  "
        try ledger.saveMeasurement(session, name: name)
        #expect(try ledger.savedMeasurements().first?.name == name.trimmingCharacters(in: .whitespacesAndNewlines))
        let locale = Locale(identifier: "de_DE"), zone = TimeZone(secondsFromGMT: 0)!
        let result = try SavedMeasurement(session: session, name: " \n ", locale: locale, timeZone: zone)
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = zone
        formatter.dateStyle = .medium; formatter.timeStyle = .medium
        #expect(result.name == formatter.string(from: start))
        #expect(throws: UsageError.self) { try ledger.saveMeasurement(session, name: "bad\0name") }
    }

    @Test func saveAndDeleteNeverChangeUsageIncludingPendingDeltas() throws {
        let ledger = try UsageLedger(location: .memory)
        try ledger.record(reading(), endingAt: start.addingTimeInterval(1))
        let before = try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(20))
        let one = finished(), two = finished(gaps: true)
        try ledger.saveMeasurement(one, name: "Eins")
        try ledger.saveMeasurement(two, name: "Zwei")
        try ledger.deleteMeasurement(id: one.id)
        try ledger.deleteMeasurement(id: UUID())
        #expect(try ledger.savedMeasurements().map(\.id) == [two.id])
        let after = try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(20))
        #expect(after.totals == before.totals && after.buckets.map(\.totals) == before.buckets.map(\.totals))
        try ledger.flush()
        #expect(try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(20)).totals == before.totals)
    }

    @Test func restartRestoresSavedResultsAndDeleteIsPermanent() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("usage.sqlite"), session = finished(gaps: true)
        do {
            let ledger = try UsageLedger(location: .file(source))
            try ledger.record(reading(), endingAt: start.addingTimeInterval(1)); try ledger.flush()
            try ledger.saveMeasurement(session, name: "Neustart")
            try ledger.saveMeasurement(session, name: "Doppelklick")
        }
        do {
            let ledger = try UsageLedger(location: .file(source))
            let results = try ledger.savedMeasurements()
            #expect(results.count == 1)
            let expected = try SavedMeasurement(session: session, name: "Neustart")
            #expect(results.first == expected)
            try ledger.deleteMeasurement(id: session.id)
        }
        let ledger = try UsageLedger(location: .file(source))
        #expect(try ledger.savedMeasurements().isEmpty)
        #expect(try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(20)).totals.received == 123)
        #expect(try scalar(source, "PRAGMA integrity_check") == "ok")
    }

    @Test func interruptionsAndDeadlineAfterSleepRetainExactBytesAndCoverage() throws {
        let ledger = try UsageLedger(location: .memory)
        var session = MeasurementSession(startedAt: start, duration: 900)
        session.ingest(reading(), previousEnd: start, endingAt: start.addingTimeInterval(1), accepted: true)
        session.noteGap()
        session.ingest(.init(state: .warmingUp), previousEnd: nil, endingAt: start.addingTimeInterval(950), accepted: false)
        try ledger.saveMeasurement(session, name: "Unterbrochen")
        let result = try #require(ledger.savedMeasurements().first)
        #expect(result.startedAt == start && result.endedAt == start.addingTimeInterval(900))
        #expect(result.received == 123 && result.sent == 45 && result.observedSeconds == 1)
        #expect(result.hasGaps && result.missingSeconds == 899)
        let running = MeasurementSession(startedAt: start, duration: nil)
        #expect(throws: UsageError.self) { try ledger.saveMeasurement(running, name: "Läuft noch") }
        #expect(try ledger.savedMeasurements().count == 1)
    }

    @Test func zeroObservationsAndWallClockAmbiguityAreNotCompleteCoverage() throws {
        var zero = MeasurementSession(startedAt: start, duration: nil)
        zero.noteGap(); zero.stop(at: start.addingTimeInterval(5))
        let empty = try SavedMeasurement(session: zero, name: "Leer")
        #expect(empty.hasGaps && empty.observedSeconds == 0 && empty.missingSeconds == 5)
        let ambiguous = try SavedMeasurement(id: UUID(), name: "Uhr", startedAt: start, endedAt: start,
            received: 1, sent: 0, observedSeconds: 1, hasGaps: false)
        #expect(ambiguous.hasGaps && ambiguous.coverageIsUnclear)
        #expect(throws: UsageError.self) {
            try SavedMeasurement(id: UUID(), name: "Überlauf", startedAt: start, endedAt: start,
                received: UInt64.max, sent: 0, observedSeconds: 1, hasGaps: false)
        }
    }

    @Test func additiveMigrationBacksUpLegacySchemaAndPreservesRollupsAndCSV() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("usage.sqlite")
        do {
            let ledger = try UsageLedger(location: .file(source))
            try ledger.record(reading(), endingAt: start.addingTimeInterval(1)); try ledger.flush()
        }
        try sql(source, "DROP TABLE measurement_sessions") // Exact pre-0.8.2 schema.
        let legacySchema = try scalar(source, "SELECT group_concat(sql) FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
        do {
            let ledger = try UsageLedger(location: .file(source))
            #expect(try ledger.savedMeasurements().isEmpty)
            #expect(try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(2)).totals.received == 123)
        }
        let backups = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        let backupSchema = try scalar(backup, "SELECT group_concat(sql) FROM sqlite_master WHERE sql IS NOT NULL ORDER BY name")
        #expect(backupSchema == legacySchema)
        for table in ["minute_usage", "hour_usage", "recording"] {
            let original = try scalar(source, "SELECT group_concat(received || '/' || sent || '/' || seconds) FROM \(table)")
            let copied = try scalar(backup, "SELECT group_concat(received || '/' || sent || '/' || seconds) FROM \(table)")
            #expect(copied == original)
        }
        #expect(try scalar(backup, "PRAGMA integrity_check") == "ok")
        #expect(try scalar(source, "PRAGMA user_version") == "1")
        // 0.8.1's version guard and existing queries still work against this file.
        #expect(try scalar(source, "SELECT received FROM recording WHERE id=1") == "123")
        let csv = directory.appendingPathComponent("usage.csv")
        try UsageCSV.export(source: source, destination: csv)
        #expect(try String(contentsOf: csv, encoding: .utf8).contains(",123,45,"))
        _ = try UsageLedger(location: .file(source))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Backups").path).count == 1)
    }

    @Test func failedMigrationBackupLeavesOriginalDatabaseUntouched() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("usage.sqlite")
        do { _ = try UsageLedger(location: .file(source)) }
        try sql(source, "DROP TABLE measurement_sessions")
        try Data("block".utf8).write(to: directory.appendingPathComponent("Backups"))
        let before = try Data(contentsOf: source)
        #expect(throws: (any Error).self) { _ = try UsageLedger(location: .file(source)) }
        #expect(try Data(contentsOf: source) == before)
        #expect(try scalar(source, "PRAGMA integrity_check") == "ok")
    }

    @Test func writeFailuresKeepSessionsAndUsageIntact() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("usage.sqlite")
        let ledger = try UsageLedger(location: .file(source)), session = finished()
        try ledger.record(reading(), endingAt: start.addingTimeInterval(1)); try ledger.flush()
        try sql(source, "CREATE TRIGGER reject_save BEFORE INSERT ON measurement_sessions BEGIN SELECT RAISE(ABORT,'test'); END")
        #expect(throws: UsageError.self) { try ledger.saveMeasurement(session, name: "Fehler") }
        #expect(try ledger.savedMeasurements().isEmpty)
        try sql(source, "DROP TRIGGER reject_save")
        try ledger.saveMeasurement(session, name: "Erhalten")
        try sql(source, "CREATE TRIGGER reject_delete BEFORE DELETE ON measurement_sessions BEGIN SELECT RAISE(ABORT,'test'); END")
        #expect(throws: UsageError.self) { try ledger.deleteMeasurement(id: session.id) }
        #expect(try ledger.savedMeasurements().count == 1)
        #expect(try scalar(source, "SELECT received FROM recording WHERE id=1") == "123")
        #expect(try scalar(source, "PRAGMA integrity_check") == "ok")
    }

    @Test func resetHistoryDoesNotDeleteSavedSessions() throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try UsageLedger(location: .file(directory.appendingPathComponent("usage.sqlite")))
        try ledger.saveMeasurement(finished(), name: "Behalten")
        try ledger.record(reading(), endingAt: start.addingTimeInterval(1))
        _ = try ledger.backupAndReset(in: directory.appendingPathComponent("Backups"))
        #expect(try ledger.savedMeasurements().count == 1)
        #expect(try ledger.snapshot(selection: .init(period: .allTime), now: start.addingTimeInterval(2)).totals == .zero)
    }
}
