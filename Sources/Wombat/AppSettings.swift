import AppKit
import ServiceManagement
import SwiftUI
import WombatCore
import UniformTypeIdentifiers

enum AppVersion {
    static var number: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Entwicklung" }
    static var short: String { number == "Entwicklung" ? "Entwicklungsbuild" : "v\(number)" }
    static var full: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return "Version \(number)" + (build.map { " (\($0))" } ?? "")
    }
}

@MainActor
final class SystemLoginItemService: LoginItemService {
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    func register() async throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw NSError(domain: "Wombat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bitte Wombat.app öffnen, damit macOS die App als Anmeldeobjekt registrieren kann."])
        }
        try SMAppService.mainApp.register()
    }

    func unregister() async throws { try await SMAppService.mainApp.unregister() }
}

struct SettingsView: View {
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var display: DisplaySettings
    @ObservedObject var monitor: NetworkMonitor
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Anzeige")
                Text("Menüleiste").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 8)
                Picker("Menüleistenanzeige", selection: Binding(get: { display.layout }, set: { display.setLayout($0) })) {
                    ForEach(MenuBarLayout.allCases, id: \.self) { layout in Text(layout.label).tag(layout) }
                }.pickerStyle(.segmented).labelsHidden().padding(.top, 5).accessibilityLabel("Menüleistenanzeige")
                Text("Darstellung").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
                Picker("Darstellung", selection: Binding(get: { display.appearance }, set: { display.setAppearance($0) })) {
                    ForEach(AppearancePreference.allCases, id: \.self) { appearance in Text(appearance.label).tag(appearance) }
                }.pickerStyle(.segmented).labelsHidden().padding(.top, 5).accessibilityLabel("Darstellung")

                Divider().padding(.vertical, 10)
                sectionTitle("Allgemein")
                Toggle("Beim Anmelden starten", isOn: Binding(
                    get: { loginItem.state.isEnabled }, set: { value in Task { await loginItem.setEnabled(value) } }))
                    .toggleStyle(.switch).disabled(loginItem.isBusy).font(.system(size: 12)).padding(.top, 9)
                if loginItem.state == .requiresApproval {
                    Text("macOS benötigt deine Freigabe in den Anmeldeobjekten.").font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 7)
                    HStack {
                        Button("Anmeldeobjekte öffnen") { SMAppService.openSystemSettingsLoginItems() }
                        Button("Eintrag entfernen") { Task { await loginItem.setEnabled(false) } }.disabled(loginItem.isBusy)
                    }.controlSize(.small).padding(.top, 5)
                }
                if let error = loginItem.errorMessage {
                    Text(error).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
                DisclosureGroup("Datenverwaltung") {
                    VStack(alignment: .leading, spacing: 7) {
                        Button("Datenordner öffnen") {
                            if let url = try? UsageStorageLocation.applicationURL() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        Button("Statistik exportieren") { chooseExportDestination() }.disabled(monitor.dataManagementBusy)
                        Button("Statistik zurücksetzen") { confirmReset = true }
                            .disabled(monitor.dataManagementBusy || monitor.measurement?.isRunning == true)
                        if monitor.measurement?.isRunning == true { Text("Bitte die laufende Messung zuerst stoppen.").foregroundStyle(.secondary) }
                        if let message = monitor.dataManagementMessage { Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }.controlSize(.small).padding(.top, 7)
                }.font(.system(size: 11)).padding(.top, 10)

                Divider().padding(.vertical, 10)
                sectionTitle("Über Wombat")
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Datenschutz").font(.system(size: 11, weight: .medium))
                        Text("Deine Statistik bleibt auf diesem Mac.").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("Messgrenzen").font(.system(size: 11, weight: .medium))
                        Text("Die Statistik erfasst den Datenverkehr dieses Mac.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        DisclosureGroup("Mehr Informationen") {
                            Text("Mac Wombat erfasst aktive WLAN- und Ethernet-Schnittstellen, einschließlich lokalem Verkehr und VPN-Transport. Schlaf und nicht erfasste Schnittstellen können Lücken verursachen. Programme zeigt eine Momentaufnahme.")
                                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                        }.font(.system(size: 10)).padding(.top, 1)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(spacing: 3) {
                        WombatMark(size: 64)
                        Text(AppVersion.full).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(width: 150)
                }.padding(.top, 8)
            }.frame(maxWidth: .infinity, alignment: .topLeading).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { loginItem.refresh() }
        .alert("Statistik zurücksetzen?", isPresented: $confirmReset) {
            Button("Abbrechen", role: .cancel) {}
            Button("Statistik zurücksetzen", role: .destructive) { monitor.resetHistory() }
        } message: {
            Text("Die gespeicherte Verbrauchshistorie wird gelöscht. Vorher wird eine Sicherung im Datenordner angelegt. Einstellungen und Autostart bleiben erhalten.")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
    }

    private func chooseExportDestination() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "Wombat-Statistik.csv"
        panel.begin { response in
            if response == .OK, let destination = panel.url { monitor.exportHistory(to: destination) }
        }
    }
}

@MainActor
final class DisplaySettings: ObservableObject {
    @Published private(set) var layout: MenuBarLayout
    @Published private(set) var appearance: AppearancePreference
    private let defaults: UserDefaults
    var onChange: ((MenuBarLayout) -> Void)?
    var onAppearanceChange: ((AppearancePreference) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.layout = MenuBarLayout.stored(defaults.string(forKey: MenuBarLayout.defaultsKey))
        self.appearance = AppearancePreference.stored(defaults.string(forKey: AppearancePreference.defaultsKey))
    }

    func setLayout(_ layout: MenuBarLayout) {
        guard self.layout != layout else { return }
        self.layout = layout
        defaults.set(layout.rawValue, forKey: MenuBarLayout.defaultsKey)
        onChange?(layout)
    }

    func setAppearance(_ appearance: AppearancePreference) {
        guard self.appearance != appearance else { return }
        self.appearance = appearance
        defaults.set(appearance.rawValue, forKey: AppearancePreference.defaultsKey)
        onAppearanceChange?(appearance)
    }
}
