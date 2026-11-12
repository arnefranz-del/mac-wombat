import Foundation

public enum MenuBarLayout: String, CaseIterable, Sendable {
    case compact, standard, large

    public static let defaultsKey = "menuBarLayout"
    public static func stored(_ value: String?) -> MenuBarLayout {
        value.flatMap(MenuBarLayout.init(rawValue:)) ?? .standard
    }

    public var label: String {
        switch self { case .compact: "Kompakt"; case .standard: "Standard"; case .large: "Groß" }
    }
}

public enum PopoverTab: String, CaseIterable, Sendable {
    case statistics, programs, settings

    public var label: String {
        switch self { case .statistics: "Statistik"; case .programs: "Programme"; case .settings: "Einstellungen" }
    }
}

public enum AppearancePreference: String, CaseIterable, Sendable {
    case system, light, dark
    public static let defaultsKey = "appearancePreference"
    public static func stored(_ value: String?) -> AppearancePreference {
        value.flatMap(AppearancePreference.init(rawValue:)) ?? .system
    }
    public var label: String {
        switch self { case .system: "System"; case .light: "Hell"; case .dark: "Dunkel" }
    }
}

/// Two equal, separated marks within a single interval, with a shared scale.
public struct UsageBarSpans: Equatable, Sendable {
    public let download: DateInterval
    public let upload: DateInterval

    public init(interval: DateInterval, chartDuration: TimeInterval, plotWidth: Double = 380) {
        // Cap each pair to 16 points even if the entire chart contains one bucket.
        // The proportional cap keeps the pair inside its own time interval.
        let width = max(1, plotWidth)
        let groupDuration = min(interval.duration * 0.62, max(0, chartDuration) * 16 / width)
        let start = interval.start.addingTimeInterval((interval.duration - groupDuration) / 2)
        download = DateInterval(start: start, end: start.addingTimeInterval(groupDuration * 0.44))
        upload = DateInterval(start: start.addingTimeInterval(groupDuration * 0.56),
                              end: start.addingTimeInterval(groupDuration))
    }
}

public enum UsageAxisTicks {
    /// Select actual bucket positions, rather than inventing sub-bucket dates.
    public static func indices(count: Int, limit: Int = 4) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        if count <= limit { return Array(0..<count) }
        if limit == 1 { return [0] }
        return (0..<limit).map { $0 * (count - 1) / (limit - 1) }
    }
}

public enum AppTrafficSort: String, CaseIterable, Sendable {
    case name, received, sent

    public var label: String {
        switch self { case .name: "Name"; case .received: "Empfangen"; case .sent: "Gesendet" }
    }

    /// Missing counters always follow measured values, including genuine zeroes.
    public func sorted(_ rows: [AppTrafficRow], ascending: Bool) -> [AppTrafficRow] {
        rows.sorted { left, right in
            if self != .name {
                if left.hasCounters != right.hasCounters { return left.hasCounters }
                if left.hasCounters {
                    let a = self == .received ? left.received : left.sent
                    let b = self == .received ? right.received : right.sent
                    if a != b { return ascending ? a < b : a > b }
                }
            }
            let comparison = left.identity.name.localizedStandardCompare(right.identity.name)
            if comparison != .orderedSame { return self == .name && !ascending ? comparison == .orderedDescending : comparison == .orderedAscending }
            return left.id < right.id
        }
    }
}
