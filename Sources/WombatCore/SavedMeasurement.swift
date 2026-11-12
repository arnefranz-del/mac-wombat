import Foundation

/// An immutable result, independent of the regular usage rollups.
public struct SavedMeasurement: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let startedAt: Date
    public let endedAt: Date
    public let received: UInt64
    public let sent: UInt64
    public let observedSeconds: TimeInterval
    public let hasGaps: Bool

    public var elapsedSeconds: TimeInterval { endedAt.timeIntervalSince(startedAt) }
    public var missingSeconds: TimeInterval { max(0, elapsedSeconds - observedSeconds) }
    /// Wall-clock changes can make observed time exceed elapsed time. Never claim
    /// complete coverage in that case, or hide a known interruption behind rounding.
    public var coverageIsUnclear: Bool { observedSeconds > elapsedSeconds + 0.01 }

    public init(session: MeasurementSession, name: String, locale: Locale = .current, timeZone: TimeZone = .current) throws {
        guard let end = session.endedAt else { throw UsageError.invalidSample }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = locale; formatter.timeZone = timeZone
        formatter.dateStyle = .medium; formatter.timeStyle = .medium
        try self.init(id: session.id, name: trimmed.isEmpty ? formatter.string(from: session.startedAt) : trimmed,
            startedAt: session.startedAt, endedAt: end, received: session.received, sent: session.sent,
            observedSeconds: session.observedSeconds, hasGaps: session.hasGaps)
    }

    init(id: UUID, name: String, startedAt: Date, endedAt: Date, received: UInt64, sent: UInt64,
         observedSeconds: TimeInterval, hasGaps: Bool) throws {
        guard startedAt.timeIntervalSince1970.isFinite, endedAt.timeIntervalSince1970.isFinite,
              endedAt >= startedAt, observedSeconds.isFinite, observedSeconds >= 0,
              received <= Int64.max, sent <= Int64.max, !name.isEmpty, !name.contains("\0") else {
            throw UsageError.invalidSample
        }
        self.id = id; self.name = name; self.startedAt = startedAt; self.endedAt = endedAt
        self.received = received; self.sent = sent; self.observedSeconds = observedSeconds
        self.hasGaps = hasGaps || observedSeconds + 0.01 < endedAt.timeIntervalSince(startedAt)
            || observedSeconds > endedAt.timeIntervalSince(startedAt) + 0.01
    }
}
