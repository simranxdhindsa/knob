import SwiftUI

/// The arm, built like a real one: a chrome tube with an S bend, a collar, a perforated headshell
/// and a cartridge with its screws and stylus. It follows the song from the outer groove to the
/// inner one, swings in from its rest when the deck opens, and can be picked up and set down
/// anywhere on the record.
struct VinylTonearm: View {
    @ObservedObject var turntable: KnobShiftTurntable
    @ObservedObject var clock: KnobShiftClock
    let geometry: KnobShiftVinylGeometry
    var resting = false
    /// Raised off the record while it swings, so it casts a longer shadow.
    var lifted = false
    /// Told when the arm has been picked up and set down.
    var onUsed: () -> Void = {}
    /// Resets by itself if the system takes the touch away, which ends the drag with no word.
    @GestureState private var touching = false
    /// Where the finger and the song were when the arm was picked up.
    @State private var pickedUp: (finger: CGPoint, progress: Double)?
    /// The arm turns by this share of the finger's turn, for finer control over where it lands.
    private static let precision = 0.5

    private var progress: Double {
        if let held = turntable.heldProgress { return held }
        // In a KnobMix the record already shows the song coming in, so the arm plays that one,
        // read from its own deck each time the clock ticks, and is already in place as it takes over.
        let model = turntable.model
        if let next = model.mixingInto, next.duration > 0 {
            let deck = model.secondaryDeck
            return min(max((deck.position ?? deck.startOffset) / next.duration, 0), 1)
        }
        return clock.duration > 0 ? clock.time / clock.duration : 0
    }

    var body: some View {
        let held = turntable.isArmHeld
        let up = held || lifted
        let angle = resting ? geometry.restAngle : geometry.angle(progress: progress)
        let reach = geometry.armLength
        ZStack {
            VinylArmBase(diameter: geometry.diameter)
                .position(geometry.pivot)
            Canvas { context, size in VinylArmDrawing.draw(context, size: size, reach: reach) }
                .frame(width: VinylArmDrawing.width(reach), height: VinylArmDrawing.height(reach))
                .allowsHitTesting(false)
                .shadow(color: Glass.shadow, radius: up ? 12 : 5, x: 2, y: up ? 12 : 5)
                .rotationEffect(.degrees(angle), anchor: VinylArmDrawing.anchor(reach))
                .position(x: geometry.pivot.x + VinylArmDrawing.width(reach) / 2 - VinylArmDrawing.pivot(reach).x,
                          y: geometry.pivot.y + VinylArmDrawing.height(reach) / 2 - VinylArmDrawing.pivot(reach).y)
            // The part a finger takes hold of, laid out in the deck's own space on top of
            // everything, so a touch anywhere on the arm, its bend and its headshell included,
            // picks the arm up instead of turning the record underneath it.
            Color.clear
                .contentShape(VinylArmDrawing.grip(pivot: geometry.pivot, reach: reach, angle: angle))
                .gesture(pick)
        }
        .onChange(of: touching) {
            guard !touching else { return }
            pickedUp = nil
            Haptics.mark()
            turntable.armDropped()
            onUsed()
        }
        .animation(held ? nil : Motion.armSwing, value: resting)
        .animation(Motion.armLift, value: lifted)
        .animation(held || resting ? nil : .linear(duration: 0.1), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Tonearm")
        .accessibilityValue("\(Int(progress * 100)) percent through the song")
        .accessibilityAdjustableAction { direction in
            turntable.armLifted(progress: progress)
            turntable.armMoved(progress: min(max(progress + (direction == .increment ? 0.05 : -0.05), 0), 1))
            turntable.armDropped()
        }
    }

    private var pick: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(VinylStage.space))
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { drag in
                if turntable.isArmHeld, let pickedUp {
                    turntable.armMoved(progress: geometry.progress(from: pickedUp.finger, to: drag.location,
                                                                   startingAt: pickedUp.progress, precision: Self.precision))
                } else if !turntable.isArmHeld {
                    Haptics.mark()
                    pickedUp = (drag.location, progress)
                    turntable.armLifted(progress: progress)
                }
            }
    }
}

/// The bearing the arm turns on.
private struct VinylArmBase: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Vinyl.metalShade, Vinyl.base], center: .init(x: 0.4, y: 0.35), startRadius: 1, endRadius: diameter * 0.075))
            Circle().stroke(Vinyl.metal.opacity(0.5), lineWidth: 1).padding(diameter * 0.018)
            Circle()
                .fill(RadialGradient(colors: [Vinyl.shine, Vinyl.metal, Vinyl.metalShade], center: .init(x: 0.38, y: 0.32), startRadius: 0, endRadius: diameter * 0.03))
                .frame(width: diameter * 0.055, height: diameter * 0.055)
        }
        .frame(width: diameter * 0.15, height: diameter * 0.15)
        .shadow(color: Glass.shadow, radius: 7, y: 4)
        .allowsHitTesting(false)
    }
}

/// The arm's shape, laid out pointing right from its pivot, with the stylus on that line at the
/// arm's full reach, so the record's geometry needs to know nothing about the bends.
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

    /// Where the tube ends, worked back from the stylus so the tip lands exactly on the line.
    private static var bendEnd: CGPoint {
        let turn = stylusAngle * .pi / 180, head = headAngle * .pi / 180
        let along = stylusFrom + stylusReach
        let x = collar + neck + cartridge / 2 + along * cos(turn)
        let y = -stylusRise + along * sin(turn)
        return CGPoint(x: 1 - (x * cos(head) - y * sin(head)), y: -(x * sin(head) + y * cos(head)))
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

    /// The far end of the headshell, where the cartridge stops.
    private static var headEnd: CGPoint {
        let head = headAngle * .pi / 180, along = collar + neck + cartridge
        return CGPoint(x: bendEnd.x + along * cos(head), y: bendEnd.y + along * sin(head))
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
        chrome(context, tube(reach), thick: thick)
        drawKnuckle(context, start: start, reach: reach)
        var head = context
        head.translateBy(x: start.x + bendEnd.x * reach, y: start.y + bendEnd.y * reach)
        head.rotate(by: .degrees(headAngle))
        drawHead(head, reach: reach, thick: thick)
    }

    /// A round tube: dark edges, a bright body and one hard line of light along the top.
    private static func chrome(_ context: GraphicsContext, _ path: Path, thick: CGFloat) {
        let style = { (share: CGFloat) in StrokeStyle(lineWidth: thick * share, lineCap: .round, lineJoin: .round) }
        context.stroke(path, with: .color(Vinyl.chromeDark), style: style(1))
        context.stroke(path, with: .color(Vinyl.metalShade), style: style(0.82))
        context.stroke(path.offsetBy(dx: 0, dy: -thick * 0.07), with: .color(Vinyl.metal), style: style(0.56))
        context.stroke(path.offsetBy(dx: 0, dy: -thick * 0.17), with: .color(Vinyl.shine), style: style(0.18))
    }

    /// A short polished cylinder across the tube.
    private static func band(_ context: GraphicsContext, _ rect: CGRect) {
        let shape = Path(roundedRect: rect, cornerRadius: min(rect.height, rect.width) * 0.18)
        context.fill(shape, with: .linearGradient(Gradient(stops: [
            .init(color: Vinyl.chromeDark, location: 0), .init(color: Vinyl.metal, location: 0.22),
            .init(color: Vinyl.shine, location: 0.36), .init(color: Vinyl.metalShade, location: 0.62),
            .init(color: Vinyl.chromeDark, location: 1),
        ]), startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
    }

    /// The gimbal at the pivot: two polished blocks and the sleeve the tube runs into.
    private static func drawKnuckle(_ context: GraphicsContext, start: CGPoint, reach: CGFloat) {
        var joint = context
        joint.translateBy(x: start.x, y: start.y)
        band(joint, CGRect(x: -reach * 0.075, y: -reach * 0.052, width: reach * 0.095, height: reach * 0.104))
        band(joint, CGRect(x: reach * 0.02, y: -reach * 0.036, width: reach * 0.06, height: reach * 0.072))
        band(joint, CGRect(x: reach * 0.08, y: -reach * 0.027, width: reach * 0.035, height: reach * 0.05))
    }

    private static func drawHead(_ context: GraphicsContext, reach: CGFloat, thick: CGFloat) {
        let collarLength = reach * collar, neckLength = reach * neck
        band(context, CGRect(x: -reach * 0.004, y: -thick * 0.72, width: collarLength, height: thick * 1.44))
        band(context, CGRect(x: collarLength * 0.5, y: -thick * 0.9, width: collarLength * 0.32, height: thick * 1.8))
        // The perforated part of the headshell.
        let neckBox = CGRect(x: collarLength, y: -reach * 0.037, width: neckLength, height: reach * 0.074)
        let plate = Gradient(colors: [Vinyl.plateLight, Vinyl.plate])
        let from = CGPoint(x: neckBox.midX, y: neckBox.minY), to = CGPoint(x: neckBox.midX, y: neckBox.maxY)
        context.fill(Path(roundedRect: neckBox, cornerRadius: reach * 0.006), with: .linearGradient(plate, startPoint: from, endPoint: to))
        let hole = reach * 0.0125
        for column in 0..<5 {
            for row in 0..<2 {
                let x = neckBox.minX + neckBox.width * (0.14 + 0.18 * CGFloat(column)) + (row == 0 ? 0 : neckBox.width * 0.09)
                let y = neckBox.midY + (row == 0 ? -1 : 1) * reach * 0.015
                context.fill(Path(ellipseIn: CGRect(x: x - hole / 2, y: y - hole / 2, width: hole, height: hole)), with: .color(Vinyl.chromeDark))
            }
        }
        // The wider front, with the cartridge's two pairs of screws.
        let cartridgeLength = reach * cartridge
        let front = CGRect(x: neckBox.maxX, y: -reach * 0.062, width: cartridgeLength, height: reach * 0.124)
        context.fill(Path(roundedRect: front, cornerRadius: reach * 0.005), with: .linearGradient(
            plate, startPoint: CGPoint(x: front.midX, y: front.minY), endPoint: CGPoint(x: front.midX, y: front.maxY)))
        context.stroke(Path(roundedRect: front, cornerRadius: reach * 0.005), with: .color(Vinyl.shine.opacity(0.22)), lineWidth: 0.6)
        context.stroke(Path(roundedRect: neckBox, cornerRadius: reach * 0.006), with: .color(Vinyl.shine.opacity(0.14)), lineWidth: 0.5)
        for side: CGFloat in [-1, 1] {
            for step: CGFloat in [0.32, 0.68] {
                let screw = reach * 0.016
                let box = CGRect(x: front.minX + front.width * step - screw / 2, y: front.midY + side * reach * 0.034 - screw / 2, width: screw, height: screw)
                context.fill(Path(ellipseIn: box), with: .radialGradient(Gradient(colors: [Vinyl.shine, Vinyl.metalShade]), center: CGPoint(x: box.midX, y: box.midY), startRadius: 0, endRadius: screw / 2))
            }
        }
        // The stylus, reaching down to the groove.
        var tip = context
        tip.translateBy(x: front.midX, y: front.midY - reach * stylusRise)
        tip.rotate(by: .degrees(stylusAngle))
        let needle = CGRect(x: reach * stylusFrom, y: -reach * 0.0055, width: reach * stylusReach, height: reach * 0.011)
        band(tip, needle)
    }
}
