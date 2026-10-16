import SwiftUI
import LorisListKit

/// The look of the website (public/style.css and Material Design Bootstrap), carried over:
/// a grey page, white cards, rows in each list's own colour, and a blue gradient bar.
enum Theme {
    /// `body { background: gray }`
    static let pageBackground = Color(red: 128 / 255, green: 128 / 255, blue: 128 / 255)

    /// MDB's `blue-gradient`: linear-gradient(40deg, #45cafc, #303f9f)
    static let navStart = Color(hex: "45cafc")
    static let navEnd = Color(hex: "303f9f")
    static let navGradient = LinearGradient(
        colors: [navStart, navEnd], startPoint: .bottomLeading, endPoint: .topTrailing)

    /// `btn-dark`
    static let dark = Color(hex: "212121")
    /// `btn-danger`
    static let danger = Color(hex: "ff3547")
    /// Links on the sign-in card are plain blue on the site.
    static let link = Color(hex: "303f9f")

    static let fieldBorder = Color(hex: "ced4da")
    static let fieldIconBackground = Color(hex: "e9ecef")
    static let rowSeparator = Color.black.opacity(0.125)

    // Bootstrap alert colours.
    static let alertDangerBackground = Color(hex: "f8d7da")
    static let alertDangerText = Color(hex: "721c24")
    static let alertInfoBackground = Color(hex: "cce5ff")
    static let alertInfoText = Color(hex: "004085")
    static let alertSuccessBackground = Color(hex: "d4edda")
    static let alertSuccessText = Color(hex: "155724")

    static let cornerRadius: CGFloat = 4
    /// The website caps its cards at 40rem (lists) and 30rem (one list).
    static let maxCardWidth: CGFloat = 640
}

extension Color {
    /// "ff9900" or "#FF9900". Anything unreadable becomes grey.
    init(hex: String) {
        if let rgb = HexColor.rgb(hex) {
            self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
        } else {
            self = .gray
        }
    }

    /// Text colour that reads well on a list's colour: white on dark colours, near-black on light ones.
    static func foreground(on hex: String) -> Color {
        HexColor.prefersDarkText(on: hex) ? Color(hex: "212121") : .white
    }
}

extension View {
    /// The blue gradient bar of the website, with white text and icons.
    func brandedNavigationBar() -> some View {
        self
            .toolbarBackground(Theme.navGradient, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }

    /// The grey page behind the cards.
    func pageBackground() -> some View {
        self.background(Theme.pageBackground.ignoresSafeArea())
    }
}
