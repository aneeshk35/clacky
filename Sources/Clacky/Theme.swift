import AppKit
import SwiftUI

/// Clacky's colors, "Sorbet, dark": ink, a pastel keycap for every switch, and one tangerine for
/// everything you can change.
enum Theme {
    static let ground = Color(hex: 0x17171C)
    static let card = Color(hex: 0x202027)
    /// Buttons, key chips and the add tile: a step up from the cards.
    static let raised = Color(hex: 0x26262E)
    static let line = Color(hex: 0x2E2E38)
    static let dashed = Color(hex: 0x3C3C48)
    static let text = Color(hex: 0xF4F4F6)
    static let secondary = Color(hex: 0xA9AAB6)
    static let accent = Color(hex: 0xF0592A)
    static let warning = Color(hex: 0xFFE38F)
    static let danger = Color(hex: 0xFF8A95)

    static let groundColor = NSColor(srgbRed: 0x17 / 255, green: 0x17 / 255, blue: 0x1C / 255, alpha: 1)

    /// A keycap's two colors: the top you press and the sides below it.
    struct Keycap {
        let top: Color
        let side: Color
    }

    static let keycaps = [
        Keycap(top: Color(hex: 0xB5D8FF), side: Color(hex: 0x8DBBEF)),  // sky
        Keycap(top: Color(hex: 0xFFE38F), side: Color(hex: 0xEDC85E)),  // butter
        Keycap(top: Color(hex: 0xFFC7A8), side: Color(hex: 0xF2A47C)),  // peach
        Keycap(top: Color(hex: 0xB8EDD6), side: Color(hex: 0x88D3B4)),  // mint
        Keycap(top: Color(hex: 0xFFC2CF), side: Color(hex: 0xF29AAE)),  // pink
    ]

    /// The switches Clacky ships with, each in a color that suits it.
    private static let shipped: [String: Keycap] = [
        "Clicky (Real)": keycaps[0],
        "Creamy Linear": keycaps[1],
        "Creamy Thock": keycaps[2],
        "Thocky": keycaps[3],
        "Hako Violet": Keycap(top: Color(hex: 0xD9CCFF), side: Color(hex: 0xB8A6F0)),
        "MX Blue": Keycap(top: Color(hex: 0xA8EEF0), side: Color(hex: 0x7FD3D6)),
        "MX Brown": Keycap(top: Color(hex: 0xF2C79B), side: Color(hex: 0xDDA46B)),
        "MX Clear": Keycap(top: Color(hex: 0xE8ECF2), side: Color(hex: 0xC5CCD6)),
        "MX Red": keycaps[4],
    ]

    /// Shipped switches keep their colors; any other pack gets one from its name, so it stays the
    /// same from launch to launch.
    static func keycap(for name: String) -> Keycap {
        shipped[name] ?? keycaps[name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % keycaps.count]
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
