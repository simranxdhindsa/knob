import SwiftUI

/// The arm, built like a real one: a machined base and arm rest, a counterweight, a chrome tube
/// with an S bend, a brushed perforated headshell and a cartridge with its screws and stylus
/// (drawn in `VinylArmDrawing`). It follows the song from the outer groove to the
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
            VinylArmRest(size: geometry.diameter * 0.05, angle: geometry.restAngle)
                .position(restPoint(reach))
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

    /// The arm rest sits under the tube where it lies at rest.
    private func restPoint(_ reach: CGFloat) -> CGPoint {
        let turn = geometry.restAngle * .pi / 180, spot = VinylArmDrawing.restSpot
        return CGPoint(x: geometry.pivot.x + reach * (spot.x * cos(turn) - spot.y * sin(turn)),
                       y: geometry.pivot.y + reach * (spot.x * sin(turn) + spot.y * cos(turn)))
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

/// The round mount the arm turns on: turned metal, darker towards its edge, with machined rings.
private struct VinylArmBase: View {
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(gradient: Vinyl.machined, center: .center, angle: .degrees(-35)))
            Circle().fill(RadialGradient(colors: [Vinyl.base.opacity(0), Vinyl.base.opacity(0.6)], center: .center,
                                         startRadius: diameter * 0.03, endRadius: diameter * 0.075))
            Circle().stroke(Vinyl.chromeDark, lineWidth: 1)
            Circle().stroke(Vinyl.shine.opacity(0.25), lineWidth: 0.6).padding(diameter * 0.012)
            Circle().stroke(Vinyl.chromeDark.opacity(0.6), lineWidth: 0.8).padding(diameter * 0.03)
        }
        .frame(width: diameter * 0.15, height: diameter * 0.15)
        .shadow(color: Glass.shadow, radius: 7, y: 4)
        .allowsHitTesting(false)
    }
}

/// The post the arm lies on at rest, with a rubber cradle across it.
private struct VinylArmRest: View {
    let size: CGFloat
    let angle: Double

    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(gradient: Vinyl.machined, center: .center, angle: .degrees(-35)))
            Circle().stroke(Vinyl.chromeDark, lineWidth: 0.8)
            Capsule().fill(Vinyl.rubber)
                .frame(width: size * 0.34, height: size * 0.9)
                .overlay(Capsule().stroke(Vinyl.shine.opacity(0.12), lineWidth: 0.5))
                .rotationEffect(.degrees(angle))
        }
        .frame(width: size, height: size)
        .shadow(color: Glass.shadow, radius: 3, y: 2)
        .allowsHitTesting(false)
    }
}
