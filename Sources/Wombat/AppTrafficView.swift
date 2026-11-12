import AppKit
import SwiftUI
import WombatCore

@MainActor
final class AppTrafficViewState: ObservableObject {
    @Published var search = ""
    @Published var includeProcesses = false
    @Published var sort: AppTrafficSort = .received
    @Published var ascending = false
}

struct AppTrafficView: View {
    @ObservedObject var controller: AppTrafficController
    @ObservedObject var state: AppTrafficViewState
    @State private var refreshMessage: String?
    @State private var showingMeasurementInfo = false

    private var rows: [AppTrafficRow] {
        let query = state.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = (controller.snapshot?.rows ?? []).filter {
            (state.includeProcesses || !$0.identity.isBackgroundService)
                && (query.isEmpty || $0.identity.name.localizedCaseInsensitiveContains(query))
        }
        return state.sort.sorted(filtered, ascending: state.ascending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Momentaufnahme").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button { showingMeasurementInfo.toggle() } label: {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("Hinweise zur Programmmessung")
                    .popover(isPresented: $showingMeasurementInfo, arrowEdge: .top) {
                        Text("Diese Werte sind eine Momentaufnahme der von macOS gemeldeten Prozesszähler. Sie zeigen keinen Stunden-, Tages- oder Gesamtverbrauch. Kurze Verbindungen können fehlen; gemeinsam genutzte Dienste lassen sich nicht immer einer App zuordnen.")
                            .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .padding(16).frame(width: 300)
                    }
            }.padding(.bottom, 9)

            if let count = controller.snapshot?.skippedRows, count > 0 {
                Label("Einzelne Prozesswerte nicht lesbar", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("\(count) Prozesszeilen wurden ausgelassen; die Momentaufnahme ist unvollständig.")
                    .padding(.bottom, 8)
            }

            TextField("Programm suchen", text: $state.search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Programm suchen").padding(.bottom, 10)
            HStack(spacing: 4) {
                sortButton(.name).frame(maxWidth: .infinity, alignment: .leading)
                sortButton(.received).frame(width: 78, alignment: .trailing)
                sortButton(.sent).frame(width: 78, alignment: .trailing)
            }
            .padding(.horizontal, 5).padding(.bottom, 7)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        HStack(spacing: 8) {
                            programIcon(row)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.identity.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                if row.identity.kind == .shared {
                                    Text("Zuordnung offen").font(.system(size: 9)).foregroundStyle(.secondary)
                                } else if !row.hasCounters {
                                    Text("Kein Zähler gemeldet").font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(row.hasCounters ? UsageFormatter.bytes(row.received).text : "—")
                                .frame(width: 78, alignment: .trailing)
                            Text(row.hasCounters ? UsageFormatter.bytes(row.sent).text : "—")
                                .frame(width: 78, alignment: .trailing)
                        }
                        .font(.system(size: 10).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 7)
                        .help(row.processes.isEmpty ? "Kein Prozesszähler gemeldet" : row.processes.joined(separator: "\n"))
                        Divider().opacity(0.45)
                    }
                }
            }
            .overlay {
                if controller.snapshot == nil {
                    VStack(spacing: 9) {
                        if controller.isBusy { ProgressView().controlSize(.small) }
                        Text(controller.isBusy ? "Prozesszähler werden gelesen …" : "Noch keine Momentaufnahme")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }.allowsHitTesting(false)
                } else if rows.isEmpty {
                    Text("Keine passenden Einträge").font(.system(size: 11)).foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Toggle("Auch Systemdienste", isOn: $state.includeProcesses).toggleStyle(.checkbox)
                .font(.system(size: 10)).padding(.top, 10)
            if let issue = controller.issue {
                Label("Aktualisierung fehlgeschlagen", systemImage: "exclamationmark.circle")
                    .font(.system(size: 10)).foregroundStyle(.orange).help(issue).padding(.top, 8)
            }
            HStack(alignment: .center) {
                Text(refreshMessage ?? controller.snapshot.map { "Aktualisiert " + $0.date.formatted(.dateTime.hour().minute().second()) }
                     ?? "Noch nicht aktualisiert")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if controller.isBusy { ProgressView().controlSize(.small) }
                Button(controller.automaticRefreshPaused ? "Erneut versuchen" : "Aktualisieren") {
                    switch controller.requestManualRefresh() {
                    case .started: refreshMessage = "Aktualisiere …"
                    case .busy: refreshMessage = "Aktualisiere …"
                    case .notVisible: refreshMessage = "Ansicht ist nicht sichtbar"
                    case .wait(let seconds): refreshMessage = "Bitte \(seconds) s warten"
                    }
                }.disabled(controller.isBusy).controlSize(.small)
                    .help("Höchstens eine Abfrage alle \(Int(AppTrafficController.refreshSeconds)) Sekunden.")
            }.padding(.top, 10)
        }
        .task(id: refreshMessage) {
            guard refreshMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { refreshMessage = nil }
        }
        .onChange(of: controller.isBusy) { _, busy in
            if !busy && refreshMessage == "Aktualisiere …" { refreshMessage = nil }
        }
    }

    private func sortButton(_ value: AppTrafficSort) -> some View {
        Button {
            if state.sort == value { state.ascending.toggle() } else { state.sort = value; state.ascending = value == .name }
        } label: {
            HStack(spacing: 3) {
                Text(value.label)
                if state.sort == value { Image(systemName: state.ascending ? "arrow.up" : "arrow.down") }
            }.font(.system(size: 9, weight: state.sort == value ? .semibold : .regular)).foregroundStyle(.secondary)
        }.buttonStyle(.plain).accessibilityLabel("Sortieren nach \(value.label)")
    }

    @ViewBuilder private func programIcon(_ row: AppTrafficRow) -> some View {
        if row.identity.kind == .app, !row.identity.isBackgroundService, let path = row.identity.bundlePath,
           FileManager.default.fileExists(atPath: path) {
            Image(nsImage: ProgramIconCache.icon(for: path)).resizable().interpolation(.high)
                .frame(width: 22, height: 22).accessibilityHidden(true)
        } else {
            Image(systemName: row.identity.kind == .shared ? "questionmark.circle" : "gearshape")
                .foregroundStyle(.secondary).frame(width: 22, height: 22).accessibilityHidden(true)
        }
    }
}

@MainActor private enum ProgramIconCache {
    private static let cache = NSCache<NSString, NSImage>()
    static func icon(for path: String) -> NSImage {
        if let image = cache.object(forKey: path as NSString) { return image }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

/// Add visible desktop apps with a dash when nettop has no counters for them.
/// A missing Safari row must not be mistaken for proven zero browser traffic.
final class DesktopAppTrafficSampler: AppTrafficSampling, Sendable {
    private let source = SystemAppTrafficSampler()
    func sample() async throws -> AppTrafficSnapshot {
        let snapshot = try await source.sample()
        let apps = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app -> TrafficIdentity? in
                guard app.activationPolicy == .regular, !app.isTerminated,
                      let url = app.bundleURL?.standardizedFileURL else { return nil }
                return TrafficIdentity(id: "app:" + url.path, name: app.localizedName ?? url.deletingPathExtension().lastPathComponent,
                    kind: .app, bundlePath: url.path)
            }
        }
        try Task.checkCancellation()
        return snapshot.includingUnreportedApps(apps)
    }
    func cancel() { source.cancel() }
}
