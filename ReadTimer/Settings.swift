import StoreKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL
    @State private var route: Route?
    let close: () -> Void

    private enum Route: String, Identifiable {
        case goal, goalImport, privacy, paywall
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("home.settings"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    actions
                    ShareStatus()
                    MessageLine(text: model.error, warning: true)
                }.padding(22)
            }
        }
        .modifier(ShareHost())
        .sheet(item: $route) { destination in
            Group {
                switch destination {
                case .goal: GoalEditor { route = nil }
                case .goalImport: GoalImportView { route = nil }
                case .privacy: privacy
                case .paywall: PaywallView { route = nil }
                }
            }.background(Design.paper).presentationDragIndicator(.visible).presentationBackground(Design.paper)
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            if model.hasPro || model.library.goalMinutes != nil {
                ActionRow(title: L.t("goal.title"), id: "settings.goal") { show(.goal) }
            }
            ActionRow(title: L.t("goal.import"), id: "settings.import") { show(.goalImport) }
            ActionRow(title: L.t("history.export"), id: "settings.export") { Task { await model.exportCSV() } }
            if !Launch.isFree {
                ActionRow(title: L.t("paid.title"), id: "settings.pro") { show(.paywall) }
            }
            ActionRow(title: L.t("settings.privacy"), id: "settings.privacy") { show(.privacy) }
            ActionRow(title: L.t("settings.rate"), id: "settings.rate", action: rate)
        }
        .background(Design.white, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Design.line).allowsHitTesting(false))
    }

    private var privacy: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("settings.privacy")) { route = nil }
            ScrollView {
                Text(L.t("settings.privacyBody")).frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }
        }
    }

    private func show(_ destination: Route) {
        model.error = nil
        model.shareRequested = false
        route = destination
    }

    private func rate() {
        guard !Launch.testing else { return }
        if let id = StoreLink.productID(),
           let url = URL(string: "itms-apps://apps.apple.com/app/id\(id)?action=write-review") {
            openURL(url)
        } else { requestReview() }
    }
}

struct GoalEditor: View {
    @EnvironmentObject private var model: AppModel
    @State private var minutes = ""
    @State private var validation: String?
    @State private var copied = false
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("goal.title"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let target = model.library.goalMinutes {
                        Text(L.f("goal.progress", model.week.seconds / 60, target))
                            .font(.headline).accessibilityIdentifier("goal.progress")
                    }
                    if model.hasPro {
                        InputField(title: L.t("goal.minutes"), placeholder: L.t("goal.example"),
                                   id: "goal.minutes", text: $minutes, keyboard: .numberPad)
                        Button(L.t("common.save"), action: save).buttonStyle(ReadingButton(primary: true))
                            .disabled(model.saving).accessibilityIdentifier("goal.save")
                        if let target = model.library.goalMinutes {
                            Button(L.t(copied ? "share.copied" : "goal.copy")) {
                                UIPasteboard.general.string = GoalCode.make(target)
                                copied = true
                            }.buttonStyle(ReadingButton()).accessibilityIdentifier("goal.copy")
                            if copied {
                                Text(GoalCode.make(target)).foregroundStyle(Design.muted)
                                    .textSelection(.enabled).accessibilityIdentifier("goal.code")
                            }
                        }
                    }
                    MessageLine(text: validation ?? model.error, warning: true)
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
        }.onAppear {
            minutes = model.library.goalMinutes.map { String($0) } ?? ""
        }
    }

    private func save() {
        guard let value = ReadingInput.positive(minutes), GoalCode.range.contains(value) else {
            validation = L.t("error.goal")
            return
        }
        validation = nil
        copied = false
        Task { _ = await model.saveGoal(value, imported: false) }
    }
}

struct GoalImportView: View {
    @EnvironmentObject private var model: AppModel
    @State private var code = ""
    @State private var preview: Int?
    @State private var validation: String?
    @State private var pickingFile = false
    @FocusState private var focused: Bool
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("goal.import"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text(L.t("goal.importHelp")).font(.subheadline).foregroundStyle(Design.muted)
                    InputField(title: L.t("goal.code"), placeholder: GoalCode.make(90),
                               id: "import.code", text: $code, focus: $focused)
                    Button(L.t("goal.chooseFile")) {
                        focused = false
                        pickingFile = true
                    }.buttonStyle(QuietButton()).accessibilityIdentifier("import.file")
                    Button(L.t("goal.preview")) { inspect(code) }
                        .buttonStyle(ReadingButton()).accessibilityIdentifier("import.preview")
                    if let preview {
                        Text(L.f("goal.previewMinutes", preview)).font(.title3.bold())
                            .accessibilityIdentifier("import.value")
                        if model.library.goalMinutes != nil {
                            Text(L.t("goal.replace")).font(.footnote).foregroundStyle(Design.muted)
                        }
                        Button(L.t("goal.apply")) {
                            Task { if await model.saveGoal(preview, imported: true) { close() } }
                        }.buttonStyle(ReadingButton(primary: true))
                            .disabled(model.saving).accessibilityIdentifier("import.apply")
                    }
                    MessageLine(text: validation ?? model.error, warning: true)
                }.padding(22)
            }.scrollDismissesKeyboard(.interactively)
        }
        .onChange(of: code) { _, value in
            if preview != GoalCode.parse(value) { preview = nil }
            validation = nil
        }
        .onAppear {
            if Launch.testing, let fixture = ProcessInfo.processInfo.environment["READTIMER_TEST_IMPORT"] {
                code = fixture
            }
        }
        .fileImporter(isPresented: $pickingFile, allowedContentTypes: [.plainText]) { result in
            Task {
                do {
                    let url = try result.get()
                    let text = try await Task.detached { try Self.readCode(url) }.value
                    code = text
                    if let minutes = GoalCode.parse(text) { preview = minutes }
                    else {
                        await Task.yield()
                        inspect(text)
                    }
                } catch { validation = L.t("error.file") }
            }
        }
    }

    private func inspect(_ value: String) {
        focused = false
        preview = GoalCode.parse(value)
        validation = preview == nil ? L.t("error.code") : nil
    }

    private nonisolated static func readCode(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 1_025) ?? Data()
        guard data.count <= 1_024, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
    }
}

struct PaywallView: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t("paid.title"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Image(systemName: "book.closed").font(.system(size: 39, weight: .light))
                        .foregroundStyle(Design.green).accessibilityHidden(true)
                    Text(L.t("paid.heading")).font(.largeTitle.bold()).accessibilityIdentifier("paywall.title")
                    Text(L.t("paid.features")).font(.body)
                    Text(L.t("paid.freeFeatures")).font(.subheadline).foregroundStyle(Design.muted)
                    if model.entitlement?.purchasedPro == true {
                        Text(L.t("paid.unlocked")).font(.headline).foregroundStyle(Design.green)
                    } else {
                        if let price = model.price {
                            Button(L.f("paid.buy", price)) { Task { await model.purchase(Launch.proID) } }
                                .buttonStyle(ReadingButton(primary: true)).disabled(model.purchasing)
                                .accessibilityIdentifier("paywall.buy")
                        } else {
                            Button(L.t("paid.loadPrice")) { Task { await model.loadProducts() } }
                                .buttonStyle(ReadingButton(primary: true)).accessibilityIdentifier("paywall.reload")
                        }
                        if model.trialAvailable {
                            Button(L.t("paid.claim")) { Task { await model.purchase(Launch.trialID) } }
                                .buttonStyle(ReadingButton()).accessibilityIdentifier("paywall.trial")
                                .disabled(model.purchasing || (!Launch.testing && !model.products.contains(where: { $0.id == Launch.trialID })))
                        }
                    }
                    Button(L.t("paid.restore")) { Task { await model.restore() } }
                        .buttonStyle(QuietButton()).accessibilityIdentifier("paywall.restore").disabled(model.purchasing)
                    Text(L.t("paid.terms")).font(.footnote).foregroundStyle(Design.muted)
                    MessageLine(text: model.purchaseMessage)
                }.padding(22)
            }
        }.task { await model.loadProducts() }
    }
}
