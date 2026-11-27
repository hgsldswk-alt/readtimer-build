import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var currentOnly = false
    @State private var route: Route?
    let close: () -> Void

    private enum Route: Identifiable {
        case entry(ReadingEntry), manual(Book), weeks, books
        var id: String {
            switch self {
            case .entry(let entry): return entry.id.uuidString
            case .manual: return "manual"
            case .weeks: return "weeks"
            case .books: return "choose"
            }
        }
    }

    private var filter: UUID? { currentOnly ? model.library.currentBookID : nil }
    private var entries: [ReadingEntry] {
        model.library.orderedEntries.filter { filter == nil || $0.bookID == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("home.history"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    filters
                    summary
                    actions
                    ShareStatus()
                    MessageLine(text: model.error, warning: true)
                    historyList
                }.padding(.horizontal, 22).padding(.vertical, 13)
            }
        }
        .modifier(ShareHost())
        .sheet(item: $route) { value in
            Group {
                switch value {
                case .entry(let entry):
                    if let book = model.library.book(entry.bookID) {
                        EntryEditor(mode: .edit(entry), book: book) { route = nil }
                    }
                case .manual(let book): EntryEditor(mode: .manual, book: book) { route = nil }
                case .weeks: weeks
                case .books: chooseBook
                }
            }
            .background(Design.paper)
            .presentationDragIndicator(.visible)
            .presentationBackground(Design.paper)
        }
    }

    private var filters: some View {
        HStack(spacing: 9) {
            Button(L.t("history.all")) { currentOnly = false }
                .buttonStyle(ReadingButton(primary: !currentOnly, compact: true))
                .accessibilityAddTraits(!currentOnly ? .isSelected : [])
                .accessibilityIdentifier("history.all")
            Button(L.t("history.current")) { currentOnly = true }
                .buttonStyle(ReadingButton(primary: currentOnly, compact: true))
                .accessibilityAddTraits(currentOnly ? .isSelected : [])
                .disabled(model.library.selected == nil).accessibilityIdentifier("history.current")
        }
    }

    private var summary: some View {
        let week = model.library.week(containing: model.today, bookID: filter)
        return VStack(alignment: .leading, spacing: 5) {
            Text(L.t("home.week")).font(.footnote.weight(.semibold)).foregroundStyle(Design.muted)
            Text(L.duration(week.seconds)).font(.title2.bold()).monospacedDigit()
                .accessibilityIdentifier("history.weekTotal")
            Text(L.f("card.days", week.days.count)).font(.footnote).foregroundStyle(Design.muted)
        }.modifier(PaperCard())
    }

    private var actions: some View {
        VStack(spacing: 0) {
            if let book = model.library.selected {
                ActionRow(title: L.t("entry.manual"), id: "history.manual") {
                    show(!currentOnly && model.library.books.count > 1 ? .books : .manual(book))
                }
            }
            ActionRow(title: L.t("history.export"), id: "history.export") { Task { await model.exportCSV() } }
            if model.hasPro {
                ActionRow(title: L.t("history.weeks"), id: "history.weeks") {
                    if model.hasPro { show(.weeks) }
                }
            }
        }
        .background(Design.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Design.line).allowsHitTesting(false))
    }

    @ViewBuilder private var historyList: some View {
        let grouped = Dictionary(grouping: entries, by: \.day)
        if grouped.isEmpty {
            Text(L.t("history.empty")).font(.footnote).foregroundStyle(Design.muted)
                .accessibilityIdentifier("history.empty")
        }
        ForEach(grouped.keys.sorted(by: >)) { day in
            VStack(alignment: .leading, spacing: 6) {
                Text(day.label).font(.footnote.weight(.semibold)).foregroundStyle(Design.muted)
                    .accessibilityAddTraits(.isHeader)
                ForEach(grouped[day, default: []]) { entry in entryRow(entry) }
            }
        }
    }

    private func entryRow(_ entry: ReadingEntry) -> some View {
        Button { show(.entry(entry)) } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.library.book(entry.bookID)?.title ?? L.t("entry.missingBook")).font(.headline)
                    Text(entryDescription(entry)).font(.footnote).foregroundStyle(Design.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                    .foregroundStyle(Design.green).accessibilityHidden(true)
            }.modifier(PaperCard()).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("history.entry.\(entry.id)")
    }

    private func entryDescription(_ entry: ReadingEntry) -> String {
        var parts = [entry.kind.title]
        if entry.kind != .bookmark { parts.append(L.duration(entry.seconds)) }
        if let end = entry.endPage {
            if let start = entry.startPage, entry.kind != .bookmark {
                parts.append(L.f("page.range", start, end))
                if end == start { parts.append(L.t("page.same")) }
                else if end < start { parts.append(L.t("page.back")) }
                else { parts.append(L.f("page.advanced", entry.advancedPages)) }
            } else { parts.append(L.f("page.number", end)) }
        }
        return parts.joined(separator: " · ")
    }

    private func show(_ value: Route) {
        model.error = nil
        model.shareRequested = false
        route = value
    }

    private var weeks: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("history.weeks")) { route = nil }
            ScrollView {
                let past = model.hasPro ? model.library.weeks(bookID: filter).filter { $0.monday < model.today.monday } : []
                VStack(alignment: .leading, spacing: 10) {
                    if past.isEmpty { Text(L.t("history.weeksEmpty")).foregroundStyle(Design.muted) }
                    ForEach(past) { week in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(week.label).font(.footnote).foregroundStyle(Design.muted)
                            Text(L.duration(week.seconds)).font(.headline)
                            Text(L.f("card.days", week.days.count)).font(.footnote)
                        }.modifier(PaperCard())
                    }
                }.padding(22)
            }
        }
    }

    private var chooseBook: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("home.switch")) { route = nil }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.library.books) { book in
                        ActionRow(title: book.title, id: "history.book.\(book.id)") { route = .manual(book) }
                            .modifier(PaperCard())
                    }
                }.padding(22)
            }
        }
    }
}
