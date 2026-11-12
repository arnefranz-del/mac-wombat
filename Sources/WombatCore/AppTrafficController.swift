import Combine
import Foundation

public enum ManualRefreshResult: Equatable, Sendable {
    case started, busy, notVisible, wait(seconds: Int)
}

@MainActor
public final class AppTrafficController: ObservableObject {
    @Published public private(set) var snapshot: AppTrafficSnapshot?
    @Published public private(set) var isBusy = false
    @Published public private(set) var issue: String?
    @Published public private(set) var isVisible = false
    @Published public private(set) var automaticRefreshPaused = false
    private let sampler: any AppTrafficSampling
    private let clock: @Sendable () -> TimeInterval
    private var lastAttempt: TimeInterval?
    private var generation = 0
    private var sampleTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    public static let refreshSeconds: Double = 20

    public init(sampler: any AppTrafficSampling = SystemAppTrafficSampler(),
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.sampler = sampler; self.clock = clock
    }

    public func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible; generation += 1
        timerTask?.cancel(); timerTask = nil
        if !visible {
            sampleTask?.cancel(); sampler.cancel()
            return
        }
        refresh()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(Self.refreshSeconds)) } catch { return }
                guard let self, self.isVisible else { return }
                self.refresh()
            }
        }
    }

    public func refresh() {
        guard isVisible, !isBusy, !automaticRefreshPaused else { return }
        let now = clock()
        if let lastAttempt, now - lastAttempt < Self.refreshSeconds { return }
        lastAttempt = now
        isBusy = true
        let current = generation
        sampleTask = Task { [weak self, sampler] in
            let outcome: Result<AppTrafficSnapshot, Error>
            do { outcome = .success(try await sampler.sample()) }
            catch { outcome = .failure(error) }
            guard let self else { return }
            self.isBusy = false; self.sampleTask = nil
            guard self.generation == current, self.isVisible else {
                // A newly reopened window may need a fresh request after cancellation.
                if self.isVisible { self.refresh() }
                return
            }
            switch outcome {
            case .success(let snapshot): self.snapshot = snapshot; self.issue = nil
            case .failure(let error):
                self.issue = error.localizedDescription
                self.automaticRefreshPaused = true // Never repeat expensive/failing probes automatically.
            }
        }
    }

    public func retry() {
        _ = requestManualRefresh()
    }

    /// Give the UI an immediate truthful response without bypassing the sampling limit.
    @discardableResult public func requestManualRefresh() -> ManualRefreshResult {
        guard isVisible else { return .notVisible }
        guard !isBusy else { return .busy }
        if let lastAttempt {
            let remaining = Self.refreshSeconds - (clock() - lastAttempt)
            if remaining > 0 { return .wait(seconds: Int(ceil(remaining))) }
        }
        automaticRefreshPaused = false
        refresh()
        return .started
    }
}
