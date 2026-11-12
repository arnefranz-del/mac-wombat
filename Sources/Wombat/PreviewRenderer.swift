#if DEBUG
import AppKit
import SwiftUI
import WombatCore

/// Developer-only native rendering, with real samples in a separate in-memory
/// ledger. Offscreen views never change the user's history, appearance or focus.
@MainActor
enum PreviewRenderer {
    static func renderRelease(to path: String) throws {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "Wombat-release-preview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = try NetworkMonitor.releasePreview()
        let navigation = PopoverNavigation(defaults: defaults)
        let traffic = AppTrafficController()
        let login = LoginItemController(service: PreviewLoginService())
        let display = DisplaySettings(defaults: defaults)
        for dark in [false, true] {
            navigation.tab = .statistics
            let view = VStack(spacing: 0) {
                Text("DEMO · Synthetische Beispieldaten").font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.20))
                    .padding(7).frame(width: 420).background(Color(red: 0.98, green: 0.96, blue: 0.90))
                PopoverRootView(monitor: monitor, traffic: traffic, navigation: navigation,
                    loginItem: login, display: display, onSelectTab: { navigation.tab = $0 })
            }.frame(width: 420, height: 657).environment(\.colorScheme, dark ? .dark : .light)
            try renderNative(view, appearance: dark ? .darkAqua : .aqua,
                to: directory.appendingPathComponent("mac-\(dark ? "dark" : "light").png"))
        }
        print("Zwei native Dokumentationsbilder mit synthetischen Daten erstellt.")
    }
    static func render(to path: String) throws {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let monitor = NetworkMonitor(storage: .memory)
        monitor.setPopoverVisible(true)
        monitor.setStatisticsVisible(true)
        monitor.start()
        RunLoop.current.run(until: Date().addingTimeInterval(8.3))
        defer { monitor.stopAndFlush() }
        let traffic = AppTrafficController(sampler: DesktopAppTrafficSampler())
        let navigation = PopoverNavigation(defaults: UserDefaults(suiteName: "Wombat-preview-navigation-\(UUID().uuidString)")!)
        let login = LoginItemController(service: SystemLoginItemService())
        let display = DisplaySettings(defaults: UserDefaults(suiteName: "Wombat-preview-\(UUID().uuidString)")!)

        for period in UsagePeriod.allCases {
            monitor.selectPeriod(period)
            wait(until: { monitor.statistics?.selection.period == period })
            guard monitor.statistics?.selection.period == period else { throw RenderError.statisticsUnavailable }
            for (name, scheme, appearance) in [
                ("light", ColorScheme.light, NSAppearance.Name.aqua),
                ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
            ] {
                let content = PopoverRootView(monitor: monitor, traffic: traffic, navigation: navigation,
                    loginItem: login, display: display, onSelectTab: { navigation.tab = $0 })
                    .environment(\.colorScheme, scheme)
                let file = directory.appendingPathComponent("\(period.rawValue)-\(name).png")
                try renderNative(content, appearance: appearance, to: file)
                if period == .day {
                    try FileManager.default.copyItemReplacing(file, to: directory.appendingPathComponent("popover-\(name).png"))
                    for layout in MenuBarLayout.allCases {
                        let view = StatusRatesView(frame: NSRect(x: 0, y: 0, width: StatusRatesView.width(for: layout), height: 22))
                        view.appearance = NSAppearance(named: appearance)
                        view.setLayout(layout)
                        view.update(monitor.reading)
                        try renderBitmap(view, to: directory.appendingPathComponent("status-\(layout.rawValue)-\(name).png"))
                        for (caseName, reading) in [
                            ("zero", NetworkReading(download: 0, upload: 0, state: .measuring)),
                            ("unit-switch", NetworkReading(download: 999_000, upload: 999_600, state: .measuring)),
                            ("large", NetworkReading(download: 999_000_000_000, upload: 99_000_000_000, state: .measuring)),
                            ("unavailable", NetworkReading(state: .unavailable)),
                        ] {
                            view.update(reading)
                            try renderBitmap(view, to: directory.appendingPathComponent("status-\(layout.rawValue)-\(name)-\(caseName).png"))
                        }
                    }
                }
            }
        }
        traffic.setVisible(true)
        wait(until: { traffic.snapshot != nil || traffic.issue != nil })
        traffic.setVisible(false)
        guard traffic.snapshot != nil else { throw RenderError.statisticsUnavailable }
        navigation.tab = .programs
        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let content = PopoverRootView(monitor: monitor, traffic: traffic, navigation: navigation,
                loginItem: login, display: display, onSelectTab: { navigation.tab = $0 }).environment(\.colorScheme, scheme)
            try renderNative(content, appearance: appearance, to: directory.appendingPathComponent("programs-\(name).png"))
        }
        navigation.tab = .settings
        for (name, scheme, appearance) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let content = PopoverRootView(monitor: monitor, traffic: traffic, navigation: navigation,
                loginItem: login, display: display, onSelectTab: { navigation.tab = $0 }).environment(\.colorScheme, scheme)
            try renderNative(content, appearance: appearance, to: directory.appendingPathComponent("settings-\(name).png"))
        }
        print("Native Vorschauen aller sechs Zeiträume mit echten Messwerten: \(path)")
    }

    private static func wait(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.025))
        }
    }

    private static func renderNative<V: View>(_ content: V, appearance: NSAppearance.Name, to file: URL) throws {
        let host = NSHostingView(rootView: content)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { throw RenderError.imageUnavailable }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
        try renderBitmap(host, to: file)
        window.close()
    }

    private static func renderBitmap(_ view: NSView, to file: URL) throws {
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { throw RenderError.imageUnavailable }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.imageUnavailable }
        try png.write(to: file)
    }

    private enum RenderError: Error { case imageUnavailable, statisticsUnavailable }
}

@MainActor private final class PreviewLoginService: LoginItemService {
    var state: LoginItemState { .notRegistered }
    func register() async throws {}
    func unregister() async throws {}
}

private extension FileManager {
    func copyItemReplacing(_ source: URL, to destination: URL) throws {
        // Preview artifacts only, never user statistics.
        try Data(contentsOf: source).write(to: destination, options: .atomic)
    }
}
#endif
