import SwiftUI

/// The pictures a record is made of, each drawn once per size and then only ever turned, so a
/// frame of spinning costs a transform and nothing is redrawn. `face` is what turns with the
/// record: fine grooves, the gaps between tracks, the smooth band around the label and the faint
/// marks that show it spinning, since perfect circles alone look still however fast they turn.
/// `light` stays put, as light does: the fans of reflection that catch on the grooves.
@MainActor
enum VinylTexture {
    private static var faces: [Int: Image] = [:]
    private static var lights: [Int: Image] = [:]

    static let grooveOuter = 0.975, grooveInner = 0.44, label = 0.35

    static func face(_ diameter: CGFloat) -> Image {
        cached(&faces, diameter) { Canvas { context, size in drawFace(context, size) } }
    }

    static func light(_ diameter: CGFloat) -> Image {
        cached(&lights, diameter) { Canvas { context, size in drawLight(context, size) } }
    }

    private static func cached<V: View>(_ store: inout [Int: Image], _ diameter: CGFloat, @ViewBuilder _ content: () -> V) -> Image {
        let key = Int(diameter.rounded())
        if let image = store[key] { return image }
        let side = CGFloat(key)
        let renderer = ImageRenderer(content: content().frame(width: side, height: side))
        renderer.scale = 3
        renderer.isOpaque = false
        guard let picture = renderer.cgImage else { return Image(systemName: "circle") }
        let image = Image(decorative: picture, scale: 3)
        store = [key: image]
        return image
    }

    /// The same every time: a record's marks must not change between drawings.
    private struct Noise {
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(UInt32.max >> 1)
        }
    }

    /// Where the gaps between tracks fall, as shares of the radius.
    private static let gaps = [0.845, 0.73, 0.625, 0.525]

    private static func isGap(_ share: Double) -> Bool { gaps.contains { abs($0 - share) < 0.007 } }

    private static func ring(_ middle: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: middle.x - radius, y: middle.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func drawFace(_ context: GraphicsContext, _ size: CGSize) {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width / 2
        var noise = Noise()
        context.fill(ring(middle, radius), with: .radialGradient(
            Gradient(colors: [Vinyl.discCore, Vinyl.disc, Vinyl.discCore]), center: middle, startRadius: radius * 0.3, endRadius: radius))
        context.stroke(ring(middle, radius - 0.5), with: .color(Vinyl.rim), lineWidth: 1)
        let spacing = max(radius / 190, 0.55)
        var at = radius * grooveOuter
        while at > radius * grooveInner {
            let share = Double(at / radius)
            if !isGap(share) {
                let strength = 0.025 + noise.next() * 0.05
                context.stroke(ring(middle, at), with: .color(Vinyl.shine.opacity(strength)), lineWidth: spacing * 0.42)
            }
            at -= spacing
        }
        for gap in gaps {
            context.stroke(ring(middle, radius * (gap + 0.0075)), with: .color(Vinyl.shine.opacity(0.11)), lineWidth: 0.5)
            context.stroke(ring(middle, radius * (gap - 0.0075)), with: .color(Vinyl.shine.opacity(0.08)), lineWidth: 0.5)
        }
        for share in [0.43, 0.405, 0.385] {
            context.stroke(ring(middle, radius * share), with: .color(Vinyl.shine.opacity(0.05)), lineWidth: 0.5)
        }
        // Long faint sweeps along the grooves and a few hairlines across them.
        for _ in 0..<34 {
            let at = radius * (grooveInner + 0.02 + noise.next() * (grooveOuter - grooveInner - 0.04))
            let start = noise.next() * 360, span = 16 + noise.next() * 46
            var sweep = Path()
            sweep.addArc(center: middle, radius: at, startAngle: .degrees(start), endAngle: .degrees(start + span), clockwise: false)
            context.stroke(sweep, with: .color(Vinyl.shine.opacity(0.018 + noise.next() * 0.03)), lineWidth: radius * (0.004 + noise.next() * 0.012))
        }
        for _ in 0..<9 {
            let angle = noise.next() * 2 * .pi, from = radius * (0.5 + noise.next() * 0.42)
            let length = radius * (0.03 + noise.next() * 0.07), lean = (noise.next() - 0.5) * 0.9
            var hair = Path()
            hair.move(to: CGPoint(x: middle.x + cos(angle) * from, y: middle.y + sin(angle) * from))
            hair.addLine(to: CGPoint(x: middle.x + cos(angle + lean / 4) * (from + length), y: middle.y + sin(angle + lean / 4) * (from + length)))
            context.stroke(hair, with: .color(Vinyl.shine.opacity(0.1)), lineWidth: 0.35)
        }
    }

    private static func drawLight(_ context: GraphicsContext, _ size: CGSize) {
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width / 2
        var noise = Noise(state: 0x9E37_79B9_7F4A_7C15)
        let spacing = max(radius / 190, 0.55)
        var at = radius * grooveOuter
        while at > radius * grooveInner {
            let share = Double(at / radius)
            if !isGap(share) {
                // Each groove catches the light a little differently, which is what makes the
                // reflection look like fine lines rather than a smooth glow.
                let catches = pow(noise.next(), 2.6) * 0.62 + 0.08
                context.stroke(ring(middle, at), with: .conicGradient(fan(catches), center: middle), lineWidth: spacing * 0.8)
            }
            at -= spacing
        }
        context.stroke(ring(middle, radius - 0.7), with: .conicGradient(fan(1.9), center: middle), lineWidth: 1.1)
    }

    /// Two fans of light across from each other, the stronger one low on the right.
    private static func fan(_ strength: Double) -> Gradient {
        func light(_ value: Double) -> Color { Vinyl.shine.opacity(min(value * strength, 1)) }
        return Gradient(stops: [
            .init(color: light(0.34), location: 0), .init(color: light(0.62), location: 0.07),
            .init(color: light(0.3), location: 0.15), .init(color: light(0), location: 0.25),
            .init(color: light(0), location: 0.45), .init(color: light(0.2), location: 0.53),
            .init(color: light(0.42), location: 0.59), .init(color: light(0.16), location: 0.67),
            .init(color: light(0), location: 0.76), .init(color: light(0), location: 0.92),
            .init(color: light(0.34), location: 1),
        ])
    }
}
