import Foundation

/// Session-only accumulation of the existing sampler's accepted intervals.
/// Running/unsaved sessions remain temporary; only explicit saves persist a result.
public struct MeasurementSession: Equatable, Sendable {
    public let id = UUID()
    public let startedAt: Date
    public let duration: TimeInterval?
    public private(set) var endedAt: Date?
    public private(set) var received: UInt64 = 0
    public private(set) var sent: UInt64 = 0
    public private(set) var observedSeconds: TimeInterval = 0
    public private(set) var hasGaps = false
    public var isRunning: Bool { endedAt == nil }
    public var deadline: Date? { duration.map { startedAt.addingTimeInterval($0) } }

    public init(startedAt: Date, duration: TimeInterval?) {
        self.startedAt = startedAt
        self.duration = duration
    }

    public mutating func noteGap() { if isRunning { hasGaps = true } }

    /// At a fixed deadline the final complete interval may end just after it;
    /// the actual end is recorded, rather than inventing a fraction of bytes.
    public mutating func ingest(_ reading: NetworkReading, previousEnd: Date?, endingAt end: Date, accepted: Bool) {
        guard isRunning else { return }
        if let deadline, end >= deadline, previousEnd.map({ $0 >= deadline }) ?? true {
            hasGaps = true
            endedAt = deadline
            return
        }
        if accepted, let previousEnd, previousEnd >= startedAt {
            let rx = received.addingReportingOverflow(reading.receivedDelta)
            let tx = sent.addingReportingOverflow(reading.sentDelta)
            let all = rx.partialValue.addingReportingOverflow(tx.partialValue)
            if rx.overflow || tx.overflow || all.overflow {
                hasGaps = true
                endedAt = end
                return
            }
            received = rx.partialValue
            sent = tx.partialValue
            observedSeconds += reading.interval
        } else {
            hasGaps = true
        }
        if let deadline, end >= deadline { endedAt = accepted ? end : deadline }
    }

    public mutating func stop(at date: Date) {
        guard isRunning else { return }
        endedAt = max(startedAt, date)
    }
}
