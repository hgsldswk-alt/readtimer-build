import StoreKit
import SwiftUI

@main
struct ReadTimerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .tint(Design.green)
                .foregroundStyle(Design.ink)
        }
    }
}

private enum HomeSheet: Identifiable {
    case books, addBook, finish, bookmark(Book), edit(ReadingEntry), history, settings, sharing(Int?), paywall

    var id: String {
        switch self {
        case .books: return "books"
        case .addBook: return "add"
        case .finish: return "finish"
        case .bookmark(let book): return "bookmark-\(book.id)"
        case .edit(let entry): return "edit-\(entry.id)"
        case .history: return "history"
        case .settings: return "settings"
        case .sharing(let days): return "share-\(days ?? 0)"
        case .paywall: return "paywall"
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    @Environment(\.requestReview) private var requestReview
    @State private var sheet: HomeSheet?
    @State private var started = false
    @State private var reviewTask: Task<Void, Never>?
    @ScaledMetric(relativeTo: .largeTitle) private var pageSize: CGFloat = 76
    @ScaledMetric(relativeTo: .largeTitle) private var timerSize: CGFloat = 83

    var body: some View {
        ZStack {
            Design.paper.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if !model.ready { loading }
                    else if let draft = model.library.draft {
                        if let book = model.library.book(draft.bookID) { timing(draft, book: book) }
                    } else if let book = model.library.selected {
                        home(book)
                    } else {
                        Button(L.t("home.add")) { show(.addBook) }.buttonStyle(ReadingButton(primary: true))
                            .padding(.top, 20).accessibilityIdentifier("home.add")
                    }
                    if sheet == nil { MessageLine(text: model.error, warning: true).padding(.top, 10) }
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 22)
                .frame(maxWidth: 540)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.library.draft == nil, let id = model.savedEntryID,
               let entry = model.library.entries.first(where: { $0.id == id }) {
                savedBanner(entry)
            }
        }
        .reviewAfterCoreAction(when: model.ready && !model.saving && model.error == nil && model.library.draft == nil && sheet == nil && model.sharing == nil) { requestReview() }
        .sheet(item: $sheet, onDismiss: scheduleReview) { route in
            sheetContent(route)
                .background(Design.paper)
                .presentationDragIndicator(.visible)
                .presentationBackground(Design.paper)
        }
        .task {
            await model.load()
            openInitialScreen()
        }
        .task { await model.startStoreKit() }
        .task(id: phase) {
            if phase == .active {
                scheduleReview()
                guard !Launch.testing else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) }
                    catch { return }
                    model.checkpoint()
                }
            } else { model.checkpoint() }
        }
        .onChange(of: model.library.draft?.state) { _, state in
            if state == .pending { show(.finish) }
        }
        .onChange(of: model.ready) { _, ready in
            if ready { openInitialScreen() }
        }
    }

    private var header: some View {
        HStack {
            Text(L.t("app.shortName")).font(.title3.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if model.ready && model.library.draft == nil {
                Button(L.t("home.settings")) { show(.settings) }
                    .buttonStyle(QuietButton()).accessibilityIdentifier("home.settings")
            }
        }.frame(minHeight: 52)
    }

    @ViewBuilder private var loading: some View {
        if model.error == nil { ProgressView().padding(.top, 20) }
        else {
            Button(L.t("common.retry")) { Task { await model.load() } }
                .buttonStyle(ReadingButton()).accessibilityIdentifier("home.retry")
        }
    }

    private func home(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            bookCard(book).padding(.top, 17)
            Button(L.t("home.start")) { Task { await model.start() } }
                .buttonStyle(ReadingButton(primary: true)).padding(.top, 16)
                .accessibilityIdentifier("home.start")
            HStack(spacing: 10) {
                Button(L.t("home.bookmark")) { show(.bookmark(book)) }
                    .buttonStyle(ReadingButton(compact: true)).accessibilityIdentifier("home.bookmark")
                Button(L.t("home.history")) { show(.history) }
                    .buttonStyle(ReadingButton(compact: true)).accessibilityIdentifier("home.history")
            }.padding(.top, 10)
            weekCard.padding(.top, 26)
            if let milestone = model.library.pendingMilestones.first {
                HStack(spacing: 8) {
                    Button(L.f("milestone.earned", milestone)) { show(.sharing(milestone)) }
                        .buttonStyle(QuietButton()).accessibilityIdentifier("home.milestone")
                    Spacer(minLength: 0)
                    Button {
                        Task { await model.dismissMilestone(milestone) }
                    } label: {
                        Image(systemName: "xmark").frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).accessibilityLabel(L.t("common.close"))
                    .accessibilityIdentifier("home.dismissMilestone")
                }
                .padding(.horizontal, 8)
                .background(Design.pale, in: RoundedRectangle(cornerRadius: 14))
                .padding(.top, 12)
            }
        }
    }

    private func savedBanner(_ entry: ReadingEntry) -> some View {
        HStack {
            Text(L.t("home.saved")).font(.subheadline)
            Spacer()
            Button(L.t("common.edit")) { show(.edit(entry)) }
                .buttonStyle(QuietButton()).accessibilityIdentifier("home.editSaved")
        }
        .padding(.horizontal, 14)
        .background(Design.pale, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: 500)
        .padding(.horizontal, 23)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Design.paper)
    }

    private func bookCard(_ book: Book) -> some View {
        let page = model.library.page(for: book)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L.t("home.reading")).font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Design.soft)
                Spacer()
                Button(L.t("home.switch")) { show(.books) }
                    .buttonStyle(QuietButton(color: Design.cream))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Design.soft.opacity(0.42)))
                    .accessibilityIdentifier("home.switch")
            }
            Text(book.title).font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 11)
                .accessibilityIdentifier("home.book")
            cardRule.padding(.top, 20).padding(.bottom, 16)
            Text(L.t("home.lastPage")).font(.footnote).foregroundStyle(Design.soft)
            if let page {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(page, format: .number.grouping(.never))
                        .font(.system(size: pageSize, weight: .semibold)).tracking(-3)
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.35)
                        .accessibilityIdentifier("home.page")
                    Text(L.t("home.pageUnit")).font(.subheadline)
                }
            } else {
                Text(L.t("home.noPage")).font(.title3.bold()).padding(.top, 9)
                    .accessibilityIdentifier("home.page")
            }
            if let total = book.totalPages {
                ProgressView(value: Double(page ?? 0), total: Double(total))
                    .tint(Design.soft).padding(.top, 13)
                    .accessibilityLabel(L.t("home.progress"))
                Text(L.f("home.total", total)).font(.caption).foregroundStyle(Design.soft)
                    .frame(maxWidth: .infinity, alignment: .trailing).padding(.top, 10)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
        .frame(maxWidth: .infinity, minHeight: 314, alignment: .topLeading)
        .background(Design.dark, in: RoundedRectangle(cornerRadius: 25))
        .foregroundStyle(Design.cream)
    }

    private var weekCard: some View {
        let week = model.week
        return VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center) {
                    weekTitle(week).fixedSize(horizontal: true, vertical: false)
                    Spacer()
                    weekShare(week)
                }
                VStack(alignment: .leading, spacing: 3) {
                    weekTitle(week)
                    weekShare(week)
                }
            }
            if let goal = model.library.goalMinutes {
                ProgressView(value: min(Double(week.seconds), Double(goal * 60)), total: Double(goal * 60))
                    .accessibilityLabel(L.t("goal.title"))
                Text(L.f("goal.progress", week.seconds / 60, goal)).font(.caption).foregroundStyle(Design.muted)
                    .accessibilityIdentifier("home.goalProgress")
            }
        }.modifier(PaperCard())
    }

    private func weekTitle(_ week: WeekSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L.t("home.week")).font(.footnote.weight(.semibold)).foregroundStyle(Design.muted)
            Text(L.duration(week.seconds)).font(.title3.weight(.bold)).monospacedDigit()
                .accessibilityIdentifier("home.weekTotal")
        }
    }

    private func weekShare(_ week: WeekSummary) -> some View {
        Button(L.t("share.week")) { show(.sharing(nil)) }.buttonStyle(QuietButton())
            .disabled(week.days.isEmpty).accessibilityIdentifier("home.share")
    }

    private var cardRule: some View { Rectangle().fill(Design.soft.opacity(0.28)).frame(height: 1) }

    private func timing(_ draft: SessionDraft, book: Book) -> some View {
        let paused = draft.state == .paused
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Design.soft).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(L.t(paused ? "timer.paused" : "timer.running"))
                        .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Design.soft)
                        .accessibilityIdentifier("timer.status")
                }
                Text(book.title).font(.title2.weight(.bold)).padding(.top, 15)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(L.clock(draft.seconds(at: ReadingClock.sample())))
                        .font(.system(size: timerSize, weight: .semibold)).monospacedDigit().tracking(-4)
                        .lineLimit(1).minimumScaleFactor(0.38)
                        .accessibilityIdentifier("timer.elapsed")
                }.padding(.top, 40)
                Text(L.t("timer.elapsed")).font(.footnote).foregroundStyle(Design.soft)
                Spacer(minLength: 30)
                cardRule.padding(.bottom, 16)
                HStack {
                    Text(L.t("timer.startPage")).font(.footnote).foregroundStyle(Design.soft)
                    Spacer()
                    Text(draft.startPage.map { L.f("page.number", $0) } ?? L.t("home.noPage")).font(.headline)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 23)
            .frame(minHeight: 365)
            .background(Design.dark, in: RoundedRectangle(cornerRadius: 25))
            .foregroundStyle(Design.cream)
            .padding(.top, 17)
            if draft.state != .pending {
                Button(L.t("timer.end")) { Task { await model.end() } }
                    .buttonStyle(ReadingButton(primary: true)).padding(.top, 18)
                    .accessibilityIdentifier("timer.end")
                Button(L.t(paused ? "timer.resume" : "timer.pause")) { Task { await model.pauseOrResume() } }
                    .buttonStyle(ReadingButton()).padding(.top, 10)
                    .accessibilityIdentifier(paused ? "timer.resume" : "timer.pause")
                Text(L.t(draft.needsDurationReview ? "timer.clockReview" : paused ? "timer.pausedNote" : "timer.lockNote"))
                    .font(.footnote).foregroundStyle(Design.muted).padding(.top, 22)
            }
        }
    }

    private func show(_ route: HomeSheet) {
        reviewTask?.cancel()
        model.error = nil
        model.shareRequested = false
        sheet = route
    }

    @ViewBuilder private func sheetContent(_ route: HomeSheet) -> some View {
        switch route {
        case .books: BooksView { sheet = nil }
        case .addBook: BookEditor { sheet = nil }
        case .finish:
            if let draft = model.library.draft, let book = model.library.book(draft.bookID), draft.ending != nil {
                EntryEditor(mode: .finish(draft), book: book) { sheet = nil }
                    .interactiveDismissDisabled()
            }
        case .bookmark(let book): EntryEditor(mode: .bookmark, book: book) { sheet = nil }
        case .edit(let entry):
            if let book = model.library.book(entry.bookID) {
                EntryEditor(mode: .edit(entry), book: book) { sheet = nil }
            }
        case .history: HistoryView { sheet = nil }
        case .settings: SettingsView { sheet = nil }
        case .sharing(let days): SharePreview(milestone: days) { sheet = nil }
        case .paywall: PaywallView { sheet = nil }
        }
    }

    private func scheduleReview() {
        guard model.ready, !Launch.testing else { return }
        reviewTask?.cancel()
        reviewTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            let idle = phase == .active && sheet == nil && model.sharing == nil
            if !Task.isCancelled { model.offerMilestoneReview(allowed: idle) { requestReview() } }
        }
    }

    private func openInitialScreen() {
        guard model.ready, !started else { return }
        started = true
        if model.library.draft?.state == .pending { show(.finish) }
        else if Launch.testing && Launch.has("-paywall") { show(.paywall) }
        else { scheduleReview() }
    }
}
