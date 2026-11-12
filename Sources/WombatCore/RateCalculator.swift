import Foundation

/// Pure state machine: no timers, wall clock, network access or UI dependencies.
public struct RateCalculator: Sendable {
    public let validInterval: ClosedRange<TimeInterval>
    private var previous: CounterSnapshot?

    public init(validInterval: ClosedRange<TimeInterval> = 0.25...3.5) {
        self.validInterval = validInterval
    }

    public mutating func reset() { previous = nil }

    public mutating func update(_ snapshot: CounterSnapshot) -> NetworkReading {
        guard snapshot.timestamp.isFinite else {
            reset()
            return NetworkReading(state: .resynchronizing)
        }
        let old = previous
        previous = snapshot

        guard !snapshot.interfaces.isEmpty else { return NetworkReading(state: .offline) }
        guard let old, !old.interfaces.isEmpty else { return NetworkReading(state: .warmingUp) }

        let interval = snapshot.timestamp - old.timestamp
        guard validInterval.contains(interval) else { return NetworkReading(state: .resynchronizing) }

        // Check individual identities before summing, so a disappearing adapter or
        // one reset cannot be hidden by traffic on another adapter.
        let oldIDs = old.interfaces.map(\.identity)
        let newIDs = snapshot.interfaces.map(\.identity)
        guard Set(oldIDs).count == oldIDs.count, Set(newIDs).count == newIDs.count,
              Set(oldIDs) == Set(newIDs) else { return NetworkReading(state: .warmingUp) }
        let oldByID = Dictionary(uniqueKeysWithValues: old.interfaces.map { ($0.identity, $0) })
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for current in snapshot.interfaces {
            guard let baseline = oldByID[current.identity],
                  current.received >= baseline.received, current.sent >= baseline.sent
            else { return NetworkReading(state: .resynchronizing) }
            let rx = received.addingReportingOverflow(current.received - baseline.received)
            let tx = sent.addingReportingOverflow(current.sent - baseline.sent)
            guard !rx.overflow, !tx.overflow else { return NetworkReading(state: .resynchronizing) }
            received = rx.partialValue
            sent = tx.partialValue
        }
        return NetworkReading(download: Double(received) / interval, upload: Double(sent) / interval,
                              state: .measuring, interval: interval,
                              receivedDelta: received, sentDelta: sent)
    }
}
