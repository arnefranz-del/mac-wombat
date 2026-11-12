import Foundation

public enum UsagePeriod: String, CaseIterable, Sendable {
    case hour, day, week, month, year, allTime

    public var label: String {
        switch self {
        case .hour: "Stunde"
        case .day: "Tag"
        case .week: "Woche"
        case .month: "Monat"
        case .year: "Jahr"
        case .allTime: "Gesamt"
        }
    }

    var component: Calendar.Component {
        switch self {
        case .hour: .hour
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        case .year, .allTime: .year
        }
    }

    public func interval(containing date: Date, calendar: Calendar) throws -> DateInterval {
        guard let interval = calendar.dateInterval(of: component, for: date) else { throw UsageError.invalidPeriod }
        return interval
    }
}

public struct UsageSelection: Equatable, Hashable, Sendable {
    public let period: UsagePeriod
    public let offset: Int
    public init(period: UsagePeriod = .day, offset: Int = 0) {
        self.period = period
        self.offset = period == .allTime ? 0 : min(0, max(-100_000, offset))
    }

    public func interval(now: Date, calendar: Calendar) throws -> DateInterval {
        let current = try period.interval(containing: now, calendar: calendar)
        guard let date = calendar.date(byAdding: period.component, value: offset, to: current.start) else {
            throw UsageError.invalidPeriod
        }
        return try period.interval(containing: date, calendar: calendar)
    }

    /// Browsing an unrecorded period is valid. Only future periods and dates
    /// before the supported calendar range are excluded, not missing history.
    public func moving(by delta: Int, now: Date = Date(), calendar: Calendar = .current) throws -> UsageSelection {
        guard period != .allTime else { return self }
        let sum = offset.addingReportingOverflow(delta)
        guard !sum.overflow else { return self }
        let next = UsageSelection(period: period, offset: sum.partialValue)
        let range = try next.interval(now: now, calendar: calendar)
        let floor = try period.interval(containing: Date(timeIntervalSince1970: 0), calendar: calendar)
        return range.start < floor.start ? self : next
    }
}

public enum UsageBucketScale: Sendable {
    case fiveMinutes, hour, day, month, year
}

struct UsagePlan {
    let interval: DateInterval
    let chartInterval: DateInterval
    let bucketIntervals: [DateInterval]
    let canGoBack: Bool
    let bucketScale: UsageBucketScale

    init(selection: UsageSelection, now: Date, first: Date?, last: Date?, calendar: Calendar) throws {
        let period = selection.period
        let bucketComponent: Calendar.Component
        let bucketStep: Int
        if period == .allTime {
            let beginning = min(first ?? now, now)
            let ending = max(last ?? now, now)
            let days = calendar.dateComponents([.day], from: beginning, to: ending).day ?? 0
            bucketComponent = days <= 14 ? .day : days <= 730 ? .month : .year
            bucketStep = 1
            guard let start = calendar.dateInterval(of: bucketComponent, for: beginning)?.start,
                  let end = calendar.dateInterval(of: bucketComponent, for: ending)?.end else {
                throw UsageError.invalidPeriod
            }
            chartInterval = DateInterval(start: start, end: end)
            interval = chartInterval
            canGoBack = false
        } else {
            interval = try selection.interval(now: now, calendar: calendar)
            chartInterval = interval
            let floor = try period.interval(containing: Date(timeIntervalSince1970: 0), calendar: calendar)
            canGoBack = interval.start > floor.start
            bucketComponent = switch period {
            case .hour: .minute
            case .day: .hour
            case .week, .month: .day
            case .year, .allTime: .month
            }
            bucketStep = period == .hour ? 5 : 1
        }
        bucketScale = switch bucketComponent {
        case .minute: .fiveMinutes
        case .hour: .hour
        case .day: .day
        case .month: .month
        default: .year
        }
        var cursor = chartInterval.start
        var buckets: [DateInterval] = []
        while cursor < chartInterval.end {
            guard buckets.count < 10_000,
                  let next = calendar.date(byAdding: bucketComponent, value: bucketStep, to: cursor), next > cursor else {
                throw UsageError.invalidPeriod
            }
            let end = min(chartInterval.end, next)
            buckets.append(DateInterval(start: cursor, end: end))
            cursor = end
        }
        bucketIntervals = buckets
    }
}
