import SwiftUI
import UIKit
import LorisListKit

/// The look of the website (public/style.css and Material Design Bootstrap), carried over:
/// a grey page, white cards, rows in each list's own colour, and a blue gradient bar.
/// In dark mode the page goes black and the cards dark grey, following the system's own colours.
enum Theme {
    /// `body { background: gray }`
    static let pageBackground = Color.adaptive(light: "808080", dark: "000000")
    /// The cards and forms: white, or the system's dark grey.
    static let cardBackground = Color.adaptive(light: "ffffff", dark: "1c1c1e")
    static let fieldBackground = Color.adaptive(light: "ffffff", dark: "2c2c2e")
    /// Body text on cards.
    static let text = Color.primary
    /// Quieter text (`text-muted`).
    static let mutedText = Color.secondary

    /// MDB's `blue-gradient`: linear-gradient(40deg, #45cafc, #303f9f)
    static let navStart = Color(hex: "45cafc")
    static let navEnd = Color(hex: "303f9f")
    static let navGradient = LinearGradient(
        colors: [navStart, navEnd], startPoint: .bottomLeading, endPoint: .topTrailing)

    /// `btn-dark`
    static let dark = Color.adaptive(light: "212121", dark: "3a3a3c")
    /// `btn-danger`
    static let danger = Color(hex: "ff3547")
    /// Links on the sign-in card are plain blue on the site.
    static let link = Color.adaptive(light: "303f9f", dark: "8c9eff")

    static let fieldBorder = Color.adaptive(light: "ced4da", dark: "48484a")
    static let fieldIconBackground = Color.adaptive(light: "e9ecef", dark: "3a3a3c")
    static let rowSeparator = Color(uiColor: .separator)

    // Bootstrap alert colours.
    static let alertDangerBackground = Color.adaptive(light: "f8d7da", dark: "4a1c21")
    static let alertDangerText = Color.adaptive(light: "721c24", dark: "f8b4bb")
    static let alertInfoBackground = Color.adaptive(light: "cce5ff", dark: "0f2e4d")
    static let alertInfoText = Color.adaptive(light: "004085", dark: "a8d1ff")
    static let alertSuccessBackground = Color.adaptive(light: "d4edda", dark: "16351f")
    static let alertSuccessText = Color.adaptive(light: "155724", dark: "a9dfb7")

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

    /// One colour in light mode and another in dark mode.
    static func adaptive(light: String, dark: String) -> Color {
        let lightColor = UIColor(Color(hex: light))
        let darkColor = UIColor(Color(hex: dark))
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
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
            // The bar draws the gradient as its first colour.
            .barUnderlay(Theme.navStart)
    }

    /// Paints everything from the screen's top edge down to the bottom of the top bar.
    ///
    /// On most iPhones the bar covers this already, so it never shows. On a device whose status
    /// bar sits at the side (iPhone Duo), the bar stops short of the top edge and the page
    /// showed through above it; this fills that strip in the bar's colour.
    func barUnderlay<S: ShapeStyle>(_ style: S) -> some View {
        overlay(alignment: .top) {
            GeometryReader { proxy in
                Rectangle()
                    .fill(style)
                    .frame(height: proxy.safeAreaInsets.top)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The grey page behind the cards.
    func pageBackground() -> some View {
        self.background(Theme.pageBackground.ignoresSafeArea())
    }
}
