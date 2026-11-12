import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Wombat
import WombatCore

@MainActor private final class FakeLogin: LoginItemService {
    var state: LoginItemState = .notRegistered
    var failRegistration = false
    func register() async throws {
        if failRegistration {
            throw NSError(domain: "WombatUITest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(repeating: "Autostart-Fehler ", count: 50)])
        }
        state = .enabled
    }
    func unregister() async throws { state = .notRegistered }
}

@Suite(.serialized) @MainActor
struct PopoverRenderingTests {
    @Test func eachTabRendersAtTheSameNativeSizeInBothAppearances() throws {
        _ = NSApplication.shared
        let monitor = NetworkMonitor(storage: .memory)
        let traffic = AppTrafficController()
        let login = LoginItemController(service: FakeLogin())
        let suite = "Wombat-ui-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let display = DisplaySettings(defaults: defaults)
        var images: [String: Data] = [:]
        for dark in [false, true] {
            for tab in PopoverTab.allCases {
                let nav = PopoverNavigation(defaults: defaults)
                nav.tab = tab
                let root = PopoverRootView(monitor: monitor, traffic: traffic, navigation: nav,
                    loginItem: login, display: display, onSelectTab: { nav.tab = $0 })
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: root)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(size.width == 420 && size.height == 630)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = host.appearance
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                if tab == .statistics {
                    func containsScrollView(_ view: NSView) -> Bool {
                        if view is NSScrollView { return true }
                        for child in view.subviews {
                            if containsScrollView(child) { return true }
                        }
                        return false
                    }
                    #expect(!containsScrollView(host), "Die Statistik darf keinen Scrollbereich enthalten.")
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    Issue.record("Native view bitmap unavailable for \(tab.rawValue)")
                    continue
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(data.count > 1_000)
                images["\(dark)-\(tab.rawValue)"] = data
                window.close()
            }
        }
        for dark in [false, true] {
            #expect(images["\(dark)-statistics"] != images["\(dark)-programs"])
            #expect(images["\(dark)-programs"] != images["\(dark)-settings"])
        }
        #expect(images["false-statistics"] != images["true-statistics"])
    }

    @Test func legacyHomePreferencesLeaveMacNavigationAndLayoutAvailable() throws {
        let suite = "Wombat-navigation-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "homeSelected")
        defaults.set("devices", forKey: "homeTab")
        defaults.set("192.168.200.10", forKey: "homeRouterAddress")
        defaults.set("192.168.200.10", forKey: "homeStoredRouterAddress")
        defaults.set(MenuBarLayout.large.rawValue, forKey: MenuBarLayout.defaultsKey)
        defaults.set(AppearancePreference.dark.rawValue, forKey: AppearancePreference.defaultsKey)

        let navigation = PopoverNavigation(defaults: defaults)
        #expect(navigation.tab == .statistics)
        let display = DisplaySettings(defaults: defaults)
        #expect(display.layout == .large && display.appearance == .dark)
        navigation.tab = .programs
        #expect(PopoverNavigation(defaults: defaults).tab == .programs)
        #expect(defaults.bool(forKey: "homeSelected"))
        #expect(defaults.string(forKey: "homeTab") == "devices")
        #expect(defaults.string(forKey: "homeRouterAddress") == "192.168.200.10")
        #expect(defaults.string(forKey: "homeStoredRouterAddress") == "192.168.200.10")
    }

    @Test func displaySelectionsPersistInAnIsolatedDefaultsDomain() throws {
        let suite = "Wombat-ui-preferences-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = DisplaySettings(defaults: defaults)
        first.setLayout(.compact)
        first.setAppearance(.dark)
        let reopened = DisplaySettings(defaults: defaults)
        #expect(reopened.layout == .compact && reopened.appearance == .dark)
        reopened.setAppearance(.system)
        #expect(DisplaySettings(defaults: defaults).appearance == .system)
    }

    @Test func settingsRetainAScrollContainerForApprovalAndLongErrors() async throws {
        _ = NSApplication.shared
        let suite = "Wombat-ui-warning-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let display = DisplaySettings(defaults: defaults)
        let service = FakeLogin()
        let login = LoginItemController(service: service)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 450),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        func renderSettings() -> NSHostingView<SettingsView> {
            let host = NSHostingView(rootView: SettingsView(loginItem: login, display: display, monitor: NetworkMonitor(storage: .memory)))
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 450)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.08))
            return host
        }
        func containsScrollView(_ view: NSView) -> Bool {
            if view is NSScrollView { return true }
            for child in view.subviews {
                if containsScrollView(child) { return true }
            }
            return false
        }

        service.state = .requiresApproval; login.refresh()
        let approval = renderSettings()
        #expect(containsScrollView(approval))
        service.state = .notRegistered; service.failRegistration = true; login.refresh()
        await login.setEnabled(true)
        #expect(login.errorMessage != nil)
        let error = renderSettings()
        #expect(containsScrollView(error))
    }
}

@Suite(.serialized) @MainActor
struct MeasurementStripTests {
    @Test func closingParentClearsSavedListPresentationWithoutChangingTheDraftName() {
        let monitor = NetworkMonitor(storage: .memory)
        monitor.measurementName = "Entwurf"
        monitor.showingSavedMeasurements = true
        monitor.setPopoverVisible(false)
        #expect(!monitor.showingSavedMeasurements)
        #expect(monitor.measurementName == "Entwurf")
    }

    @Test func dismissedResultStaysHiddenWithoutHidingANewOrRunningMeasurement() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let running = MeasurementSession(startedAt: start, duration: nil)
        var finished = running; finished.stop(at: start.addingTimeInterval(5))
        #expect(NetworkMonitor.presentedMeasurement(finished, dismissedStart: nil) == finished)
        #expect(NetworkMonitor.presentedMeasurement(finished, dismissedStart: start) == nil)
        #expect(NetworkMonitor.presentedMeasurement(running, dismissedStart: start) == running)
        let next = MeasurementSession(startedAt: start.addingTimeInterval(6), duration: 900)
        #expect(NetworkMonitor.presentedMeasurement(next, dismissedStart: start) == next)
    }

    @Test func remainingAndElapsedTimeUseTheExistingSession() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let timed = MeasurementSession(startedAt: start, duration: 900)
        let manual = MeasurementSession(startedAt: start, duration: nil)
        #expect(MeasurementStrip.clockText(timed, now: start.addingTimeInterval(2)) == "14:58 verbleibend")
        #expect(MeasurementStrip.clockText(timed, now: start.addingTimeInterval(950)) == "00:00 verbleibend")
        #expect(MeasurementStrip.clockText(manual, now: start.addingTimeInterval(65)) == "01:05 vergangen")
        #expect(MeasurementStrip.clockText(manual, now: start.addingTimeInterval(3605)) == "01:00:05 vergangen")
    }

    @Test func idleRunningAndFinishedRenderCompactlyInBothAppearances() throws {
        _ = NSApplication.shared
        let start = Date()
        var running = MeasurementSession(startedAt: start, duration: nil)
        running.ingest(NetworkReading(download: 100, upload: 20, state: .measuring, interval: 1,
            receivedDelta: 100, sentDelta: 20), previousEnd: start, endingAt: start.addingTimeInterval(1), accepted: true)
        var finished = running; finished.stop(at: start.addingTimeInterval(2))
        let variants: [MeasurementSession?] = [nil, running, finished]
        for dark in [false, true] {
            var images: [Data] = []
            for session in variants {
                let strip = MeasurementStrip(measurement: session, name: .constant(""), onStart: { _ in }, onStop: {}, onSave: {}, onDismiss: {})
                    .environment(\.colorScheme, dark ? .dark : .light).frame(width: 380, alignment: .leading)
                let host = NSHostingView(rootView: strip)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = host.fittingSize
                #expect(size.width == 380 && size.height <= 90)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.appearance = host.appearance; window.contentView = host
                host.frame = NSRect(origin: .zero, size: size); host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                images.append(try #require(bitmap.representation(using: .png, properties: [:])))
                window.close()
            }
            #expect(images[0] != images[1] && images[1] != images[2])
        }
    }
}

@Suite(.serialized) @MainActor struct MenuBarModeTests {
    @Test func allModesKeepFixedWidthsAndShowOnlyMacRates() throws {
        _ = NSApplication.shared
        let mac = NetworkReading(download: 1200, upload: 75, state: .measuring)
        for layout in MenuBarLayout.allCases {
            let width = StatusRatesView.width(for: layout)
            for dark in [false, true] {
                let view = StatusRatesView(frame: NSRect(x: 0, y: 0, width: width, height: 22))
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.setLayout(layout)
                view.update(NetworkReading(state: .unavailable))
                #expect(view.displayedRates == [nil, nil])
                view.update(mac)
                #expect(view.displayedRates == [1200, 75])
                #expect(view.frame.width == width)
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                #expect(bitmap.representation(using: .png, properties: [:]) != nil)
            }
        }
        #expect(Set(MenuBarLayout.allCases.map(StatusRatesView.width(for:))).count == 3)
        for rate in [1.0, 999.0, 1_000.0, 99_900.0, 999_000.0, 999_600.0, 99_900_000.0, 999_000_000.0, 1_000_000_000.0] {
            for size in [9.0, 9.5] {
                let (text, font) = StatusRatesView.fittedRate(rate, width: 50, fontSize: size)
                #expect(text == RateFormatter.format(rate).text)
                #expect((text as NSString).size(withAttributes: [.font: font]).width <= 50)
            }
        }
    }
}
