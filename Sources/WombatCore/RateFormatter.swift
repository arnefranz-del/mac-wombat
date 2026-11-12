import Foundation

public struct FormattedRate: Equatable, Sendable {
    public let value: String
    public let unit: String
    public var text: String { "\(value) \(unit)" }
}

public enum RateFormatter {
    /// Decimal units: 1 KB = 1,000 B, matching the requested KB/s and MB/s labels.
    public static func format(_ bytesPerSecond: Double, locale: Locale = .current) -> FormattedRate {
        let rate = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var value = rate
        var unit = 0
        while value >= 1_000 && unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        // Promote on rounded boundaries instead of displaying 1,000 KB/s.
        if unit < units.count - 1 && value.rounded() >= 1_000 {
            value /= 1_000
            unit += 1
        }
        let fraction = unit > 0 && value < 100 ? 1 : 0
        let text = value.formatted(.number.locale(locale)
            .grouping(.never).precision(.fractionLength(fraction)))
        return FormattedRate(value: text, unit: units[unit])
    }
}
