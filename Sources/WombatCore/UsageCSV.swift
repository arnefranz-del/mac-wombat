import Darwin
import Foundation
import SQLite3

/// Export a consistent view of the existing database through a read-only connection.
/// Missing minutes are emitted as ranges with empty byte fields, never as zero.
public enum UsageCSV {
    public static func export(source: URL, destination: URL) throws {
        try checkDestination(destination, against: source)
        var db: OpaquePointer?
        guard sqlite3_open_v2(source.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw UsageError.database("Statistikdatei konnte nicht lesend geöffnet werden.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1500)
        guard sqlite3_exec(db, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw UsageError.database("Lesetransaktion konnte nicht gestartet werden.")
        }
        defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
        var version: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK, let version else {
            throw UsageError.database("Statistikformat konnte nicht gelesen werden.")
        }
        let validVersion = sqlite3_step(version) == SQLITE_ROW && sqlite3_column_int(version, 0) == 1
        sqlite3_finalize(version)
        guard validVersion else { throw UsageError.unsupportedSchema }
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT tick,received,sent,seconds FROM minute_usage ORDER BY tick", -1, &query, nil) == SQLITE_OK, let query else {
            throw UsageError.database("Statistikzeilen konnten nicht gelesen werden.")
        }
        defer { sqlite3_finalize(query) }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".wombat-export-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw UsageError.database("Exportdatei konnte nicht angelegt werden.")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        func write(_ string: String) throws { try file.write(contentsOf: Data(string.utf8)) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func stamp(_ tick: Int64) -> String { formatter.string(from: Date(timeIntervalSince1970: TimeInterval(tick))) }
        try write("start_utc,end_utc,download_bytes,upload_bytes,erfasste_sekunden,status\n")
        var next: Int64?
        var code = sqlite3_step(query)
        while code == SQLITE_ROW {
            let tick = sqlite3_column_int64(query, 0)
            let received = sqlite3_column_int64(query, 1)
            let sent = sqlite3_column_int64(query, 2)
            let seconds = sqlite3_column_double(query, 3)
            guard tick % 60 == 0, tick <= Int64.max - 60, received >= 0, sent >= 0,
                  seconds.isFinite, seconds >= 0,
                  next.map({ tick >= $0 }) ?? true else { throw UsageError.database("Ungültige Minutenzeile im Export.") }
            if let next, tick > next { try write("\(stamp(next)),\(stamp(tick)),,,,nicht_erfasst\n") }
            let status = seconds > 60.01 || (seconds == 0 && (received > 0 || sent > 0)) ? "unklar" : (seconds >= 59.99 ? "erfasst" : "teilweise")
            let duration = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
            try write("\(stamp(tick)),\(stamp(tick + 60)),\(received),\(sent),\(duration),\(status)\n")
            next = tick + 60
            code = sqlite3_step(query)
        }
        guard code == SQLITE_DONE else { throw UsageError.database("Statistikexport wurde beim Lesen unterbrochen.") }
        try file.synchronize()
        try file.close()
        try checkDestination(destination, against: source)
        guard rename(temporary.path, destination.path) == 0 else { throw UsageError.database("Exportdatei konnte nicht gespeichert werden.") }
    }

    private static func checkDestination(_ destination: URL, against source: URL) throws {
        guard source.isFileURL, destination.isFileURL else { throw UsageError.database("Kein lokaler Dateipfad") }
        let targetDirectory = destination.deletingLastPathComponent()
        // SQLite may create companion files after the destination was chosen.
        // Reserve those names even if the files do not exist yet.
        for base in [source, source.resolvingSymlinksInPath()] {
            let directory = base.deletingLastPathComponent()
            let inDatabaseDirectory = sameFile(targetDirectory, directory)
            for suffix in ["", "-journal", "-wal", "-shm"] {
                let name = base.lastPathComponent + suffix
                let protected = directory.appendingPathComponent(name)
                if destination.path == protected.path || sameFile(destination, protected)
                    || (inDatabaseDirectory && destination.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame) {
                    throw UsageError.database("Die Statistikdatei und ihre SQLite-Nebendateien dürfen nicht überschrieben werden.")
                }
            }
        }
    }

    private static func sameFile(_ first: URL, _ second: URL) -> Bool {
        var firstInfo = stat(), secondInfo = stat()
        return stat(first.path, &firstInfo) == 0 && stat(second.path, &secondInfo) == 0
            && firstInfo.st_dev == secondInfo.st_dev && firstInfo.st_ino == secondInfo.st_ino
    }
}
