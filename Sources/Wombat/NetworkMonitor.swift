import Foundation
import SwiftUI
import WombatCore

@MainActor
final class NetworkMonitor: ObservableObject {
    @Published private(set) var reading = NetworkReading(state: .warmingUp)
    @Published private(set) var interfaces: [InterfaceDescriptor] = []
    @Published private(set) var errorMessage: String?
    var onReading: ((NetworkReading) -> Void)?

    @Published private(set) var selection = UsageSelection()
    @Published private(set) var statistics: UsageSnapshot?
    @Published private(set) var storageIssue: String?
    @Published private(set) var temporaryStatistics = false
    @Published private(set) var measurement: MeasurementSession?
    @Published private var dismissedMeasurementStart: Date?
    @Published private(set) var dataManagementBusy = false
    @Published var dataManagementMessage: String?
    @Published private(set) var savedMeasurements: [SavedMeasurement] = []
    @Published private(set) var measurementBusy = false
    @Published private(set) var measurementIssue: String?
    @Published var measurementName = ""
    @Published var showingSavedMeasurements = false
    private let sampler: NetworkSampler
    private var statisticsVisible = false
    private var popoverVisible = false
    private var latestReading = NetworkReading(state: .warmingUp)
    private var latestInterfaces: [InterfaceDescriptor] = []
    private var latestError: String?
    private var latestStorageIssue: String?
    private var latestTemporaryStatistics = false
    private var latestMeasurement: MeasurementSession?

    init(storage: UsageStorageLocation = .applicationSupport) {
        sampler = NetworkSampler(storage: storage)
    }
    #if DEBUG
    /// Documentation only: no sampler start, disk ledger, process list or router.
    static func releasePreview(now: Date = Date()) throws -> NetworkMonitor {
        let monitor = NetworkMonitor(storage: .memory)
        let ledger = try UsageLedger(location: .memory)
        for second in 0..<600 {
            let rate = UInt64(180_000 + (second % 90) * 8_000)
            try ledger.record(NetworkReading(download: Double(rate), upload: 42_000,
                state: .measuring, interval: 1, receivedDelta: rate, sentDelta: 42_000),
                endingAt: now.addingTimeInterval(Double(second - 600)))
        }
        monitor.statisticsVisible = true
        monitor.setPopoverVisible(true)
        monitor.consume(SampleUpdate(reading: NetworkReading(download: 420_000, upload: 42_000,
            state: .measuring), interfaces: [], statistics: try ledger.snapshot(selection: monitor.selection, now: now),
            error: nil, storageIssue: nil, temporaryStatistics: false, measurement: nil))
        return monitor
    }
    #endif
    private var generation = 0

    var stateLabel: String {
        switch latestReading.state {
        case .measuring: "Live"
        case .warmingUp: "Messung startet"
        case .offline: "Kein aktives Interface"
        case .resynchronizing: "Neue Messbasis"
        case .sleeping: "Ruhezustand"
        case .unavailable: "Messung nicht verfügbar"
        }
    }

    func start() {
        generation += 1
        let current = generation
        sampler.start { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.consume(update)
            }
        }
    }

    func pause() {
        generation += 1 // Reject a sample queued just before the sleep notification.
        sampler.pause()
        latestReading = NetworkReading(state: .sleeping)
        if popoverVisible { reading = latestReading }
        onReading?(latestReading)
    }

    func selectPeriod(_ period: UsagePeriod) {
        select(UsageSelection(period: period))
    }

    func movePeriod(by offset: Int) {
        guard let next = try? selection.moving(by: offset) else { return }
        select(next)
    }

    private func select(_ value: UsageSelection) {
        guard value != selection else { return }
        selection = value
        statistics = nil // Never show an old period underneath a new selection.
        sampler.select(value)
    }

    func setStatisticsVisible(_ visible: Bool) {
        statisticsVisible = visible
        if visible {
            statistics = nil
            publishLiveDetails()
        }
        sampler.setStatisticsVisible(visible)
        if visible { refreshMeasurements() }
    }

    func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        if !visible { showingSavedMeasurements = false }
        if visible { publishLiveDetails() }
    }

    func stopAndFlush() {
        generation += 1
        if let error = sampler.stopAndFlush() {
            FileHandle.standardError.write(Data((error + "\n").utf8))
        }
    }

    var presentedMeasurement: MeasurementSession? {
        Self.presentedMeasurement(measurement, dismissedStart: dismissedMeasurementStart)
    }

    static func presentedMeasurement(_ measurement: MeasurementSession?, dismissedStart: Date?) -> MeasurementSession? {
        guard let measurement else { return nil }
        return !measurement.isRunning && measurement.startedAt == dismissedStart ? nil : measurement
    }

    func dismissMeasurementResult() {
        guard let measurement, !measurement.isRunning, !measurementBusy else { return }
        dismissedMeasurementStart = measurement.startedAt
        measurementName = ""; measurementIssue = nil
        sampler.discardMeasurement(id: measurement.id)
    }

    func startMeasurement(duration: TimeInterval?) {
        guard !measurementBusy else { return }
        measurementName = ""; measurementIssue = nil
        sampler.startMeasurement(duration: duration)
    }
    func stopMeasurement() { sampler.stopMeasurement() }

    func refreshMeasurements() {
        sampler.loadMeasurements { [weak self] values, error in
            Task { @MainActor [weak self] in
                if let values { self?.savedMeasurements = values }
                self?.measurementIssue = error
            }
        }
    }

    func saveMeasurement() {
        guard let measurement, !measurement.isRunning, !measurementBusy else { return }
        measurementBusy = true; measurementIssue = nil
        sampler.saveMeasurement(id: measurement.id, name: measurementName) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.measurementBusy = false; self.measurementIssue = error
                if error == nil {
                    self.dismissedMeasurementStart = measurement.startedAt
                    self.measurementName = ""
                    self.refreshMeasurements()
                }
            }
        }
    }

    func deleteMeasurement(id: UUID) {
        guard !measurementBusy else { return }
        measurementBusy = true; measurementIssue = nil
        sampler.deleteMeasurement(id: id) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.measurementBusy = false; self.measurementIssue = error
                if error == nil { self.refreshMeasurements() }
            }
        }
    }

    func exportHistory(to destination: URL) {
        guard !dataManagementBusy else { return }
        dataManagementBusy = true; dataManagementMessage = nil
        sampler.exportHistory(to: destination) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.dataManagementBusy = false
                self?.dataManagementMessage = error ?? "Statistik exportiert."
            }
        }
    }

    func resetHistory() {
        guard !dataManagementBusy, measurement?.isRunning != true else { return }
        dataManagementBusy = true; dataManagementMessage = nil
        sampler.resetHistory { [weak self] error in
            Task { @MainActor [weak self] in
                self?.dataManagementBusy = false
                self?.dataManagementMessage = error ?? "Statistik zurückgesetzt. Eine Sicherung wurde im Datenordner abgelegt."
            }
        }
    }

    private func consume(_ update: SampleUpdate) {
        latestMeasurement = update.measurement
        if popoverVisible, measurement != latestMeasurement { measurement = latestMeasurement }
        latestStorageIssue = update.storageIssue
        latestTemporaryStatistics = update.temporaryStatistics
        if statisticsVisible, let stats = update.statistics, stats.selection == selection { statistics = stats }
        if popoverVisible {
            if storageIssue != latestStorageIssue { storageIssue = latestStorageIssue }
            if temporaryStatistics != latestTemporaryStatistics { temporaryStatistics = latestTemporaryStatistics }
        }
        guard let reading = update.reading else { return }
        latestReading = reading
        latestInterfaces = update.interfaces
        latestError = update.error
        if popoverVisible { publishLiveDetails() }
        onReading?(reading)
    }

    private func publishLiveDetails() {
        if measurement != latestMeasurement { measurement = latestMeasurement }
        reading = latestReading
        if interfaces != latestInterfaces { interfaces = latestInterfaces }
        if errorMessage != latestError { errorMessage = latestError }
        if storageIssue != latestStorageIssue { storageIssue = latestStorageIssue }
        if temporaryStatistics != latestTemporaryStatistics { temporaryStatistics = latestTemporaryStatistics }
    }
}
