import Foundation

public struct ProcessTrafficCounter: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let received: UInt64
    public let sent: UInt64

    public init(pid: Int32, name: String, received: UInt64, sent: UInt64) {
        self.pid = pid; self.name = name; self.received = received; self.sent = sent
    }
}

public struct TrafficIdentity: Equatable, Sendable {
    public enum Kind: String, Sendable { case app, shared, process }
    public let id: String
    public let name: String
    public let kind: Kind
    public let bundlePath: String?

    /// Some macOS daemons live in an .app inside a private framework; they are
    /// services for display/filtering, while Finder and normal system apps are apps.
    public var isBackgroundService: Bool {
        if kind == .process { return true }
        guard kind == .app, let path = bundlePath else { return false }
        return path.hasPrefix("/System/Library/PrivateFrameworks/")
            || path.hasPrefix("/System/Library/Frameworks/")
    }

    public init(id: String, name: String, kind: Kind, bundlePath: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.bundlePath = bundlePath
    }
}

public struct AppTrafficRow: Identifiable, Equatable, Sendable {
    public var id: String { identity.id }
    public let identity: TrafficIdentity
    public let received: UInt64
    public let sent: UInt64
    public let processes: [String]
    public let hasCounters: Bool
    public var total: UInt64 { received + sent }
}

public struct AppTrafficSnapshot: Sendable {
    public let date: Date
    public let rows: [AppTrafficRow]
    public let processCount: Int
    public let querySeconds: TimeInterval
    public let skippedRows: Int

    public init(date: Date = Date(), rows: [AppTrafficRow], processCount: Int, querySeconds: TimeInterval, skippedRows: Int = 0) {
        self.date = date; self.rows = rows; self.processCount = processCount; self.querySeconds = querySeconds
        self.skippedRows = skippedRows
    }

    /// Running apps without a reported external socket are unknown, not zero.
    public func includingUnreportedApps(_ apps: [TrafficIdentity]) -> AppTrafficSnapshot {
        var seen = Set(rows.map(\.id))
        let missing = apps.filter { seen.insert($0.id).inserted }.map {
            AppTrafficRow(identity: $0, received: 0, sent: 0, processes: [], hasCounters: false)
        }.sorted { $0.identity.name.localizedStandardCompare($1.identity.name) == .orderedAscending }
        return AppTrafficSnapshot(date: date, rows: rows + missing, processCount: processCount, querySeconds: querySeconds,
                                  skippedRows: skippedRows)
    }
}

public enum AppTrafficError: LocalizedError, Equatable {
    case malformedOutput, duplicateProcess, counterOverflow
    case timeout, cpuBudget, outputLimit, cancelled, alreadyRunning, commandFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .malformedOutput: "macOS lieferte kein lesbares Prozesszähler-Format."
        case .duplicateProcess: "Die Prozessabfrage enthielt einen doppelten Eintrag."
        case .counterOverflow: "Die Prozesszähler überschreiten den unterstützten Zahlenbereich."
        case .timeout: "Die Prozessabfrage dauerte zu lange und wurde beendet."
        case .cpuBudget: "Die Prozessabfrage benötigte zu viel CPU und wurde beendet."
        case .outputLimit: "Die Prozessabfrage lieferte zu viele Daten und wurde beendet."
        case .cancelled: "Die Prozessabfrage wurde abgebrochen."
        case .alreadyRunning: "Eine Prozessabfrage läuft bereits."
        case .commandFailed(let status): "Die macOS-Prozessabfrage ist fehlgeschlagen (\(status))."
        }
    }
}

/// A single snapshot, not lifetime consumption or deltas between snapshots.
/// Counters may shrink as sockets disappear. Never add snapshots to the ledger.
public enum AppTrafficGrouper {
    public static func group(_ counters: [ProcessTrafficCounter], identities: [Int32: TrafficIdentity]) throws -> [AppTrafficRow] {
        var groups: [String: AppTrafficRow] = [:]
        var seen = Set<Int32>()
        for counter in counters {
            guard seen.insert(counter.pid).inserted else { throw AppTrafficError.duplicateProcess }
            let identity = identities[counter.pid] ?? TrafficIdentity(id: "process:\(counter.name)", name: counter.name, kind: .process)
            let old = groups[identity.id]
            let received = (old?.received ?? 0).addingReportingOverflow(counter.received)
            let sent = (old?.sent ?? 0).addingReportingOverflow(counter.sent)
            guard !received.overflow, !sent.overflow, !received.partialValue.addingReportingOverflow(sent.partialValue).overflow else {
                throw AppTrafficError.counterOverflow
            }
            groups[identity.id] = AppTrafficRow(identity: identity, received: received.partialValue, sent: sent.partialValue,
                processes: (old?.processes ?? []) + ["\(counter.name) (\(counter.pid))"], hasCounters: true)
        }
        return groups.values.sorted { $0.total == $1.total ? $0.id < $1.id : $0.total > $1.total }
    }
}

public enum AppBundleLocator {
    /// Nested Chromium helpers belong to the outer app, not their helper bundle.
    public static func outerApp(in executablePath: String) -> URL? {
        let url = URL(fileURLWithPath: executablePath).standardizedFileURL
        let components = url.pathComponents
        guard let end = components.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: Array(components[...end])), isDirectory: true)
    }

    public static func isSharedWebKit(name: String, path: String?) -> Bool {
        name.hasPrefix("com.apple.WebKit.") || path?.contains("/com.apple.WebKit.Networking.xpc/") == true
    }
}
