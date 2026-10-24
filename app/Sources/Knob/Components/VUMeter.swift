import SwiftUI

/// A small analog VU meter in Knob's hardware style: a recessed face in the knobs' own finish
/// (charcoal in dark, speckled white in light) behind glass, the classic 20...0...3 scale with
/// Knob's orange over 0, and a glowing orange needle swinging on a knob-cap hub. 0 VU sits at
/// -6 dBFS peak.
/// Needle shape, hub placement and spring follow Analog UI's Needle Gauge (TechSquidTV, MIT),
/// https://analogui.com/docs/components/needle-gauge/, restyled to Knob's palette.
struct VUMeter: View {
    /// Linear peak level, 0...1, as the engine reports it.
    var level: Double
    var width: CGFloat = 84
    var height: CGFloat = 60

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled

    /// Half the needle's swing, in degrees either side of upright.
    private static let swing = 40.0
    /// Scale marks in VU, and which carry a number.
    private static let marks: [Double] = [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3]
    private static let numbered: [Double] = [-20, -10, -5, 0, 3]
    private static let bezel: CGFloat = 3.5

    private var p: Palette { Palette.of(scheme) }
    private var faceWidth: CGFloat { width - Self.bezel * 2 }
    private var faceHeight: CGFloat { height - Self.bezel * 2 }
    private var rotation: Double { angle(Self.position(level: level)) }

    var body: some View {
        ZStack {
            // Raised housing, lit from above like the knobs.
            RoundedRectangle(cornerRadius: 7)
                .fill(LinearGradient(colors: [p.knobBodyTop, p.knobBodyBottom], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(p.knobOutline, lineWidth: 0.8))
                .shadow(color: p.dropShadow, radius: 4, x: 0, y: 3)
            face
                .frame(width: faceWidth, height: faceHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // The face sits recessed: a shadow cast by the top edge of the bezel.
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(p.knobOutline.opacity(0.7), lineWidth: 0.8))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(LinearGradient(colors: [p.dropShadow, .clear], startPoint: .top, endPoint: .center),
                            lineWidth: 3)
                    .blur(radius: 1.5)
                    .clipShape(RoundedRectangle(cornerRadius: 4)))
        }
        .frame(width: width, height: height)
        .opacity(isEnabled ? 1 : 0.6)
        .accessibilityHidden(true)   // The L/R meter beside it already reads the level out.
    }

    private var face: some View {
        ZStack {
            LinearGradient(colors: [p.knobWellBottom, p.knobCapBottom], startPoint: .top, endPoint: .bottom)
            Grain(opacity: p.grain)
            // Orange backlight that warms with the level, like the screen glow below.
            RadialGradient(colors: [Palette.accentGlow.opacity(isEnabled ? 0.06 + 0.16 * Self.position(level: level) : 0), .clear],
                           center: UnitPoint(x: 0.5, y: 1), startRadius: 0, endRadius: faceWidth * 0.7)
                .animation(.linear(duration: 0.15), value: level)
            scale
            Text("VU")
                .font(.system(size: 8, weight: .bold)).tracking(0.8)
                .foregroundStyle(p.muted)
                .position(x: faceWidth / 2, y: faceHeight * 0.6)
            needle
            hub
            glass
        }
    }

    // MARK: Geometry

    /// The needle pivots on the bottom edge of the face, under the hub.
    private var pivot: CGPoint { CGPoint(x: faceWidth / 2, y: faceHeight) }
    private var arcRadius: CGFloat { faceHeight * 0.8 }

    /// Where a VU value sits along the scale, 0...1. Like a real VU face the scale follows
    /// voltage, so the low end is crowded and the top end is wide.
    static func position(vu: Double) -> Double {
        let low = pow(10, -20.0 / 20), high = pow(10, 3.0 / 20)
        return (pow(10, vu / 20) - low) / (high - low)
    }

    /// Needle position for a linear peak level; rests on its stop just below the scale when silent.
    static func position(level: Double) -> Double {
        let vu = LevelMeter.decibels(level) + 6
        return min(max(position(vu: vu), -0.06), 1.06)
    }

    private func angle(_ position: Double) -> Double { -Self.swing + 2 * Self.swing * position }

    private func point(_ position: Double, radius: CGFloat) -> CGPoint {
        let a = angle(position) * .pi / 180
        return CGPoint(x: pivot.x + radius * sin(a), y: pivot.y - radius * cos(a))
    }

    // MARK: Layers

    private var scale: some View {
        let ink = p.label, minor = p.muted
        return Canvas { context, _ in
            let r = arcRadius
            let zero = Self.position(vu: 0)
            var arc = Path()
            arc.addArc(center: pivot, radius: r, startAngle: .degrees(-90 - Self.swing),
                       endAngle: .degrees(-90 + angle(zero)), clockwise: false)
            context.stroke(arc, with: .color(minor), lineWidth: 0.8)

            var hot = Path()
            hot.addArc(center: pivot, radius: r + 1.2, startAngle: .degrees(-90 + angle(zero)),
                       endAngle: .degrees(-90 + Self.swing), clockwise: false)
            context.stroke(hot, with: .color(Palette.accent), lineWidth: 2.6)

            for vu in Self.marks {
                let pos = Self.position(vu: vu)
                let long = Self.numbered.contains(vu)
                var tick = Path()
                tick.move(to: point(pos, radius: r))
                tick.addLine(to: point(pos, radius: r + (long ? 4.5 : 3)))
                context.stroke(tick, with: .color(vu > 0 ? Palette.accent : (long ? ink : minor)), lineWidth: 0.8)
            }
            for vu in Self.numbered {
                let label = Text("\(Int(abs(vu)))")
                    .font(.system(size: 6.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(vu > 0 ? Palette.accent : ink)
                context.draw(label, at: point(Self.position(vu: vu), radius: r + 9.5))
            }
            context.draw(Text("−").font(.system(size: 7, weight: .bold)).foregroundStyle(minor),
                         at: CGPoint(x: 5, y: faceHeight * 0.62))
            context.draw(Text("+").font(.system(size: 7, weight: .bold)).foregroundStyle(Palette.accent),
                         at: CGPoint(x: faceWidth - 5, y: faceHeight * 0.62))
        }
    }

    /// Tapered needle (Analog UI's outline): a fine tip, widest near the hub, lit orange at the
    /// tip and falling into shade at the base.
    private var needle: some View {
        let length = arcRadius + 5
        return NeedleBlade()
            .fill(LinearGradient(stops: [.init(color: Palette.accentGlow, location: 0),
                                         .init(color: Palette.accent, location: 0.42),
                                         .init(color: Meter.needleShade, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 4, height: length)
            .shadow(color: Palette.accentGlow.opacity(isEnabled ? 0.7 : 0), radius: 2)
            .offset(y: -length / 2)
            .rotationEffect(.degrees(rotation), anchor: .center)
            .position(pivot)
            .animation(Motion.vuNeedle, value: level)
    }

    /// The hub on the bottom edge, finished like a knob cap.
    private var hub: some View {
        let d = faceWidth * 0.17
        return ZStack {
            Circle().fill(RadialGradient(colors: [p.knobCapTop, p.knobCapBottom],
                                         center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: d * 0.75))
            Circle().stroke(p.knobOutline, lineWidth: 0.7)
        }
        .frame(width: d, height: d)
        .shadow(color: p.dropShadow, radius: 1.5, x: 0, y: -0.5)
        .position(x: faceWidth / 2, y: faceHeight)
    }

    /// Glare on the glass: a soft diagonal sheen across the top of the face.
    private var glass: some View {
        LinearGradient(stops: [.init(color: Meter.glass.opacity(scheme == .dark ? 0.12 : 0.45), location: 0),
                               .init(color: Meter.glass.opacity(scheme == .dark ? 0.03 : 0.1), location: 0.42),
                               .init(color: .clear, location: 0.43)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .allowsHitTesting(false)
    }
}

/// Analog UI's needle outline, `polygon(46% 0%, 54% 0%, 68% 82%, 50% 100%, 32% 82%)`.
private struct NeedleBlade: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + r.width * 0.46, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.54, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.68, y: r.minY + r.height * 0.82))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.32, y: r.minY + r.height * 0.82))
        p.closeSubpath()
        return p
    }
}
