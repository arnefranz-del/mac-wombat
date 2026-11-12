import AppKit
import Charts
import SwiftUI
import WombatCore

enum Palette {
    static let download = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.33, green: 0.85, blue: 0.53, alpha: 1)
            : NSColor(red: 0.08, green: 0.45, blue: 0.23, alpha: 1)
    })
    static let upload = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.00, green: 0.47, blue: 0.44, alpha: 1)
            : NSColor(red: 0.76, green: 0.17, blue: 0.17, alpha: 1)
    })
}

struct PopoverView: View {
    @ObservedObject var monitor: NetworkMonitor
    @State private var hoveredBucketID: Date?
    @State private var inspectedBucketID: Date?
    @State private var showCoverageDetails = false
    private var stats: UsageSnapshot? { monitor.statistics }
    private var period: UsagePeriod { monitor.selection.period }
    private var hasData: Bool { stats?.totals.hasObservations == true }
    private var amount: FormattedRate { UsageFormatter.bytes(stats?.totals.bytes ?? 0) }
    private var peak: UInt64 { stats?.buckets.map { max($0.totals.received, $0.totals.sent) }.max() ?? 0 }
    private var hoveredBucket: UsageBucket? { stats?.buckets.first { $0.id == hoveredBucketID } }
    private var inspectedBucket: UsageBucket? { stats?.buckets.first { $0.id == inspectedBucketID } }

    var body: some View {
        statisticsBody
            .onChange(of: monitor.selection) { _, _ in hoveredBucketID = nil; inspectedBucketID = nil; showCoverageDetails = false }
    }

    private var statisticsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            UsagePeriodPicker(selection: Binding(get: { period }, set: { monitor.selectPeriod($0) }))
            .padding(.bottom, 12)

            periodNavigation.padding(.bottom, 9)
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 11)).accessibilityHidden(true)
                Text("DATENVERBRAUCH").font(.system(size: 9, weight: .semibold)).tracking(1.1)
            }.foregroundStyle(.secondary).padding(.bottom, 3)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(hasData ? amount.value : "—")
                    .font(.system(size: 43, weight: .medium, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(hasData ? amount.unit : "")
                    .font(.system(size: 19, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hasData ? "Verbrauch gesamt: \(amount.text)" : "Noch kein Verbrauch aufgezeichnet")
            .padding(.bottom, 10)

            HStack(spacing: 0) {
                consumptionColumn("Download", symbol: "arrow.down", bytes: stats?.totals.received ?? 0, color: Palette.download)
                consumptionColumn("Upload", symbol: "arrow.up", bytes: stats?.totals.sent ?? 0, color: Palette.upload)
            }.padding(.bottom, 14)

            HStack {
                Text("Verlauf").font(.system(size: 11, weight: .medium))
                Spacer()
            }.padding(.bottom, 6)
            consumptionChart.frame(height: 106)
            ZStack(alignment: .leading) {
                Color.clear
                if let hoveredBucket { bucketDetail(hoveredBucket) }
            }
            .frame(height: 38, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chart-detail-below")
            Group {
                if coverageWarning != nil {
                    Button { showCoverageDetails.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .accessibilityLabel("Informationen zur Aufzeichnung")
                    .popover(isPresented: $showCoverageDetails, arrowEdge: .bottom) {
                        Text(coverageHelp).font(.system(size: 11)).frame(width: 260, alignment: .leading).padding(12)
                    }
                }
            }.frame(height: 16, alignment: .leading)

            Divider().padding(.top, 7).padding(.bottom, 10)
            MeasurementStrip(measurement: monitor.presentedMeasurement,
                name: $monitor.measurementName, busy: monitor.measurementBusy,
                savedCount: monitor.savedMeasurements.count, onShowSaved: { monitor.showingSavedMeasurements.toggle() },
                onStart: { monitor.startMeasurement(duration: $0) },
                onStop: { monitor.stopMeasurement() },
                onSave: { monitor.saveMeasurement() },
                onDismiss: { monitor.dismissMeasurementResult() })
                .popover(isPresented: $monitor.showingSavedMeasurements, arrowEdge: .bottom) {
                    SavedMeasurementsView(monitor: monitor)
                }
            if let issue = monitor.measurementIssue {
                Text(issue).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).help(issue)
                    .padding(.top, 4)
            }
            if let error = monitor.errorMessage {
                Text("Netzwerkstatus nicht verfügbar").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(error).padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var periodNavigation: some View {
        HStack {
            Text(periodTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Spacer()
            if period != .allTime {
                HStack(spacing: 10) {
                    Button { monitor.movePeriod(by: -1) } label: {
                        Image(systemName: "chevron.left").frame(width: 15, height: 18)
                    }.disabled(stats?.canGoBack == false).help("Vorheriger Zeitraum – auch ohne Aufzeichnung")
                    Button { monitor.movePeriod(by: 1) } label: {
                        Image(systemName: "chevron.right").frame(width: 15, height: 18)
                    }.disabled(monitor.selection.offset == 0).help(monitor.selection.offset == 0 ? "Du bist im aktuellen Zeitraum" : "Nächster Zeitraum")
                }
                .buttonStyle(.plain).font(.system(size: 10, weight: .semibold))
            }
        }.frame(height: 20)
    }

    private func consumptionColumn(_ title: String, symbol: String, bytes: UInt64, color: Color) -> some View {
        let formatted = UsageFormatter.bytes(bytes)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12)).accessibilityHidden(true)
                Text(title)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(hasData ? formatted.value : "—").font(.system(size: 19, weight: .medium).monospacedDigit())
                Text(hasData ? formatted.unit : "").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }


    private var consumptionChart: some View {
        Chart {
            RuleMark(y: .value("Null", 0)).foregroundStyle(Color.primary.opacity(0.10))
            ForEach(stats?.buckets ?? []) { bucket in
                if bucket.totals.hasObservations {
                    let spans = UsageBarSpans(interval: bucket.interval,
                        chartDuration: chartDomain.upperBound.timeIntervalSince(chartDomain.lowerBound))
                    RectangleMark(xStart: .value("Beginn", spans.download.start),
                        xEnd: .value("Ende", spans.download.end),
                        yStart: .value("Von", 0.0), yEnd: .value("Bytes", Double(bucket.totals.received)))
                        .foregroundStyle(by: .value("Richtung", "Download")).cornerRadius(2)
                        .accessibilityLabel("Download \(bucketTitle(bucket))")
                        .accessibilityValue(UsageFormatter.bytes(bucket.totals.received).text)
                    RectangleMark(xStart: .value("Beginn", spans.upload.start),
                        xEnd: .value("Ende", spans.upload.end),
                        yStart: .value("Von", 0.0), yEnd: .value("Bytes", Double(bucket.totals.sent)))
                        .foregroundStyle(by: .value("Richtung", "Upload")).cornerRadius(2)
                        .accessibilityLabel("Upload \(bucketTitle(bucket))")
                        .accessibilityValue(UsageFormatter.bytes(bucket.totals.sent).text)
                }
            }
        }
        .chartForegroundStyleScale(["Download": Palette.download, "Upload": Palette.upload])
        .chartXScale(domain: chartDomain)
        .chartYScale(domain: 0...max(1_000, Double(peak) * 1.15))
        .chartYAxis(.hidden).chartLegend(.hidden)
        .chartXAxis {
            if period == .allTime {
                AxisMarks(values: allTimeTickDates) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(axisLabel(date)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(axisLabel(date)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            guard let plot = proxy.plotFrame else { hoveredBucketID = nil; return }
                            inspect(point, proxy: proxy, frame: geometry[plot])
                        case .ended: hoveredBucketID = nil
                        }
                    }
                    .gesture(SpatialTapGesture().onEnded { value in
                        guard let plot = proxy.plotFrame else { return }
                        inspect(value.location, proxy: proxy, frame: geometry[plot])
                    })
            }
        }
        .overlay {
            if !hasData && hoveredBucket == nil {
                VStack(spacing: 5) {
                    Text(stats == nil ? "Statistik wird geladen" : "Keine Aufzeichnung")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.bottom, 16)
                .allowsHitTesting(false)
            } else if hasData && stats?.totals.bytes == 0 {
                Text("Im erfassten Anteil kein Datenverkehr").font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.bottom, 16)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Aufgezeichneter Datenverbrauch. Download grün, Upload korallenrot. \(coverageCaption)")
    }

    private var chartDomain: ClosedRange<Date> {
        let interval = stats?.chartInterval ?? DateInterval(start: Calendar.current.startOfDay(for: Date()), duration: 86_400)
        return interval.start...interval.end
    }

    private var allTimeTickDates: [Date] {
        let buckets = stats?.buckets ?? []
        return UsageAxisTicks.indices(count: buckets.count).map { buckets[$0].midpoint }
    }

    private var periodTitle: String {
        guard let stats else { return period == .allTime ? "Seit Messbeginn" : period.label }
        if period == .allTime { return "Seit Messbeginn" }
        let start = stats.interval.start
        switch period {
        case .hour: return start.formatted(.dateTime.hour().minute()) + " – " + stats.interval.end.formatted(.dateTime.hour().minute())
        case .day:
            if monitor.selection.offset == 0 { return "Heute" }
            if monitor.selection.offset == -1 { return "Gestern" }
            return start.formatted(.dateTime.day().month(.wide).year())
        case .week:
            if monitor.selection.offset == 0 { return "Diese Woche" }
            return start.formatted(.dateTime.day().month()) + " – " + stats.interval.end.addingTimeInterval(-1).formatted(.dateTime.day().month().year())
        case .month: return start.formatted(.dateTime.month(.wide).year())
        case .year: return start.formatted(.dateTime.year())
        case .allTime: return "Seit Messbeginn"
        }
    }

    private func axisLabel(_ date: Date) -> String {
        switch period {
        case .hour, .day: return date.formatted(.dateTime.hour().minute())
        case .week: return date.formatted(.dateTime.weekday(.abbreviated))
        case .month: return date.formatted(.dateTime.day())
        case .year: return date.formatted(.dateTime.month(.abbreviated))
        case .allTime:
            if stats?.bucketScale == .day { return date.formatted(.dateTime.day().month()) }
            if stats?.bucketScale == .month { return date.formatted(.dateTime.month(.abbreviated).year()) }
            return date.formatted(.dateTime.year())
        }
    }

    private var coverageCaption: String {
        guard let stats else { return "Statistik wird geladen" }
        return stats.coverage.label
    }

    private var coverageHelp: String {
        let start = stats?.recordingSince.map { "Messbeginn: " + $0.formatted(.dateTime.day().month().year().hour().minute()) + ". " } ?? ""
        let selected = inspectedBucket.map { "Ausgewählter Zeitraum: " + bucketCoverage($0).label + ". " } ?? ""
        return selected + coverageCaption + ". " + start + "Nur gültige Messzeit ist erfasst. Fehlende Zeit bleibt unbekannt und wird nicht als null Verbrauch gewertet. Die Summe enthält nur aufgezeichnete Bytes."
    }

    private func bucketCoverage(_ bucket: UsageBucket) -> UsageCoverage {
        UsageCoverage(interval: bucket.interval, observedSeconds: bucket.totals.observedSeconds,
                      asOf: stats?.capturedAt ?? Date())
    }

    private var coverageWarning: String? {
        inspectedBucket.flatMap { bucketCoverage($0).compactWarning } ?? stats?.coverage.compactWarning
    }

    private func bucketDetail(_ bucket: UsageBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bucketTitle(bucket)).font(.system(size: 10, weight: .semibold)).lineLimit(1)
            HStack(spacing: 14) {
                Text("↓ \(bucket.totals.hasObservations ? UsageFormatter.bytes(bucket.totals.received).text : "—")").foregroundStyle(Palette.download)
                Text("↑ \(bucket.totals.hasObservations ? UsageFormatter.bytes(bucket.totals.sent).text : "—")").foregroundStyle(Palette.upload)
            }.font(.system(size: 10).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
        }
        .padding(.top, 4)
    }

    private func inspect(_ point: CGPoint, proxy: ChartProxy, frame: CGRect) {
        guard frame.contains(point), let date: Date = proxy.value(atX: point.x - frame.minX) else {
            hoveredBucketID = nil
            return
        }
        let id = stats?.bucket(containing: date)?.id
        inspectedBucketID = id
        if hoveredBucketID != id { hoveredBucketID = id }
    }

    private func bucketTitle(_ bucket: UsageBucket) -> String {
        switch stats?.bucketScale {
        case .fiveMinutes, .hour:
            return bucket.interval.start.formatted(.dateTime.hour().minute()) + " – "
                + bucket.interval.end.formatted(.dateTime.hour().minute())
        case .month: return bucket.interval.start.formatted(.dateTime.month(.wide).year())
        case .year: return bucket.interval.start.formatted(.dateTime.year())
        default: return bucket.interval.start.formatted(.dateTime.weekday(.abbreviated).day().month().year())
        }
    }
}

/// Presentation only; measurement accounting remains on the existing sampler queue.
struct MeasurementStrip: View {
    let measurement: MeasurementSession?
    @Binding var name: String
    var busy = false
    var savedCount = 0
    var onShowSaved: () -> Void = {}
    var onStart: (TimeInterval?) -> Void
    var onStop: () -> Void
    var onSave: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let measurement {
                HStack(spacing: 6) {
                    Label(measurement.isRunning ? "Messung läuft" : "Messung beendet", systemImage: "timer")
                        .font(.system(size: 10, weight: .medium))
                    if measurement.hasGaps {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help("Messlücken: Ergebnis unvollständig")
                            .accessibilityLabel("Messlücken: Ergebnis unvollständig")
                    }
                    Spacer(minLength: 4)
                    if measurement.isRunning {
                        Text(Self.clockText(measurement, now: Date()))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        Button("Stoppen", action: onStop).controlSize(.small)
                            .accessibilityIdentifier("measurement-stop")
                    }
                }
                HStack(spacing: 12) {
                    Text("↓ " + value(measurement.received)).foregroundStyle(Palette.download)
                    Text("↑ " + value(measurement.sent)).foregroundStyle(Palette.upload)
                    if !measurement.isRunning {
                        Text("Gesamt " + value(measurement.received + measurement.sent))
                            .foregroundStyle(.secondary)
                    }
                }.font(.system(size: 10).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.75)
                if !measurement.isRunning {
                    HStack(spacing: 6) {
                        TextField("Name (optional)", text: $name)
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                            .accessibilityLabel("Name der Messung, optional")
                            .accessibilityIdentifier("measurement-name")
                            .help("Ohne Namen wird Datum und Uhrzeit verwendet.")
                        Button("Speichern", action: onSave).controlSize(.small)
                            .accessibilityIdentifier("measurement-save")
                        Button("Verwerfen", action: onDismiss).controlSize(.small)
                            .accessibilityIdentifier("measurement-discard")
                    }.disabled(busy)
                }
                HStack { Spacer(); savedButton }
            } else {
                HStack {
                    Menu {
                        Button("15 Minuten") { onStart(900) }
                        Button("30 Minuten") { onStart(1800) }
                        Button("60 Minuten") { onStart(3600) }
                        Button("Manuell") { onStart(nil) }
                    } label: { Label("Messung starten", systemImage: "timer") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 10, weight: .medium))
                    .accessibilityIdentifier("measurement-start")
                    .help("Misst aktive WLAN- und Ethernet-Schnittstellen einschließlich lokalem Verkehr. Virtuelle Schnittstellen und Loopback sind ausgeschlossen.")
                    Spacer()
                    savedButton
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var savedButton: some View {
        Button("Gespeichert (\(savedCount))", action: onShowSaved)
            .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary)
            .accessibilityLabel("Gespeicherte Messungen")
            .accessibilityIdentifier("measurement-list")
    }

    private func value(_ bytes: UInt64) -> String {
        (measurement?.observedSeconds ?? 0) > 0 ? UsageFormatter.bytes(bytes).text : "—"
    }

    static func clockText(_ session: MeasurementSession, now: Date) -> String {
        let remaining = session.deadline.map { max(0, $0.timeIntervalSince(now)) }
        let seconds = Int((remaining ?? max(0, now.timeIntervalSince(session.startedAt))).rounded(remaining == nil ? .down : .up))
        let text = seconds >= 3600
            ? String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%02d:%02d", seconds / 60, seconds % 60)
        return text + (remaining == nil ? " vergangen" : " verbleibend")
    }
}
