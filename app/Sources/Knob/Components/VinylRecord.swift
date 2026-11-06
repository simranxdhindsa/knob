import SwiftUI

/// The record: a real texture and a label cut from the song's cover. The face turns as one
/// picture while the light stays still, shifting a touch with each turn the way a real record's
/// slight warp moves its reflections, which is most of what makes a record look like it's
/// spinning. A hand on it moves the song.
struct VinylRecord: View {
    @ObservedObject var turntable: KnobShiftTurntable
    @ObservedObject var model: KnobShiftModel
    /// The song on the label, which only changes while the record is in its sleeve.
    let url: URL?
    let diameter: CGFloat
    /// A hand can't move a record that is still coming out of its sleeve.
    var movable = true
    /// Told when a hand has been on the record and let go.
    var onUsed: () -> Void = {}
    /// Resets by itself if the system takes the touch away, which ends the drag with no word.
    @GestureState private var touching = false

    /// How far the warp sways the reflections, in degrees.
    private static let warp = 2.6

    var body: some View {
        TimelineView(.animation(paused: !(model.isPlaying || turntable.isActive))) { context in
            let angle = turntable.recordAngle(at: context.date)
            ZStack {
                RecordFace(url: url, diameter: diameter)
                    .rotationEffect(.degrees(angle))
                VinylTexture.light(diameter)
                    .frame(width: diameter, height: diameter)
                    .rotationEffect(.degrees(sin(angle * .pi / 180) * Self.warp))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: Glass.shadow, radius: 16, y: 7)
        .contentShape(Circle())
        .gesture(hand)
        .onChange(of: touching) {
            guard !touching else { return }
            turntable.handUp()
            if movable { onUsed() }
        }
        .accessibilityElement()
        .accessibilityLabel("Record")
        .accessibilityHint("Turn clockwise to move ahead in the song, anticlockwise to go back.")
    }

    private var hand: some Gesture {
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        return DragGesture(minimumDistance: 0)
            .updating($touching) { _, touching, _ in touching = true }
            .onChanged { drag in
                guard movable else { return }
                if turntable.isHolding {
                    turntable.handMoved(to: drag.location, center: center)
                } else {
                    turntable.handDown(at: drag.location, center: center)
                }
            }
    }
}

/// What turns: the grooves, the label and the spindle hole.
private struct RecordFace: View {
    let url: URL?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            VinylTexture.face(diameter).frame(width: diameter, height: diameter)
            AlbumArtwork(url: url, size: diameter * VinylTexture.label, corner: 0.5)
            Circle().fill(Vinyl.discCore).frame(width: diameter * 0.03, height: diameter * 0.03)
            Circle().stroke(Vinyl.shine.opacity(0.25), lineWidth: 0.5).frame(width: diameter * 0.03, height: diameter * 0.03)
        }
        .frame(width: diameter, height: diameter)
    }
}
