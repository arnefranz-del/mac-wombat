import Darwin
import Foundation
import SystemConfiguration

public enum CounterReadError: LocalizedError {
    case systemCall(Int32)
    case malformedMessage
    case configurationUnavailable

    public var errorDescription: String? {
        switch self {
        case .systemCall(let code): "Netzwerkzähler nicht lesbar: \(String(cString: strerror(code)))"
        case .malformedMessage: "macOS lieferte unvollständige Netzwerkzähler."
        case .configurationUnavailable: "Die Netzwerkschnittstellen sind gerade nicht verfügbar."
        }
    }
}

public struct RawInterfaceCounters: Sendable {
    public let counters: InterfaceCounters
    public let flags: Int32

    public var isUp: Bool {
        flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 && flags & IFF_LOOPBACK == 0
    }
}

/// Single-thread confined. Reads counters only; never captures packets or changes configuration.
public final class DarwinCounterReader {
    private var catalog: [InterfaceDescriptor] = []
    private var catalogTimestamp = -Double.infinity
    private let store = SCDynamicStoreCreate(nil, "Wombat" as CFString, nil, nil)
    public private(set) var activeInterfaces: [InterfaceDescriptor] = []

    public init() {}

    public func invalidateCatalog() { catalogTimestamp = -Double.infinity }

    public func read() throws -> CounterSnapshot {
        let before = ProcessInfo.processInfo.systemUptime
        if before - catalogTimestamp > 5 {
            guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
                throw CounterReadError.configurationUnavailable
            }
            catalog = all.compactMap { interface in
                guard let name = SCNetworkInterfaceGetBSDName(interface) as String? else { return nil }
                let type = SCNetworkInterfaceGetInterfaceType(interface)
                let kind: TransportKind = type == kSCNetworkInterfaceTypeIEEE80211 ? .wifi
                    : type == kSCNetworkInterfaceTypeEthernet ? .ethernet : .other
                let descriptor = InterfaceDescriptor(name: name,
                    displayName: SCNetworkInterfaceGetLocalizedDisplayName(interface) as String? ?? kind.label,
                    kind: kind)
                return InterfacePolicy.includes(descriptor) ? descriptor : nil
            }.sorted { $0.name < $1.name }
            catalogTimestamp = before
        }
        let raw = try Self.readRawCounters()
        let byName = Dictionary(uniqueKeysWithValues: raw.map { ($0.counters.name, $0) })
        activeInterfaces = catalog.filter { descriptor in
            guard let entry = byName[descriptor.name], entry.isUp else { return false }
            // IFF_RUNNING means allocated, not necessarily cable/radio connected.
            // The Link state supplies the actual carrier state when available.
            if let store,
               let link = SCDynamicStoreCopyValue(store,
                   "State:/Network/Interface/\(descriptor.name)/Link" as CFString) as? [String: Any],
               let active = link["Active"] as? Bool { return active }
            return true
        }
        let after = ProcessInfo.processInfo.systemUptime
        return CounterSnapshot(timestamp: (before + after) / 2,
            interfaces: activeInterfaces.compactMap { byName[$0.name]?.counters })
    }

    public static func readRawCounters() throws -> [RawInterfaceCounters] {
        // IFMIB provides true 64-bit counters. NET_RT_IFLIST2 was tested here:
        // on macOS 14.7 its unprivileged output truncates/rounds byte counters.
        var mib: [Int32] = [CTL_NET, PF_LINK, NETLINK_GENERIC, IFMIB_IFALLDATA, 0, IFDATA_GENERAL]
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else {
                throw CounterReadError.systemCall(errno)
            }
            var data = Data(count: size)
            let result = data.withUnsafeMutableBytes { buffer in
                sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
            }
            if result == 0 {
                data.count = size
                return try parse(data)
            }
            let code = errno
            if code != ENOMEM { throw CounterReadError.systemCall(code) }
        }
        throw CounterReadError.systemCall(ENOMEM)
    }

    /// The kernel table contains packed, fixed-size ifmibdata records.
    static func parse(_ data: Data, indexResolver: (String) -> UInt32 = interfaceIndex) throws -> [RawInterfaceCounters] {
        let stride = MemoryLayout<ifmibdata>.stride
        guard data.count % stride == 0 else { throw CounterReadError.malformedMessage }
        return try data.withUnsafeBytes { buffer in
            var result: [RawInterfaceCounters] = []
            for offset in Swift.stride(from: 0, to: buffer.count, by: stride) {
                let entry = buffer.loadUnaligned(fromByteOffset: offset, as: ifmibdata.self)
                let nameBytes = buffer[offset..<(offset + Int(IFNAMSIZ))]
                guard let end = nameBytes.firstIndex(of: 0) else { throw CounterReadError.malformedMessage }
                // A detached interface can leave an empty entry in a racing table read.
                if end == offset { continue }
                let name = String(decoding: nameBytes[..<end], as: UTF8.self)
                let index = indexResolver(name)
                if index == 0 { continue }
                let stats = entry.ifmd_data
                // ifi_lastchange is deliberately unused: it changes on every sample
                // on the tested Mac. Path/link events and decreasing counters reset
                // the baseline instead of interpreting that timestamp as an identity.
                result.append(RawInterfaceCounters(counters: InterfaceCounters(
                    name: name, index: index, received: stats.ifi_ibytes, sent: stats.ifi_obytes),
                    flags: Int32(bitPattern: entry.ifmd_flags)))
            }
            return result
        }
    }

    private static func interfaceIndex(_ name: String) -> UInt32 {
        name.withCString { if_nametoindex($0) }
    }
}
