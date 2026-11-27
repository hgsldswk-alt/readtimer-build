import CoreImage
import Foundation
import ImageIO
import XCTest

final class CoreTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let book = Book(title: "春天在路上", initialPage: nil, totalPages: 240)
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func sample(_ continuous: Double, wall: Date = Date(timeIntervalSince1970: 1_000),
                        boot: String = "boot-a") -> ClockReading {
        ClockReading(wall: wall, continuous: continuous, boot: boot)
    }

    func testCoreReviewRequiresThreeActionsOnTwoLocalDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let firstDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 23)))
        let nextDay = firstDay.addingTimeInterval(2 * 3600)
        let empty = try JSONDecoder().decode(CoreReviewProgress.self, from: Data("{}".utf8))
        XCTAssertFalse(empty.isEligible)
        var progress = CoreReviewProgress.recording(empty, at: firstDay, calendar: calendar)
        var twoDays = progress
        twoDays.record(at: nextDay, calendar: calendar)
        XCTAssertFalse(twoDays.isEligible)
        progress.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(progress.isEligible)

        var sameDay = progress
        sameDay.record(at: firstDay, calendar: calendar)
        XCTAssertFalse(sameDay.isEligible)

        let data = try JSONEncoder().encode(progress)
        progress = try JSONDecoder().decode(CoreReviewProgress.self, from: data)
        progress.record(at: nextDay, calendar: calendar)
        XCTAssertTrue(progress.isEligible)
    }

    func testPauseResumeAndSleepUseContinuousTimeEvenWhenWallTimeJumps() {
        var draft = SessionDraft(book: book, page: 84, sample: sample(100))
        let changedWall = date("2001-02-03T04:05:06Z")
        XCTAssertEqual(draft.seconds(at: sample(130, wall: changedWall)), 30)
        draft.pause(at: sample(160))
        XCTAssertEqual(draft.seconds(at: sample(10_000)), 60)
        draft.resume(at: sample(10_000))
        draft.stop(at: sample(10_120), zone: utc, total: 240)
        XCTAssertEqual(draft.state, .pending)
        XCTAssertEqual(draft.seconds(at: sample(10_500)), 180)
        XCTAssertEqual(draft.ending?.pageText, "84")
        XCTAssertEqual(draft.ending?.durationText, "0:03:00")
    }

    func testSameBootRelaunchAndUnverifiableClockKeepOnlyKnownTime() throws {
        var draft = SessionDraft(book: book, page: nil, sample: sample(100))
        draft.checkpoint(at: sample(115))
        let stored = try JSONEncoder().encode(draft)
        var restored = try JSONDecoder().decode(SessionDraft.self, from: stored)
        restored.checkpoint(at: sample(130))
        XCTAssertEqual(restored.accumulated, 30)
        restored.checkpoint(at: sample(40_000, wall: date("2026-11-20T12:00:00Z"), boot: "boot-b"))
        XCTAssertEqual(restored.state, .paused)
        XCTAssertTrue(restored.needsDurationReview)
        XCTAssertEqual(restored.seconds(at: sample(70_000)), 30)
        restored.stop(at: sample(70_000), zone: utc, total: nil)
        XCTAssertEqual(restored.ending?.durationText, "0:00:30")
        XCTAssertEqual(ReadingInput.duration("0:02:45"), 165)
        var regressed = draft
        regressed.checkpoint(at: sample(105))
        XCTAssertEqual(regressed.accumulated, 15)
        XCTAssertTrue(regressed.needsDurationReview)
    }

    func testMidnightWeekTimeZoneAndDaylightSaving() throws {
        let west = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let east = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let start = date("2026-11-16T07:45:00Z")
        let end = date("2026-11-16T08:05:00Z")
        let record = ReadingEntry(bookID: book.id, kind: .timed, startedAt: start, endedAt: end,
                                  zone: west, seconds: 1_200, startPage: 10, endPage: 20)
        var library = ReadingLibrary(books: [book], currentBookID: book.id)
        library.append(record)
        XCTAssertEqual(ReadingDay(start, in: west).iso, "2026-11-15")
        XCTAssertEqual(record.day.iso, "2026-11-16")
        XCTAssertEqual(library.week(containing: ReadingDay(start, in: west)).seconds, 0)
        XCTAssertEqual(library.week(containing: ReadingDay(end, in: east)).seconds, 1_200)
        XCTAssertEqual(library.weeks().first?.days.count, 1)
        let zoneChange = date("2026-11-16T02:00:00Z")
        let local = makeEntry(end: zoneChange, zone: west, page: 5)
        XCTAssertNotEqual(local.day, ReadingDay(zoneChange, in: east))
        XCTAssertEqual(local.day.iso, "2026-11-15")
        let firstOneThirty = date("2026-11-01T08:30:00Z")
        let secondOneThirty = date("2026-11-01T09:30:00Z")
        XCTAssertEqual(ReadingDay(firstOneThirty, in: west), ReadingDay(secondOneThirty, in: west))
        XCTAssertEqual(secondOneThirty.timeIntervalSince(firstOneThirty), 3_600)
    }

    func testAtomicDraftPersistenceRepeatedSaveAndWriteFailure() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = LibraryStore(url: url.appendingPathComponent("library.json"))
        var draft = SessionDraft(book: book, page: nil, sample: sample(10))
        draft.stop(at: sample(71), zone: utc, total: 240)
        draft.ending?.pageText = "84"
        let initial = ReadingLibrary(books: [book], currentBookID: book.id, draft: draft)
        try await store.save(initial)
        let reopened = try await store.load()
        var loaded = try XCTUnwrap(reopened)
        XCTAssertEqual(loaded.draft?.ending?.pageText, "84")

        loaded.finishDraft(seconds: 61, page: 84)
        loaded.finishDraft(seconds: 61, page: 84)
        XCTAssertEqual(loaded.entries.map(\.id), [draft.id])
        XCTAssertNil(loaded.draft)
        XCTAssertEqual(loaded.page(for: book), 84)
        let blocked = LibraryStore(url: store.url.appendingPathComponent("bad-path"))
        do {
            try await blocked.save(loaded)
            XCTFail("Expected a file write error")
        } catch {
            let intact = try await store.load()
            XCTAssertEqual(intact?.draft, draft)
        }
        try await store.save(loaded)
        let saved = try await store.load()
        XCTAssertEqual(saved, loaded)
    }

    func testEditHistoryAndBookmarkOrdering() {
        let first = date("2026-11-17T12:00:00Z")
        let second = first.addingTimeInterval(7_200)
        var library = ReadingLibrary(books: [book], currentBookID: book.id)
        var old = makeEntry(end: first, kind: .manual, page: 50)
        library.append(old)
        library.append(makeEntry(end: second, startPage: 50, page: 84))
        old.edit(end: first, zone: utc, seconds: 1_800, page: 55)
        library.entries[0] = old
        XCTAssertEqual(library.page(for: book), 84)
        XCTAssertNil(old.startPage)
        library.append(makeEntry(end: second, kind: .bookmark, seconds: 0, startPage: 84, page: 73))
        XCTAssertEqual(library.page(for: book), 73)
        library.append(makeEntry(end: second.addingTimeInterval(600), startPage: 73, page: nil))
        XCTAssertEqual(library.page(for: book), 73)
        XCTAssertEqual(library.week(containing: ReadingDay(second, in: utc)).seconds, 1_920)
        XCTAssertEqual(makeEntry(end: second, startPage: 73, page: 73).advancedPages, 0)
        XCTAssertEqual(makeEntry(end: second, startPage: 73, page: 60).advancedPages, 0)
        XCTAssertEqual(makeEntry(end: second, page: 84).advancedPages, 0)
        XCTAssertFalse(makeEntry(end: second, seconds: 0, page: 74).counted)
    }

    func testMilestonesOnlyCountDistinctDaysWithTime() {
        let first = date("2026-10-01T12:00:00Z")
        var library = ReadingLibrary(books: [book], currentBookID: book.id)
        for day in 0..<30 {
            let end = first.addingTimeInterval(Double(day) * 86_400)
            library.append(makeEntry(end: end, kind: .bookmark, seconds: 0, page: 10))
            library.append(makeEntry(end: end, seconds: 0, page: 10))
            XCTAssertEqual(library.readingDays, day)
            library.append(makeEntry(end: end, page: 12))
            library.append(makeEntry(end: end, page: 13))
        }
        XCTAssertEqual(library.pendingMilestones, [7, 30])
        XCTAssertEqual(library.readingDays, 30)
        library.pendingMilestones.removeAll()
        library.updateMilestones()
        XCTAssertTrue(library.pendingMilestones.isEmpty)
    }

    func testUTF8CSVAndLocalizationFromHostlessBundle() throws {
        let named = Book(id: book.id, title: "春天,\"书\"\n第二行", initialPage: 1, totalPages: nil)
        var library = ReadingLibrary(books: [named], currentBookID: named.id)
        library.append(makeEntry(end: date("2026-11-20T12:00:00Z"), page: 10))
        let csv = try XCTUnwrap(String(data: ReadingCSV.data(library), encoding: .utf8))
        XCTAssertTrue(csv.contains("\"春天,\"\"书\"\"\n第二行\""))
        XCTAssertTrue(csv.contains("\"2026-11-20\",\"\(utc.identifier)\",\"60\""))
        XCTAssertTrue(csv.hasSuffix("\r\n"))
        XCTAssertNotEqual(L.t("home.start"), "home.start")
        XCTAssertNotEqual(EntryKind.timed.title, "kind.timed")
    }

    func testGoalCodeAndInputValidation() {
        XCTAssertEqual(GoalCode.make(90), "READWEEK1-090")
        XCTAssertEqual(GoalCode.parse("  READWEEK1-090\n"), 90)
        XCTAssertEqual(GoalCode.parse(GoalCode.make(5)), 5)
        XCTAssertEqual(GoalCode.parse(GoalCode.make(10_080)), 10_080)
        for invalid in ["READWEEK2-090", "READWEEK1-004", "READWEEK1-10081",
                        "READWEEK1--090", "READWEEK1-９０", "READWEEK1-090-PrivateBook"] {
            XCTAssertNil(GoalCode.parse(invalid), invalid)
        }
        XCTAssertNil(ReadingInput.positive("0"))
        XCTAssertNil(ReadingInput.positive("-2"))
        XCTAssertNil(ReadingInput.positive("1.5"))
        XCTAssertEqual(ReadingInput.positive("１０２"), 102)
        XCTAssertNil(ReadingInput.duration("0:99:00"))
    }

    @MainActor
    func testAnonymousPNGHasReadableDownloadQRAndNoPrivateMetadata() throws {
        let monday = ReadingDay(date("2026-11-16T12:00:00Z"), in: utc)
        let secret = "PRIVATE-TITLE-84"
        let privateBook = Book(title: secret, initialPage: 84, totalPages: nil)
        let week = WeekSummary(monday: monday, seconds: 6_120, days: [monday], bookIDs: [privateBook.id])
        var card = CardContent(summary: week, milestone: nil)
        let png = ReadingCard.png(card, productID: "123456789")
        XCTAssertFalse(card.caption.contains(secret))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        XCTAssertEqual(metadata[kCGImagePropertyPixelWidth as String] as? Int, 1_080)
        XCTAssertEqual(metadata[kCGImagePropertyPixelHeight as String] as? Int, 1_350)
        XCTAssertNil(metadata[kCGImagePropertyGPSDictionary as String])
        let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertNil(exif[kCGImagePropertyExifLensModel as String])
        XCTAssertNil(png.range(of: Data(secret.utf8)))
        let image = try XCTUnwrap(CIImage(data: png))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                              options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let feature = try XCTUnwrap(detector.features(in: image).compactMap { $0 as? CIQRCodeFeature }.first)
        XCTAssertEqual(feature.messageString, "https://apps.apple.com/app/id123456789")
        XCTAssertEqual(StoreLink.download(for: nil).absoluteString, "https://apps.apple.com/")
        card.titles = [privateBook.title]
        XCTAssertNotEqual(ReadingCard.png(card, productID: "123456789"), png)
        XCTAssertFalse(card.caption.contains(secret))
    }

    func testTrialBoundaryPaidTransitionVerifiedReceiptAndRestore() {
        let first = date("2026-09-17T12:00:00Z")
        let paidStart = date("2026-11-20T12:00:00Z")
        var state = Entitlement(firstOpen: first, proStartedAt: paidStart)
        XCTAssertEqual(state.trialStart, paidStart)
        XCTAssertTrue(state.hasPro(at: paidStart, free: false))
        XCTAssertTrue(state.hasPro(at: paidStart.addingTimeInterval(30 * 86_400 - 1), free: false))
        XCTAssertFalse(state.hasPro(at: paidStart.addingTimeInterval(30 * 86_400), free: false))
        XCTAssertTrue(state.hasPro(at: paidStart.addingTimeInterval(90 * 86_400), free: true))
        let existingReceipt = paidStart.addingTimeInterval(-10 * 86_400)
        state.applyVerifiedTrial(existingReceipt)
        state.applyVerifiedTrial(paidStart.addingTimeInterval(86_400))
        XCTAssertEqual(state.trialStart, existingReceipt)
        XCTAssertFalse(state.hasPro(at: paidStart.addingTimeInterval(20 * 86_400), free: false))
        state.applyVerifiedPro(revoked: false)
        XCTAssertTrue(state.hasPro(at: paidStart.addingTimeInterval(90 * 86_400), free: false))
        state.applyVerifiedPro(revoked: true)
        XCTAssertFalse(state.hasPro(at: paidStart.addingTimeInterval(90 * 86_400), free: false))
        XCTAssertEqual(Entitlement(firstOpen: first).trialStart, first)
    }

    func testExpiredStillFinishesDraftAndProducesCSV() {
        let time = date("2026-11-20T12:00:00Z")
        XCTAssertFalse(Entitlement(firstOpen: time.addingTimeInterval(-31 * 86_400)).hasPro(at: time, free: false))
        var draft = SessionDraft(book: book, page: 84, sample: sample(1, wall: time))
        draft.stop(at: sample(121, wall: time.addingTimeInterval(120)), zone: utc, total: 240)
        var library = ReadingLibrary(books: [book], currentBookID: book.id, draft: draft)
        library.finishDraft(seconds: 120, page: 102)
        XCTAssertEqual(library.page(for: book), 102)
        XCTAssertTrue(String(decoding: ReadingCSV.data(library), as: UTF8.self).contains("\"120\",\"84\",\"102\""))
    }

    private func makeEntry(end: Date, kind: EntryKind = .timed, zone: TimeZone? = nil, seconds: Int = 60,
                           startPage: Int? = nil, page: Int?) -> ReadingEntry {
        ReadingEntry(bookID: book.id, kind: kind, startedAt: end.addingTimeInterval(-Double(seconds)),
                     endedAt: end, zone: zone ?? utc, seconds: seconds, startPage: startPage, endPage: page)
    }
}
