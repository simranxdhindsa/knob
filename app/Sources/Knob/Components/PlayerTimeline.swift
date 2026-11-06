import SwiftUI

/// The song's position: the slider, the times, and what
/// KnobShift is doing between them, where Apple Music shows the audio quality. It alone watches
/// the playback clock, so ten updates a second redraw nothing else.
struct PlayerTimeline: View {
    @ObservedObject var model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock
    @ObservedObject var scrub: PlayerScrub
    /// Full screen's times grow with the screen.
    var textSize: CGFloat = 12
    /// Full screen has the room to show how long until the next mix all the way there.
    var showsMixAhead = false

    /// How many seconds ahead a planned mix is announced.
    private static let warning = 5

    var body: some View {
        let playing = model.nowPlaying != nil
        let duration = max(clock.duration, 1)
        let time = scrub.position ?? clock.time
        VStack(spacing: 0) {
            slider(playing: playing, time: time, duration: duration)
            ZStack {
                HStack {
                    Text(playing ? KnobShiftNowPlaying.clock(time) : "0:00")
                    Spacer()
                    Text(playing ? KnobShiftNowPlaying.clock(max(0, clock.duration - time)) + " left" : "0:00")
                }
                .font(.system(size: textSize, weight: .medium).monospacedDigit())
                .foregroundStyle(Glass.secondary)
                chip
            }
        }
    }

    /// The system's own slider. With nothing playing it is an empty line, since the slider
    /// shows its handle even with nothing to move.
    @ViewBuilder private func slider(playing: Bool, time: TimeInterval, duration: TimeInterval) -> some View {
        if playing {
            Slider(value: Binding(get: { min(time, duration) }, set: { scrub.position = $0 }), in: 0...duration) { editing in
                if !editing, let position = scrub.position {
                    model.seek(to: position)
                    scrub.position = nil
                }
            }
            .tint(Palette.accent)
            .accessibilityLabel("Position in song")
        } else {
            KnobGroove(value: 0, accessibilityLabel: "Position in song", accessibilityValue: "0:00", onChange: { _ in })
                .disabled(true)
        }
    }

    @ViewBuilder private var chip: some View {
        let lit = model.mixState == .mixing
        let text = chipText
        ZStack {
            if let text {
                Text(text)
                    .font(.system(size: textSize - 2, weight: .semibold).monospacedDigit()).tracking(0.4)
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(lit || countdown != nil ? Glass.onAccent : (mixAhead != nil ? Glass.text : Glass.secondary))
                    .padding(.horizontal, 9)
                    .frame(height: textSize + 8)
                    .background(Capsule().fill(lit ? Palette.accent : (countdown != nil ? Palette.accent.opacity(0.45) : (mixAhead != nil ? Palette.accent.opacity(0.3) : Glass.fill))))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(Motion.snappy, value: text)
    }

    /// Seconds to a mix that is about to start: the last few of a planned one, or all of them
    /// once KnobMix Now has been tapped.
    private var countdown: Int? {
        guard let mix = model.nextMix, mix.blends, model.mixState != .mixing else { return nil }
        let left = Int(mix.at.timeIntervalSinceNow.rounded(.up))
        return left > 0 && (model.mixNowWaiting || left <= Self.warning) ? left : nil
    }

    /// How far off the planned mix is, by the song's own position, so it holds still while paused.
    /// The last few seconds belong to `countdown`, so the two never swap back and forth.
    private var mixAhead: TimeInterval? {
        guard showsMixAhead, let mix = model.nextMix, mix.blends, model.mixState != .mixing, countdown == nil else { return nil }
        let left = mix.startsAt - clock.time
        return left > Double(Self.warning) ? left : nil
    }

    private var chipText: String? {
        guard model.nowPlaying != nil else { return nil }
        if model.mixState == .mixing { return "KNOBMIX" }
        if let countdown { return "KNOBMIX IN \(countdown)" }
        if model.mixNowWaiting { return "KNOBMIX STARTING" }
        if let mixAhead { return "KNOBMIX IN \(KnobShiftNowPlaying.clock(mixAhead))" }
        return model.mixState == .analyzing ? "PREPARING" : nil
    }
}
