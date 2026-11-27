import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

struct CardContent {
    let summary: WeekSummary
    let milestone: Int?
    var titles: [String] = []

    var heading: String { L.t(milestone == nil ? "card.title" : "card.milestone") }
    var topic: String { L.t("card.topic") }
    var caption: String {
        if let milestone { return L.f("card.milestoneCaption", milestone) }
        return L.f("card.caption", L.duration(summary.seconds))
    }
}

enum StoreLink {
    static func productID(in bundle: Bundle = .main) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: "APP_STORE_ID") as? String,
              !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), (UInt64(raw) ?? 0) > 0 else { return nil }
        return raw
    }

    static func download(for productID: String?) -> URL {
        if let productID { return URL(string: "https://apps.apple.com/app/id" + productID)! }
        return URL(string: "https://apps.apple.com/")!
    }
}

enum ReadingCard {
    static let size = CGSize(width: 1_080, height: 1_350)

    private static let pale = UIColor(red: 0.898, green: 0.933, blue: 0.902, alpha: 1)
    private static let dark = UIColor(red: 0.082, green: 0.286, blue: 0.224, alpha: 1)
    private static let ink = UIColor(red: 0.110, green: 0.169, blue: 0.145, alpha: 1)
    private static let muted = UIColor(red: 0.302, green: 0.369, blue: 0.333, alpha: 1)
    private static let rule = UIColor(red: 0.776, green: 0.839, blue: 0.784, alpha: 1)

    static func png(_ card: CardContent, productID: String?) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            pale.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            if card.milestone == nil {
                title(card.summary.label, at: 82, size: 39, weight: .medium, color: muted)
            }
            title(card.heading, at: 150, size: 78, weight: .bold, color: ink)
            let measure = card.milestone.map { L.f("card.milestoneDays", $0) } ?? L.duration(card.summary.seconds)
            drawMeasure(measure)
            if card.milestone == nil {
                title(L.f("card.days", card.summary.days.count), at: 575, size: 43, weight: .medium, color: muted)
                if !card.titles.isEmpty {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.lineBreakMode = .byTruncatingTail
                    let text = card.titles.joined(separator: L.t("card.bookSeparator"))
                    (text as NSString).draw(with: CGRect(x: 73, y: 669, width: 934, height: 172),
                                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                             attributes: [.font: UIFont.systemFont(ofSize: 36, weight: .medium),
                                                          .foregroundColor: ink, .paragraphStyle: paragraph], context: nil)
                }
            }

            rule.setFill()
            context.fill(CGRect(x: 73, y: 982, width: 934, height: 3))
            title(L.t("app.storeName"), at: 1094, size: 39, weight: .semibold, color: ink, width: 646)
            title(card.topic, at: 1150, size: 33, weight: .medium, color: muted, width: 646)
            drawQR(StoreLink.download(for: productID), context: context.cgContext)
            let label = L.t(productID == nil ? "card.demoQR" : "card.download")
            title(label, at: 1255, size: 25, weight: .medium, color: muted,
                  x: 754, width: 253, alignment: .center)
        }
    }

    private static func title(_ text: String, at y: CGFloat, size: CGFloat, weight: UIFont.Weight,
                              color: UIColor, x: CGFloat = 73, width: CGFloat = 934,
                              alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        let font = UIFont.systemFont(ofSize: size, weight: weight)
        (text as NSString).draw(with: CGRect(x: x, y: y, width: width, height: size * 2.52),
                                 options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph],
                                 context: nil)
    }

    private static func drawMeasure(_ text: String) {
        let wholeText = NSRange(text.startIndex..<text.endIndex, in: text)
        let digits = try! NSRegularExpression(pattern: "\\p{Nd}+")
        let numeralRanges = digits.matches(in: text, range: wholeText).map(\.range)
        let measure = NSMutableAttributedString(string: text)
        func applyFonts(scale: CGFloat) {
            measure.setAttributes([.font: UIFont.systemFont(ofSize: 50 * scale, weight: .medium),
                                   .foregroundColor: dark], range: wholeText)
            let figures = UIFont.monospacedDigitSystemFont(ofSize: 164 * scale, weight: .semibold)
            for range in numeralRanges { measure.addAttribute(.font, value: figures, range: range) }
        }
        applyFonts(scale: 1)
        let width = measure.size().width
        if width > 934 { applyFonts(scale: 930 / width) }
        measure.draw(at: CGPoint(x: 73, y: 357))
    }

    private static func drawQR(_ url: URL, context: CGContext) {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return }
        let modules = Int(output.extent.width)
        let step = 244 / (modules + 8)
        guard step > 0 else { return }
        let side = CGFloat((modules + 8) * step)
        let quiet = CGFloat(4 * step)
        let rect = CGRect(x: 754 + floor((253 - side) / 2), y: 1014, width: side, height: side)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(rect)
        context.saveGState()
        context.interpolationQuality = .none
        let code = UIImage(cgImage: image)
        code.draw(in: rect.insetBy(dx: quiet, dy: quiet))
        context.restoreGState()
    }
}
