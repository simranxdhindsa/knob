import SwiftUI

/// A thin flat slider with an orange fill, for the iPhone player. It thickens under the finger
/// like Apple Music's bar, and a drag moves the value by how far the finger travels. SwiftUI's
/// Slider can't be drawn this way.
struct KnobGroove: View {
    var value: Double
    /// Draws a round handle on the end of the fill (GrooveCap).
    var showsCap = false
    var accessibilityLabel: String
    var accessibilityValue: String
    var onChange: (Double) -> Void
    var onEnd: () -> Void = {}

    @Environment(\.isEnabled) private var isEnabled
    @State private var dragStart: Double?

    private static let height: CGFloat = 5, heldHeight: CGFloat = 10

    var body: some View {
        let v = min(max(value, 0), 1)
        let thickness = dragStart != nil && !showsCap ? Self.heldHeight : Self.height
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Glass.fill)
                if isEnabled {
                    Capsule().fill(Palette.accent).frame(width: max(thickness, width * v))
                }
            }
            .frame(height: thickness)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if showsCap { GrooveCap().offset(x: (width - GrooveCap.size) * v) }
            }
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        .frame(height: 30)
        .animation(Motion.snappy, value: dragStart != nil)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            onChange(min(max(value + (direction == .increment ? 0.05 : -0.05), 0), 1))
            onEnd()
        }
    }

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { gesture in
                if dragStart == nil { dragStart = value }
                let next = min(max((dragStart ?? value) + Double(gesture.translation.width / max(width, 1)), 0), 1)
                Haptics.moved(from: value, to: next)
                onChange(next)
            }
            .onEnded { _ in
                dragStart = nil
                onEnd()
            }
    }
}

/// A slider's round white handle.
struct GrooveCap: View {
    static let size: CGFloat = 20

    var body: some View {
        Circle().fill(Glass.onAccent)
            .frame(width: Self.size, height: Self.size)
            .shadow(color: Glass.shadow, radius: 3, y: 1)
    }
}
