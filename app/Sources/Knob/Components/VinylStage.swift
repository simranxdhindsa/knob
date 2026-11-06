import SwiftUI

/// The record deck: the song's cover, the record and the arm, shared by the iPhone on its side
/// and the Mac in full screen. The cover appears, the record slides out of it, and it settles
/// with the sleeve over half of the record. Nothing here touches the sound by itself, so the song
/// carries on from exactly where it was. Everything works: turn the record to move through the
/// song, pick the arm up and set it down, and tap the sleeve to play or pause or swipe for
/// another song. When the song changes, by a button or a KnobMix, the arm lifts, the record goes
/// back into its sleeve, the cover changes and the new record comes out, always in the same time.
/// In a KnobMix that happens as the mix begins, and the arm stays up until the new song has taken
/// over, since until then the song's clock still belongs to the old one.
struct VinylStage: View {
    static let space = "VinylStage"

    @ObservedObject var model: KnobShiftModel
    @ObservedObject private var turntable: KnobShiftTurntable
    let size: CGSize
    /// Told when the deck has settled, for whatever sits around it to appear.
    var onSettled: () -> Void = {}
    /// Told which song is on show, so the name beside the deck changes with the cover.
    var onShowing: (KnobShiftModel.Track?) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var stage = Stage.sleeve
    /// What the sleeve and the record show. It only changes while the record is out of sight.
    @State private var showing: KnobShiftModel.Track?
    /// The last cover, left solid underneath while the new one fades in over it, so the record
    /// hidden behind the sleeve never shows through.
    @State private var leaving: KnobShiftModel.Track?

    private enum Stage { case sleeve, out, settled, tucked }

    /// The song the deck should be showing: in a KnobMix, the one coming in.
    private var wanted: KnobShiftModel.Track? { model.mixingInto ?? model.nowPlaying }

    init(model: KnobShiftModel, size: CGSize, onSettled: @escaping () -> Void = {},
         onShowing: @escaping (KnobShiftModel.Track?) -> Void = { _ in }) {
        self.model = model
        self.size = size
        self.onSettled = onSettled
        self.onShowing = onShowing
        turntable = .shared(for: model)
    }

    var body: some View {
        let layout = VinylLayout(size: size)
        let geometry = KnobShiftVinylGeometry(center: layout.record, diameter: layout.diameter)
        ZStack(alignment: .topLeading) {
            VinylRecord(turntable: turntable, model: model, url: showing?.url, diameter: layout.diameter, movable: stage == .settled && model.mixingInto == nil)
                // A touch smaller inside the sleeve, which is narrower than the record.
                .scaleEffect(isInSleeve ? 0.9 : 1)
                .position(recordPosition(layout))
            sleeve(layout)
            VinylTonearm(turntable: turntable, clock: model.clock, geometry: geometry, resting: stage != .settled || model.mixingInto != nil)
                .opacity(stage == .sleeve ? 0 : 1)
        }
        .frame(width: size.width, height: size.height)
        .coordinateSpace(name: Self.space)
        .onAppear {
            turntable.start()
            if showing == nil { showing = wanted }
        }
        .onDisappear { turntable.stop() }
        .task { await open() }
        .task(id: wanted?.id) { await change() }
        .onChange(of: showing, initial: true) { onShowing(showing) }
        .onChange(of: model.nowPlaying) { turntable.follow(model.nowPlaying) }
        // A call or leaving the app takes the touch away too.
        .onChange(of: scenePhase) { if scenePhase != .active { turntable.releaseNow() } }
    }

    private var isInSleeve: Bool { stage == .sleeve || stage == .tucked }

    /// The record changing with the song. A newer change cancels this one and takes over from
    /// wherever it got to, so quick taps of Next just show the last song. Every way out leaves
    /// the record back on the deck: a change cut short by going straight back to the song on
    /// show, a cancelled KnobMix or an emptied queue has nothing newer coming to finish the job.
    private func change() async {
        leaving = nil
        guard let wanted, wanted != showing else {
            comeBackOut()
            return
        }
        // Nothing on show yet, or still opening: the new song simply goes in the sleeve.
        guard showing != nil, stage == .settled || stage == .tucked else {
            showing = wanted
            return
        }
        // Read while the record goes away, so the new cover is ready the moment it is shown, and
        // the drawn stand in for a song with no cover never flashes up.
        let url = wanted.url
        let cover = Task { await KnobShiftArtwork.load(url) }
        guard !reduceMotion else {
            _ = await cover.value
            leaving = showing
            withAnimation(.easeOut(duration: 0.2)) { showing = wanted }
            try? await Task.sleep(for: .seconds(0.2))
            leaving = nil
            comeBackOut()
            return
        }
        let began = Date()
        do {
            withAnimation(Motion.vinylTuck) { stage = .tucked }
            try await Task.sleep(for: .seconds(Motion.vinylTuckSeconds))
            _ = await cover.value
            leaving = showing
            withAnimation(Motion.vinylCover) { showing = wanted }
            try await Task.sleep(for: .seconds(Motion.vinylCoverSeconds))
            leaving = nil
            withAnimation(Motion.vinylReturn) { stage = .settled }
            try await Task.sleep(for: .seconds(Motion.vinylReturnSeconds))
            model.log("VINYL", "The record changed in \(String(format: "%.2f", Date().timeIntervalSince(began)))s.")
        } catch {
            // A newer song took over.
        }
    }

    private func comeBackOut() {
        guard stage == .tucked else { return }
        withAnimation(Motion.vinylReturn) { stage = .settled }
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
        case .tucked: layout.sleeveCenter
        case .out: CGPoint(x: size.width / 2 - layout.sleeve * 0.42, y: layout.record.y)
        case .settled: layout.sleeveCenter
        }
    }

    private func recordPosition(_ layout: VinylLayout) -> CGPoint {
        let sleeve = sleevePosition(layout)
        return switch stage {
        case .sleeve, .tucked: sleeve
        case .out: CGPoint(x: sleeve.x + layout.sleeve * 0.8, y: sleeve.y)
        case .settled: layout.record
        }
    }

    private func sleeve(_ layout: VinylLayout) -> some View {
        ZStack {
            if let leaving {
                AlbumArtwork(url: leaving.url, size: layout.sleeve, corner: 0.02)
            }
            // The old cover gives way to the new one on the spot, not sliding or scaling.
            AlbumArtwork(url: showing?.url, size: layout.sleeve, animated: model.isPlaying, corner: 0.02)
                .id(showing?.id)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
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
            .accessibilityLabel("Album cover, \(showing?.name ?? "no song")")
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
