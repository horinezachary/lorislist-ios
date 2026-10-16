import LorisListKit

/// List colours come from the server (GET /colors). These are used until that answers, or when
/// the phone is offline, so the "new list" sheet is never empty. Any six-digit hex colour is
/// accepted by the server, so lists made with these work either way.
enum ColorPalette {
    static let fallback: [ListColorOption] = [
        ListColorOption(id: -1, hex: "ff9900", name: "Orange"),
        ListColorOption(id: -2, hex: "e53935", name: "Red"),
        ListColorOption(id: -3, hex: "e91e63", name: "Pink"),
        ListColorOption(id: -4, hex: "8e44ad", name: "Purple"),
        ListColorOption(id: -5, hex: "3366cc", name: "Blue"),
        ListColorOption(id: -6, hex: "00a8a8", name: "Teal"),
        ListColorOption(id: -7, hex: "2e9e4f", name: "Green"),
        ListColorOption(id: -8, hex: "f1c40f", name: "Yellow"),
        ListColorOption(id: -9, hex: "8d6e63", name: "Brown"),
        ListColorOption(id: -10, hex: "607d8b", name: "Slate")
    ]
}
