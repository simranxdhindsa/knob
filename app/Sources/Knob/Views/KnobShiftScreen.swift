import SwiftUI

/// KnobShift in Knob's sound-control panel: always a mini player (cover, song, progress,
/// transport and what plays next) with a small expand button that opens the full player. The
/// layout is the same playing, paused, stopped or empty, so the panel never jumps.
struct KnobShiftScreen: View {
    @ObservedObject var model: KnobShiftModel

    /// The playing song, or the first one in the queue so Play has something to start.
    private var track: KnobShiftModel.Track? { model.nowPlaying ?? model.tracks.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            progress
            transport
            next
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(Motion.gentle, value: model.nowPlaying?.id)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AlbumArtwork(url: track?.url, size: 52, lit: model.mixState == .mixing)
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.name ?? "Nothing playing")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(track == nil ? Screen.textSecondary : Screen.text)
                    .lineLimit(1)
                Text(track.map { $0.artist ?? "Local music" } ?? "Open the player to add music")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Screen.textSecondary)
                    .lineLimit(1)
            }
            .padding(.top, 6)
            Spacer(minLength: 4)
            Button { KnobShiftWindow.show(model: model) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Screen.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Screen.tabTrack))
            }
            .buttonStyle(.plain)
            .help("Open the full KnobShift player")
            .accessibilityLabel("Open the full KnobShift player")
        }
    }

    private var progress: some View { KnobShiftTimeline(model: model, clock: model.clock, mini: true) }

    private var transport: some View {
        HStack(spacing: 26) {
            Button { model.previous() } label: { Image(systemName: "backward.fill").font(.system(size: 13)) }
                .accessibilityLabel("Previous")
            Button { model.pauseOrResume() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(model.tracks.isEmpty ? Screen.textTertiary : Palette.accent))
                    .shadow(color: model.tracks.isEmpty ? .clear : Palette.accentGlow.opacity(0.55), radius: 7)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button { model.next() } label: { Image(systemName: "forward.fill").font(.system(size: 13)) }
                .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.tracks.isEmpty ? Screen.textTertiary : Screen.text)
        .disabled(model.tracks.isEmpty)
        .frame(maxWidth: .infinity)
    }

    /// What plays next, or that a mix is happening; always there, so the height never changes.
    private var next: some View {
        HStack(spacing: 6) {
            Text("NEXT").font(.system(size: 9, weight: .bold)).tracking(0.9).foregroundStyle(Screen.textTertiary)
            Text(model.mixState == .mixing ? "Mixing now" : (model.upNext?.name ?? "Nothing yet"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.mixState == .mixing ? Palette.accent : (model.upNext == nil ? Screen.textTertiary : Screen.text))
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Capsule().fill(Screen.tabTrack))
    }
}
