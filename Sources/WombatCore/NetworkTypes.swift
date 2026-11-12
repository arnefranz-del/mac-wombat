import Foundation

public enum TransportKind: String, Codable, Sendable {
    case wifi, ethernet, other

    public var label: String {
        switch self {
        case .wifi: "WLAN"
        case .ethernet: "Ethernet"
        case .other: "Andere"
        }
    }
}

public struct InterfaceDescriptor: Equatable, Sendable {
    public let name: String
    public let displayName: String
    public let kind: TransportKind

    public init(name: String, displayName: String, kind: TransportKind) {
        self.name = name
        self.displayName = displayName
        self.kind = kind
    }
}

public enum InterfacePolicy {
    /// SCNetworkInterface's hardware transports use enN. Layered devices
    /// (utun, bridge, bond, VLAN, awdl, llw, vmnet, …) are intentionally excluded.
    public static func includes(_ descriptor: InterfaceDescriptor) -> Bool {
        guard descriptor.kind == .wifi || descriptor.kind == .ethernet else { return false }
        guard descriptor.name.hasPrefix("en") else { return false }
        let suffix = descriptor.name.dropFirst(2)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

public struct InterfaceCounters: Equatable, Sendable {
    public let name: String
    public let index: UInt32
    public let received: UInt64
    public let sent: UInt64
    public init(name: String, index: UInt32, received: UInt64, sent: UInt64) {
        self.name = name
        self.index = index
        self.received = received
        self.sent = sent
    }

    var identity: Identity { Identity(name: name, index: index) }
    struct Identity: Hashable { let name: String; let index: UInt32 }
}

public struct CounterSnapshot: Sendable {
    public let timestamp: TimeInterval
    public let interfaces: [InterfaceCounters]

    public init(timestamp: TimeInterval, interfaces: [InterfaceCounters]) {
        self.timestamp = timestamp
        self.interfaces = interfaces
    }
}

public enum ReadingState: String, Codable, Sendable {
    case measuring, warmingUp, offline, resynchronizing, sleeping, unavailable
}

public struct NetworkReading: Sendable {
    public let download: Double
    public let upload: Double
    public let state: ReadingState
    public let interval: Double
    public let receivedDelta: UInt64
    public let sentDelta: UInt64

    public init(download: Double = 0, upload: Double = 0, state: ReadingState,
                interval: Double = 0, receivedDelta: UInt64 = 0, sentDelta: UInt64 = 0) {
        self.download = download
        self.upload = upload
        self.state = state
        self.interval = interval
        self.receivedDelta = receivedDelta
        self.sentDelta = sentDelta
    }
}
