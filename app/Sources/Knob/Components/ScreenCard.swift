import SwiftUI

/// The always-dark rounded card KnobShift's panels sit on: the same recessed screen finish as
/// Knob's analyser, so the player reads as part of the hardware in light and dark mode.
struct ScreenCard: ViewModifier {
    var radius: CGFloat = 16
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(LinearGradient(colors: [Screen.top, Screen.bottom], startPoint: .top, endPoint: .bottom)))
            .overlay(shape.stroke(Screen.edge, lineWidth: 1.2))
            .overlay(shape.inset(by: 1.2).stroke(Screen.highlight, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    }
}

extension View {
    func screenCard(radius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(ScreenCard(radius: radius, padding: padding))
    }
}
