import Foundation
import Darwin
import SQLite3

struct UsageDatabaseState {
    let first: Date
    let last: Date
    let totals: UsageTotals
}

/// Confined to the sampling queue. One connection, bound numeric parameters,
/// atomic rollback-journal transactions, no background service or dependency.
final class UsageDatabase {
    private var handle: OpaquePointer?
    private var totalsCache: [DateInterval: UsageTotals] = [:]
    private var stateCache: UsageDatabaseState?
    private var stateLoaded = false

    init(location: UsageStorageLocation) throws {
        let path: String
        let fileURL: URL?
        switch location {
        case .memory: path = ":memory:"; fileURL = nil
        case .applicationSupport:
            let url = try UsageStorageLocation.applicationURL()
            path = try Self.prepare(url); fileURL = url
        case .file(let url): path = try Self.prepare(url); fileURL = url
        }
        var database: OpaquePointer?
        let result = sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil)
        guard result == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Datei nicht erreichbar"
            if let database { sqlite3_close(database) }
            throw UsageError.database(detail)
        }
        handle = database
        do {
            sqlite3_busy_timeout(database, 1_500)
            let version = try integer("PRAGMA user_version")
            guard version == 0 || version == 1 else { throw UsageError.unsupportedSchema }
            if version == 0 {
                guard try integer("SELECT COUNT(*) FROM sqlite_master WHERE type='table'") == 0 else {
                    throw UsageError.unsupportedSchema
                }
            }
            try execute("PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;")
            if version == 0 {
                try execute("""
                    BEGIN IMMEDIATE;
                    CREATE TABLE minute_usage (
                        tick INTEGER PRIMARY KEY,
                        received INTEGER NOT NULL CHECK(typeof(received)='integer' AND received>=0),
                        sent INTEGER NOT NULL CHECK(typeof(sent)='integer' AND sent>=0),
                        seconds REAL NOT NULL CHECK(seconds>=0)
                    ) WITHOUT ROWID;
                    CREATE TABLE hour_usage (
                        tick INTEGER PRIMARY KEY,
                        received INTEGER NOT NULL CHECK(typeof(received)='integer' AND received>=0),
                        sent INTEGER NOT NULL CHECK(typeof(sent)='integer' AND sent>=0),
                        seconds REAL NOT NULL CHECK(seconds>=0)
                    ) WITHOUT ROWID;
                    CREATE TABLE recording (
                        id INTEGER PRIMARY KEY CHECK(id=1), first REAL NOT NULL, last REAL NOT NULL,
                        received INTEGER NOT NULL CHECK(typeof(received)='integer' AND received>=0),
                        sent INTEGER NOT NULL CHECK(typeof(sent)='integer' AND sent>=0),
                        seconds REAL NOT NULL CHECK(seconds>=0)
                    );
                    PRAGMA user_version=1;
                    COMMIT;
                    """)
            }
            _ = try state()
            if try integer("SELECT COUNT(*) FROM sqlite_master WHERE name='measurement_sessions'") == 0 {
                // Additive extension: keep user_version=1 so 0.8.1 and its CSV
                // reader can still use the unchanged minute/hour/recording tables.
                if version == 1, let fileURL {
                    try backup(to: fileURL.deletingLastPathComponent().appendingPathComponent("Backups")
                        .appendingPathComponent("usage-before-sessions-\(UUID().uuidString).sqlite"))
                }
                try execute("BEGIN IMMEDIATE")
                do {
                    try execute("""
                        CREATE TABLE measurement_sessions (
                            id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL CHECK(length(name)>0),
                            started REAL NOT NULL, ended REAL NOT NULL CHECK(ended>=started),
                            received INTEGER NOT NULL CHECK(typeof(received)='integer' AND received>=0),
                            sent INTEGER NOT NULL CHECK(typeof(sent)='integer' AND sent>=0),
                            seconds REAL NOT NULL CHECK(seconds>=0),
                            has_gaps INTEGER NOT NULL CHECK(has_gaps IN (0,1))
                        ) WITHOUT ROWID;
                        COMMIT;
                        """)
                } catch { try? execute("ROLLBACK"); throw error }
            }
            // Fail safely on a conflicting table, never replace it.
            try statement("SELECT id,name,started,ended,received,sent,seconds,has_gaps FROM measurement_sessions LIMIT 0") { _ in }
        } catch {
            sqlite3_close(database)
            handle = nil
            throw error
        }
    }

    private static func prepare(_ url: URL) throws -> String {
        guard url.isFileURL else { throw UsageError.database("Kein lokaler Dateipfad") }
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let directory = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw UsageError.database("Unsicherer Statistikordner") }
        defer { close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFDIR, fchmod(directory, 0o700) == 0 else {
            throw UsageError.database("Unsicherer Statistikordner")
        }
        // SQLite may open recovery/WAL files itself. Validate those boundaries too,
        // before opening the database; never follow links or chmod their targets.
        for suffix in ["-journal", "-wal", "-shm"] {
            try prepareFile(url.lastPathComponent + suffix, directory: directory, create: false)
        }
        try prepareFile(url.lastPathComponent, directory: directory, create: true)
        return url.path
    }

    private static func prepareFile(_ name: String, directory: Int32, create: Bool) throws {
        let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (create ? O_CREAT : 0)
        let descriptor = openat(directory, name, flags, 0o600)
        if descriptor < 0, !create, errno == ENOENT { return }
        guard descriptor >= 0 else { throw UsageError.database("Unsichere Statistikdatei") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else { throw UsageError.database("Unsichere Statistikdatei") }
    }

    func state() throws -> UsageDatabaseState? {
        if stateLoaded { return stateCache }
        let result: UsageDatabaseState? = try statement("SELECT first,last,received,sent,seconds FROM recording WHERE id=1") { query in
            let code = sqlite3_step(query)
            if code == SQLITE_DONE { return nil }
            guard code == SQLITE_ROW else { throw failure() }
            let first = sqlite3_column_double(query, 0)
            let last = sqlite3_column_double(query, 1)
            guard first.isFinite, last.isFinite, first <= last else {
                throw UsageError.database("Ungültige Messzeiten in der Statistikdatei")
            }
            return UsageDatabaseState(first: Date(timeIntervalSince1970: first),
                last: Date(timeIntervalSince1970: last), totals: try readTotals(query, start: 2))
        }
        stateCache = result
        stateLoaded = true
        return result
    }

    /// Calendar boundaries are minute-aligned. Sum full UTC hours from rollups,
    /// and only the partial leading/trailing hours from minute rows. This also
    /// handles time zones such as Kathmandu with a 45-minute offset.
    func totals(in interval: DateInterval) throws -> UsageTotals {
        if let cached = totalsCache[interval] { return cached }
        let start = Int64(interval.start.timeIntervalSince1970.rounded())
        let end = Int64(interval.end.timeIntervalSince1970.rounded())
        guard start % 60 == 0, end % 60 == 0, end >= start else { throw UsageError.invalidPeriod }
        let firstHour = Int64((Double(start) / 3_600).rounded(.up)) * 3_600
        let lastHour = Int64((Double(end) / 3_600).rounded(.down)) * 3_600
        let result: UsageTotals
        if firstHour >= lastHour {
            result = try sum(table: "minute_usage", start: start, end: end)
        } else {
            result = try sum(table: "hour_usage", start: firstHour, end: lastHour)
                .adding(sum(table: "minute_usage", start: start, end: firstHour))
                .adding(sum(table: "minute_usage", start: lastHour, end: end))
        }
        totalsCache[interval] = result
        return result
    }

    func commit(minutes: [Int64: UsageTotals], totals: UsageTotals, first: Date, last: Date) throws {
        var hours: [Int64: UsageTotals] = [:]
        for (minute, usage) in minutes {
            let hour = Int64((Double(minute) / 3_600).rounded(.down)) * 3_600
            hours[hour] = try (hours[hour] ?? .zero).adding(usage)
        }
        try execute("BEGIN IMMEDIATE")
        do {
            for (key, usage) in minutes { try upsert(table: "minute_usage", key: key, totals: usage) }
            for (key, usage) in hours { try upsert(table: "hour_usage", key: key, totals: usage) }
            try statement("""
                INSERT INTO recording(id,first,last,received,sent,seconds) VALUES(1,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET first=MIN(first,excluded.first),last=MAX(last,excluded.last),
                    received=received+excluded.received,sent=sent+excluded.sent,seconds=seconds+excluded.seconds
                """) { query in
                sqlite3_bind_double(query, 1, first.timeIntervalSince1970)
                sqlite3_bind_double(query, 2, last.timeIntervalSince1970)
                try bind(totals, to: query, start: 3)
                guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
            }
            try execute("COMMIT")
            totalsCache.removeAll(keepingCapacity: true)
            stateLoaded = false
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Private online backup, verified before any migration or destructive change.
    func backup(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw UsageError.database("Sicherung konnte nicht angelegt werden.") }
        close(fd)
        var backupDB: OpaquePointer?
        var backupComplete = false
        defer {
            if let backupDB { sqlite3_close(backupDB) }
            if !backupComplete { try? FileManager.default.removeItem(at: url) }
        }
        guard sqlite3_open_v2(url.path, &backupDB, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let target = backupDB, let source = handle,
              let copy = sqlite3_backup_init(target, "main", source, "main") else {
            throw UsageError.database("Sicherung konnte nicht gestartet werden.")
        }
        let step = sqlite3_backup_step(copy, -1)
        let finish = sqlite3_backup_finish(copy)
        guard step == SQLITE_DONE, finish == SQLITE_OK else { throw UsageError.database("Sicherung ist fehlgeschlagen.") }
        var check: OpaquePointer?
        guard sqlite3_prepare_v2(target, "PRAGMA integrity_check", -1, &check, nil) == SQLITE_OK, let check else {
            throw UsageError.database("Sicherung konnte nicht geprüft werden.")
        }
        let valid = sqlite3_step(check) == SQLITE_ROW && String(cString: sqlite3_column_text(check, 0)) == "ok"
        sqlite3_finalize(check)
        guard valid else { throw UsageError.database("Sicherung ist nicht konsistent.") }
        guard sqlite3_close(target) == SQLITE_OK else { throw UsageError.database("Sicherung konnte nicht abgeschlossen werden.") }
        backupDB = nil
        backupComplete = true
    }

    /// Retain the verified backup even if the following transaction fails.
    func backupAndReset(to url: URL) throws {
        try backup(to: url)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM minute_usage; DELETE FROM hour_usage; DELETE FROM recording;")
            try execute("COMMIT")
            totalsCache.removeAll(keepingCapacity: true); stateCache = nil; stateLoaded = false
        } catch { try? execute("ROLLBACK"); throw error }
    }

    func saveMeasurement(_ value: SavedMeasurement) throws {
        try statement("""
            INSERT INTO measurement_sessions(id,name,started,ended,received,sent,seconds,has_gaps)
            VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id) DO NOTHING
            """) { query in
            try bindText(value.id.uuidString, to: query, at: 1)
            try bindText(value.name, to: query, at: 2)
            sqlite3_bind_double(query, 3, value.startedAt.timeIntervalSince1970)
            sqlite3_bind_double(query, 4, value.endedAt.timeIntervalSince1970)
            try bind(UsageTotals(received: value.received, sent: value.sent, observedSeconds: value.observedSeconds), to: query, start: 5)
            sqlite3_bind_int(query, 8, value.hasGaps ? 1 : 0)
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    func savedMeasurements() throws -> [SavedMeasurement] {
        try statement("SELECT id,name,started,ended,received,sent,seconds,has_gaps FROM measurement_sessions ORDER BY started DESC,id") { query in
            var results: [SavedMeasurement] = []
            while true {
                let code = sqlite3_step(query)
                if code == SQLITE_DONE { return results }
                guard code == SQLITE_ROW, let idText = sqlite3_column_text(query, 0),
                      let id = UUID(uuidString: String(cString: idText)), let name = sqlite3_column_text(query, 1),
                      [0, 1].contains(sqlite3_column_int(query, 7)) else { throw failure() }
                let totals = try readTotals(query, start: 4)
                results.append(try SavedMeasurement(id: id, name: String(cString: name),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 2)),
                    endedAt: Date(timeIntervalSince1970: sqlite3_column_double(query, 3)),
                    received: totals.received, sent: totals.sent, observedSeconds: totals.observedSeconds,
                    hasGaps: sqlite3_column_int(query, 7) != 0))
            }
        }
    }

    func deleteMeasurement(id: UUID) throws {
        try statement("DELETE FROM measurement_sessions WHERE id=?") { query in
            try bindText(id.uuidString, to: query, at: 1)
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    private func bindText(_ value: String, to query: OpaquePointer, at index: Int32) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(query, index, value, -1, transient) == SQLITE_OK else { throw failure() }
    }

    private func upsert(table: String, key: Int64, totals: UsageTotals) throws {
        try statement("""
            INSERT INTO \(table)(tick,received,sent,seconds) VALUES(?,?,?,?)
            ON CONFLICT(tick) DO UPDATE SET received=received+excluded.received,
                sent=sent+excluded.sent,seconds=seconds+excluded.seconds
            """) { query in
            sqlite3_bind_int64(query, 1, key)
            try bind(totals, to: query, start: 2)
            guard sqlite3_step(query) == SQLITE_DONE else { throw failure() }
        }
    }

    private func bind(_ totals: UsageTotals, to query: OpaquePointer, start: Int32) throws {
        guard totals.received <= Int64.max, totals.sent <= Int64.max else { throw UsageError.overflow }
        guard sqlite3_bind_int64(query, start, Int64(totals.received)) == SQLITE_OK,
              sqlite3_bind_int64(query, start + 1, Int64(totals.sent)) == SQLITE_OK,
              sqlite3_bind_double(query, start + 2, totals.observedSeconds) == SQLITE_OK else { throw failure() }
    }

    private func sum(table: String, start: Int64, end: Int64) throws -> UsageTotals {
        try statement("SELECT COALESCE(SUM(received),0),COALESCE(SUM(sent),0),COALESCE(SUM(seconds),0) FROM \(table) WHERE tick>=? AND tick<?") { query in
            sqlite3_bind_int64(query, 1, start)
            sqlite3_bind_int64(query, 2, end)
            guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
            return try readTotals(query, start: 0)
        }
    }

    private func readTotals(_ query: OpaquePointer, start: Int32) throws -> UsageTotals {
        let received = sqlite3_column_int64(query, start)
        let sent = sqlite3_column_int64(query, start + 1)
        let seconds = sqlite3_column_double(query, start + 2)
        guard sqlite3_column_type(query, start) == SQLITE_INTEGER,
              sqlite3_column_type(query, start + 1) == SQLITE_INTEGER,
              received >= 0, sent >= 0, seconds.isFinite, seconds >= 0 else {
            throw UsageError.database("Ungültige Byte-Summen in der Statistikdatei")
        }
        return UsageTotals(received: UInt64(received), sent: UInt64(sent), observedSeconds: seconds)
    }

    private func integer(_ sql: String) throws -> Int64 {
        try statement(sql) { query in
            guard sqlite3_step(query) == SQLITE_ROW else { throw failure() }
            return sqlite3_column_int64(query, 0)
        }
    }

    private func statement<T>(_ sql: String, body: (OpaquePointer) throws -> T) throws -> T {
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query else {
            if let query { sqlite3_finalize(query) }
            throw failure()
        }
        defer { sqlite3_finalize(query) }
        return try body(query)
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func failure() -> UsageError {
        .database(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Datenbank nicht geöffnet")
    }

    deinit { if let handle { sqlite3_close(handle) } }
}
