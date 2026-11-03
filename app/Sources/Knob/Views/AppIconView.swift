import SwiftUI

/// Knob's app icon, drawn with the same parts as the panel: a grained charcoal faceplate in the
/// macOS icon shape, a soft orange glow and the realistic knob. `--icons DIR` renders it to PNG.
/// `fullBleed` is the iPhone icon: the faceplate fills the whole square, since iOS rounds the
/// corners itself and an iPhone icon may not be see-through anywhere.
struct AppIconView: View {
    var size: CGFloat = 1024
    var fullBleed = false

    var body: some View {
        let scale = size / 1024
        let plate = RoundedRectangle(cornerRadius: fullBleed ? 0 : 185 * scale, style: .continuous)
        let plateSize = (fullBleed ? 1024 : 824) * scale
        ZStack {
            plate
                .fill(LinearGradient(colors: [Color(hex: 0x484B51), Color(hex: 0x1C1E21)], startPoint: .top, endPoint: .bottom))
                .overlay(Grain(opacity: 0.05).clipShape(plate))
                .overlay(plate.stroke(LinearGradient(colors: [.white.opacity(fullBleed ? 0 : 0.22), .clear], startPoint: .top, endPoint: .center),
                                      lineWidth: 3 * scale))
                .overlay {
                    RadialGradient(colors: [Palette.accentGlow.opacity(0.34), .clear],
                                   center: UnitPoint(x: 0.5, y: 0.1), startRadius: 0, endRadius: 300 * scale)
                        .scaleEffect(x: 1.6, y: 1, anchor: .top)
                        .clipShape(plate)
                }
                .frame(width: plateSize, height: plateSize)
                .shadow(color: .black.opacity(fullBleed ? 0 : 0.35), radius: 22 * scale, y: 14 * scale)
            RealisticKnob(value: .constant(0.68), size: (fullBleed ? 790 : 590) * scale, showsMinMax: false,
                          accessibilityLabel: "Knob", accessibilityValue: "")
                .offset(y: 8 * scale)
        }
        .frame(width: size, height: size)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }
}

/// Knob's knob as the iPhone app's opening shows it: no halo behind it, only its own indicator
/// marks glowing as they light. The same view draws the iPhone's launch image (`--icons`) and
/// the live opening (ios/Sources/PhoneLaunch.swift), so the still picture and the first frame of
/// the animation match exactly.
struct LaunchKnobPose: View {
    var value: Double
    var size: CGFloat
    var knobScale: Double = 1
    var knobOpacity: Double = 1
    /// Degrees the pointer strains past the end stop.
    var overshoot: Double = 0

    var body: some View {
        RealisticKnob(value: .constant(value), size: size, showsMinMax: false,
                      accessibilityLabel: "Knob", accessibilityValue: "", springsToChanges: false,
                      pointerOvershoot: overshoot)
            .allowsHitTesting(false)
            .scaleEffect(knobScale)
            .opacity(knobOpacity)
            .frame(width: size * 1.8, height: size * 1.8)
            .environment(\.colorScheme, .dark)
            .accessibilityHidden(true)
    }
}
