import SwiftUI

/// What a view sits on, and so the colours it draws with. Shared views read `surface.text`,
/// `surface.fill` and so on from the environment and never choose between dark and light
/// themselves, so one view looks right on the Mac's dark screen and in both iPhone themes.
/// `ios/check-theme.sh` stops the iPhone build if a view reaches past this to a fixed dark colour.
enum Surface {
    /// The always dark recessed screen: the analyser, and KnobShift on the Mac.
    case screen
    /// Glass that follows the light or dark theme: everything on the iPhone.
    case glass

    var text: Color { self == .glass ? Glass.text : Screen.text }
    var secondary: Color { self == .glass ? Glass.secondary : Screen.textSecondary }
    /// The quietest text. Still secondary on glass, which a cover can sit behind.
    var tertiary: Color { self == .glass ? Glass.secondary : Screen.textTertiary }
    /// Tracks, fields and other recessed shapes.
    var fill: Color { self == .glass ? Glass.fill : Screen.tabTrack }
    var stroke: Color { self == .glass ? Glass.stroke : Screen.highlight }
    var grid: Color { self == .glass ? Glass.fill : Screen.grid }
    /// The selected tab's thumb and its outline.
    var thumb: Color { self == .glass ? Glass.fill : Screen.tabThumb }
    var thumbStroke: Color { self == .glass ? Glass.stroke : Color.white.opacity(0.55) }
    /// A plain backdrop, top to bottom.
    var backdrop: [Color] { self == .glass ? [Glass.fill, Glass.fill] : [Screen.top, Screen.bottom] }

    /// The scheme for hardware drawn on this surface: the screen is dark in both themes.
    func scheme(_ theme: ColorScheme) -> ColorScheme { self == .glass ? theme : .dark }
}

/// A card's rounded background on the current surface: frosted glass, or the screen finish.
struct SurfaceBackground: View {
    var radius: CGFloat

    @Environment(\.surface) private var surface

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if surface == .glass {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Glass.scrim))
                .overlay(shape.stroke(Glass.stroke, lineWidth: 0.5))
        } else {
            shape.fill(LinearGradient(colors: surface.backdrop, startPoint: .top, endPoint: .bottom))
                .overlay(shape.stroke(Screen.edge, lineWidth: 1.2))
                .overlay(shape.inset(by: 1.2).stroke(Screen.highlight, lineWidth: 0.5))
        }
    }
}

private struct SurfaceKey: EnvironmentKey {
    // Decided by the platform, so a new iPhone view follows the theme without having to ask.
    #if os(iOS)
    static let defaultValue = Surface.glass
    #else
    static let defaultValue = Surface.screen
    #endif
}

extension EnvironmentValues {
    var surface: Surface {
        get { self[SurfaceKey.self] }
        set { self[SurfaceKey.self] = newValue }
    }
}
