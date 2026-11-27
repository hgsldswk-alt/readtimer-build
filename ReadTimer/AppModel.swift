import Combine
import Foundation
import StoreKit
import UIKit

struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var library = ReadingLibrary()
    @Published private(set) var ready = false
    @Published private(set) var saving = false
    @Published private(set) var entitlement: Entitlement?
    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasing = false
    @Published private(set) var savedEntryID: UUID?
    @Published var error: String?
    @Published var purchaseMessage: String?
    @Published var shareRequested = false
    @Published var sharing: SharePayload?

    private var store: LibraryStore?
    private var loading = false
    private var draftInputRevision = 0
    private let vault = EntitlementVault()
    private var entitlementRefresh = 0
    private var preparingStoreKit = false
    private var purchaseListener: Task<Void, Never>?
    private var reviewEligible = false

    var hasPro: Bool { Launch.isFree || entitlement?.hasPro(at: ReadingClock.now) == true }
    var today: ReadingDay { ReadingDay(ReadingClock.now, in: ReadingClock.zone) }
    var week: WeekSummary { library.week(containing: today) }
    var price: String? {
        if Launch.testing && Launch.has("-paywall") { return L.t("paid.fixturePrice") }
        return products.first { $0.id == Launch.proID }?.displayPrice
    }
    var trialAvailable: Bool {
        entitlement?.trialClaimedAt == nil && entitlement?.purchasedPro != true
            && entitlement.map { ReadingClock.now < $0.trialEnd } == true
    }

    func load() async {
        guard !ready, !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        let store = LibraryStore.open()
        self.store = store
        do {
            let existing = try await store.load(reset: Launch.testing && Launch.has("-reset"))
            var loaded = existing ?? (Launch.demo ? Self.seed() : ReadingLibrary())
            if loaded.draft?.state == .running {
                loaded.draft?.checkpoint(at: ReadingClock.sample())
            }
            if (existing != nil || Launch.demo) && loaded != existing { try await store.save(loaded) }
            library = loaded
            ready = true
        } catch { self.error = L.t("error.load") }
    }

    func startStoreKit() async {
        guard !Launch.isFree, entitlement == nil, !preparingStoreKit else { return }
        preparingStoreKit = true
        defer { preparingStoreKit = false }
        if Launch.testing {
            let now = ReadingClock.now
            let start = Launch.has("-expired") ? now.addingTimeInterval(-31 * 86_400) : now
            entitlement = Entitlement(firstOpen: start, proStartedAt: start)
            return
        }
        do {
            entitlement = try await vault.load(at: ReadingClock.now)
        } catch {
            purchaseMessage = L.t("error.entitlement")
            return
        }
        purchaseListener = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard !Task.isCancelled else { return }
                guard let self, case .verified(let transaction) = result else { continue }
                guard self.accepts(transaction) else { continue }
                if await self.apply(transaction) { await transaction.finish() }
            }
        }
        await refreshPurchases()
    }

    private func accepts(_ transaction: StoreKit.Transaction) -> Bool {
        transaction.productID == Launch.proID || transaction.productID == Launch.trialID
    }

    @discardableResult
    private func apply(_ transaction: StoreKit.Transaction) async -> Bool {
        guard var updated = entitlement else { return false }
        if transaction.productID == Launch.proID {
            updated.applyVerifiedPro(revoked: transaction.revocationDate != nil)
        } else if transaction.revocationDate == nil {
            updated.applyVerifiedTrial(transaction.originalPurchaseDate)
        }
        return await storeEntitlement(updated)
    }

    private func storeEntitlement(_ updated: Entitlement) async -> Bool {
        entitlementRefresh += 1
        let revision = entitlementRefresh
        entitlement = updated
        do {
            try await vault.save(updated, revision: revision)
            return true
        } catch {
            purchaseMessage = L.t("error.entitlement")
            return false
        }
    }

    func refreshPurchases(afterSync: Bool = false) async {
        guard !Launch.isFree, !Launch.testing else { return }
        let generation = entitlementRefresh
        var pro: Bool?
        var verifiedDate: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == Launch.proID { pro = true }
            if transaction.productID == Launch.trialID { verifiedDate = transaction.originalPurchaseDate }
        }
        if pro == nil, let result = await StoreKit.Transaction.latest(for: Launch.proID),
           case .verified(let transaction) = result {
            pro = transaction.revocationDate == nil
        }
        guard generation == entitlementRefresh, var updated = entitlement else { return }
        if let pro { updated.applyVerifiedPro(revoked: !pro) }
        else if afterSync { updated.applyVerifiedPro(revoked: true) }
        if let verifiedDate { updated.applyVerifiedTrial(verifiedDate) }
        if updated != entitlement { _ = await storeEntitlement(updated) }
    }

    func loadProducts() async {
        guard !Launch.isFree, !Launch.testing else { return }
        if entitlement == nil { await startStoreKit() }
        do { products = try await Product.products(for: [Launch.proID, Launch.trialID]) }
        catch { purchaseMessage = L.t("error.products") }
    }

    func purchase(_ id: String) async {
        guard !Launch.isFree, !Launch.testing, !purchasing,
              let product = products.first(where: { $0.id == id }),
              id != Launch.trialID || trialAvailable else { return }
        purchasing = true
        purchaseMessage = nil
        defer { purchasing = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let transaction)):
                if await apply(transaction) {
                    await transaction.finish()
                    purchaseMessage = L.t(id == Launch.trialID ? "paid.claimed" : "paid.unlocked")
                }
            case .success(.unverified): purchaseMessage = L.t("error.verify")
            case .pending: purchaseMessage = L.t("paid.pending")
            case .userCancelled: break
            @unknown default: break
            }
        } catch { purchaseMessage = L.t("error.purchase") }
    }

    func restore() async {
        guard !Launch.isFree, !Launch.testing, !purchasing else { return }
        purchasing = true
        purchaseMessage = nil
        defer { purchasing = false }
        do {
            if entitlement == nil { await startStoreKit() }
            guard entitlement != nil else { return }
            try await AppStore.sync()
            await refreshPurchases(afterSync: true)
            if purchaseMessage == nil {
                let restored = entitlement?.purchasedPro == true || entitlement?.trialClaimedAt != nil
                purchaseMessage = L.t(restored ? "paid.restored" : "paid.noPurchase")
            }
        } catch { purchaseMessage = L.t("error.restore") }
    }

    @discardableResult
    private func commit(_ next: ReadingLibrary) async -> Bool {
        guard ready, !saving, let store else { return false }
        saving = true
        defer { saving = false }
        do {
            try await store.save(next)
            library = next
            error = nil
            return true
        } catch {
            self.error = L.t("error.save")
            return false
        }
    }

    func select(_ book: Book) async -> Bool {
        guard library.draft == nil else { return false }
        var next = library
        next.currentBookID = book.id
        return await commit(next)
    }

    func add(_ book: Book) async -> Bool {
        guard library.draft == nil else { return false }
        var next = library
        next.books.append(book)
        next.currentBookID = book.id
        return await commit(next)
    }

    func start() async {
        guard let book = library.selected, library.draft == nil else { return }
        var next = library
        let seedSeconds: TimeInterval = Launch.demo && Launch.has("-store-shots") ? 1_458 : 0
        next.draft = SessionDraft(book: book, page: library.page(for: book),
                                  sample: ReadingClock.sample(), accumulated: seedSeconds)
        if await commit(next) { savedEntryID = nil }
    }

    func pauseOrResume() async {
        guard let draft = library.draft, draft.state != .pending else { return }
        var next = library
        let sample = ReadingClock.sample()
        if draft.state == .running { next.draft?.pause(at: sample) }
        else { next.draft?.resume(at: sample) }
        await commit(next)
    }

    func end() async {
        guard let draft = library.draft, draft.state != .pending else { return }
        var next = library
        next.draft?.stop(at: ReadingClock.sample(), zone: ReadingClock.zone, total: library.book(draft.bookID)?.totalPages)
        if Launch.demo && Launch.has("-store-shots"),
           let page = ProcessInfo.processInfo.environment["READTIMER_SHOT_PAGE"] {
            next.draft?.ending?.pageText = page
        }
        await commit(next)
    }

    func checkpoint() {
        guard ready, !saving, let store, library.draft?.state == .running else { return }
        var next = library
        next.draft?.checkpoint(at: ReadingClock.sample())
        library = next
        store.enqueue(next) { _ in }
    }

    func persistInput(_ input: SessionDraft.Ending) {
        guard !saving, let store, library.draft?.state == .pending,
              library.draft?.ending != input else { return }
        library.draft?.ending = input
        draftInputRevision += 1
        let revision = draftInputRevision
        store.enqueue(library) { [weak self] result in
            Task { @MainActor in
                guard let self, self.draftInputRevision == revision, !self.saving,
                      self.library.draft?.state == .pending else { return }
                switch result {
                case .success: self.error = nil
                case .failure: self.error = L.t("error.save")
                }
            }
        }
    }

    func saveEntry(_ entry: ReadingEntry, updatedTotal: Int?, finishing: Bool) async -> Bool {
        guard let bookIndex = library.books.firstIndex(where: { $0.id == entry.bookID }) else { return false }
        var next = library
        if let updatedTotal { next.books[bookIndex].totalPages = updatedTotal }
        if finishing {
            guard next.draft?.id == entry.id else { return false }
            next.finishDraft(seconds: entry.seconds, page: entry.endPage)
        } else if let index = next.entries.firstIndex(where: { $0.id == entry.id }) {
            next.entries[index] = entry
            next.updateMilestones()
        } else {
            next.append(entry)
        }
        let newEntry = finishing || !library.entries.contains(where: { $0.id == entry.id })
        guard await commit(next) else { return false }
        if newEntry { CoreReview.shared.record() }
        savedEntryID = entry.id
        return true
    }

    func delete(_ id: UUID) async -> Bool {
        var next = library
        next.entries.removeAll { $0.id == id }
        guard await commit(next) else { return false }
        if savedEntryID == id { savedEntryID = nil }
        return true
    }

    func discardDraft() async -> Bool {
        var next = library
        next.draft = nil
        return await commit(next)
    }

    func saveGoal(_ minutes: Int, imported: Bool) async -> Bool {
        guard imported || hasPro, GoalCode.range.contains(minutes) else { return false }
        var next = library
        next.goalMinutes = minutes
        return await commit(next)
    }

    func dismissMilestone(_ days: Int) async -> Bool {
        var next = library
        next.pendingMilestones.removeAll { $0 == days }
        return await commit(next)
    }

    func offerMilestoneReview(allowed: Bool, _ request: () -> Void) {
        guard !Launch.testing, allowed, ready, !saving, error == nil, library.draft == nil,
              !UserDefaults.standard.bool(forKey: "readTimer.reviewAsked") else { return }
        guard library.earnedMilestones.contains(7) else { return }
        if !reviewEligible, savedEntryID != nil {
            reviewEligible = true
            return
        }
        if CoreReview.shared.attempt(request) { UserDefaults.standard.set(true, forKey: "readTimer.reviewAsked") }
    }

    func requestShare(_ url: URL) {
        shareRequested = Launch.testing
        if !Launch.testing { sharing = SharePayload(url: url) }
    }

    func exportCSV() async {
        let snapshot = library
        error = nil
        shareRequested = false
        do {
            let url = try await Task.detached(priority: .userInitiated) {
                try ExportFile.write(ReadingCSV.data(snapshot), fileName: "reading-history.csv")
            }.value
            requestShare(url)
        } catch { self.error = L.t("error.export") }
    }

    private static func seed() -> ReadingLibrary {
        let sample = ReadingClock.sample()
        let book = Book(title: L.t("demo.book"), initialPage: 57, totalPages: 240)
        var seeded = ReadingLibrary(books: [book], currentBookID: book.id)
        let monday = ReadingDay(sample.wall, in: ReadingClock.zone).monday
        let examples = [(25, 57, 65), (30, 65, 74), (22, 74, 74), (25, 74, 84)]
        for (index, row) in examples.enumerated() {
            let end = monday.adding(days: index).date.addingTimeInterval(19 * 3_600)
            seeded.append(ReadingEntry(bookID: book.id, kind: index == 1 ? .manual : .timed,
                                       startedAt: end.addingTimeInterval(-Double(row.0 * 60)),
                                       endedAt: end, zone: ReadingClock.zone, seconds: row.0 * 60,
                                       startPage: row.1, endPage: row.2))
        }
        seeded.append(ReadingEntry(bookID: book.id, kind: .bookmark, startedAt: sample.wall,
                                   endedAt: sample.wall, zone: ReadingClock.zone, seconds: 0,
                                   startPage: 84, endPage: 84))
        return seeded
    }
}

enum ExportFile {
    static func write(_ data: Data, fileName: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName)
        try data.write(to: url, options: .atomic)
        return url
    }
}
