import SwiftUI
import WombatCore

@MainActor
final class PopoverNavigation: ObservableObject {
    private let defaults: UserDefaults
    @Published var tab: PopoverTab { didSet { defaults.set(tab.rawValue, forKey: "macTab") } }
    let trafficState = AppTrafficViewState()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tab = defaults.string(forKey: "macTab").flatMap(PopoverTab.init(rawValue:)) ?? .statistics
    }
}

struct PopoverRootView: View {
    @ObservedObject var monitor: NetworkMonitor
    @ObservedObject var traffic: AppTrafficController
    @ObservedObject var navigation: PopoverNavigation
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var display: DisplaySettings
    let onSelectTab: (PopoverTab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacHeader(monitor: monitor).padding(.bottom, 22)
            HStack(spacing: 0) {
                ForEach(PopoverTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) { onSelectTab(tab) }
                    } label: {
                        VStack(spacing: 7) {
                            Text(tab.label).font(.system(size: 11, weight: navigation.tab == tab ? .semibold : .regular))
                                .foregroundStyle(navigation.tab == tab ? Color.primary : Color.secondary)
                            Rectangle().fill(navigation.tab == tab ? Color.primary.opacity(0.7) : Color.clear).frame(height: 1.5)
                        }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("tab-\(tab.rawValue)")
                    .accessibilityAddTraits(navigation.tab == tab ? .isSelected : [])
                }
            }.padding(.bottom, 16)

            if let issue = monitor.storageIssue {
                Label(monitor.temporaryStatistics ? "Statistik nur für diese Sitzung" : "Statistik kann nicht gespeichert werden",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(.orange).help(issue).padding(.bottom, 8)
            }
            ZStack(alignment: .topLeading) {
                switch navigation.tab {
                case .statistics:
                    PopoverView(monitor: monitor).transition(.opacity)
                case .programs:
                    AppTrafficView(controller: traffic, state: navigation.trafficState).transition(.opacity)
                case .settings:
                    SettingsView(loginItem: loginItem, display: display, monitor: monitor).transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20).frame(width: 420, height: 630, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(display.appearance.colorScheme)
    }
}

private struct MacHeader: View {
    @ObservedObject var monitor: NetworkMonitor
    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 10) {
                headerRate("Download", rate: macRate(monitor.reading.download), color: Palette.download)
                headerRate("Upload", rate: macRate(monitor.reading.upload), color: Palette.upload)
            }
            Spacer(minLength: 6)
            Text("Mac Wombat")
                .font(.system(size: 13, weight: .semibold))
            WombatMark(size: 34)
        }.frame(height: 44)
    }

    private func macRate(_ rate: Double) -> Double? { monitor.reading.state == .measuring ? rate : nil }

    private func headerRate(_ title: String, rate: Double?, color: Color) -> some View {
        let value = rate.map { RateFormatter.format($0).text } ?? "—"
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 70, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) jetzt: \(value)")
        .accessibilityIdentifier("header-\(title.lowercased())")
    }
}

extension AppearancePreference {
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}
