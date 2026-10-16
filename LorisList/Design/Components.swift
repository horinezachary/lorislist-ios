import SwiftUI

// MARK: - Cards

/// A white card, like Bootstrap's `.card`.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 1)
    }
}

/// The bold heading at the top of a card (`h3.font-weight-bold`).
struct CardTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.title2.bold())
            .foregroundColor(.black)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A thin line between rows, like `list-group-flush`.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.rowSeparator)
            .frame(height: 1)
    }
}

/// Scrolls a column of cards on the grey page and keeps them to a readable width on iPad.
struct CardColumn<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    init(spacing: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: spacing) {
                content
            }
            .frame(maxWidth: Theme.maxCardWidth)
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .pageBackground()
    }
}

// MARK: - Buttons

/// Buttons as the website draws them: dark, outlined, red, or dark with the blue gradient.
/// MDB sets button text in small uppercase.
struct AppButtonStyle: ButtonStyle {
    enum Kind {
        case dark, outline, danger, gradient
    }

    var kind: Kind = .dark
    var compact = false
    /// Text and border colour of the `.outline` kind. Dark by default; pass white on dark list colours.
    var outlineColor: Color = Theme.dark

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        AppButtonBody(configuration: configuration, kind: kind, compact: compact, outlineColor: outlineColor)
    }
}

private struct AppButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: AppButtonStyle.Kind
    let compact: Bool
    let outlineColor: Color

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .textCase(.uppercase)
            .foregroundColor(textColor)
            .padding(.horizontal, compact ? 12 : 18)
            .padding(.vertical, compact ? 7 : 10)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(outlineColor, lineWidth: kind == .outline ? 1.5 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Rectangle())
    }

    private var textColor: Color {
        kind == .outline ? outlineColor : .white
    }

    @ViewBuilder
    private var background: some View {
        switch kind {
        case .dark: Theme.dark
        case .danger: Theme.danger
        case .gradient: Theme.navGradient
        case .outline: Color.clear
        }
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static var appDark: AppButtonStyle { AppButtonStyle(kind: .dark) }
    static var appGradient: AppButtonStyle { AppButtonStyle(kind: .gradient) }
    static var appDanger: AppButtonStyle { AppButtonStyle(kind: .danger) }
    static var appOutline: AppButtonStyle { AppButtonStyle(kind: .outline) }
    static var appOutlineCompact: AppButtonStyle { AppButtonStyle(kind: .outline, compact: true) }
}

// MARK: - Messages

/// Bootstrap's `.alert`: red for errors, blue for tips, green for good news.
struct Banner: View {
    enum Kind {
        case error, info, success
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.subheadline)
            .multilineTextAlignment(.center)
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(backgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .accessibilityElement(children: .combine)
    }

    private var backgroundColor: Color {
        switch kind {
        case .error: return Theme.alertDangerBackground
        case .info: return Theme.alertInfoBackground
        case .success: return Theme.alertSuccessBackground
        }
    }

    private var textColor: Color {
        switch kind {
        case .error: return Theme.alertDangerText
        case .info: return Theme.alertInfoText
        case .success: return Theme.alertSuccessText
        }
    }
}

// MARK: - Fields

/// An input with a grey icon box on its left, as on the website's sign-in form.
struct IconField<Field: View>: View {
    let systemImage: String
    private let field: Field

    init(systemImage: String, @ViewBuilder field: () -> Field) {
        self.systemImage = systemImage
        self.field = field()
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: systemImage)
                .foregroundColor(Color(hex: "495057"))
                .frame(width: 42, height: 42)
                .background(Theme.fieldIconBackground)
                .accessibilityHidden(true)
            field
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .frame(height: 42)
        }
        .background(Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.fieldBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

/// A plain white text box with a border, for places that have no icon.
struct BoxedFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundColor(.black)
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(Theme.fieldBorder, lineWidth: 1)
            )
    }
}

extension View {
    func boxedField() -> some View {
        modifier(BoxedFieldStyle())
    }
}

// MARK: - Colour swatches

/// The round colour choices of the "new list" and "edit list" forms. The chosen one gets
/// a heavy dark ring, as on the website.
struct ColorSwatch: View {
    let hex: String
    let name: String
    let isSelected: Bool

    var body: some View {
        Circle()
            .fill(Color(hex: hex))
            .frame(width: 36, height: 36)
            .overlay(
                Circle().stroke(Color.black, lineWidth: isSelected ? 4 : 0)
            )
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Small helpers

/// A spinner that sits in a button's place while a request runs.
struct BusyLabel: View {
    let title: String
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isBusy {
                ProgressView().tint(.white)
            }
            Text(title)
        }
    }
}
