import SwiftUI

/// Every colour Knob draws with. Views never hardcode colours; they read these tokens.
/// The panel follows light/dark mode. The inset screen stays dark in both, like real hardware.
struct Palette {
    let panelTop: Color
    let panelBottom: Color
    let panelEdge: Color
    let panelHighlight: Color
    let grain: Double

    let label: Color
    let muted: Color
    let faint: Color

    let knobWellTop: Color
    let knobWellBottom: Color
    let knobBodyTop: Color
    let knobBodyBottom: Color
    let knobCapTop: Color
    let knobCapBottom: Color
    let knobOutline: Color
    let knobIndicator: Color
    let knobSheen: Double

    let pillFill: Color
    let pillStroke: Color
    let dropShadow: Color

    static let accent = Color(hex: 0xFF6B1F)
    static let accentGlow = Color(hex: 0xFF8A3D)

    static func of(_ scheme: ColorScheme) -> Palette { scheme == .dark ? dark : light }

    static let dark = Palette(
        panelTop: Color(hex: 0x3B3E43), panelBottom: Color(hex: 0x242629),
        panelEdge: Color.black.opacity(0.55), panelHighlight: Color.white.opacity(0.09), grain: 0.035,
        label: Color(hex: 0xD4D6DA), muted: Color(hex: 0x8A8F96), faint: Color(hex: 0x5C6168),
        knobWellTop: Color(hex: 0x121315), knobWellBottom: Color(hex: 0x34373C),
        knobBodyTop: Color(hex: 0x50535A), knobBodyBottom: Color(hex: 0x1F2124),
        knobCapTop: Color(hex: 0x4A4D53), knobCapBottom: Color(hex: 0x2A2C30),
        knobOutline: Color.black.opacity(0.65), knobIndicator: Color(hex: 0xF2F2F2), knobSheen: 0.16,
        pillFill: Color.black.opacity(0.28), pillStroke: Color.white.opacity(0.09),
        dropShadow: Color.black.opacity(0.6))

    static let light = Palette(
        panelTop: Color(hex: 0xF8F8F6), panelBottom: Color(hex: 0xDFDFDB),
        panelEdge: Color.black.opacity(0.18), panelHighlight: Color.white.opacity(0.95), grain: 0.20,
        label: Color(hex: 0x2E3034), muted: Color(hex: 0x6E7278), faint: Color(hex: 0xA3A6AB),
        knobWellTop: Color(hex: 0xC9C9C5), knobWellBottom: Color(hex: 0xF4F4F2),
        knobBodyTop: Color(hex: 0xFFFFFF), knobBodyBottom: Color(hex: 0xCDCDC9),
        knobCapTop: Color(hex: 0xFDFDFC), knobCapBottom: Color(hex: 0xE2E2DF),
        knobOutline: Color(hex: 0x2C2D30), knobIndicator: Color(hex: 0x3A3C40), knobSheen: 0.0,
        pillFill: Color.white.opacity(0.75), pillStroke: Color.black.opacity(0.13),
        dropShadow: Color.black.opacity(0.28))
}

/// The always-dark inset screen. Tab colours come from the 21st.dev Segmented Control dark tokens.
enum Screen {
    static let top = Color(hex: 0x1B1C1F)
    static let bottom = Color(hex: 0x0E0F11)
    static let edge = Color.black
    static let highlight = Color.white.opacity(0.07)
    static let grid = Color.white.opacity(0.07)
    static let bar = Color(hex: 0x8C9096)
    static let text = Color(hex: 0xD8D8D8)
    static let textSecondary = Color(hex: 0x999999)
    static let textTertiary = Color(hex: 0x6A6A6A)
    static let tabTrack = Color(hex: 0x333333).opacity(0.5)
    static let tabThumb = Color(hex: 0x2A2A2A)
}

/// The VU meter's own tokens. Its face, ink and hub follow `Palette` like the knobs; only the
/// needle's shaded base and the glass glare live here.
enum Meter {
    /// Base of the needle, where Knob's orange falls into shadow near the hub.
    static let needleShade = Color(hex: 0x7A2A08)
    static let glass = Color.white
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
