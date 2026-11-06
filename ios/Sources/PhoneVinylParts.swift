import SwiftUI

/// The record: grooves, a label cut from the song's cover and a spindle. It turns as one picture,
/// drawn once, so a frame of spinning costs a single transform. The light across it stays still,
/// as light on a real record does. A hand on it moves the song.
struct PhoneRecord: View {
    @ObservedObject var turntable: PhoneTurntable
    @ObservedObject var model: KnobShiftModel
    let diameter: CGFloat
    /// A hand can't move a record that is still coming out of its sleeve.
    var movable = true

    var body: some View {
        ZStack {
            TimelineView(.animation(paused: !(model.isPlaying || turntable.isActive))) { context in
                RecordFace(url: model.nowPlaying?.url, diameter: diameter)
                    .rotationEffect(.degrees(turntable.recordAngle(at: context.date)))
            }
            Circle()
                .fill(AngularGradient(stops: Self.light, center: .center))
                .allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: Glass.shadow, radius: 14, y: 6)
        .contentShape(Circle())
        .gesture(hand)
        .accessibilityElement()
        .accessibilityLabel("Record")
        .accessibilityHint("Turn clockwise to move ahead in the song, anticlockwise to go back.")
    }

    private var hand: some Gesture {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        return DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard movable else { return }
                if turntable.isHolding {
                    turntable.handMoved(to: drag.location, center: center)
                } else {
                    turntable.handDown(at: drag.location, center: center)
                }
            }
            .onEnded { _ in turntable.handUp() }
    }

    private static let light: [Gradient.Stop] = [
        .init(color: .clear, location: 0.02), .init(color: Vinyl.sheen, location: 0.1), .init(color: .clear, location: 0.2),
        .init(color: .clear, location: 0.52), .init(color: Vinyl.sheen, location: 0.6), .init(color: .clear, location: 0.7),
    ]
}

private struct RecordFace: View {
    let url: URL?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Canvas { context, size in
                let middle = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = size.width / 2
                context.fill(Path(ellipseIn: CGRect(origin: .zero, size: size)), with: .color(Vinyl.disc))
                context.stroke(Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)), with: .color(Vinyl.rim), lineWidth: 2)
                var ring = radius * 0.96
                var index = 0
                while ring > radius * 0.42 {
                    let box = CGRect(x: middle.x - ring, y: middle.y - ring, width: ring * 2, height: ring * 2)
                    // A wider gap now and then, as between the tracks on a real record.
                    context.stroke(Path(ellipseIn: box), with: .color(Vinyl.groove), lineWidth: index % 23 == 0 ? 1.6 : 0.6)
                    ring -= 2.1
                    index += 1
                }
            }
            AlbumArtwork(url: url, size: diameter * 0.38, corner: 0.5)
            Circle().fill(Vinyl.metal).frame(width: diameter * 0.024, height: diameter * 0.024)
        }
        .frame(width: diameter, height: diameter)
        .drawingGroup()
    }
}

/// The arm. It follows the song from the outer groove to the inner one, swings in from its rest
/// when the deck opens, and can be picked up and set down anywhere on the record.
struct PhoneTonearm: View {
    @ObservedObject var turntable: PhoneTurntable
    @ObservedObject var clock: KnobShiftClock
    let geometry: KnobShiftVinylGeometry
    var resting = false

    private var progress: Double {
        turntable.heldProgress ?? (clock.duration > 0 ? clock.time / clock.duration : 0)
    }

    var body: some View {
        let held = turntable.isArmHeld
        let angle = resting ? geometry.restAngle : geometry.angle(progress: progress)
        let thick = geometry.diameter * 0.024
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Vinyl.metalShade, Vinyl.base], center: .center, startRadius: 2, endRadius: geometry.diameter * 0.07))
                .frame(width: geometry.diameter * 0.14, height: geometry.diameter * 0.14)
                .shadow(color: Glass.shadow, radius: 6, y: 3)
                .position(geometry.pivot)
            arm(thick: thick)
                .frame(width: geometry.armLength, height: 44)
                .contentShape(Rectangle())
                .shadow(color: Glass.shadow, radius: held ? 12 : 4, y: held ? 10 : 3)
                .scaleEffect(held ? 1.02 : 1, anchor: .leading)
                .rotationEffect(.degrees(angle), anchor: .leading)
                .position(x: geometry.pivot.x + geometry.armLength / 2, y: geometry.pivot.y)
                .gesture(pick)
            Circle().fill(Vinyl.metal).frame(width: geometry.diameter * 0.05, height: geometry.diameter * 0.05)
                .position(geometry.pivot)
                .allowsHitTesting(false)
        }
        .animation(held ? nil : Motion.gentle, value: resting)
        .animation(held || resting ? nil : .linear(duration: 0.1), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Tonearm")
        .accessibilityValue("\(Int(progress * 100)) percent through the song")
        .accessibilityAdjustableAction { direction in
            let move = direction == .increment ? 0.05 : -0.05
            turntable.armLifted(progress: progress)
            turntable.armMoved(progress: min(max(progress + move, 0), 1))
            turntable.armDropped()
        }
    }

    private func arm(thick: CGFloat) -> some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(LinearGradient(colors: [Vinyl.metal, Vinyl.metalShade], startPoint: .top, endPoint: .bottom))
                .frame(height: thick)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(LinearGradient(colors: [Palette.accent, Vinyl.base], startPoint: .top, endPoint: .bottom))
                .frame(width: geometry.diameter * 0.1, height: thick * 2.2)
        }
    }

    private var pick: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(PhoneVinylDeck.space))
            .onChanged { drag in
                let at = geometry.progress(finger: drag.location)
                if turntable.isArmHeld {
                    turntable.armMoved(progress: at)
                } else {
                    Haptics.mark()
                    turntable.armLifted(progress: progress)
                }
            }
            .onEnded { _ in
                Haptics.mark()
                turntable.armDropped()
            }
    }
}
