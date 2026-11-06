import SwiftUI

/// The record deck: the song's cover, the record and the arm, shared by the iPhone on its side
/// and the Mac in full screen. The cover appears, the record slides out of it, and it settles
/// with the sleeve over half of the record. Nothing here touches the sound by itself, so the song
/// carries on from exactly where it was. Everything works: turn the record to move through the
/// song, pick the arm up and set it down, and tap the sleeve to play or pause or swipe for
/// another song.
struct VinylStage: View {
    static let space = "VinylStage"

    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var turntable: KnobShiftTurntable
    let size: CGSize
    /// Told when the deck has settled, for whatever sits around it to appear.
    var onSettled: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var stage = Stage.sleeve

    private enum Stage { case sleeve, out, settled }

    init(model: KnobShiftModel, size: CGSize, onSettled: @escaping () -> Void = {}) {
        self.model = model
        self.size = size
        self.onSettled = onSettled
        turntable = .shared(for: model)
    }

    var body: some View {
        let layout = VinylLayout(size: size)
        let geometry = KnobShiftVinylGeometry(center: layout.record, diameter: layout.diameter)
        ZStack(alignment: .topLeading) {
            VinylRecord(turntable: turntable, model: model, diameter: layout.diameter, movable: stage == .settled)
                .position(recordPosition(layout))
            sleeve(layout)
            VinylTonearm(turntable: turntable, clock: model.clock, geometry: geometry, resting: stage != .settled)
                .opacity(stage == .sleeve ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.space)
        .onAppear { turntable.start() }
        .onDisappear { turntable.stop() }
        .task { await open() }
        .onChange(of: model.nowPlaying) { turntable.follow(model.nowPlaying) }
        // A call or leaving the app takes the touch away too.
        .onChange(of: scenePhase) { if scenePhase != .active { turntable.releaseNow() } }
    }

    /// The opening. Reduce Motion goes straight to the settled deck.
    private func open() async {
        guard !reduceMotion else {
            stage = .settled
            onSettled()
            return
        }
        do {
            // After the phone has finished turning, so the cover is seen on its own first.
            try await Task.sleep(for: .milliseconds(620))
            withAnimation(Motion.vinylOut) { stage = .out }
            try await Task.sleep(for: .milliseconds(760))
            withAnimation(Motion.vinylSettle) { stage = .settled }
            onSettled()
        } catch {
            // The deck left mid opening, and there is nothing left to open.
        }
    }

    private func sleevePosition(_ layout: VinylLayout) -> CGPoint {
        switch stage {
        case .sleeve: CGPoint(x: size.width / 2, y: layout.record.y)
        case .out: CGPoint(x: size.width / 2 - layout.sleeve * 0.42, y: layout.record.y)
        case .settled: layout.sleeveCenter
        }
    }

    private func recordPosition(_ layout: VinylLayout) -> CGPoint {
        let sleeve = sleevePosition(layout)
        return switch stage {
        case .sleeve: sleeve
        case .out: CGPoint(x: sleeve.x + layout.sleeve * 0.8, y: sleeve.y)
        case .settled: layout.record
        }
    }

    private func sleeve(_ layout: VinylLayout) -> some View {
        KnobShiftCover(model: model, clock: model.clock, size: layout.sleeve, animated: model.isPlaying, corner: 0.02)
            .contentShape(Rectangle())
            .onTapGesture {
                Haptics.mark()
                model.pauseOrResume()
            }
            .gesture(DragGesture(minimumDistance: 24).onEnded { drag in
                guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                Haptics.mark()
                if drag.translation.width < 0 { model.next() } else { model.previous() }
            })
            .position(sleevePosition(layout))
            .accessibilityElement()
            .accessibilityLabel("Album cover, \(model.nowPlaying?.name ?? "no song")")
            .accessibilityHint("Tap to play or pause, swipe for another song.")
            .accessibilityAddTraits(.isButton)
    }
}

/// Where the deck's parts sit in the room it is given: the record as big as the height allows
/// once the sleeve and the arm have theirs, and the whole deck centred.
struct VinylLayout {
    /// The deck's width as a share of the record: the sleeve, then half the record and the arm.
    private static let widthShare: CGFloat = 1.72

    let size: CGSize

    var diameter: CGFloat { min(size.height * 0.96, size.width / Self.widthShare) }
    var sleeve: CGFloat { diameter * 0.92 }
    private var left: CGFloat { (size.width - diameter * Self.widthShare) / 2 }
    var sleeveCenter: CGPoint { CGPoint(x: left + sleeve / 2, y: size.height / 2) }
    /// The record's centre sits on the sleeve's edge, so the sleeve covers half of it.
    var record: CGPoint { CGPoint(x: left + sleeve, y: size.height / 2) }
}

/// A small real record, for the switch that turns the deck on. It turns while the deck is on.
struct VinylIcon: View {
    let size: CGFloat
    var spinning = false

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8 * 360
            ZStack {
                VinylTexture.face(size).frame(width: size, height: size)
                Circle().fill(Palette.accent).frame(width: size * 0.36, height: size * 0.36)
                Rectangle().fill(Vinyl.shine.opacity(0.75)).frame(width: size * 0.15, height: size * 0.02).offset(x: size * 0.08)
                Circle().fill(Vinyl.discCore).frame(width: size * 0.08, height: size * 0.08)
            }
            .rotationEffect(.degrees(spinning ? turn : 0))
            .overlay { VinylTexture.light(size).frame(width: size, height: size) }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
