import SwiftUI

/// The arm's shape, laid out pointing right from its pivot, with the stylus on that line at the
/// arm's full reach, so the record's geometry needs to know nothing about the bends. Drawn with
/// the finish of a real arm: a knurled counterweight behind a machined gimbal, a deep chrome tube,
/// a brushed headshell with its lead wires, and a glossy cartridge with a fine
/// stylus. Every colour comes from `Vinyl`.
enum VinylArmDrawing {
    static func width(_ reach: CGFloat) -> CGFloat { reach * 1.22 }
    static func height(_ reach: CGFloat) -> CGFloat { reach * 0.6 }
    static func pivot(_ reach: CGFloat) -> CGPoint { CGPoint(x: reach * 0.14, y: reach * 0.3) }
    static func anchor(_ reach: CGFloat) -> UnitPoint {
        UnitPoint(x: pivot(reach).x / width(reach), y: pivot(reach).y / height(reach))
    }

    /// Key points as shares of the reach, measured from the pivot.
    private static let bendStart = CGPoint(x: 0.56, y: -0.075)
    private static let headAngle = 30.0, stylusAngle = -80.0
    private static let collar = 0.05, neck = 0.125, cartridge = 0.075
    /// The stylus starts this far in from the front's centre and reaches this far.
    private static let stylusFrom = 0.02, stylusReach = 0.095, stylusRise = 0.02
    /// The point on the straight part of the tube that lies in the arm rest's cradle.
    static let restSpot = CGPoint(x: 0.45, y: -0.059)

    /// Where the tube ends, worked back from the stylus so the tip lands exactly on the line.
    private static var bendEnd: CGPoint {
        let turn = stylusAngle * .pi / 180, head = headAngle * .pi / 180
        let along = stylusFrom + stylusReach
        let x = collar + neck + cartridge / 2 + along * cos(turn)
        let y = -stylusRise + along * sin(turn)
        return CGPoint(x: 1 - (x * cos(head) - y * sin(head)), y: -(x * sin(head) + y * cos(head)))
    }

    /// The far end of the headshell, where the cartridge stops.
    private static var headEnd: CGPoint {
        let head = headAngle * .pi / 180, along = collar + neck + cartridge
        return CGPoint(x: bendEnd.x + along * cos(head), y: bendEnd.y + along * sin(head))
    }

    private static func tube(_ reach: CGFloat) -> Path {
        let start = pivot(reach)
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: start.x + x * reach, y: start.y + y * reach) }
        var path = Path()
        path.move(to: at(0.05, 0))
        path.addLine(to: at(bendStart.x, bendStart.y))
        let head = headAngle * .pi / 180
        path.addCurve(to: at(bendEnd.x, bendEnd.y), control1: at(bendStart.x + 0.07, bendStart.y - 0.01),
                      control2: at(bendEnd.x - 0.06 * cos(head), bendEnd.y - 0.06 * sin(head)))
        return path
    }

    /// Where a finger can take hold of the arm, in the deck's space with the arm turned to this
    /// angle: along the tube, round the bend, over the whole headshell and down to the stylus,
    /// and wide enough for a fingertip all the way.
    static func grip(pivot: CGPoint, reach: CGFloat, angle: Double) -> Path {
        let points = [CGPoint(x: 0.05, y: 0), bendStart, bendEnd, headEnd, CGPoint(x: 1, y: 0)]
        var line = Path()
        line.addLines(points.map { CGPoint(x: $0.x * reach, y: $0.y * reach) })
        let place = CGAffineTransform(rotationAngle: angle * .pi / 180)
            .concatenating(CGAffineTransform(translationX: pivot.x, y: pivot.y))
        return line.strokedPath(StrokeStyle(lineWidth: max(48, reach * 0.17), lineCap: .round, lineJoin: .round))
            .applying(place)
    }

    static func draw(_ context: GraphicsContext, size: CGSize, reach: CGFloat) {
        let thick = reach * 0.03
        let start = pivot(reach)
        var joint = context
        joint.translateBy(x: start.x, y: start.y)
        drawCounterweight(joint, reach: reach, thick: thick)
        chrome(context, tube(reach), thick: thick)
        drawGimbal(joint, reach: reach)
        var head = context
        head.translateBy(x: start.x + bendEnd.x * reach, y: start.y + bendEnd.y * reach)
        head.rotate(by: .degrees(headAngle))
        drawHead(head, reach: reach, thick: thick)
    }

    // MARK: Finishes

    /// Polished round tube: dark edges, a bright body, the warm room low on its side, the dark band
    /// chrome always shows across its middle, a soft and a hard highlight, and a thin rim light.
    private static func chrome(_ context: GraphicsContext, _ path: Path, thick: CGFloat) {
        func line(_ color: Color, _ share: CGFloat, _ shift: CGFloat) {
            context.stroke(path.offsetBy(dx: 0, dy: thick * shift), with: .color(color),
                           style: StrokeStyle(lineWidth: thick * share, lineCap: .round, lineJoin: .round))
        }
        line(Vinyl.chromeDark, 1, 0)
        line(Vinyl.metalShade, 0.86, -0.02)
        line(Vinyl.metal, 0.6, -0.08)
        line(Vinyl.chromeWarm.opacity(0.55), 0.22, 0.24)
        line(Vinyl.chromeDark.opacity(0.65), 0.1, 0.1)
        line(Vinyl.shine.opacity(0.35), 0.36, -0.2)
        line(Vinyl.shine, 0.12, -0.22)
        line(Vinyl.shine.opacity(0.3), 0.06, 0.4)
    }

    /// A short polished cylinder seen from above, lit from the top.
    private static func band(_ context: GraphicsContext, _ rect: CGRect, corner: CGFloat = 0.18) {
        let shape = Path(roundedRect: rect, cornerRadius: min(rect.height, rect.width) * corner)
        context.fill(shape, with: .linearGradient(Gradient(stops: [
            .init(color: Vinyl.chromeDark, location: 0), .init(color: Vinyl.metalShade, location: 0.1),
            .init(color: Vinyl.metal, location: 0.24), .init(color: Vinyl.shine, location: 0.32),
            .init(color: Vinyl.metal, location: 0.42), .init(color: Vinyl.metalShade, location: 0.62),
            .init(color: Vinyl.chromeWarm, location: 0.82), .init(color: Vinyl.chromeDark, location: 1),
        ]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        context.stroke(shape, with: .color(Vinyl.chromeDark.opacity(0.6)), lineWidth: 0.5)
    }

    /// Fine lines along a flat plate, each a touch lighter or darker, and a soft sheen across it.
    private static func brushed(_ context: GraphicsContext, _ shape: Path, _ rect: CGRect) {
        var plate = context
        plate.clip(to: shape)
        let spacing: CGFloat = 0.8
        for row in 0..<Int(rect.height / spacing) {
            let y = rect.minY + CGFloat(row) * spacing + spacing / 2
            let noise = sin(Double(row) * 12.9898 + Double(rect.width) * 0.37) * 43_758.5453
            let shade = noise - noise.rounded(.down)
            let color = shade > 0.5 ? Vinyl.shine.opacity(0.03 + 0.1 * (shade - 0.5)) : Vinyl.chromeDark.opacity(0.06 + 0.12 * shade)
            var line = Path()
            line.move(to: CGPoint(x: rect.minX, y: y))
            line.addLine(to: CGPoint(x: rect.maxX, y: y))
            plate.stroke(line, with: .color(color), lineWidth: 0.5)
        }
        plate.fill(shape, with: .linearGradient(Gradient(colors: [Vinyl.shine.opacity(0), Vinyl.shine.opacity(0.13), Vinyl.shine.opacity(0)]),
                                                 startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
    }

    private static func dome(_ context: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let box = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: box), with: .radialGradient(Gradient(colors: [Vinyl.shine, Vinyl.metal, Vinyl.metalShade, Vinyl.chromeDark]),
                                                                 center: CGPoint(x: center.x - radius * 0.3, y: center.y - radius * 0.35),
                                                                 startRadius: 0, endRadius: radius * 1.3))
    }

    // MARK: Parts

    /// The stub behind the pivot and the weight that balances the arm, knurled for the fingers.
    private static func drawCounterweight(_ context: GraphicsContext, reach: CGFloat, thick: CGFloat) {
        band(context, CGRect(x: -reach * 0.075, y: -thick * 0.36, width: reach * 0.075, height: thick * 0.72))
        let weight = CGRect(x: -reach * 0.135, y: -reach * 0.062, width: reach * 0.075, height: reach * 0.124)
        band(context, weight, corner: 0.12)
        let ridges = 16
        for ridge in 0..<ridges {
            let x = weight.minX + weight.width * (0.1 + 0.4 * CGFloat(ridge) / CGFloat(ridges - 1))
            var line = Path()
            line.move(to: CGPoint(x: x, y: weight.minY + 1))
            line.addLine(to: CGPoint(x: x, y: weight.maxY - 1))
            context.stroke(line, with: .color(ridge.isMultiple(of: 2) ? Vinyl.chromeDark.opacity(0.55) : Vinyl.shine.opacity(0.22)), lineWidth: 0.6)
        }
        // The engraved line of the weight's scale.
        var mark = Path()
        mark.move(to: CGPoint(x: weight.minX + weight.width * 0.62, y: weight.minY + 1))
        mark.addLine(to: CGPoint(x: weight.minX + weight.width * 0.62, y: weight.maxY - 1))
        context.stroke(mark, with: .color(Vinyl.chromeDark.opacity(0.7)), lineWidth: 0.8)
    }

    /// The gimbal: a yoke either side, the machined bearing cap and the sleeve the tube runs into.
    private static func drawGimbal(_ context: GraphicsContext, reach: CGFloat) {
        band(context, CGRect(x: -reach * 0.032, y: -reach * 0.072, width: reach * 0.064, height: reach * 0.144), corner: 0.3)
        let radius = reach * 0.044
        band(context, CGRect(x: radius * 0.75, y: -reach * 0.024, width: reach * 0.05, height: reach * 0.048))
        let cap = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: cap), with: .conicGradient(Vinyl.machined, center: .zero, angle: .degrees(-35)))
        context.stroke(Path(ellipseIn: cap), with: .color(Vinyl.chromeDark), lineWidth: 0.8)
        context.stroke(Path(ellipseIn: cap.insetBy(dx: radius * 0.3, dy: radius * 0.3)), with: .color(Vinyl.chromeDark.opacity(0.5)), lineWidth: 0.6)
        dome(context, center: .zero, radius: radius * 0.28)
    }

    private static func drawHead(_ context: GraphicsContext, reach: CGFloat, thick: CGFloat) {
        let collarLength = reach * collar, neckLength = reach * neck, cartridgeLength = reach * cartridge
        let neckBox = CGRect(x: collarLength, y: -reach * 0.037, width: neckLength, height: reach * 0.074)
        let front = CGRect(x: neckBox.maxX, y: -reach * 0.062, width: cartridgeLength, height: reach * 0.124)

        // The lead wires, from the tube's end to the cartridge pins, half under the plate.
        for (index, color) in Vinyl.leads.enumerated() {
            let y = (CGFloat(index) - 1.5) * reach * 0.011
            var wire = Path()
            wire.move(to: CGPoint(x: collarLength * 0.7, y: y * 0.6))
            wire.addLine(to: CGPoint(x: neckBox.minX + neckBox.width * 0.18, y: y))
            context.stroke(wire, with: .color(color.opacity(0.9)), lineWidth: max(0.8, reach * 0.004))
        }

        // The cartridge hangs under the front of the headshell; its glossy body shows past the plate.
        let body = CGRect(x: front.minX + front.width * 0.1, y: -reach * 0.05, width: front.width, height: reach * 0.1)
        context.fill(Path(roundedRect: body, cornerRadius: reach * 0.008), with: .linearGradient(Gradient(stops: [
            .init(color: Vinyl.cartridgeGloss, location: 0), .init(color: Vinyl.cartridge, location: 0.3),
            .init(color: Vinyl.cartridge, location: 0.78), .init(color: Vinyl.cartridgeGloss.opacity(0.6), location: 1),
        ]), startPoint: CGPoint(x: body.midX, y: body.minY), endPoint: CGPoint(x: body.midX, y: body.maxY)))

        // The stylus: a fine cantilever from under the cartridge, with its tip catching the light.
        var tip = context
        tip.translateBy(x: front.midX, y: front.midY - reach * stylusRise)
        tip.rotate(by: .degrees(stylusAngle))
        band(tip, CGRect(x: reach * stylusFrom, y: -reach * 0.0035, width: reach * stylusReach, height: reach * 0.007), corner: 0.5)
        dome(tip, center: CGPoint(x: reach * (stylusFrom + stylusReach), y: 0), radius: max(1, reach * 0.0045))

        // The collar where the headshell plugs into the tube.
        band(context, CGRect(x: -reach * 0.004, y: -thick * 0.72, width: collarLength, height: thick * 1.44))
        band(context, CGRect(x: collarLength * 0.5, y: -thick * 0.9, width: collarLength * 0.32, height: thick * 1.8))

        // The headshell plates: brushed metal, the neck perforated with bevelled holes.
        let plate = Gradient(colors: [Vinyl.plateLight, Vinyl.plate])
        let neckShape = Path(roundedRect: neckBox, cornerRadius: reach * 0.006)
        context.fill(neckShape, with: .linearGradient(plate, startPoint: CGPoint(x: neckBox.midX, y: neckBox.minY), endPoint: CGPoint(x: neckBox.midX, y: neckBox.maxY)))
        brushed(context, neckShape, neckBox)
        let hole = reach * 0.0125
        for column in 0..<5 {
            for row in 0..<2 {
                let x = neckBox.minX + neckBox.width * (0.14 + 0.18 * CGFloat(column)) + (row == 0 ? 0 : neckBox.width * 0.09)
                let y = neckBox.midY + (row == 0 ? -1 : 1) * reach * 0.015
                let box = CGRect(x: x - hole / 2, y: y - hole / 2, width: hole, height: hole)
                context.fill(Path(ellipseIn: box), with: .color(Vinyl.cartridge))
                context.stroke(Path(ellipseIn: box.offsetBy(dx: 0, dy: hole * 0.12)), with: .color(Vinyl.shine.opacity(0.2)), lineWidth: 0.5)
            }
        }
        let frontShape = Path(roundedRect: front, cornerRadius: reach * 0.005)
        context.fill(frontShape, with: .linearGradient(plate, startPoint: CGPoint(x: front.midX, y: front.minY), endPoint: CGPoint(x: front.midX, y: front.maxY)))
        brushed(context, frontShape, front)
        context.stroke(frontShape, with: .color(Vinyl.shine.opacity(0.22)), lineWidth: 0.6)
        context.stroke(neckShape, with: .color(Vinyl.shine.opacity(0.14)), lineWidth: 0.5)

        // The cartridge's mounting screws, each slot at its own angle.
        let slots: [Double] = [20, 75, -35, 110]
        var index = 0
        for side: CGFloat in [-1, 1] {
            for step: CGFloat in [0.32, 0.68] {
                let screw = reach * 0.016
                let center = CGPoint(x: front.minX + front.width * step, y: front.midY + side * reach * 0.034)
                dome(context, center: center, radius: screw / 2)
                var slot = context
                slot.translateBy(x: center.x, y: center.y)
                slot.rotate(by: .degrees(slots[index]))
                slot.fill(Path(CGRect(x: -screw * 0.4, y: -screw * 0.07, width: screw * 0.8, height: screw * 0.14)), with: .color(Vinyl.chromeDark))
                index += 1
            }
        }
    }
}
