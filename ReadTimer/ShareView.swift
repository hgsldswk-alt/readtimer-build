import SwiftUI

struct ShareActivity: UIViewControllerRepresentable {
    let item: SharePayload

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ShareHost: ViewModifier {
    @EnvironmentObject private var model: AppModel
    func body(content: Content) -> some View {
        content.sheet(item: $model.sharing) { item in
            ShareActivity(item: item)
        }
    }
}

struct ShareStatus: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if model.shareRequested {
            Text(L.t("share.prepared")).font(.footnote.weight(.semibold)).foregroundStyle(Design.green)
                .accessibilityIdentifier("share.requested")
        }
    }
}

struct SharePreview: View {
    @EnvironmentObject private var model: AppModel
    @State private var includeTitles = false
    @State private var rendered: RenderedCard?
    @State private var working = false
    @State private var copied = false
    let milestone: Int?
    let close: () -> Void

    private struct RenderedCard {
        let withTitles: Bool
        let data: Data
        let image: UIImage
    }

    private var card: CardContent {
        let week = model.week
        let names = includeTitles ? model.library.books.filter { week.bookIDs.contains($0.id) }.map(\.title) : []
        return CardContent(summary: week, milestone: milestone, titles: names)
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: L.t(milestone == nil ? "share.week" : "share.milestone"), close: close)
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    preview
                    if milestone == nil {
                        Text(L.t(includeTitles ? "share.named" : "share.anonymous"))
                            .font(.footnote).foregroundStyle(Design.muted)
                            .accessibilityIdentifier(includeTitles ? "share.named" : "share.anonymous")
                        Toggle(L.t("share.includeTitles"), isOn: $includeTitles)
                            .font(.subheadline).accessibilityIdentifier("share.includeTitles")
                    }
                    ShareStatus()
                    MessageLine(text: model.error, warning: true)
                    Button(L.t("share.image")) { share() }
                        .buttonStyle(ReadingButton(primary: true))
                        .disabled(rendered?.withTitles != includeTitles || working)
                        .accessibilityIdentifier("share.image")
                    Button(L.t(copied ? "share.copied" : "share.copyCaption")) {
                        UIPasteboard.general.string = card.caption
                        copied = true
                    }.buttonStyle(QuietButton()).frame(maxWidth: .infinity).accessibilityIdentifier("share.copyCaption")
                }.padding(.horizontal, 22).padding(.vertical, 10)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .modifier(ShareHost())
        .task(id: includeTitles) {
            let data = ReadingCard.png(card, productID: StoreLink.productID())
            if let image = UIImage(data: data) {
                rendered = RenderedCard(withTitles: includeTitles, data: data, image: image)
            }
        }
    }

    private var preview: some View {
        let content = card
        return Group {
            if let rendered, rendered.withTitles == includeTitles {
                Image(uiImage: rendered.image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 19).fill(Design.pale).aspectRatio(4.0 / 5, contentMode: .fit)
            }
        }
        .frame(maxWidth: 365)
        .clipShape(RoundedRectangle(cornerRadius: 19))
        .frame(maxWidth: .infinity)
        .accessibilityLabel([content.heading,
                             milestone.map { L.f("card.milestoneDays", $0) } ?? L.duration(content.summary.seconds),
                             content.titles.joined(separator: L.t("card.bookSeparator"))]
            .filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier("share.preview")
    }

    private func share() {
        guard !working, let rendered, rendered.withTitles == includeTitles else { return }
        let data = rendered.data
        working = true
        model.shareRequested = false
        model.error = nil
        Task {
            defer { working = false }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try ExportFile.write(data, fileName: "reading-card.png")
                }.value
                model.requestShare(url)
            } catch { model.error = L.t("error.export") }
        }
    }
}
