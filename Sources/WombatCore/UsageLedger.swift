import Foundation

/// Exact accepted deltas, never inferred from rounded displayed rates. This
/// object and its database belong to one queue. Invalid samples create gaps.
public final class UsageLedger {
    private let database: UsageDatabase
    private var pending: [Int64: UsageTotals] = [:]
    private var pendingTotals = UsageTotals.zero
    private var pendingFirst: Date?
    private var pendingLast: Date?

    public init(location: UsageStorageLocation = .applicationSupport) throws {
        database = try UsageDatabase(location: location)
    }

    public func record(_ reading: NetworkReading, endingAt date: Date) throws {
        let portions = try UsageIntervalSplitter.split(reading, endingAt: date)
        guard !portions.isEmpty else { return }
        // Stage changes first: neither overflow nor rejected input may half-apply.
        let newTotals = try pendingTotals.adding(UsageTotals(received: reading.receivedDelta,
            sent: reading.sentDelta, observedSeconds: reading.interval))
        var changes: [Int64: UsageTotals] = [:]
        for part in portions {
            changes[part.minute] = try (changes[part.minute] ?? pending[part.minute] ?? .zero).adding(part.totals)
        }
        for (minute, usage) in changes { pending[minute] = usage }
        pendingTotals = newTotals
        let start = date.addingTimeInterval(-reading.interval)
        pendingFirst = min(pendingFirst ?? start, start)
        pendingLast = max(pendingLast ?? date, date)
    }

    public func flush() throws {
        guard let first = pendingFirst, let last = pendingLast else { return }
        try database.commit(minutes: pending, totals: pendingTotals, first: first, last: last)
        pending.removeAll(keepingCapacity: true)
        pendingTotals = .zero
        pendingFirst = nil
        pendingLast = nil
    }

    public func backupAndReset(in directory: URL) throws -> URL {
        try flush()
        let url = directory.appendingPathComponent("usage-reset-\(UUID().uuidString).sqlite")
        try database.backupAndReset(to: url)
        return url
    }

    public func saveMeasurement(_ session: MeasurementSession, name: String) throws {
        try database.saveMeasurement(SavedMeasurement(session: session, name: name))
    }

    public func savedMeasurements() throws -> [SavedMeasurement] { try database.savedMeasurements() }

    public func deleteMeasurement(id: UUID) throws { try database.deleteMeasurement(id: id) }

    public func snapshot(selection: UsageSelection, now: Date = Date(), calendar: Calendar = .current) throws -> UsageSnapshot {
        let saved = try database.state()
        let first = [saved?.first, pendingFirst].compactMap { $0 }.min()
        let last = [saved?.last, pendingLast].compactMap { $0 }.max()
        let plan = try UsagePlan(selection: selection, now: now, first: first, last: last, calendar: calendar)
        let totals = selection.period == .allTime
            ? try (saved?.totals ?? .zero).adding(pendingTotals) : try totals(in: plan.interval)
        let buckets = try plan.bucketIntervals.map { UsageBucket(interval: $0, totals: try self.totals(in: $0)) }
        return UsageSnapshot(capturedAt: now, selection: selection, interval: plan.interval, chartInterval: plan.chartInterval,
            totals: totals, buckets: buckets, recordingSince: first, canGoBack: plan.canGoBack, bucketScale: plan.bucketScale)
    }

    private func totals(in interval: DateInterval) throws -> UsageTotals {
        var result = try database.totals(in: interval)
        for (minute, usage) in pending {
            let date = Date(timeIntervalSince1970: Double(minute))
            if date >= interval.start && date < interval.end { result = try result.adding(usage) }
        }
        return result
    }
}
