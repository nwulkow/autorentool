import SwiftUI

/// Port of app.js's `CHAR_PALETTE`/`charColor`/`charColorLight` (app.js:6-10,
/// 851-861) — a character's color is just its index into a fixed palette,
/// so it stays stable across a session without being stored on the model.
/// `nil` (the "General" column) always renders in neutral gray.
enum CharacterPalette {
    static let colors: [Color] = [
        Color(hex: 0xe74c3c), Color(hex: 0x3498db), Color(hex: 0x2ecc71), Color(hex: 0xf39c12), Color(hex: 0x9b59b6),
        Color(hex: 0x1abc9c), Color(hex: 0xe67e22), Color(hex: 0xe84393), Color(hex: 0x00b894), Color(hex: 0x6c5ce7),
        Color(hex: 0xfd79a8), Color(hex: 0x00cec9), Color(hex: 0xd63031), Color(hex: 0x0984e3), Color(hex: 0x6ab04c),
    ]

    static func color(for characterId: String?, in characters: [Character]) -> Color {
        guard let characterId, let index = characters.firstIndex(where: { $0.id == characterId }) else {
            return Color(white: 0.53) // #888888
        }
        return colors[index % colors.count]
    }

    static func lightColor(for characterId: String?, in characters: [Character]) -> Color {
        color(for: characterId, in: characters).opacity(0.12)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
