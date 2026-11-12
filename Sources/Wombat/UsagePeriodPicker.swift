import AppKit
import SwiftUI
import WombatCore

/// Native segmented selection without implicit period changes from wheel input.
struct UsagePeriodPicker: NSViewRepresentable {
    @Binding var selection: UsagePeriod

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> FixedPeriodSegmentedControl {
        let control = FixedPeriodSegmentedControl(labels: UsagePeriod.allCases.map(\.label),
            trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.selectPeriod(_:)))
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel("Zeitraum für den Datenverbrauch")
        control.setAccessibilityIdentifier("usage-period")
        return control
    }

    func updateNSView(_ control: FixedPeriodSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = UsagePeriod.allCases.firstIndex(of: selection) ?? 0
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<UsagePeriod>
        init(selection: Binding<UsagePeriod>) { self.selection = selection }

        @objc func selectPeriod(_ control: NSSegmentedControl) {
            let periods = UsagePeriod.allCases
            guard periods.indices.contains(control.selectedSegment) else { return }
            selection.wrappedValue = periods[control.selectedSegment]
        }
    }
}

final class FixedPeriodSegmentedControl: NSSegmentedControl {
    override func scrollWheel(with event: NSEvent) { /* Period changes require deliberate selection. */ }
}
