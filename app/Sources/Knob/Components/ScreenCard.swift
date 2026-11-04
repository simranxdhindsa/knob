import SwiftUI

/// The rounded card KnobShift's panels sit on: the recessed screen finish on the Mac, and frosted
/// glass that follows the theme on the iPhone (Surface).
struct ScreenCard: ViewModifier {
    var radius: CGFloat = 16
    var padding: CGFloat = 16

    @Environment(\.surface) private var surface

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                SurfaceBackground(radius: radius)
                    .shadow(color: .black.opacity(surface == .screen ? 0.28 : 0), radius: 8, y: 3)
            }
    }
}

extension View {
    func screenCard(radius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(ScreenCard(radius: radius, padding: padding))
    }
}
