import Foundation

/// The home screen shows the person's own lists and, separately, lists shared with them.
public struct ListGroups: Equatable, Sendable {
    public var mine: [ListSummary]
    public var shared: [ListSummary]

    public init(_ lists: [ListSummary]) {
        mine = lists.filter { $0.role == .owner }
        shared = lists.filter { $0.role != .owner }
    }
}

/// Colours arrive as six hex digits without "#", in either case.
public enum HexColor {
    /// "#FF9900", "ff9900" and " ff9900 " all become "ff9900". Anything else is nil.
    public static func normalize(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return value
    }

    public static func rgb(_ text: String) -> (red: Double, green: Double, blue: Double)? {
        guard let hex = normalize(text), let number = UInt32(hex, radix: 16) else { return nil }
        return (
            Double((number >> 16) & 0xFF) / 255,
            Double((number >> 8) & 0xFF) / 255,
            Double(number & 0xFF) / 255
        )
    }

    /// Relative luminance (WCAG), 0 for black and 1 for white.
    public static func luminance(_ text: String) -> Double {
        guard let c = rgb(text) else { return 0.5 }
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }

    /// True when dark text reads better than white text on this colour.
    public static func prefersDarkText(on text: String) -> Bool {
        // White has contrast (1.05 / (L + 0.05)); black has ((L + 0.05) / 0.05).
        // Dark text wins once L passes about 0.18.
        luminance(text) > 0.18
    }
}

public enum ItemInput {
    public static let maxNameLength = 100

    /// An empty field means "no quantity". A number below 1 or text that is not a number is nil too.
    public static func parseCount(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed), value >= 1 else { return nil }
        return value
    }

    public static func cleanName(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength))
    }

    /// Names the person has used before that fit what they have typed so far.
    /// Names that start with the text come first. A name that already matches exactly is left out.
    public static func suggestions(for typed: String, from names: [String], limit: Int = 5) -> [String] {
        let query = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        var starts: [String] = []
        var contains: [String] = []
        for name in names {
            let lower = name.lowercased()
            if lower == query { continue }
            if lower.hasPrefix(query) {
                starts.append(name)
            } else if lower.contains(query) {
                contains.append(name)
            }
        }
        return Array((starts + contains).prefix(limit))
    }
}

public enum Validation {
    /// Matches the server: 1 to 50 letters, numbers or . _ @ + -
    public static func isValidUsername(_ text: String) -> Bool {
        guard (1...50).contains(text.count) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            let c = Character(scalar)
            return (c.isASCII && (c.isLetter || c.isNumber)) || "._@+-".contains(c)
        }
    }

    public static func isValidEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !text.contains(" ") else { return false }
        return !(parts[1].hasPrefix(".") || parts[1].hasSuffix("."))
    }

    public static let minPasswordLength = 8
}
