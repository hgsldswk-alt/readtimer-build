import SwiftUI

struct BooksView: View {
    @EnvironmentObject private var model: AppModel
    @State private var adding = false
    @State private var pickedNewBook = false
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("home.switch"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 1) {
                        ForEach(model.library.books) { book in
                            Button {
                                Task { if await model.select(book) { close() } }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(book.title).font(.headline)
                                        Text(model.library.page(for: book).map { L.f("page.number", $0) } ?? L.t("home.noPage"))
                                            .font(.footnote).foregroundStyle(Design.muted)
                                    }
                                    Spacer()
                                    if book.id == model.library.currentBookID {
                                        Image(systemName: "checkmark").foregroundStyle(Design.green).accessibilityHidden(true)
                                    }
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .frame(minHeight: 54).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("books.select.\(book.id)")
                        }
                    }.background(Design.white, in: RoundedRectangle(cornerRadius: 14))
                    Button(L.t("books.add")) { adding = true }.buttonStyle(ReadingButton())
                        .accessibilityIdentifier("books.add")
                    MessageLine(text: model.error, warning: true)
                }.padding(22)
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $adding, onDismiss: { if pickedNewBook { close() } }) {
            BookEditor {
                pickedNewBook = true
                adding = false
            }
        }
    }
}

struct BookEditor: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var nameFocused: Bool
    @State private var title = ""
    @State private var page = ""
    @State private var total = ""
    @State private var validation: String?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("books.add"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    InputField(title: L.t("book.name"), placeholder: L.t("book.name"), id: "book.name",
                               text: $title, focus: $nameFocused)
                    InputField(title: L.t("book.current"), placeholder: L.t("common.optional"),
                               id: "book.page", text: $page, keyboard: .numberPad)
                    InputField(title: L.t("book.total"), placeholder: L.t("common.optional"),
                               id: "book.total", text: $total, keyboard: .numberPad)
                    MessageLine(text: validation ?? model.error, warning: true)
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
            Button(L.t("common.save"), action: save).buttonStyle(ReadingButton(primary: true))
                .disabled(model.saving).accessibilityIdentifier("book.save")
                .padding(.horizontal, 22).padding(.vertical, 9)
        }
        .background(Design.paper)
        .presentationDragIndicator(.visible)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled { nameFocused = true }
        }
    }

    private func save() {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = ReadingInput.positive(page)
        let limit = ReadingInput.positive(total)
        guard !name.isEmpty else { validation = L.t("error.bookName"); return }
        guard (page.isEmpty || start != nil), (total.isEmpty || limit != nil) else {
            validation = L.t("error.page")
            return
        }
        if let start, let limit, start > limit {
            validation = L.t("error.bookLimit")
            return
        }
        validation = nil
        Task {
            if await model.add(Book(title: name, initialPage: start, totalPages: limit)) { close() }
        }
    }
}

struct EntryEditor: View {
    enum Mode {
        case finish(SessionDraft), bookmark, manual, edit(ReadingEntry)
        var kind: EntryKind {
            switch self {
            case .finish: return .timed
            case .manual: return .manual
            case .bookmark: return .bookmark
            case .edit(let entry): return entry.kind
            }
        }
        var title: String {
            switch self {
            case .finish: return L.t("entry.finish")
            case .manual: return L.t("entry.manual")
            case .bookmark: return L.t("home.bookmark")
            case .edit: return L.t("entry.edit")
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @FocusState private var pageFocused: Bool
    @State private var page: String
    @State private var duration: String
    @State private var total: String
    @State private var endDate: Date
    @State private var showDuration = false
    @State private var confirmDelete = false
    @State private var validation: String?

    let mode: Mode
    let book: Book
    let close: () -> Void

    init(mode: Mode, book: Book, close: @escaping () -> Void) {
        self.mode = mode
        self.book = book
        self.close = close
        let originalTotal = book.totalPages.map { String($0) } ?? ""
        switch mode {
        case .finish(let draft):
            _page = State(initialValue: draft.ending?.pageText ?? "")
            _duration = State(initialValue: draft.ending?.durationText ?? "")
            _total = State(initialValue: draft.ending?.totalText ?? originalTotal)
            _endDate = State(initialValue: draft.ending?.date ?? ReadingClock.now)
            _showDuration = State(initialValue: draft.needsDurationReview)
        case .edit(let entry):
            _page = State(initialValue: entry.endPage.map { String($0) } ?? "")
            _duration = State(initialValue: L.clock(entry.seconds, forceHours: true))
            _total = State(initialValue: originalTotal)
            _endDate = State(initialValue: entry.endedAt)
        case .bookmark, .manual:
            _page = State(initialValue: "")
            _duration = State(initialValue: "")
            _total = State(initialValue: originalTotal)
            _endDate = State(initialValue: ReadingClock.now)
        }
    }

    private var finishing: Bool { if case .finish = mode { return true }; return false }
    private var editing: Bool { if case .edit = mode { return true }; return false }
    private var changesDate: Bool { editing || mode.kind == .manual }
    private var zone: TimeZone {
        if case .edit(let entry) = mode { return TimeZone(identifier: entry.zoneID) ?? ReadingClock.zone }
        if case .finish(let draft) = mode, let id = draft.ending?.zoneID {
            return TimeZone(identifier: id) ?? ReadingClock.zone
        }
        return ReadingClock.zone
    }
    private var overLimit: Bool {
        guard let limit = book.totalPages, let parsedPage = ReadingInput.positive(page) else { return false }
        return parsedPage > limit
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: mode.title, close: closeEditor)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(book.title).font(.headline).accessibilityIdentifier("entry.book")
                    if finishing { finishSummary }
                    InputField(title: L.t("entry.page"), placeholder: L.t("entry.page"), id: "entry.page",
                               text: $page, keyboard: .numberPad, focus: $pageFocused)
                    if overLimit || total != (book.totalPages.map { String($0) } ?? "") {
                        Text(L.t("error.overTotal")).font(.footnote).foregroundStyle(Design.danger)
                        InputField(title: L.t("book.total"), placeholder: L.t("book.total"), id: "entry.total",
                                   text: $total, keyboard: .numberPad)
                    }
                    if mode.kind != .bookmark && (!finishing || showDuration) {
                        InputField(title: L.t("entry.duration"), placeholder: L.t("entry.durationHint"),
                                   id: "entry.duration", text: $duration, keyboard: .numbersAndPunctuation)
                    }
                    if changesDate {
                        DatePicker(L.t("entry.date"), selection: $endDate, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.timeZone, zone).accessibilityIdentifier("entry.date")
                    }
                    MessageLine(text: validation ?? model.error, warning: true)
                    if editing {
                        Button(L.t("entry.delete"), role: .destructive) {
                            pageFocused = false
                            confirmDelete = true
                        }.buttonStyle(QuietButton(color: Design.danger)).accessibilityIdentifier("entry.delete")
                    }
                }.padding(.horizontal, 22).padding(.vertical, 17)
            }.scrollDismissesKeyboard(.interactively)
            saveBar
        }
        .background(Design.paper)
        .presentationDragIndicator(.visible)
        .onChange(of: page) { _, _ in persist() }
        .onChange(of: duration) { _, _ in persist() }
        .onChange(of: total) { _, _ in persist() }
        .task {
            if !editing && mode.kind != .manual && !(Launch.demo && Launch.has("-store-shots")) {
                if case .bookmark = mode, page.isEmpty, let current = model.library.page(for: book) { page = String(current) }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { pageFocused = true }
            }
        }
        .confirmationDialog(L.t(finishing ? "entry.discardTitle" : "entry.deleteTitle"),
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L.t(finishing ? "entry.discard" : "entry.delete"), role: .destructive, action: remove)
            Button(L.t("common.cancel"), role: .cancel) {}
        }
    }

    private var finishSummary: some View {
        HStack(spacing: 6) {
            Text(L.clock(ReadingInput.duration(duration) ?? 0)).font(.title2.weight(.bold)).monospacedDigit()
                .accessibilityIdentifier("entry.elapsed")
            Spacer(minLength: 0)
            Button(L.t("entry.adjustDuration")) {
                pageFocused = false
                withAnimation { showDuration.toggle() }
            }.buttonStyle(QuietButton()).accessibilityIdentifier("entry.adjustDuration")
        }.modifier(PaperCard())
    }

    private var saveBar: some View {
        let timeOnly = finishing && page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(L.t(timeOnly ? "entry.saveTime" : "common.save"), action: save)
            .buttonStyle(ReadingButton(primary: true)).disabled(model.saving)
            .accessibilityIdentifier("entry.save")
            .padding(.horizontal, 22).padding(.vertical, 9)
            .background(Design.paper)
    }

    private func persist() {
        validation = nil
        guard finishing, var input = model.library.draft?.ending else { return }
        input.pageText = page
        input.durationText = duration
        input.totalText = total
        model.persistInput(input)
    }

    private func save() {
        let trimmedPage = page.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPage = ReadingInput.positive(trimmedPage)
        guard parsedPage != nil || (trimmedPage.isEmpty && mode.kind != .bookmark) else {
            validation = L.t("error.page")
            return
        }
        let enteredDuration = mode.kind == .bookmark ? 0 : ReadingInput.duration(duration)
        guard let seconds = enteredDuration, seconds > 0 || mode.kind != .manual else {
            validation = L.t("error.duration")
            return
        }
        let previousTotal = book.totalPages.map { String($0) } ?? ""
        var updatedTotal: Int?
        if overLimit || total != previousTotal {
            let existingID: UUID?
            if case .edit(let entry) = mode { existingID = entry.id } else { existingID = nil }
            let minimum = max(model.library.maxLoggedPage(for: book, excluding: existingID), parsedPage ?? 0, startPage ?? 0)
            guard let valid = ReadingInput.positive(total), valid >= minimum else {
                validation = L.f("error.newTotal", minimum)
                return
            }
            updatedTotal = valid == book.totalPages ? nil : valid
        }
        let entry: ReadingEntry
        switch mode {
        case .finish(let draft):
            entry = ReadingEntry(id: draft.id, bookID: book.id, kind: .timed, startedAt: draft.startedAt,
                                 endedAt: endDate, zone: zone, seconds: seconds, startPage: draft.startPage, endPage: parsedPage)
        case .edit(var old):
            old.edit(end: endDate, zone: zone, seconds: seconds, page: parsedPage)
            entry = old
        case .manual, .bookmark:
            entry = ReadingEntry(bookID: book.id, kind: mode.kind, startedAt: endDate.addingTimeInterval(-Double(seconds)),
                                 endedAt: endDate, zone: zone, seconds: seconds, startPage: startPage, endPage: parsedPage)
        }
        validation = nil
        Task {
            if await model.saveEntry(entry, updatedTotal: updatedTotal, finishing: finishing) { close() }
        }
    }

    private var startPage: Int? {
        switch mode {
        case .finish(let draft): return draft.startPage
        case .edit(let entry): return entry.startPage
        case .manual:
            let latest = model.library.orderedEntries.first {
                $0.bookID == book.id && $0.endedAt <= endDate && $0.endPage != nil
            }
            return latest?.endPage ?? book.initialPage
        case .bookmark: return model.library.page(for: book)
        }
    }

    private func closeEditor() {
        if finishing {
            pageFocused = false
            confirmDelete = true
        } else { close() }
    }

    private func remove() {
        Task {
            if case .edit(let entry) = mode, await model.delete(entry.id) { close() }
            else if finishing, await model.discardDraft() { close() }
        }
    }
}
