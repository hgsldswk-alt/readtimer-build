import Foundation

enum GoalCode {
    static let range = 5...10_080
    private static let prefix = "READWEEK1-"

    static func make(_ minutes: Int) -> String { prefix + String(format: "%03d", minutes) }
    static func parse(_ text: String) -> Int? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix) else { return nil }
        let suffix = code.dropFirst(prefix.count)
        guard (3...5).contains(suffix.utf8.count),
              suffix.utf8.allSatisfy({ (48...57).contains($0) }),
              let minutes = Int(suffix), range.contains(minutes) else { return nil }
        return minutes
    }
}

enum ReadingCSV {
    static func data(_ library: ReadingLibrary) -> Data {
        let date = ISO8601DateFormatter()
        let headerKeys = ["csv.book", "csv.kind", "csv.start", "csv.end", "csv.day", "csv.zone",
                          "csv.seconds", "csv.startPage", "csv.endPage"]
        let header = headerKeys.map(L.t)
        let rows = library.orderedEntries.map { entry in
            [library.book(entry.bookID)?.title ?? "", entry.kind.title,
             date.string(from: entry.startedAt), date.string(from: entry.endedAt),
             entry.day.iso, entry.zoneID, String(entry.seconds),
             entry.startPage.map { String($0) } ?? "", entry.endPage.map { String($0) } ?? ""]
        }
        let csv = ([header] + rows).map { $0.map(escape).joined(separator: ",") }.joined(separator: "\r\n")
        return Data(("\u{FEFF}" + csv + "\r\n").utf8)
    }

    private static func escape(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
