import Foundation

public enum UsageError: LocalizedError {
    case invalidSample, overflow, invalidPeriod, unsupportedSchema, database(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSample: "Das Messintervall lässt sich keinem Zeitraum zuordnen."
        case .overflow: "Der gespeicherte Verbrauch liegt außerhalb des unterstützten Zahlenbereichs."
        case .invalidPeriod: "Der Zeitraum konnte nicht bestimmt werden."
        case .unsupportedSchema: "Die vorhandene Statistikdatei hat ein unbekanntes Format. Sie wurde nicht ersetzt."
        case .database(let detail): "Die Statistik konnte nicht gespeichert oder gelesen werden: \(detail)"
        }
    }
}

public struct UsageTotals: Equatable, Sendable {
    public let received: UInt64
    public let sent: UInt64
    public let observedSeconds: Double
    public static let zero = UsageTotals()
    public var bytes: UInt64 { received + sent }
    public var hasObservations: Bool { observedSeconds > 0 }

    public init(received: UInt64 = 0, sent: UInt64 = 0, observedSeconds: Double = 0) {
        self.received = received
        self.sent = sent
        self.observedSeconds = observedSeconds
    }

    func adding(_ other: UsageTotals) throws -> UsageTotals {
        let rx = received.addingReportingOverflow(other.received)
        let tx = sent.addingReportingOverflow(other.sent)
        let seconds = observedSeconds + other.observedSeconds
        guard !rx.overflow, !tx.overflow, rx.partialValue <= Int64.max, tx.partialValue <= Int64.max,
              seconds.isFinite, seconds >= 0 else { throw UsageError.overflow }
        return UsageTotals(received: rx.partialValue, sent: tx.partialValue, observedSeconds: seconds)
    }
}

public struct UsagePortion: Sendable {
    public let minute: Int64
    public let totals: UsageTotals
}

public enum UsageIntervalSplitter {
    /// Distribute bytes proportionally across UTC minutes. Cumulative rounding
    /// assigns the final remainder once, preserving every byte across boundaries.
    public static func split(_ reading: NetworkReading, endingAt end: Date) throws -> [UsagePortion] {
        guard reading.state == .measuring else { return [] }
        let finish = end.timeIntervalSince1970
        guard (0.25...3.5).contains(reading.interval), finish.isFinite,
              finish > -62_135_596_000, finish < 253_402_300_000,
              reading.receivedDelta <= Int64.max, reading.sentDelta <= Int64.max else {
            throw UsageError.invalidSample
        }
        let start = finish - reading.interval
        var cursor = start
        var assignedRX: UInt64 = 0
        var assignedTX: UInt64 = 0
        var result: [UsagePortion] = []
        while cursor < finish {
            let minute = Int64((cursor / 60).rounded(.down)) * 60
            let boundary = min(finish, Double(minute + 60))
            let fraction = (boundary - start) / reading.interval
            let rx = boundary == finish ? reading.receivedDelta
                : min(reading.receivedDelta, UInt64((Double(reading.receivedDelta) * fraction).rounded(.down)))
            let tx = boundary == finish ? reading.sentDelta
                : min(reading.sentDelta, UInt64((Double(reading.sentDelta) * fraction).rounded(.down)))
            result.append(UsagePortion(minute: minute, totals: UsageTotals(
                received: rx - assignedRX, sent: tx - assignedTX, observedSeconds: boundary - cursor)))
            assignedRX = rx
            assignedTX = tx
            cursor = boundary
        }
        return result
    }
}

public enum UsageAttribution {
    public static func accepts(_ reading: NetworkReading, endingAt end: Date, previousEnd: Date?) -> Bool {
        guard reading.state == .measuring, (0.25...3.5).contains(reading.interval), let previousEnd else { return false }
        let elapsed = end.timeIntervalSince(previousEnd)
        return elapsed.isFinite && elapsed > 0 && abs(elapsed - reading.interval) <= 2
    }
}

public enum UsageStorageLocation: Sendable {
    case applicationSupport, memory, file(URL)

    public static func applicationURL() throws -> URL {
        let folder = "Wombat"
        return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent(folder, isDirectory: true).appendingPathComponent("usage.sqlite")
    }
}

public struct UsageBucket: Identifiable, Sendable {
    public let interval: DateInterval
    public let totals: UsageTotals
    public var id: Date { interval.start }
    public var midpoint: Date { interval.start.addingTimeInterval(interval.duration / 2) }
}

public struct UsageSnapshot: Sendable {
    public let capturedAt: Date
    public let selection: UsageSelection
    public let interval: DateInterval
    public let chartInterval: DateInterval
    public let totals: UsageTotals
    public let buckets: [UsageBucket]
    public let recordingSince: Date?
    public let canGoBack: Bool
    public let bucketScale: UsageBucketScale
    public var canGoForward: Bool { selection.offset < 0 && selection.period != .allTime }
    public var coverage: UsageCoverage {
        let range = selection.period == .allTime
            ? DateInterval(start: min(recordingSince ?? capturedAt, capturedAt), end: capturedAt) : interval
        let knownGaps = buckets.contains { bucket in
            let start = max(range.start, bucket.interval.start)
            let end = min(capturedAt, min(range.end, bucket.interval.end))
            return end > start && bucket.totals.observedSeconds + 0.01 < end.timeIntervalSince(start)
        }
        return UsageCoverage(interval: range, observedSeconds: totals.observedSeconds, asOf: capturedAt, knownGaps: knownGaps)
    }

    public func bucket(containing date: Date) -> UsageBucket? {
        buckets.first { date >= $0.interval.start && date < $0.interval.end }
    }
}

public enum UsageFormatter {
    public static func bytes(_ bytes: UInt64, locale: Locale = .current) -> FormattedRate {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1_000 && unit < units.count - 1 { value /= 1_000; unit += 1 }
        if unit < units.count - 1 && value.rounded() >= 1_000 { value /= 1_000; unit += 1 }
        let fraction = unit > 0 && value < 100 ? 1 : 0
        return FormattedRate(value: value.formatted(.number.locale(locale).grouping(.never)
            .precision(.fractionLength(fraction))), unit: units[unit])
    }
}
