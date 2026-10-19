import AppKit
import SwiftUI

/// A hardware-style rotary knob: recessed well, shadowed skirt, lit cap, pointer and a glowing
/// value arc. Turn it by circling the pointer around it, like a real knob (see `RotaryDrag`).
/// Double-click resets to `defaultValue`. Outside changes (for example the Mac volume keys)
/// glide in with a spring; drags follow the pointer exactly.
struct RealisticKnob: View {
    @Binding var value: Double
    var size: CGFloat
    var defaultValue: Double? = nil
    var showsMinMax = true
    var accessibilityLabel: String
    var accessibilityValue: String
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var dragStart: Double?
    @State private var rotary: RotaryDrag?

    private static let sweep = 270.0
    /// Indicator marks around the knob, 0 to 10 like a guitar amp.
    private static let marks = 11

    /// Diameters of the well, skirt and cap as fractions of `size`. Small knobs (the effects)
    /// sit tighter inside their arc than the big volume knob, so the ring never looks oversized.
    private var proportions: (well: CGFloat, skirt: CGFloat, cap: CGFloat) {
        let t = min(max((size - 54) / (150 - 54), 0), 1)   // 0 at effect-knob size, 1 at volume size
        func mix(_ small: CGFloat, _ large: CGFloat) -> CGFloat { small + (large - small) * t }
        // Scaled down so the indicator marks fit in a ring outside the body.
        return (mix(0.92, 0.86) * 0.82, mix(0.84, 0.77) * 0.82, mix(0.73, 0.66) * 0.82)
    }

    var body: some View {
        let p = Palette.of(scheme)
        let v = min(max(value, 0), 1)
        VStack(spacing: size * 0.01) {
            ZStack {
                arc(p, v)
                well(p)
                skirt(p)
                cap(p)
                pointer(p, v)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(drag)
            .onTapGesture(count: 2) { if let d = defaultValue { set(d, animated: true) } }
            .animation(dragStart == nil ? Motion.knob : nil, value: value)
            .opacity(isEnabled ? 1 : 0.45)

            if showsMinMax {
                HStack {
                    Text("MIN")
                    Spacer()
                    Text("MAX")
                }
                .font(.system(size: max(7, size * 0.065), weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(p.muted)
                .frame(width: size * 0.92)
                .offset(y: -size * 0.1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            set(value + (direction == .increment ? 0.05 : -0.05), animated: true)
        }
    }

    // MARK: Layers

    /// Marshall-style indicator marks around the knob: short radial dashes from MIN to MAX that
    /// light up one by one in orange as the value rises. Unlit marks stay dark, like switched-off LEDs.
    private func arc(_ p: Palette, _ v: Double) -> some View {
        let marks = Self.marks
        let length = size * 0.085
        let width = max(1.8, size * 0.026)
        let inner = size * 0.415
        return ZStack {
            ForEach(0..<marks, id: \.self) { i in
                let lit = isEnabled && v * Double(marks - 1) >= Double(i) - 0.001
                let degrees = -Self.sweep / 2 + Self.sweep * Double(i) / Double(marks - 1)
                Capsule()
                    .fill(lit ? Palette.accent : p.faint.opacity(0.4))
                    .frame(width: width, height: length)
                    .shadow(color: Palette.accentGlow.opacity(lit ? 0.9 : 0), radius: width * 1.4)
                    .offset(y: -(inner + length / 2))
                    .rotationEffect(.degrees(degrees))
            }
        }
        .frame(width: size, height: size)
    }

    private func well(_ p: Palette) -> some View {
        Circle()
            .fill(LinearGradient(colors: [p.knobWellTop, p.knobWellBottom], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1).blur(radius: 1).clipShape(Circle()))
            .frame(width: size * proportions.well, height: size * proportions.well)
    }

    private func skirt(_ p: Palette) -> some View {
        let d: CGFloat = size * proportions.skirt
        let outline: CGFloat = max(1, size * 0.012)
        let body = LinearGradient(colors: [p.knobBodyTop, p.knobBodyBottom],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        let farShadow: CGFloat = size * 0.06
        let nearShadow: CGFloat = size * 0.015
        return Circle()
            .fill(body)
            .overlay(Circle().stroke(p.knobOutline, lineWidth: outline))
            .frame(width: d, height: d)
            .shadow(color: p.dropShadow, radius: farShadow, x: 0, y: size * 0.055)
            .shadow(color: p.dropShadow.opacity(0.5), radius: nearShadow, x: 0, y: size * 0.01)
    }

    private func cap(_ p: Palette) -> some View {
        let d = size * proportions.cap
        return ZStack {
            Circle().fill(RadialGradient(colors: [p.knobCapTop, p.knobCapBottom],
                                         center: UnitPoint(x: 0.35, y: 0.28),
                                         startRadius: 0, endRadius: d * 0.75))
            if p.knobSheen > 0 {
                Circle().fill(AngularGradient(colors: [.white, .clear, .white, .clear, .white, .clear, .white],
                                              center: .center))
                    .opacity(p.knobSheen)
                    .blendMode(.overlay)
            }
            Grain(opacity: p.grain * 0.8).clipShape(Circle())
            Circle().stroke(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.22 : 0.9), .clear],
                                           startPoint: .top, endPoint: .center), lineWidth: 1)
            Circle().stroke(LinearGradient(colors: [.clear, Color.black.opacity(0.25)],
                                           startPoint: .center, endPoint: .bottom), lineWidth: 1)
        }
        .frame(width: d, height: d)
    }

    private func pointer(_ p: Palette, _ v: Double) -> some View {
        let capDiameter: CGFloat = size * proportions.cap
        let width: CGFloat = max(2, size * 0.032)
        let length: CGFloat = capDiameter * 0.2
        let lift: CGFloat = capDiameter * 0.325
        let glow: Color = scheme == .dark ? Color.white.opacity(0.35) : .clear
        let degrees: Double = -Self.sweep / 2 + Self.sweep * v
        return Capsule()
            .fill(p.knobIndicator)
            .frame(width: width, height: length)
            .shadow(color: glow, radius: 2)
            .offset(y: -lift)
            .rotationEffect(.degrees(degrees))
    }

    // MARK: Interaction

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragStart == nil {
                    dragStart = value
                    rotary = RotaryDrag(sweep: Self.sweep, size: size, value: value)
                    onEditingChanged(true)
                }
                if let next = rotary?.move(to: g.location) { set(next, animated: false) }
            }
            .onEnded { _ in
                dragStart = nil
                rotary = nil
                onEditingChanged(false)
            }
    }

    private func set(_ newValue: Double, animated: Bool) {
        let clamped = min(max(newValue, 0), 1)
        if !animated { Haptics.moved(from: value, to: clamped) }
        var transaction = Transaction(animation: animated ? Motion.knob : nil)
        transaction.disablesAnimations = !animated
        withTransaction(transaction) { value = clamped }
    }
}
