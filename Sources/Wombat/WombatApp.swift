import AppKit
import Darwin
import SwiftUI
import WombatCore

@main
struct WombatApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--installation-info") {
            let service = SystemLoginItemService()
            let state: String = switch service.state {
            case .notRegistered: "notRegistered"
            case .enabled: "enabled"
            case .requiresApproval: "requiresApproval"
            case .notFound: "notFound"
            case .unknown: "unknown"
            }
            let info: [String: Any] = ["bundleIdentifier": Bundle.main.bundleIdentifier ?? "",
                "version": AppVersion.number, "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                "bundlePath": Bundle.main.bundleURL.path, "loginItemState": state]
            if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            }
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-release-preview"), index + 1 < CommandLine.arguments.count {
            do { try PreviewRenderer.renderRelease(to: CommandLine.arguments[index + 1]) }
            catch { FileHandle.standardError.write(Data("Dokumentationsvorschau fehlgeschlagen.\n".utf8)); exit(1) }
            return
        }
        #endif
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--render-preview"),
           index + 1 < CommandLine.arguments.count {
            do { try PreviewRenderer.render(to: CommandLine.arguments[index + 1]) }
            catch {
                FileHandle.standardError.write(Data("Preview fehlgeschlagen: \(error)\n".utf8))
                exit(1)
            }
            return
        }
        #endif
        let lock: SingleInstanceLock
        do {
            var lockURL = try UsageStorageLocation.applicationURL().deletingLastPathComponent().appendingPathComponent("instance.lock")
            var isolated = false
            #if DEBUG
            if let index = CommandLine.arguments.firstIndex(of: "--usage-db"), index + 1 < CommandLine.arguments.count {
                lockURL = URL(fileURLWithPath: CommandLine.arguments[index + 1] + ".instance.lock")
                isolated = true
            } else if CommandLine.arguments.contains("--diagnose-lifecycle") {
                lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("Wombat-diagnostic-\(getpid()).lock")
                isolated = true
            }
            #endif
            // Compatibility with an already-running pre-lock 0.4 copy. The
            // installer stops it before updating. New copies use flock only.
            if !isolated,
               NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.wombat.app").contains(where: {
                   guard $0.processIdentifier != getpid(), let url = $0.bundleURL else { return false }
                   let build = Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
                   return (Int(build.split(separator: ".").first ?? "0") ?? 0) < 5
               }) { return }
            lock = try SingleInstanceLock(url: lockURL)
        } catch InstanceLockError.alreadyRunning { return }
        catch {
            FileHandle.standardError.write(Data("Wombat konnte die Instanzsperre nicht übernehmen: \(error)\n".utf8))
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(lock) { withExtendedLifetime(delegate) { application.run() } }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuDelegate {
    private let monitor: NetworkMonitor = {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--usage-db"), index + 1 < CommandLine.arguments.count {
            return NetworkMonitor(storage: .file(URL(fileURLWithPath: CommandLine.arguments[index + 1])))
        }
        if CommandLine.arguments.contains("--diagnose-lifecycle") { return NetworkMonitor(storage: .memory) }
        #endif
        return NetworkMonitor()
    }()
    private var statusItem: NSStatusItem?
    private let statusView = StatusRatesView(frame: .zero)
    private let popover = NSPopover()
    private var terminationSignal: DispatchSourceSignal?
    private var popoverKeyMonitor: Any?
    private var latestStatusReading = NetworkReading(state: .warmingUp)
    private let loginItem = LoginItemController(service: SystemLoginItemService())
    private let displaySettings: DisplaySettings = {
        #if DEBUG
        if CommandLine.arguments.contains("--usage-db") || CommandLine.arguments.contains("--diagnose-lifecycle") {
            let suite = CommandLine.arguments.contains("--usage-db") ? "Wombat-isolated-debug-\(Bundle.main.bundleIdentifier ?? "test")" : "Wombat-isolated-debug-\(getpid())"
            return DisplaySettings(defaults: UserDefaults(suiteName: suite)!)
        }
        #endif
        return DisplaySettings()
    }()
    private let navigation: PopoverNavigation = {
        #if DEBUG
        if CommandLine.arguments.contains("--usage-db") || CommandLine.arguments.contains("--diagnose-lifecycle") {
            let suite = CommandLine.arguments.contains("--usage-db") ? "Wombat-isolated-debug-\(Bundle.main.bundleIdentifier ?? "test")" : "Wombat-isolated-debug-\(getpid())"
            return PopoverNavigation(defaults: UserDefaults(suiteName: suite)!)
        }
        #endif
        return PopoverNavigation()
    }()
    private let traffic = AppTrafficController(sampler: DesktopAppTrafficSampler())
    private var sleeping = false
    private let contextMenu = NSMenu()
    #if DEBUG
    private var diagnosticSamples = 0
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: StatusRatesView.width(for: displaySettings.layout))
        statusItem = item
        statusView.setLayout(displaySettings.layout)
        displaySettings.onChange = { [weak self] layout in
            self?.statusItem?.length = StatusRatesView.width(for: layout)
            self?.statusView.setLayout(layout)
            self?.updateContentVisibility()
        }
        if let button = item.button {
            button.title = ""
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Wombat Netzwerkmonitor")
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
        }
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverRootView(monitor: monitor, traffic: traffic,
            navigation: navigation, loginItem: loginItem, display: displaySettings,
            onSelectTab: { [weak self] tab in self?.selectTab(tab) }))
        popover.contentSize = NSSize(width: 420, height: 630)
        displaySettings.onAppearanceChange = { [weak self] preference in self?.applyAppearance(preference) }
        applyAppearance(displaySettings.appearance)
        configureContextMenu()
        configureMainMenu()
        signal(SIGTERM, SIG_IGN)
        let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        terminationSignal.setEventHandler { NSApplication.shared.terminate(nil) }
        self.terminationSignal = terminationSignal
        terminationSignal.resume()
        monitor.onReading = { [weak self] reading in self?.updateStatus(reading) }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(popoverOcclusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        updateStatus(monitor.reading)
        updateContentVisibility()
        #if DEBUG
        if CommandLine.arguments.contains("--diagnose-lifecycle") {
            monitor.selectPeriod(.allTime)
            monitor.setStatisticsVisible(true)
        }
        #endif
        monitor.start()
    }

    private func updateStatus(_ reading: NetworkReading) {
        latestStatusReading = reading
        refreshStatus()
        #if DEBUG
        if CommandLine.arguments.contains("--diagnose-lifecycle") {
            diagnosticSamples += 1
            let button = statusItem?.button
            let metrics: [String: Any] = [
                "state": reading.state.rawValue, "download_Bps": reading.download, "upload_Bps": reading.upload,
                "status_item_visible": statusItem?.isVisible ?? false,
                "button_width": button?.bounds.width ?? 0, "button_height": button?.bounds.height ?? 0,
                "drawing_width": statusView.bounds.width, "drawing_height": statusView.bounds.height,
                "layout": displaySettings.layout.rawValue,
                "has_status_window": button?.window != nil,
                "accessory_app": NSApplication.shared.activationPolicy() == .accessory,
                "popover_width": popover.contentViewController?.view.fittingSize.width ?? 0,
                "popover_height": popover.contentViewController?.view.fittingSize.height ?? 0,
                "statistics_available": monitor.statistics != nil,
                "recorded_received": monitor.statistics?.totals.received ?? 0,
                "recorded_sent": monitor.statistics?.totals.sent ?? 0,
                "recorded_total": monitor.statistics?.totals.bytes ?? 0,
                "storage_issue": monitor.storageIssue ?? "",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([10]))
            }
            var limit = 6
            if let index = CommandLine.arguments.firstIndex(of: "--diagnose-samples"), index + 1 < CommandLine.arguments.count {
                limit = max(3, min(120, Int(CommandLine.arguments[index + 1]) ?? 6))
            }
            if diagnosticSamples >= limit { NSApplication.shared.terminate(nil) }
        }
        #endif
    }

    private func refreshStatus() {
        statusView.update(latestStatusReading)
        func rate(_ value: Double?) -> String { value.map { RateFormatter.format($0).text } ?? "nicht verfügbar" }
        let macDown = latestStatusReading.state == .measuring ? latestStatusReading.download : nil
        let macUp = latestStatusReading.state == .measuring ? latestStatusReading.upload : nil
        let description = "Mac: Download \(rate(macDown)), Upload \(rate(macUp))"
        statusItem?.button?.toolTip = "Wombat · \(description)"
        statusItem?.button?.setAccessibilityValue(description)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func statusItemClicked() {
        if let event = NSApplication.shared.currentEvent, event.type == .rightMouseUp {
            guard let button = statusItem?.button else { return }
            popover.performClose(nil)
            NSMenu.popUpContextMenu(contextMenu, with: event, for: button)
        } else { togglePopover() }
    }

    private func configureContextMenu() {
        contextMenu.delegate = self
        contextMenu.autoenablesItems = false
        contextMenu.addItem(withTitle: "Programme …", action: #selector(showPrograms), keyEquivalent: "").target = self
        contextMenu.addItem(withTitle: "Einstellungen …", action: #selector(showSettings), keyEquivalent: ",").target = self
        let login = contextMenu.addItem(withTitle: "Beim Anmelden starten", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.tag = 1
        contextMenu.addItem(.separator())
        let version = contextMenu.addItem(withTitle: "Wombat \(AppVersion.short)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        contextMenu.addItem(withTitle: "Beenden", action: #selector(quit), keyEquivalent: "q").target = self
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let app = NSMenu(title: "Wombat")
        app.addItem(withTitle: "Programme …", action: #selector(showPrograms), keyEquivalent: "").target = self
        app.addItem(withTitle: "Einstellungen …", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Wombat ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Wombat beenden", action: #selector(quit), keyEquivalent: "q").target = self
        let appItem = NSMenuItem(title: "Wombat", action: nil, keyEquivalent: ""); appItem.submenu = app; main.addItem(appItem)
        let edit = NSMenu(title: "Bearbeiten")
        for (title, action, key) in [("Ausschneiden", "cut:", "x"), ("Kopieren", "copy:", "c"),
                                     ("Einsetzen", "paste:", "v"), ("Alles auswählen", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: "Bearbeiten", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)
        let windows = NSMenu(title: "Fenster")
        windows.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Alle nach vorne bringen", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(title: "Fenster", action: nil, keyEquivalent: ""); windowItem.submenu = windows; main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windows
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.refresh()
        menu.item(withTag: 1)?.state = loginItem.state.isEnabled ? .on : .off
        menu.item(withTag: 1)?.isEnabled = !loginItem.isBusy
    }

    @objc private func toggleLoginItem() {
        loginItem.refresh()
        Task { await loginItem.setEnabled(!loginItem.state.isEnabled) }
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    @objc private func showPrograms() {
        selectTab(.programs)
        if !popover.isShown { togglePopover() }
    }

    private func selectTab(_ tab: PopoverTab) {
        navigation.tab = tab
        monitor.setStatisticsVisible(popover.isShown && tab == .statistics)
        if tab == .settings { loginItem.refresh() }
        updateContentVisibility()
    }

    @objc private func popoverOcclusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === popover.contentViewController?.view.window else { return }
        updateContentVisibility()
    }

    private func updateContentVisibility() {
        let window = popover.contentViewController?.view.window
        let visible = !sleeping && popover.isShown && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
        monitor.setStatisticsVisible(visible && navigation.tab == .statistics)
        traffic.setVisible(visible && navigation.tab == .programs)
        refreshStatus()
    }

    @objc private func showSettings() {
        loginItem.refresh()
        selectTab(.settings)
        if !popover.isShown { togglePopover() }
    }

    private func applyAppearance(_ preference: AppearancePreference) {
        let appearance: NSAppearance? = switch preference {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        popover.contentViewController?.view.appearance = appearance
        popover.contentViewController?.view.window?.appearance = appearance
    }

    func applicationDidBecomeActive(_ notification: Notification) { loginItem.refresh() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }

    @objc private func willSleep() {
        sleeping = true
        popover.performClose(nil)
        monitor.pause()
        traffic.setVisible(false)
    }

    @objc private func didWake() {
        sleeping = false; monitor.start()
        updateContentVisibility()
    }

    func popoverWillShow(_ notification: Notification) {
        monitor.setPopoverVisible(true)
        monitor.setStatisticsVisible(navigation.tab == .statistics)
        if popoverKeyMonitor == nil {
            popoverKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self, self.popover.isShown else { return event }
                self.popover.performClose(nil)
                return nil
            }
        }
    }

    func popoverDidShow(_ notification: Notification) {
        applyAppearance(displaySettings.appearance)
        updateContentVisibility()
    }

    func popoverDidClose(_ notification: Notification) {
        monitor.setStatisticsVisible(false)
        monitor.setPopoverVisible(false)
        traffic.setVisible(false)
        updateContentVisibility()
        if let popoverKeyMonitor { NSEvent.removeMonitor(popoverKeyMonitor) }
        popoverKeyMonitor = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        traffic.setVisible(false)
        monitor.stopAndFlush()
        if let popoverKeyMonitor { NSEvent.removeMonitor(popoverKeyMonitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }
}
