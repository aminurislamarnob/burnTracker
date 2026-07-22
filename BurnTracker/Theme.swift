import SwiftUI

/// Design tokens ported from the original `src/styles.css`.
/// The content UI is dark-themed only (matches the original `body.dark-theme`);
/// only the menu-bar glyph adapts to light/dark menu bars.
enum Theme {
    static let bg = Color(hex: 0x121215)
    static let surface = Color(hex: 0x1A1A20)
    static let card = Color(hex: 0x202028)
    static let cardHover = Color(hex: 0x262632)

    static let border = Color.white.opacity(0.08)

    static let textMain = Color(hex: 0xF3F3F6)
    static let textMuted = Color(hex: 0x9E9EA8)
    static let textDimmed = Color(hex: 0x686875)

    static let accent = Color(hex: 0xCC5C3C)       // Claude peach/orange
    static let accentHover = Color(hex: 0xE06D4E)
    static let accentLight = Color(hex: 0xCC5C3C).opacity(0.15)

    static let success = Color(hex: 0x34C759)      // Apple green
    static let error = Color(hex: 0xFF453A)        // Apple red
    static let info = Color(hex: 0x0A84FF)         // Apple blue
    static let warning = Color(hex: 0xFF9F0A)      // Apple orange

    // CLI provider brand tints (compact quota bars).
    static let geminiTint = Color(hex: 0xA78BFA)       // Gemini CLI — soft violet
    static let antigravityTint = Color(hex: 0x7BC67F)  // Antigravity — sage green

    /// A subtler divider used between compact flat rows.
    static let hairline = Color.white.opacity(0.06)

    // MARK: - Glass (translucent) surfaces

    /// A slight dark tint laid over the behind-window vibrancy so text stays
    /// legible on top of bright desktops without killing the translucency.
    static let windowTint = Color(hex: 0x121215).opacity(0.30)

    /// A frosted panel tint layered on the within-window material for cards,
    /// giving them a faint lift off the window glass.
    static let cardGlass = Color.white.opacity(0.05)
    static let cardGlassHover = Color.white.opacity(0.09)

    /// A brighter hairline that reads on top of translucent glass.
    static let glassBorder = Color.white.opacity(0.12)

    /// A recessed inset (input fields, nested boxes) that reads as darker glass
    /// within a frosted card.
    static let glassInset = Color.black.opacity(0.18)
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
