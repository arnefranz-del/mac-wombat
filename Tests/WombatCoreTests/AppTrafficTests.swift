import Foundation
import Testing
@testable import WombatCore

struct AppTrafficTests {
    @Test func parserUsesNamedColumnsAndPreserves64BitCounters() throws {
        let rows = try NetTopParser.parse(",bytes_out,bytes_in,\n\"Browser, Helper.123\",700,5000000001,\ncom.example.Helper.42,4,3,\n")
        #expect(rows == [ProcessTrafficCounter(pid: 123, name: "Browser, Helper", received: 5_000_000_001, sent: 700),
                         ProcessTrafficCounter(pid: 42, name: "com.example.Helper", received: 3, sent: 4)])
        #expect(try NetTopParser.parse(",bytes_in,bytes_out,\n").isEmpty)
    }

    @Test func malformedOrPartialOutputNeverBecomesAZeroSnapshot() {
        for value in ["", "bad header", ",bytes_in,bytes_out,\nSafari.1,2,", ",bytes_in,bytes_out,\nSafari.1,-1,0,",
                      ",bytes_in,bytes_out,\nSafari.1,2 MB,0,", ",bytes_in,bytes_out,\nSafari.1,18446744073709551616,0,",
                      ",bytes_in,bytes_out,\nno_pid,2,0,", ",bytes_in,bytes_out,\n\"Safari.1,2,0,"] {
            #expect(throws: AppTrafficError.self) { try NetTopParser.parse(value) }
        }
        #expect(throws: AppTrafficError.duplicateProcess) {
            try NetTopParser.parse(",bytes_in,bytes_out,\nA.1,2,0,\nB.1,3,0,\n")
        }
    }

    @Test func invalidRowsAreIsolatedAndAmbiguousPidsAreNotAttributed() throws {
        let result = try NetTopParser.parseSnapshot(",bytes_in,bytes_out,\nSafari.11,123,4,\n.9002,10521629,652,\nbroken\nA.12,7,8,\nB.12,9,10,\nChrome.13,99,12,\n")
        #expect(result.skippedRows == 4)
        #expect(result.counters == [.init(pid: 11, name: "Safari", received: 123, sent: 4),
                                    .init(pid: 13, name: "Chrome", received: 99, sent: 12)])
        let snapshot = AppTrafficSnapshot(rows: try AppTrafficGrouper.group(result.counters, identities: [:]),
            processCount: result.counters.count, querySeconds: 0, skippedRows: result.skippedRows)
        #expect(snapshot.includingUnreportedApps([]).skippedRows == 4)
    }

    @Test func allInvalidRowsDoNotBecomeAnEmptySuccess() {
        #expect(throws: AppTrafficError.malformedOutput) {
            try NetTopParser.parseSnapshot(",bytes_in,bytes_out,\n.9002,10521629,652,\ninvalid\n")
        }
    }

    @Test func helpersUseOuterBundleAndSharedWebKitRemainsAmbiguous() {
        #expect(AppBundleLocator.outerApp(in: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Helper")?.path == "/Applications/Browser.app")
        #expect(AppBundleLocator.outerApp(in: "/usr/bin/curl") == nil)
        #expect(AppBundleLocator.outerApp(in: "/tmp/folder.appcache/process") == nil)
        #expect(AppBundleLocator.isSharedWebKit(name: "com.apple.WebKit.Networking", path: nil))
        #expect(!AppBundleLocator.isSharedWebKit(name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"))
    }

    @Test func groupingSumsOnceAndNeverCarriesPastSnapshotOrPidState() throws {
        let app = TrafficIdentity(id: "app:a", name: "A", kind: .app)
        let identities: [Int32: TrafficIdentity] = [1: app, 2: app]
        let first = try AppTrafficGrouper.group([.init(pid: 1, name: "A", received: 100, sent: 25),
            .init(pid: 2, name: "A Helper", received: 200, sent: 75), .init(pid: 3, name: "curl", received: 10, sent: 0)], identities: identities)
        #expect(first[0].received == 300 && first[0].sent == 100 && first[0].processes.count == 2)
        #expect(first[1].identity.name == "curl")
        let next = try AppTrafficGrouper.group([.init(pid: 1, name: "A", received: 3, sent: 1)], identities: identities)
        #expect(next[0].received == 3) // A reset/disappearing socket must not retain or add 300.
        let reused = try AppTrafficGrouper.group([.init(pid: 1, name: "B", received: 8, sent: 2)], identities: [:])
        #expect(reused[0].identity.name == "B")
    }

    @Test func overflowAndDuplicatePidsAreRejected() {
        let app = TrafficIdentity(id: "same", name: "Same", kind: .app)
        #expect(throws: AppTrafficError.counterOverflow) {
            try AppTrafficGrouper.group([.init(pid: 1, name: "A", received: .max, sent: 1)], identities: [:])
        }
        #expect(throws: AppTrafficError.counterOverflow) {
            try AppTrafficGrouper.group([.init(pid: 1, name: "A", received: .max, sent: 0),
                .init(pid: 2, name: "B", received: 1, sent: 0)], identities: [1: app, 2: app])
        }
    }

    @Test func unreportedRunningAppsRemainUnknownRatherThanMeasuredZero() throws {
        let app = TrafficIdentity(id: "app:a", name: "A", kind: .app)
        let safari = TrafficIdentity(id: "app:safari", name: "Safari", kind: .app)
        let rows = try AppTrafficGrouper.group([.init(pid: 1, name: "A", received: 0, sent: 0)], identities: [1: app])
        let snapshot = AppTrafficSnapshot(rows: rows, processCount: 1, querySeconds: 0).includingUnreportedApps([app, safari, safari])
        #expect(snapshot.rows.count == 2)
        #expect(snapshot.rows[0].hasCounters)
        #expect(!snapshot.rows[1].hasCounters && snapshot.rows[1].identity.name == "Safari")
        #expect(snapshot.processCount == 1)
    }
}

struct AppTrafficProcessTests {
    @Test func boundedCommandReturnsARealParsedSnapshot() throws {
        let command = SnapshotCommand(executable: "/usr/bin/printf", arguments: [",bytes_in,bytes_out,\nfixture.1,123,45,\n"])
        let result = try NetTopSnapshotReader(command: command).read()
        #expect(result.counters.first?.received == 123)
    }

    @Test func boundedCommandKeepsValidCountersAndReportsUnusableRows() throws {
        let command = SnapshotCommand(executable: "/usr/bin/printf", arguments: [
            ",bytes_in,bytes_out,\n.9002,10521629,652,\nSafari.123,300,40,\n"
        ])
        let result = try NetTopSnapshotReader(command: command).read()
        #expect(result.skippedRows == 1)
        #expect(result.counters == [.init(pid: 123, name: "Safari", received: 300, sent: 40)])
    }

    @Test func wallClockLimitKillsAndReapsChild() {
        let reader = NetTopSnapshotReader(command: .init(executable: "/bin/sleep", arguments: ["5"]),
            budget: .init(wallSeconds: 0.08))
        let start = Date()
        #expect(throws: AppTrafficError.timeout) { try reader.read() }
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test func outputLimitStopsNoisyChild() {
        let reader = NetTopSnapshotReader(command: .init(executable: "/usr/bin/yes", arguments: []),
            budget: .init(wallSeconds: 1, cpuSeconds: 1, outputBytes: 512))
        #expect(throws: AppTrafficError.outputLimit) { try reader.read() }
    }

    @Test func cpuBudgetStopsBusyChildBeforeWallTimeout() {
        let reader = NetTopSnapshotReader(command: .init(executable: "/usr/bin/awk", arguments: ["BEGIN { while (1) {} }"]),
            budget: .init(wallSeconds: 3, cpuSeconds: 0.03))
        #expect(throws: AppTrafficError.cpuBudget) { try reader.read() }
    }

    @Test func cancellationStopsRunningChild() async throws {
        let reader = NetTopSnapshotReader(command: .init(executable: "/bin/sleep", arguments: ["5"]))
        let task = Task.detached { try reader.read() }
        try await Task.sleep(for: .milliseconds(40))
        reader.cancel()
        do { _ = try await task.value; Issue.record("Cancelled read succeeded") }
        catch { #expect(error as? AppTrafficError == .cancelled) }
    }
}

private final class TestTrafficSampler: AppTrafficSampling, @unchecked Sendable {
    let lock = NSLock()
    private var calls = 0, cancellations = 0
    var failure: AppTrafficError?
    var callCount: Int { lock.withLock { calls } }
    var cancelCount: Int { lock.withLock { cancellations } }
    func sample() async throws -> AppTrafficSnapshot {
        let error = lock.withLock { calls += 1; return failure }
        if let error { throw error }
        return AppTrafficSnapshot(rows: [], processCount: 0, querySeconds: 0)
    }
    func cancel() { lock.withLock { cancellations += 1 } }
}

private final class TestTrafficClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double = 100
    func now() -> Double { lock.withLock { time } }
    func advance(_ seconds: Double) { lock.withLock { time += seconds } }
}

@MainActor
struct AppTrafficControllerTests {
    private func settle(_ controller: AppTrafficController) async {
        for _ in 0..<100 {
            if !controller.isBusy { return }
            await Task.yield()
        }
        #expect(!controller.isBusy)
    }

    @Test func samplesOnlyWhenVisibleAndThrottlesManualRefreshAndReopen() async {
        let service = TestTrafficSampler(), clock = TestTrafficClock()
        let controller = AppTrafficController(sampler: service, clock: { clock.now() })
        controller.refresh(); #expect(service.callCount == 0)
        controller.setVisible(true); await settle(controller)
        #expect(service.callCount == 1)
        for _ in 0..<20 { controller.refresh() }
        await settle(controller); #expect(service.callCount == 1)
        controller.setVisible(false)
        #expect(service.cancelCount == 1)
        clock.advance(AppTrafficController.refreshSeconds + 1); controller.refresh(); #expect(service.callCount == 1)
        controller.setVisible(true); await settle(controller); #expect(service.callCount == 2)
        controller.setVisible(false); controller.setVisible(true); await settle(controller)
        #expect(service.callCount == 2)
        controller.setVisible(false)
    }

    @Test func failurePausesAutomaticAndManualPollingUntilExplicitRetry() async {
        let service = TestTrafficSampler(), clock = TestTrafficClock()
        service.failure = .cpuBudget
        let controller = AppTrafficController(sampler: service, clock: { clock.now() })
        controller.setVisible(true); await settle(controller)
        #expect(controller.automaticRefreshPaused && controller.issue != nil)
        clock.advance(AppTrafficController.refreshSeconds + 1); controller.refresh(); await settle(controller)
        #expect(service.callCount == 1)
        service.failure = nil
        controller.retry(); await settle(controller)
        #expect(service.callCount == 2)
        #expect(controller.issue == nil && !controller.automaticRefreshPaused)
        controller.setVisible(false)
    }

    @Test func manualRefreshExplainsCooldownAndKeepsFailurePausedUntilRetryCanStart() async {
        let service = TestTrafficSampler(), clock = TestTrafficClock()
        service.failure = .cpuBudget
        let controller = AppTrafficController(sampler: service, clock: { clock.now() })
        #expect(controller.requestManualRefresh() == .notVisible)
        controller.setVisible(true)
        #expect(controller.requestManualRefresh() == .busy)
        await settle(controller)
        #expect(controller.automaticRefreshPaused)
        #expect(controller.requestManualRefresh() == .wait(seconds: 20))
        #expect(controller.automaticRefreshPaused)
        clock.advance(5.1)
        #expect(controller.requestManualRefresh() == .wait(seconds: 15))
        service.failure = nil
        clock.advance(15)
        #expect(controller.requestManualRefresh() == .started)
        await settle(controller)
        #expect(service.callCount == 2 && controller.snapshot != nil && !controller.automaticRefreshPaused)
        controller.setVisible(false)
    }
}

private final class SuspendedTrafficSampler: AppTrafficSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AppTrafficSnapshot, Error>?
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    func sample() async throws -> AppTrafficSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { calls += 1; self.continuation = continuation }
        }
    }
    func cancel() {} // Deliberately slow/uncooperative backend: controller must reject its late reply.
    func complete(processCount: Int) {
        let pending = lock.withLock { let old = continuation; continuation = nil; return old }
        pending?.resume(returning: AppTrafficSnapshot(rows: [], processCount: processCount, querySeconds: 0))
    }
}

extension AppTrafficControllerTests {
    @Test func noOverlappingQueriesAndNoLateResultAfterClose() async throws {
        let service = SuspendedTrafficSampler(), clock = TestTrafficClock()
        let controller = AppTrafficController(sampler: service, clock: { clock.now() })
        controller.setVisible(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(service.callCount == 1 && controller.isBusy)
        clock.advance(AppTrafficController.refreshSeconds + 1)
        for _ in 0..<10 { controller.refresh() }
        #expect(service.callCount == 1)
        controller.setVisible(false)
        service.complete(processCount: 99)
        await settle(controller)
        #expect(controller.snapshot == nil)
        controller.setVisible(true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(service.callCount == 2)
        service.complete(processCount: 2)
        await settle(controller)
        #expect(controller.snapshot?.processCount == 2)
        controller.setVisible(false)
    }
}
