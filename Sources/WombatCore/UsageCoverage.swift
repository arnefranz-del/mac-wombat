import Foundation

/// Duration coverage, not an estimate of unobserved bytes. Minute aggregation
/// cannot locate each sub-minute gap; it can still prove incomplete coverage.
public struct UsageCoverage: Equatable, Sendable {
    public let expectedSeconds: Double
    public let observedSeconds: Double
    public let isFuture: Bool
    public let isOngoing: Bool
    private let hasKnownGaps: Bool
    public var hasObservations: Bool { observedSeconds > 0 }
    public var missingSeconds: Double { max(0, expectedSeconds - observedSeconds) }
    public var isPartial: Bool { hasObservations && (missingSeconds > 0.01 || hasKnownGaps) }
    public var hasInconsistentDuration: Bool { observedSeconds > expectedSeconds + 0.01 }
    public var fraction: Double? {
        expectedSeconds > 0 && !hasInconsistentDuration && !(hasKnownGaps && missingSeconds <= 0.01)
            ? min(1, observedSeconds / expectedSeconds) : nil
    }

    /// A short UI warning without treating missing or contradictory coverage as zero.
    public var compactWarning: String? {
        if hasInconsistentDuration || (hasKnownGaps && missingSeconds <= 0.01) { return "Aufzeichnung unklar" }
        if isFuture && !hasObservations { return nil }
        if !hasObservations { return "Keine Aufzeichnung" }
        return isPartial ? "Messlücken" : nil
    }

    public init(interval: DateInterval, observedSeconds: Double, asOf date: Date, knownGaps: Bool = false) {
        expectedSeconds = max(0, min(date, interval.end).timeIntervalSince(interval.start))
        self.observedSeconds = observedSeconds.isFinite ? max(0, observedSeconds) : 0
        isFuture = date <= interval.start && interval.duration > 0
        isOngoing = date > interval.start && date < interval.end
        hasKnownGaps = knownGaps
    }

    public var label: String {
        if hasInconsistentDuration || (hasKnownGaps && missingSeconds <= 0.01) {
            return "Messlücken · Zeitabdeckung nicht eindeutig zuordenbar"
        }
        if isFuture && !hasObservations { return "Liegt in der Zukunft" }
        if !hasObservations { return "Keine Aufzeichnung" }
        let prefix = isPartial ? "Teilweise aufgezeichnet" : (isOngoing ? "Laufender Zeitraum" : "Vollständig aufgezeichnet")
        return "\(prefix) · \(Self.duration(observedSeconds)) von \(Self.duration(expectedSeconds)) erfasst"
    }

    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 s" }
        if seconds < 1 { return "< 1 s" }
        let rounded = seconds.rounded()
        if rounded < 60 { return "\(Int(rounded)) s" }
        if rounded < 3600 { return "\(Int(rounded / 60)) Min." }
        let hours = Int(rounded / 3600)
        let minutes = Int(rounded.truncatingRemainder(dividingBy: 3600) / 60)
        return "\(hours) Std. \(minutes) Min."
    }
}
