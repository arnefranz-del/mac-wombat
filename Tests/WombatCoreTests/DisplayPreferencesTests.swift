import Foundation
import Testing
@testable import WombatCore

struct DisplayPreferencesTests {
    private func row(_ name: String, received: UInt64, sent: UInt64, known: Bool = true) -> AppTrafficRow {
        AppTrafficRow(identity: TrafficIdentity(id: name, name: name, kind: .app),
            received: received, sent: sent, processes: [], hasCounters: known)
    }

    @Test func layoutPersistsAndInvalidOrMissingValuesFallBackToStandard() {
        #expect(MenuBarLayout.stored(nil) == .standard)
        #expect(MenuBarLayout.stored("unknown") == .standard)
        for layout in MenuBarLayout.allCases { #expect(MenuBarLayout.stored(layout.rawValue) == layout) }
    }

    @Test func appearanceFallbackAndTabLabelsAreStable() {
        #expect(AppearancePreference.stored(nil) == .system)
        #expect(AppearancePreference.stored("invalid") == .system)
        for value in AppearancePreference.allCases { #expect(AppearancePreference.stored(value.rawValue) == value) }
        #expect(PopoverTab.allCases.map(\.label) == ["Statistik", "Programme", "Einstellungen"])
    }

    @Test func pairedBarsStayInsideTheBucketAndDoNotOverlap() {
        for duration in [300.0, 3_600, 82_800, 90_000] {
            let bucket = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: duration)
            let bars = UsageBarSpans(interval: bucket, chartDuration: duration * 24)
            #expect(bars.download.start >= bucket.start)
            #expect(bars.download.end < bars.upload.start)
            #expect(bars.upload.end <= bucket.end)
            #expect(abs(bars.download.duration - bars.upload.duration) < 0.00001)
        }
        let single = DateInterval(start: Date(timeIntervalSince1970: 1_700_000_000), duration: 86_400)
        let capped = UsageBarSpans(interval: single, chartDuration: single.duration)
        let widthInPoints = (capped.upload.end.timeIntervalSince(capped.download.start) / single.duration) * 380
        #expect(widthInPoints <= 16.001)
    }

    @Test func totalAxisUsesActualBucketPositionsWithoutDuplicateLabels() {
        #expect(UsageAxisTicks.indices(count: 0).isEmpty)
        #expect(UsageAxisTicks.indices(count: 1) == [0])
        #expect(UsageAxisTicks.indices(count: 2) == [0, 1])
        #expect(UsageAxisTicks.indices(count: 12) == [0, 3, 7, 11])
        #expect(UsageAxisTicks.indices(count: 12, limit: 1) == [0])
    }

    @Test func compactCoverageDistinguishesNoDataGapsAndCompleteData() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let interval = DateInterval(start: start, duration: 100)
        let end = interval.end
        #expect(UsageCoverage(interval: interval, observedSeconds: 0, asOf: end).compactWarning == "Keine Aufzeichnung")
        #expect(UsageCoverage(interval: interval, observedSeconds: 50, asOf: end).compactWarning == "Messlücken")
        #expect(UsageCoverage(interval: interval, observedSeconds: 100, asOf: end).compactWarning == nil)
        #expect(UsageCoverage(interval: interval, observedSeconds: 100, asOf: end, knownGaps: true).compactWarning == "Aufzeichnung unklar")
        #expect(UsageCoverage(interval: interval, observedSeconds: 0, asOf: start).compactWarning == nil)
    }

    @Test func systemDaemonInsideFrameworkIsNotShownAsARegularApp() {
        let service = TrafficIdentity(id: "s", name: "service", kind: .app,
            bundlePath: "/System/Library/PrivateFrameworks/IDS.framework/service.app")
        let finder = TrafficIdentity(id: "f", name: "Finder", kind: .app,
            bundlePath: "/System/Library/CoreServices/Finder.app")
        let shared = TrafficIdentity(id: "w", name: "WebKit", kind: .shared)
        #expect(service.isBackgroundService)
        #expect(!finder.isBackgroundService && !shared.isBackgroundService)
        #expect(TrafficIdentity(id: "p", name: "p", kind: .process).isBackgroundService)
    }

    @Test func sortKeepsUnknownBehindMeasuredZeroInEitherDirection() {
        let rows = [row("Unbekannt", received: 0, sent: 0, known: false),
                    row("Null", received: 0, sent: 10), row("Viel", received: 100, sent: 5)]
        #expect(AppTrafficSort.received.sorted(rows, ascending: true).map(\.id) == ["Null", "Viel", "Unbekannt"])
        #expect(AppTrafficSort.received.sorted(rows, ascending: false).map(\.id) == ["Viel", "Null", "Unbekannt"])
        #expect(AppTrafficSort.sent.sorted(rows, ascending: false).map(\.id) == ["Null", "Viel", "Unbekannt"])
        #expect(AppTrafficSort.name.sorted(rows, ascending: true).map(\.id) == ["Null", "Unbekannt", "Viel"])
        #expect(AppTrafficSort.name.sorted(rows, ascending: false).map(\.id) == ["Viel", "Unbekannt", "Null"])
    }

    @Test func tiesAreDeterministicAndRateUnitTransitionIsUnambiguous() {
        let rows = [row("B", received: 10, sent: 2), row("A", received: 10, sent: 2)]
        #expect(AppTrafficSort.received.sorted(rows, ascending: false).map(\.id) == ["A", "B"])
        let de = Locale(identifier: "de_DE")
        #expect(RateFormatter.format(0, locale: de).text == "0 B/s")
        #expect(RateFormatter.format(999_000, locale: de).text == "999 KB/s")
        #expect(RateFormatter.format(999_600, locale: de).text == "1,0 MB/s")
    }
}
