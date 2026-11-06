import SwiftUI

/// The player on its side: a record deck. The song's cover appears, the record slides out of it,
/// and it settles with the sleeve over half of the record. Nothing here touches the sound, so the
/// song carries on from exactly where it was through every turn of the phone. The record, the arm
/// and the sleeve all work: turn the record to move through the song, pick the arm up and set it
/// down, and tap the sleeve to play or pause or swipe it for another song.
struct PhoneVinylDeck: View {
    static let space = "PhoneVinylDeck"

    @ObservedObject var model: KnobShiftModel
    @ObservedObject var scrub: PlayerScrub
    @ObservedObject private var turntable: PhoneTurntable
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var stage = Stage.sleeve

    private enum Stage { case sleeve, out, settled }

    init(model: KnobShiftModel, scrub: PlayerScrub) {
        self.model = model
        self.scrub = scrub
        turntable = .shared(for: model)
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = PhoneVinylLayout(size: proxy.size)
            let geometry = KnobShiftVinylGeometry(center: layout.record, diameter: layout.diameter)
            ZStack(alignment: .topLeading) {
                PhoneRecord(turntable: turntable, model: model, diameter: layout.diameter, movable: stage == .settled)
                    .position(recordPosition(layout))
                sleeve(layout)
                PhoneTonearm(turntable: turntable, clock: model.clock, geometry: geometry, resting: stage != .settled)
                    .opacity(stage == .sleeve ? 0 : 1)
                details(layout)
                    .opacity(stage == .settled ? 1 : 0)
            }
            .coordinateSpace(name: Self.space)
        }
        .onAppear(perform: open)
        .onDisappear { turntable.stop() }
        .onChange(of: model.nowPlaying) { turntable.follow(model.nowPlaying) }
        // A call or leaving the app takes the touch away too.
        .onChange(of: scenePhase) { if scenePhase != .active { turntable.releaseNow() } }
    }

    /// The opening. Reduce Motion goes straight to the settled deck.
    private func open() {
        turntable.start()
        guard !reduceMotion else {
            stage = .settled
            return
        }
        Task {
            // After the phone has finished turning, so the cover is seen on its own first.
            try? await Task.sleep(for: .milliseconds(620))
            withAnimation(Motion.vinylOut) { stage = .out }
            try? await Task.sleep(for: .milliseconds(760))
            withAnimation(Motion.vinylSettle) { stage = .settled }
        }
    }

    private func sleevePosition(_ layout: PhoneVinylLayout) -> CGPoint {
        switch stage {
        case .sleeve: CGPoint(x: layout.size.width / 2, y: layout.record.y)
        case .out: CGPoint(x: layout.size.width / 2 - layout.sleeve * 0.42, y: layout.record.y)
        case .settled: layout.sleeveCenter
        }
    }

    private func recordPosition(_ layout: PhoneVinylLayout) -> CGPoint {
        let sleeve = sleevePosition(layout)
        return switch stage {
        case .sleeve: sleeve
        case .out: CGPoint(x: sleeve.x + layout.sleeve * 0.8, y: sleeve.y)
        case .settled: layout.record
        }
    }

    private func sleeve(_ layout: PhoneVinylLayout) -> some View {
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

    private func details(_ layout: PhoneVinylLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.nowPlaying?.name ?? "Nothing playing")
                    .font(.system(size: 17, weight: .semibold)).foregroundStyle(Glass.text)
                    .lineLimit(2)
                Text(model.nowPlaying?.artist ?? "")
                    .font(.system(size: 13)).foregroundStyle(Glass.secondary)
                    .lineLimit(1)
            }
            VinylTimes(clock: model.clock, playing: model.nowPlaying != nil)
            HStack(spacing: 0) {
                step("backward.fill", label: "Previous", action: model.previous)
                PlayDial(model: model, clock: model.clock, scrub: scrub, size: 74)
                step("forward.fill", label: "Next", action: model.next)
            }
            if model.mixState == .mixing {
                Text("Record is free after the mix")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .frame(width: PhoneVinylLayout.column, height: layout.size.height, alignment: .leading)
        .offset(x: layout.size.width - PhoneVinylLayout.column)
    }

    private func step(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.mark()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Glass.text)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerPress())
        .accessibilityLabel(label)
    }
}

/// The song's times, alone in watching the clock so its ticks redraw nothing else.
private struct VinylTimes: View {
    @ObservedObject var clock: KnobShiftClock
    let playing: Bool

    var body: some View {
        HStack {
            Text(playing ? KnobShiftNowPlaying.clock(clock.time) : "0:00")
            Spacer()
            Text(playing ? KnobShiftNowPlaying.clock(max(0, clock.duration - clock.time)) + " left" : "0:00")
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(Glass.secondary)
    }
}

/// Where the deck's parts sit on a phone on its side. The record is as big as the height allows
/// once the sleeve, the arm and the song's details have their room.
struct PhoneVinylLayout {
    static let column: CGFloat = 164, margin: CGFloat = 6

    let size: CGSize

    var diameter: CGFloat { min(size.height * 0.96, (size.width - Self.column - Self.margin * 2) / 1.72) }
    var sleeve: CGFloat { diameter * 0.92 }
    var sleeveCenter: CGPoint { CGPoint(x: Self.margin + sleeve / 2, y: size.height / 2) }
    /// The record's centre sits on the sleeve's edge, so the sleeve covers half of it.
    var record: CGPoint { CGPoint(x: Self.margin + sleeve, y: size.height / 2) }
}
