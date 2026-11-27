import SwiftUI

enum Design {
    static let paper = Color(red: 0.973, green: 0.969, blue: 0.949)
    static let white = Color(red: 1, green: 0.996, blue: 0.980)
    static let ink = Color(red: 0.110, green: 0.169, blue: 0.145)
    static let muted = Color(red: 0.302, green: 0.369, blue: 0.333)
    static let line = Color(red: 0.851, green: 0.867, blue: 0.827)
    static let green = Color(red: 0.082, green: 0.341, blue: 0.263)
    static let dark = Color(red: 0.082, green: 0.286, blue: 0.224)
    static let pale = Color(red: 0.898, green: 0.933, blue: 0.902)
    static let cream = Color(red: 0.988, green: 0.976, blue: 0.941)
    static let soft = Color(red: 0.843, green: 0.910, blue: 0.851)
    static let danger = Color(red: 0.54, green: 0.23, blue: 0.18)
}

struct ReadingButton: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .subheadline.weight(.semibold) : .headline)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: compact ? 47 : 55)
            .foregroundStyle(primary ? Design.cream : Design.green)
            .background(primary ? Design.green : .clear, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(primary ? Design.green : Design.line))
            .contentShape(RoundedRectangle(cornerRadius: 15))
            .opacity(enabled ? (configuration.isPressed ? 0.70 : 1) : 0.48)
    }
}

struct QuietButton: ButtonStyle {
    var color: Color = Design.green
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
    }
}

struct PaperCard: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Design.white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Design.line))
    }
}

struct SheetHeader: View {
    let title: String
    var close: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 5)
            if let close {
                Button(L.t("common.done"), action: close)
                    .buttonStyle(QuietButton()).accessibilityIdentifier("sheet.done")
            }
        }
        .frame(minHeight: 50)
        .padding(.top, 14)
        .padding(.horizontal, 22)
    }
}

struct MessageLine: View {
    let text: String?
    var warning = false

    var body: some View {
        if let text {
            Text(text)
                .font(.footnote)
                .foregroundStyle(warning ? Design.danger : Design.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(warning ? "form.error" : "form.message")
        }
    }
}

struct InputField: View {
    let title: String
    let placeholder: String
    let id: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var focus: FocusState<Bool>.Binding? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Design.muted)
            Group {
                if let focus { TextField(placeholder, text: $text).focused(focus) }
                else { TextField(placeholder, text: $text) }
            }.keyboardType(keyboard)
                .padding(.horizontal, 13)
                .frame(minHeight: 49)
                .background(Design.white, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Design.line))
                .accessibilityLabel(title)
                .accessibilityIdentifier(id)
        }
    }
}

struct ActionRow: View {
    let title: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 49)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Design.green)
        .accessibilityIdentifier(id)
    }
}
