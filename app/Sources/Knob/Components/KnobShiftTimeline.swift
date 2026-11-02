import SwiftUI

/// KnobShift's song position: the native slider with elapsed and remaining time, dragged to
/// move through the song. It watches only the playback clock, so its ten updates a second never
/// redraw the rest of the player. Used by the full player and the panel's mini player.
struct KnobShiftTimeline: View {
    let model: KnobShiftModel
    @ObservedObject var clock: KnobShiftClock
    var mini = false

    @State private var position: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        let playing = model.nowPlaying != nil
        VStack(spacing: mini ? 2 : 4) {
            Slider(value: $position, in: 0...max(clock.duration, 1), onEditingChanged: { editing in
                isScrubbing = editing
                if !editing { model.seek(to: position) }
            })
            .controlSize(mini ? .mini : .regular)
            .tint(Palette.accent)
            .disabled(!playing)
            .accessibilityLabel("Position in song")
            HStack {
                Text(playing ? KnobShiftNowPlaying.clock(position) : "0:00")
                Spacer()
                Text(playing ? KnobShiftNowPlaying.clock(max(0, clock.duration - position)) + " left" : "0:00")
            }
            .font(.system(size: mini ? 9 : 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(Screen.textTertiary)
        }
        .onAppear { position = clock.time }
        .onChange(of: clock.time) { _, time in if !isScrubbing { position = time } }
    }
}
