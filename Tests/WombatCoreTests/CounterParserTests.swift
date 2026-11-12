import Darwin
import Foundation
import Testing
@testable import WombatCore

struct CounterParserTests {
    private func record(rx: UInt64 = 100_000_000_000, tx: UInt64 = 20_000_000_000) -> Data {
        var entry = ifmibdata()
        entry.ifmd_flags = UInt32(IFF_UP | IFF_RUNNING)
        entry.ifmd_data.ifi_ibytes = rx
        entry.ifmd_data.ifi_obytes = tx
        var data = withUnsafeBytes(of: &entry) { Data($0) }
        data.replaceSubrange(0..<4, with: [UInt8]("en1".utf8) + [0])
        return data
    }

    @Test func testParserPreserves64BitCounters() throws {
        let parsed = try DarwinCounterReader.parse(record(), indexResolver: { _ in 6 })
        #expect(parsed.count == 1)
        #expect(parsed[0].counters.received == 100_000_000_000)
        #expect(parsed[0].counters.sent == 20_000_000_000)
        #expect(parsed[0].counters.index == 6)
        #expect(parsed[0].isUp)
    }

    @Test func testParserRejectsTruncatedAndUnterminatedRecords() {
        var badName = record()
        badName.replaceSubrange(0..<Int(IFNAMSIZ), with: repeatElement(UInt8(65), count: Int(IFNAMSIZ)))
        for data in [Data([0]), Data(record().dropLast()), badName] {
            #expect(throws: (any Error).self) {
                try DarwinCounterReader.parse(data, indexResolver: { _ in 6 })
            }
        }
    }

    @Test func testParserSkipsEmptyAndDisappearedInterfaces() throws {
        var data = Data(count: MemoryLayout<ifmibdata>.stride)
        data.append(record())
        #expect(try DarwinCounterReader.parse(data, indexResolver: { _ in 6 }).count == 1)
        #expect(try DarwinCounterReader.parse(record(), indexResolver: { _ in 0 }).isEmpty)
        #expect(try DarwinCounterReader.parse(Data()).isEmpty)
    }

    @Test func testRealKernelCountersCanBeReadWithoutPrivileges() throws {
        let raw = try DarwinCounterReader.readRawCounters()
        #expect(!raw.isEmpty)
        #expect(raw.contains { $0.counters.name == "lo0" })
        #expect(Set(raw.map { $0.counters.name }).count == raw.count)
        let reader = DarwinCounterReader()
        let snapshot = try reader.read()
        #expect(snapshot.timestamp.isFinite)
        #expect(snapshot.interfaces.allSatisfy { $0.name.hasPrefix("en") })
    }

    @Test func testLiveSamplesProduceRatesInsteadOfPermanentResynchronization() throws {
        let reader = DarwinCounterReader()
        var calculator = RateCalculator()
        let first = try reader.read()
        _ = calculator.update(first)
        Thread.sleep(forTimeInterval: 0.3)
        let second = try reader.read()
        let result = calculator.update(second)
        if second.interfaces.isEmpty {
            #expect(result.state == .offline)
        } else if first.interfaces.map(\.name) == second.interfaces.map(\.name) {
            #expect(result.state == .measuring)
        } else {
            #expect(result.state == .warmingUp)
        }
    }

    @Test func testKernelCountersBracketNetstatWithout32BitTruncation() throws {
        let before = try DarwinCounterReader.readRawCounters()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        process.arguments = ["-ibn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let after = try DarwinCounterReader.readRawCounters()
        var compared = 0
        for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10, fields[2].hasPrefix("<Link#"), fields[0].hasPrefix("en"),
                  let rx = UInt64(fields[6]), let tx = UInt64(fields[9]) else { continue }
            let name = String(fields[0]).replacingOccurrences(of: "*", with: "")
            guard let start = before.first(where: { $0.counters.name == name })?.counters,
                  let end = after.first(where: { $0.counters.name == name })?.counters else { continue }
            // netstat executes between these two reads, with the same true totals.
            #expect(start.received <= rx && rx <= end.received)
            #expect(start.sent <= tx && tx <= end.sent)
            compared += 1
        }
        #expect(compared > 0)
    }
}
