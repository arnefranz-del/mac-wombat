import SwiftUI
import WombatCore

struct SavedMeasurementsView: View {
    @ObservedObject var monitor: NetworkMonitor
    @State private var pendingDeletion: SavedMeasurement?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gespeicherte Messungen").font(.headline)
            if monitor.savedMeasurements.isEmpty {
                Text("Noch keine Messung gespeichert.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(monitor.savedMeasurements) { result in
                            HStack(alignment: .top, spacing: 8) {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Start: " + result.startedAt.formatted(date: .abbreviated, time: .standard))
                                        Text("Ende: " + result.endedAt.formatted(date: .abbreviated, time: .standard))
                                        Text(Self.coverageText(result)).foregroundStyle(result.hasGaps ? .orange : .secondary)
                                    }.font(.system(size: 10)).padding(.top, 5)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(result.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        Text("↓ \(value(result.received, result))   ↑ \(value(result.sent, result))")
                                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                        if result.hasGaps { Text("Messlücken").font(.system(size: 10)).foregroundStyle(.orange) }
                                    }
                                }
                                Button { pendingDeletion = result } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(monitor.measurementBusy)
                                    .accessibilityLabel("Messung \(result.name) löschen")
                                    .help("Nur diese gespeicherte Messung löschen")
                            }
                            Divider()
                        }
                    }
                }
            }
            if let issue = monitor.measurementIssue {
                Text(issue).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .padding(16).frame(width: 350, height: 310, alignment: .topLeading)
        .onAppear { monitor.refreshMeasurements() }
        .alert("Messung löschen?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })) {
            Button("Abbrechen", role: .cancel) { pendingDeletion = nil }
            Button("Löschen", role: .destructive) {
                if let result = pendingDeletion { monitor.deleteMeasurement(id: result.id) }
                pendingDeletion = nil
            }
        } message: {
            Text("Die gespeicherte Sitzung wird gelöscht. Die reguläre Gesamtstatistik bleibt erhalten.")
        }
    }

    private func value(_ bytes: UInt64, _ result: SavedMeasurement) -> String {
        result.observedSeconds > 0 ? UsageFormatter.bytes(bytes).text : "—"
    }

    static func coverageText(_ result: SavedMeasurement) -> String {
        let observed = result.observedSeconds.formatted(.number.precision(.fractionLength(1)))
        if result.coverageIsUnclear { return "Abdeckung unklar · \(observed) s erfasst" }
        if !result.hasGaps { return "\(observed) s erfasst · vollständig" }
        let missing = result.missingSeconds.formatted(.number.precision(.fractionLength(1)))
        return "\(observed) s erfasst · \(missing) s nicht erfasst · Messlücken"
    }
}
