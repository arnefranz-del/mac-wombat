import Foundation
import AppKit
import WombatCore

/// JSON lines from exactly the same reader/calculator used by the menu bar app.
/// No generated traffic: use alongside curl or a local network transfer.
@main
struct WombatProbe {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let index = arguments.firstIndex(of: "--export-csv"), index + 2 < arguments.count {
            try UsageCSV.export(source: URL(fileURLWithPath: arguments[index + 1]),
                                destination: URL(fileURLWithPath: arguments[index + 2]))
            return
        }
        if arguments.contains("--app-state") {
            var duration = 0.0
            if let index = arguments.firstIndex(of: "--seconds"), index+1 < arguments.count {
                duration = min(60, max(0, Double(arguments[index+1]) ?? 0))
            }
            let end = Date().addingTimeInterval(duration)
            repeat {
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "local.wombat.app")
                let rows: [[String: Any]] = apps.map {
                    ["pid": $0.processIdentifier, "path": $0.bundleURL?.path ?? "", "active": $0.isActive,
                     "owns_menu_bar": $0.ownsMenuBar, "activation_policy": $0.activationPolicy.rawValue,
                     "frontmost": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "",
                     "menu_owner": NSWorkspace.shared.menuBarOwningApplication?.bundleIdentifier ?? "",
                     "time": Date().ISO8601Format()]
                }
                let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
                if duration > 0 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
            } while Date() < end
            return
        }
        if arguments.contains("--apps") {
            let result = try NetTopSnapshotReader().read()
            let identities = ProcessAppResolver.resolve(result.counters)
            let rows = try AppTrafficGrouper.group(result.counters, identities: identities)
            let object: [String: Any] = [
                "time": Date().ISO8601Format(), "query_seconds": result.seconds,
                "process_count": result.counters.count,
                "scope": "current external TCP/UDP process counters; not lifetime or daily usage",
                "rows": rows.map { row in ["name": row.identity.name, "kind": row.identity.kind.rawValue,
                    "received": row.received, "sent": row.sent, "processes": row.processes] as [String: Any] },
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
            return
        }
        if arguments.contains("--help") {
            print("WombatProbe [--seconds N] [--raw] | --apps\nSamples actual macOS network counters, or one bounded process snapshot.")
            return
        }
        var seconds = 15
        if let index = arguments.firstIndex(of: "--seconds"), index + 1 < arguments.count {
            guard let value = Int(arguments[index + 1]), (1...3600).contains(value) else {
                throw ProbeError.invalidDuration
            }
            seconds = value
        }
        let raw = arguments.contains("--raw")
        let reader = DarwinCounterReader()
        var calculator = RateCalculator()
        for index in 0...seconds {
            let snapshot = try reader.read()
            let reading = calculator.update(snapshot)
            var object: [String: Any] = [
                "time": Date().ISO8601Format(), "monotonic": snapshot.timestamp,
                "state": reading.state.rawValue, "interval": reading.interval,
                "download_Bps": reading.download, "upload_Bps": reading.upload,
                "received_delta": reading.receivedDelta, "sent_delta": reading.sentDelta,
                "interfaces": snapshot.interfaces.map { ["name": $0.name, "index": Int($0.index),
                    "received": $0.received, "sent": $0.sent] as [String: Any] },
            ]
            if raw {
                object["raw_interfaces"] = try DarwinCounterReader.readRawCounters().map {
                    ["name": $0.counters.name, "received": $0.counters.received,
                     "sent": $0.counters.sent, "up": $0.isUp] as [String: Any]
                }
            }
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
            if index < seconds { Thread.sleep(forTimeInterval: 1) }
        }
    }
}

private enum ProbeError: Error { case invalidDuration }
