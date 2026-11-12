import Foundation

public struct NetTopParseResult: Sendable {
    public let counters: [ProcessTrafficCounter]
    public let skippedRows: Int
}

public enum NetTopParser {
    /// A malformed header or a wholly unreadable response is an error. Isolated
    /// bad rows are excluded and counted so a partial snapshot can be identified.
    public static func parse(_ text: String) throws -> [ProcessTrafficCounter] {
        try parseSnapshot(text).counters
    }

    public static func parseSnapshot(_ text: String) throws -> NetTopParseResult {
        let lines = text.split(whereSeparator: \.isNewline).filter { !$0.allSatisfy(\.isWhitespace) }
        guard let first = lines.first else { throw AppTrafficError.malformedOutput }
        let header = try fields(String(first))
        guard let receivedIndex = header.firstIndex(of: "bytes_in"), let sentIndex = header.firstIndex(of: "bytes_out"),
              receivedIndex != 0, sentIndex != 0 else { throw AppTrafficError.malformedOutput }
        var counters: [ProcessTrafficCounter] = []
        var seen = Set<Int32>()
        var duplicatePIDs = Set<Int32>()
        var skippedRows = 0
        for line in lines.dropFirst() {
            guard counters.count + skippedRows < 4096 else { throw AppTrafficError.outputLimit }
            guard let columns = try? fields(String(line)),
                  columns.count == header.count, let dot = columns[0].lastIndex(of: "."),
                  let pid = Int32(columns[0][columns[0].index(after: dot)...]), pid >= 0,
                  let received = integer(columns[receivedIndex]), let sent = integer(columns[sentIndex]) else {
                skippedRows += 1; continue
            }
            let name = String(columns[0][..<dot])
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { skippedRows += 1; continue }
            if duplicatePIDs.contains(pid) { skippedRows += 1; continue }
            if !seen.insert(pid).inserted {
                counters.removeAll { $0.pid == pid }
                duplicatePIDs.insert(pid)
                skippedRows += 2
                continue
            }
            counters.append(ProcessTrafficCounter(pid: pid, name: name, received: received, sent: sent))
        }
        if counters.isEmpty && skippedRows > 0 {
            throw duplicatePIDs.isEmpty ? AppTrafficError.malformedOutput : AppTrafficError.duplicateProcess
        }
        return NetTopParseResult(counters: counters, skippedRows: skippedRows)
    }

    private static func integer(_ text: String) -> UInt64? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return UInt64(text)
    }

    private static func fields(_ line: String) throws -> [String] {
        var result: [String] = [], field = ""
        var quoted = false, closedQuote = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            let next = line.index(after: index)
            if quoted {
                if character == "\"" {
                    if next < line.endIndex, line[next] == "\"" { field.append("\""); index = line.index(after: next); continue }
                    quoted = false; closedQuote = true
                } else { field.append(character) }
            } else if character == "," {
                result.append(field); field = ""; closedQuote = false
            } else if character == "\"", field.isEmpty, !closedQuote { quoted = true }
            else {
                guard !closedQuote, character != "\"" else { throw AppTrafficError.malformedOutput }
                field.append(character)
            }
            index = next
        }
        guard !quoted else { throw AppTrafficError.malformedOutput }
        result.append(field)
        return result
    }
}
