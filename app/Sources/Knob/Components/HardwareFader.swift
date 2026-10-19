import SwiftUI

/// A vertical hardware fader: recessed groove, orange fill from the centre detent, and a
/// metal thumb with an orange line. Drawn for the dark screen. Value is -1...1 (0 = flat).
struct HardwareFader: View {
    @Binding var value: Double
    var height: CGFloat
    var accessibilityLabel: String
    var accessibilityValue: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragging = false

    private let thumbHeight: CGFloat = 11
    private let thumbWidth: CGFloat = 18

    var body: some View {
        let v = min(max(value, -1), 1)
        let travel = height - thumbHeight
        let centreY = height / 2
        let thumbY = centreY - CGFloat(v) * travel / 2
        ZStack(alignment: .top) {
            Capsule()
                .fill(LinearGradient(colors: [Color.black, Color(hex: 0x1E1F22)], startPoint: .leading, endPoint: .trailing))
                .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                .frame(width: 4, height: height)
            Rectangle()
                .fill(Color.white.opacity(0.18))
                .frame(width: 10, height: 1)
                .offset(y: centreY)
            Capsule()
                .fill(Palette.accent)
                .frame(width: 2, height: abs(thumbY - centreY))
                .shadow(color: Palette.accentGlow.opacity(isEnabled ? 0.9 : 0), radius: 3)
                .offset(y: min(thumbY, centreY))
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x6A6D73), Color(hex: 0x2C2E32)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Color.black.opacity(0.7), lineWidth: 0.5))
                .overlay(Capsule().fill(Palette.accent).frame(width: thumbWidth - 6, height: 1.5))
                .frame(width: thumbWidth, height: thumbHeight)
                .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
                .offset(y: thumbY - thumbHeight / 2)
        }
        .frame(width: thumbWidth + 6, height: height, alignment: .top)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if !dragging { dragging = true; onEditingChanged(true) }
                let raw = (centreY - g.location.y) / (travel / 2)
                var t = Transaction(); t.disablesAnimations = true
                let next = min(max(Double(raw), -1), 1)
                if (value < 0) != (next < 0) || (next == 0 && value != 0) { Haptics.detent() }
                else { Haptics.moved(from: (value + 1) / 2, to: (next + 1) / 2) }
                withTransaction(t) { value = next }
            }
            .onEnded { _ in dragging = false; onEditingChanged(false) })
        .onTapGesture(count: 2) { withAnimation(Motion.snappy) { value = 0 } }
        .animation(dragging ? nil : Motion.snappy, value: value)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            withAnimation(Motion.snappy) { value = min(max(value + (direction == .increment ? 0.083 : -0.083), -1), 1) }
        }
    }
}
