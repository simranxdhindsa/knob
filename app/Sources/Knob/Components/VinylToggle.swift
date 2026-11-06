import SwiftUI

/// A switch whose thumb is a real little record: on the left when off, and when on it rolls to
/// the right, the track lights up and the record keeps turning. A native Toggle underneath, so it
/// reads as a switch to VoiceOver. Its motion follows PowerSwitch, the 21st.dev Switch port.
struct VinylToggle: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
            .labelsHidden()
            .toggleStyle(VinylToggleStyle())
    }
}

private struct VinylToggleStyle: ToggleStyle {
    private static let width: CGFloat = 72, height: CGFloat = 38, inset: CGFloat = 3
    private static var thumb: CGFloat { height - inset * 2 }
    private static var travel: CGFloat { width - height }
    /// How far the record rolls on its way across.
    private static let roll = 200.0

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return Button {
            Haptics.mark()
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                Capsule().fill(on ? Palette.accent : Glass.fill)
                Capsule().stroke(Glass.stroke, lineWidth: 1)
                VinylIcon(size: Self.thumb, spinning: on)
                    .rotationEffect(.degrees(on ? Self.roll : 0))
                    .shadow(color: Glass.shadow, radius: 3, y: 1)
                    .offset(x: Self.inset + (on ? Self.travel : 0))
            }
            .frame(width: Self.width, height: Self.height)
            .shadow(color: on ? Palette.accentGlow.opacity(0.5) : .clear, radius: 8)
            // On the switch itself: the setting behind it is saved, and a saved value changing
            // doesn't carry an animation along with it.
            .animation(Motion.gentle, value: on)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
