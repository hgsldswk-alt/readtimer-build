import Foundation

struct Book: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var initialPage: Int?
    var totalPages: Int?
}

struct ReadingDay: Codable, Hashable, Comparable, Identifiable {
    let value: Int
    var id: Int { value }

    init(_ date: Date, in zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        value = (parts.year ?? 1970) * 10_000 + (parts.month ?? 1) * 100 + (parts.day ?? 1)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    var date: Date {
        Self.calendar.date(from: DateComponents(year: value / 10_000, month: value / 100 % 100, day: value % 100))!
    }
    var monday: ReadingDay {
        let weekday = Self.calendar.component(.weekday, from: date)
        return adding(days: -((weekday + 5) % 7))
    }
    func adding(days: Int) -> ReadingDay {
        let date = Self.calendar.date(byAdding: .day, value: days, to: date)!
        return ReadingDay(date, in: Self.calendar.timeZone)
    }
    var iso: String { String(format: "%04d-%02d-%02d", value / 10_000, value / 100 % 100, value % 100) }
    var label: String {
        let format = DateFormatter()
        format.timeZone = Self.calendar.timeZone
        format.calendar = Self.calendar
        format.setLocalizedDateFormatFromTemplate("yMMMEd")
        return format.string(from: date)
    }
    static func rangeLabel(from start: ReadingDay, to end: ReadingDay) -> String {
        let format = DateIntervalFormatter()
        format.calendar = Self.calendar
        format.timeZone = Self.calendar.timeZone
        format.dateTemplate = start.value / 10_000 == end.value / 10_000 ? "MMMd" : "yMMMd"
        return format.string(from: start.date, to: end.date)
    }
    static func < (lhs: ReadingDay, rhs: ReadingDay) -> Bool { lhs.value < rhs.value }
}

enum EntryKind: String, Codable {
    case timed, manual, bookmark
    var title: String { L.t("kind." + rawValue) }
}

struct ReadingEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    let bookID: UUID
    let kind: EntryKind
    var startedAt: Date
    private(set) var endedAt: Date
    private(set) var day: ReadingDay
    private(set) var zoneID: String
    var seconds: Int
    let startPage: Int?
    var endPage: Int?

    init(id: UUID = UUID(), bookID: UUID, kind: EntryKind, startedAt: Date, endedAt: Date,
         zone: TimeZone, seconds: Int, startPage: Int?, endPage: Int?, frozenDay: ReadingDay? = nil) {
        self.id = id
        self.bookID = bookID
        self.kind = kind
        self.startedAt = startedAt
        self.endedAt = endedAt
        day = frozenDay ?? ReadingDay(endedAt, in: zone)
        zoneID = zone.identifier
        self.seconds = seconds
        self.startPage = startPage
        self.endPage = endPage
    }

    mutating func edit(end: Date, zone: TimeZone, seconds: Int, page: Int?) {
        switch kind {
        case .timed: startedAt = startedAt.addingTimeInterval(end.timeIntervalSince(endedAt))
        case .manual, .bookmark: startedAt = end.addingTimeInterval(-Double(seconds))
        }
        if end != endedAt {
            day = ReadingDay(end, in: zone)
            zoneID = zone.identifier
        }
        endedAt = end
        self.seconds = seconds
        endPage = page
    }

    var advancedPages: Int {
        guard let startPage, let endPage else { return 0 }
        return max(0, endPage - startPage)
    }
    var counted: Bool { kind != .bookmark && seconds > 0 }
}

struct WeekSummary: Equatable, Identifiable {
    let monday: ReadingDay
    var id: ReadingDay { monday }
    var seconds = 0
    var days: Set<ReadingDay> = []
    var bookIDs: Set<UUID> = []
    var sunday: ReadingDay { monday.adding(days: 6) }
    var label: String { ReadingDay.rangeLabel(from: monday, to: sunday) }

    mutating func add(_ entry: ReadingEntry) {
        seconds += entry.seconds
        days.insert(entry.day)
        bookIDs.insert(entry.bookID)
    }
}

struct ReadingLibrary: Codable, Equatable {
    private(set) var version = 1
    var books: [Book] = []
    var currentBookID: UUID?
    var entries: [ReadingEntry] = []
    var draft: SessionDraft?
    var goalMinutes: Int?
    var earnedMilestones: Set<Int> = []
    var pendingMilestones: [Int] = []

    enum CodingKeys: String, CodingKey {
        case version, books, currentBookID, entries, draft, goalMinutes, earnedMilestones, pendingMilestones
    }

    var selected: Book? { books.first { $0.id == currentBookID } }
    func book(_ id: UUID) -> Book? { books.first { $0.id == id } }

    var orderedEntries: [ReadingEntry] {
        entries.enumerated().sorted {
            if $0.element.endedAt == $1.element.endedAt { return $0.offset > $1.offset }
            return $0.element.endedAt > $1.element.endedAt
        }.map(\.element)
    }

    func page(for book: Book) -> Int? {
        orderedEntries.first { $0.bookID == book.id && $0.endPage != nil }?.endPage ?? book.initialPage
    }

    func maxLoggedPage(for book: Book, excluding entryID: UUID? = nil) -> Int {
        entries.lazy.filter { $0.bookID == book.id && $0.id != entryID }.reduce(book.initialPage ?? 0) {
            max($0, $1.startPage ?? 0, $1.endPage ?? 0)
        }
    }

    mutating func append(_ entry: ReadingEntry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        updateMilestones()
    }

    mutating func finishDraft(seconds: Int, page: Int?) {
        guard let draft, draft.state == .pending, let ending = draft.ending else { return }
        let zone = TimeZone(identifier: ending.zoneID) ?? TimeZone(secondsFromGMT: 0)!
        let entry = ReadingEntry(id: draft.id, bookID: draft.bookID, kind: .timed,
                                 startedAt: draft.startedAt, endedAt: ending.date,
                                 zone: zone, seconds: seconds, startPage: draft.startPage, endPage: page,
                                 frozenDay: ending.localDay)
        append(entry)
        self.draft = nil
    }

    mutating func updateMilestones() {
        let count = readingDays
        for days in [7, 30] where count >= days && earnedMilestones.insert(days).inserted {
            pendingMilestones.append(days)
        }
    }

    var readingDays: Int { Set(entries.lazy.filter(\.counted).map(\.day)).count }

    func weeks(bookID: UUID? = nil) -> [WeekSummary] {
        var groups: [ReadingDay: WeekSummary] = [:]
        for entry in entries where entry.counted && (bookID == nil || entry.bookID == bookID) {
            let monday = entry.day.monday
            groups[monday, default: WeekSummary(monday: monday)].add(entry)
        }
        return groups.values.sorted { $0.monday > $1.monday }
    }

    func week(containing day: ReadingDay, bookID: UUID? = nil) -> WeekSummary {
        let monday = day.monday
        var summary = WeekSummary(monday: monday)
        for entry in entries where entry.counted && entry.day >= monday && entry.day <= summary.sunday
            && (bookID == nil || entry.bookID == bookID) {
            summary.add(entry)
        }
        return summary
    }
}

enum ReadingInput {
    static func positive(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isNumber }) else { return nil }
        let digits = trimmed.compactMap(\.wholeNumberValue)
        guard digits.count == trimmed.count, digits.allSatisfy({ $0 < 10 }),
              let number = Int(digits.map { String($0) }.joined()), number > 0 else { return nil }
        return number
    }

    static func duration(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        let values = parts.compactMap { part -> Int? in
            if !part.isEmpty && part.allSatisfy({ $0.wholeNumberValue == 0 }) { return 0 }
            return positive(String(part))
        }
        guard values.count == parts.count, let leading = values.first, leading <= 1_000_000,
              values.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        if values.count == 1 { return leading * 60 }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}
