import Darwin
import Foundation

public struct SnapshotCommand: Sendable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String]) { self.executable = executable; self.arguments = arguments }
    public static let nettop = SnapshotCommand(executable: "/usr/bin/nettop",
        arguments: ["-n", "-P", "-x", "-c", "-L", "1", "-t", "external", "-J", "bytes_in,bytes_out"])
}

public struct SnapshotBudget: Sendable {
    public let wallSeconds: Double
    public let cpuSeconds: Double
    public let outputBytes: Int
    public init(wallSeconds: Double = 1.5, cpuSeconds: Double = 0.15, outputBytes: Int = 262_144) {
        self.wallSeconds = wallSeconds; self.cpuSeconds = cpuSeconds; self.outputBytes = outputBytes
    }
}

public struct NetTopReadResult: Sendable {
    public let counters: [ProcessTrafficCounter]
    public let seconds: Double
    public let skippedRows: Int
}

/// Synchronous work for a utility task. No shell, no infinite nettop stream,
/// no destination/port columns, no disk output. Lock protects cancellation only.
public final class NetTopSnapshotReader: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var started = false
    private var process: Process?
    private let command: SnapshotCommand
    private let budget: SnapshotBudget

    public init(command: SnapshotCommand = .nettop, budget: SnapshotBudget = SnapshotBudget()) {
        self.command = command; self.budget = budget
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }

    public func read() throws -> NetTopReadResult {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = output; process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        process.qualityOfService = .utility
        defer {
            try? output.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            try? errors.fileHandleForReading.close(); try? errors.fileHandleForWriting.close()
            lock.withLock { if self.process === process { self.process = nil } }
        }
        try lock.withLock {
            guard !cancelled else { throw AppTrafficError.cancelled }
            guard !started else { throw AppTrafficError.alreadyRunning }
            started = true
            self.process = process
            try process.run()
        }
        let start = ProcessInfo.processInfo.systemUptime
        let descriptors = [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor]
        for fd in descriptors { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
        var stdout = Data(), stderr = Data()
        var failure: AppTrafficError?
        repeat {
            do {
                try drain(descriptors[0], into: &stdout)
                try drain(descriptors[1], into: &stderr)
                if stdout.count + stderr.count > budget.outputBytes { throw AppTrafficError.outputLimit }
            } catch { failure = .outputLimit }
            if lock.withLock({ cancelled }) { failure = .cancelled }
            if ProcessInfo.processInfo.systemUptime - start > budget.wallSeconds { failure = failure ?? .timeout }
            if process.isRunning, cpuTime(pid: process.processIdentifier) > budget.cpuSeconds { failure = failure ?? .cpuBudget }
            if failure != nil, process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.025)
        } while true
        process.waitUntilExit()
        if let failure { throw failure }
        try drain(descriptors[0], into: &stdout)
        try drain(descriptors[1], into: &stderr)
        guard stdout.count + stderr.count <= budget.outputBytes else { throw AppTrafficError.outputLimit }
        guard !lock.withLock({ cancelled }) else { throw AppTrafficError.cancelled }
        guard process.terminationStatus == 0 else { throw AppTrafficError.commandFailed(process.terminationStatus) }
        guard let text = String(data: stdout, encoding: .utf8) else { throw AppTrafficError.malformedOutput }
        let parsed = try NetTopParser.parseSnapshot(text)
        return NetTopReadResult(counters: parsed.counters, seconds: ProcessInfo.processInfo.systemUptime - start,
                                skippedRows: parsed.skippedRows)
    }

    private func drain(_ fd: Int32, into data: inout Data) throws {
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Each drain is bounded even if a misbehaving producer never stops writing.
        for _ in 0..<(max(1, budget.outputBytes / 4096) + 1) {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count <= 0 { return }
            guard count <= budget.outputBytes - data.count else { throw AppTrafficError.outputLimit }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func cpuTime(pid: Int32) -> Double {
        var info = rusage_info_v2()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard status == 0 else { return 0 }
        return Double(info.ri_user_time) / 1_000_000_000 + Double(info.ri_system_time) / 1_000_000_000
    }
}

public enum ProcessAppResolver {
    public static func resolve(_ counters: [ProcessTrafficCounter]) -> [Int32: TrafficIdentity] {
        var result: [Int32: TrafficIdentity] = [:]
        // Snapshot-local cache only. No persistent PID cache that could survive reuse.
        var bundles: [String: TrafficIdentity] = [:]
        for counter in counters {
            // The SDK macro (4 * MAXPATHLEN) is not imported by Swift.
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let count = proc_pidpath(counter.pid, &pathBuffer, UInt32(pathBuffer.count))
            let path = count > 0 ? String(decoding: pathBuffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
            if let path, let app = AppBundleLocator.outerApp(in: path), let bundle = Bundle(url: app) {
                let identity = bundles[app.path] ?? TrafficIdentity(id: "app:" + app.path,
                    name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? app.deletingPathExtension().lastPathComponent,
                    kind: .app, bundlePath: app.path)
                bundles[app.path] = identity; result[counter.pid] = identity
            } else if AppBundleLocator.isSharedWebKit(name: counter.name, path: path) {
                result[counter.pid] = TrafficIdentity(id: "shared:webkit", name: "WebKit (geteilt)", kind: .shared)
            } else if let path {
                result[counter.pid] = TrafficIdentity(id: "process:" + path, name: counter.name, kind: .process)
            }
        }
        return result
    }
}

public protocol AppTrafficSampling: AnyObject, Sendable {
    func sample() async throws -> AppTrafficSnapshot
    func cancel()
}

public final class SystemAppTrafficSampler: AppTrafficSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var reader: NetTopSnapshotReader?
    public init() {}

    public func sample() async throws -> AppTrafficSnapshot {
        let reader = NetTopSnapshotReader()
        try lock.withLock {
            guard self.reader == nil else { throw AppTrafficError.alreadyRunning }
            self.reader = reader
        }
        defer { lock.withLock { self.reader = nil } }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let snapshot = try await Task.detached(priority: .utility) {
                let result = try reader.read()
                let identities = ProcessAppResolver.resolve(result.counters)
                let rows = try AppTrafficGrouper.group(result.counters, identities: identities)
                return AppTrafficSnapshot(rows: rows, processCount: result.counters.count, querySeconds: result.seconds,
                                          skippedRows: result.skippedRows)
            }.value
            try Task.checkCancellation()
            return snapshot
        } onCancel: { reader.cancel() }
    }

    public func cancel() { lock.withLock { reader?.cancel() } }
}
