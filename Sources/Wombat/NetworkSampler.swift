import Foundation
import Network
import WombatCore

struct SampleUpdate: Sendable {
    let reading: NetworkReading?
    let interfaces: [InterfaceDescriptor]
    let statistics: UsageSnapshot?
    let error: String?
    let storageIssue: String?
    let temporaryStatistics: Bool
    let measurement: MeasurementSession?
}

/// All mutable state, including SQLite, is confined to queue.
final class NetworkSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.wombat.network-sampler", qos: .utility)
    private let reader = DarwinCounterReader()
    private var calculator = RateCalculator()
    private var timer: DispatchSourceTimer?
    private let pathMonitor = NWPathMonitor()
    private let storage: UsageStorageLocation
    private var ledger: UsageLedger?
    private var fallbackIssue: String?
    private var storageIssue: String?
    private var lastFlush: Double = 0
    private var lastWallSample: Date?
    private var measurement: MeasurementSession?
    private struct PendingMeasurement { let duration: TimeInterval? }
    private var pendingMeasurementStart: PendingMeasurement?
    private var pendingMeasurementStop = false
    private var dataManagementBusy = false
    private var selection = UsageSelection()
    private var statisticsVisible = false
    private var deliver: (@Sendable (SampleUpdate) -> Void)?

    init(storage: UsageStorageLocation) {
        self.storage = storage
        pathMonitor.pathUpdateHandler = { [weak self] _ in self?.invalidateCatalog() }
        pathMonitor.start(queue: queue)
    }

    func start(deliver: @escaping @Sendable (SampleUpdate) -> Void) {
        queue.async { [self] in
            timer?.cancel()
            self.deliver = deliver
            prepareLedger()
            calculator.reset()
            lastWallSample = nil
            reader.invalidateCatalog()
            lastFlush = ProcessInfo.processInfo.systemUptime
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source
            source.resume()
        }
    }

    private func prepareLedger() {
        guard ledger == nil else { return }
        do { ledger = try UsageLedger(location: storage) }
        catch {
            fallbackIssue = "Nur für diese Sitzung: \(error.localizedDescription)"
            storageIssue = fallbackIssue
            // Preserve the existing file; continue with explicitly temporary stats.
            ledger = try? UsageLedger(location: .memory)
        }
    }

    private func sample() {
        do {
            let snapshot = try reader.read()
            let reading = calculator.update(snapshot)
            let now = Date()
            let previousEnd = lastWallSample
            let accepted = UsageAttribution.accepts(reading, endingAt: now, previousEnd: previousEnd)
            if reading.state == .measuring {
                if accepted {
                    do { try ledger?.record(reading, endingAt: now) }
                    catch { storageIssue = error.localizedDescription }
                } else {
                    // Keep monotone live rates, but do not assign bytes to a
                    // misleading calendar interval after a wall-clock jump.
                    calculator.reset()
                }
            }
            measurement?.ingest(reading, previousEnd: previousEnd, endingAt: now, accepted: accepted)
            lastWallSample = now
            if let pending = pendingMeasurementStart {
                measurement = MeasurementSession(startedAt: now, duration: pending.duration)
                if reading.state != .measuring { measurement?.noteGap() }
                pendingMeasurementStart = nil
            }
            if pendingMeasurementStop {
                measurement?.stop(at: now)
                pendingMeasurementStop = false
            }
            if snapshot.timestamp - lastFlush >= 15 {
                flush()
                lastFlush = snapshot.timestamp
            }
            deliver?(SampleUpdate(reading: reading, interfaces: reader.activeInterfaces,
                statistics: statisticsVisible ? statistics(now: now) : nil,
                error: nil, storageIssue: storageIssue, temporaryStatistics: fallbackIssue != nil, measurement: measurement))
        } catch {
            let now = Date()
            measurement?.noteGap()
            measurement?.ingest(NetworkReading(state: .unavailable), previousEnd: lastWallSample, endingAt: now, accepted: false)
            if let pending = pendingMeasurementStart {
                measurement = MeasurementSession(startedAt: now, duration: pending.duration)
                measurement?.noteGap()
                pendingMeasurementStart = nil
            }
            if pendingMeasurementStop { measurement?.stop(at: now); pendingMeasurementStop = false }
            calculator.reset()
            lastWallSample = nil
            reader.invalidateCatalog()
            deliver?(SampleUpdate(reading: NetworkReading(state: .unavailable), interfaces: [],
                statistics: statisticsVisible ? statistics(now: Date()) : nil,
                error: error.localizedDescription, storageIssue: storageIssue, temporaryStatistics: fallbackIssue != nil, measurement: measurement))
        }
    }

    private func statistics(now: Date) -> UsageSnapshot? {
        do { return try ledger?.snapshot(selection: selection, now: now, calendar: .current) }
        catch { storageIssue = error.localizedDescription; return nil }
    }

    private func publishStatistics() {
        guard statisticsVisible else { return }
        deliver?(SampleUpdate(reading: nil, interfaces: reader.activeInterfaces,
            statistics: statistics(now: Date()), error: nil, storageIssue: storageIssue, temporaryStatistics: fallbackIssue != nil, measurement: measurement))
    }

    func select(_ selection: UsageSelection) {
        queue.async { [self] in self.selection = selection; publishStatistics() }
    }

    func setStatisticsVisible(_ visible: Bool) {
        queue.async { [self] in statisticsVisible = visible; publishStatistics() }
    }

    private func flush() {
        do { try ledger?.flush(); storageIssue = fallbackIssue }
        catch { storageIssue = "Speichern fehlgeschlagen: \(error.localizedDescription)" }
    }

    func pause() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let pending = pendingMeasurementStart {
                measurement = MeasurementSession(startedAt: Date(), duration: pending.duration)
                pendingMeasurementStart = nil
            }
            measurement?.noteGap()
            if pendingMeasurementStop { measurement?.stop(at: Date()); pendingMeasurementStop = false }
            calculator.reset()
            lastWallSample = nil
            flush()
        }
    }

    /// Called from applicationWillTerminate: do not leave the final flush queued
    /// behind an exiting process. No queue callback waits synchronously for UI.
    func stopAndFlush() -> String? {
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            flush()
            ledger = nil
            deliver = nil
            return storageIssue
        }
    }

    private func publishMeasurement() {
        deliver?(SampleUpdate(reading: nil, interfaces: reader.activeInterfaces, statistics: nil,
            error: nil, storageIssue: storageIssue, temporaryStatistics: fallbackIssue != nil, measurement: measurement))
    }

    func startMeasurement(duration: TimeInterval?) {
        queue.async { [self] in
            guard measurement?.isRunning != true, pendingMeasurementStart == nil, timer != nil else { return }
            // Begin on the next ordinary sample boundary; do not disturb the recorder.
            pendingMeasurementStart = PendingMeasurement(duration: duration)
        }
    }

    func stopMeasurement() {
        queue.async { [self] in
            guard measurement?.isRunning == true else { return }
            if timer != nil { pendingMeasurementStop = true }
            else { measurement?.noteGap(); measurement?.stop(at: Date()); publishMeasurement() }
        }
    }

    func discardMeasurement(id: UUID) {
        queue.async { [self] in
            guard measurement?.id == id, measurement?.isRunning == false else { return }
            measurement = nil
            publishMeasurement()
        }
    }

    func saveMeasurement(id: UUID, name: String, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard fallbackIssue == nil, let ledger else {
                completion("Die Sitzung kann derzeit nicht dauerhaft gespeichert werden."); return
            }
            guard let result = measurement, result.id == id, !result.isRunning else {
                completion("Keine abgeschlossene Messung verfügbar."); return
            }
            do {
                try ledger.saveMeasurement(result, name: name)
                measurement = nil
                publishMeasurement()
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }

    func loadMeasurements(completion: @escaping @Sendable ([SavedMeasurement]?, String?) -> Void) {
        queue.async { [self] in
            guard fallbackIssue == nil, let ledger else {
                completion(nil, "Gespeicherte Messungen sind derzeit nicht verfügbar."); return
            }
            do { completion(try ledger.savedMeasurements(), nil) }
            catch { completion(nil, error.localizedDescription) }
        }
    }

    func deleteMeasurement(id: UUID, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard fallbackIssue == nil, let ledger else {
                completion("Gespeicherte Messungen sind derzeit nicht verfügbar."); return
            }
            do { try ledger.deleteMeasurement(id: id); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }

    private var databaseURL: URL? {
        switch storage {
        case .applicationSupport: return try? UsageStorageLocation.applicationURL()
        case .file(let url): return url
        case .memory: return nil
        }
    }

    func exportHistory(to destination: URL, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard !dataManagementBusy, fallbackIssue == nil, let source = databaseURL, let ledger else {
                completion("Die gespeicherte Statistik ist derzeit nicht verfügbar."); return
            }
            do { try ledger.flush() }
            catch { completion(error.localizedDescription); return }
            dataManagementBusy = true
            DispatchQueue.global(qos: .utility).async { [self] in
                let message: String?
                do { try UsageCSV.export(source: source, destination: destination); message = nil }
                catch { message = error.localizedDescription }
                queue.async { [self] in dataManagementBusy = false; completion(message) }
            }
        }
    }

    func resetHistory(completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            guard !dataManagementBusy, measurement?.isRunning != true, pendingMeasurementStart == nil else {
                completion("Bitte zuerst die laufende Messung oder den Export beenden."); return
            }
            guard fallbackIssue == nil, let source = databaseURL, let ledger else {
                completion("Die gespeicherte Statistik ist derzeit nicht verfügbar."); return
            }
            dataManagementBusy = true
            defer { dataManagementBusy = false }
            do {
                _ = try ledger.backupAndReset(in: source.deletingLastPathComponent().appendingPathComponent("Backups", isDirectory: true))
                calculator.reset(); lastWallSample = nil
                measurement = nil
                storageIssue = nil
                publishStatistics(); publishMeasurement()
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }

    func invalidateCatalog() {
        queue.async { [self] in
            reader.invalidateCatalog()
            calculator.reset()
            lastWallSample = nil
        }
    }

    deinit { timer?.cancel(); pathMonitor.cancel() }
}
