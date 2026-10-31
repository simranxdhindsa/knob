import SwiftUI

/// KnobShift's now-playing deck: cover art, title and artist, the live KNOBMIX indicator, a
/// timeline that marks where the next mix happens, and the transport. Layout follows the
/// 21st.dev MusicPlayerCard by dhileepkumargm (large art, track details, time slider, centred
/// controls), rebuilt in SwiftUI on Knob's dark screen finish with its orange accent.
struct KnobShiftNowPlaying: View {
    @ObservedObject var model: KnobShiftModel
    var compact: Bool

    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(spacing: compact ? 14 : 18) {
            if compact {
                HStack(spacing: 14) {
                    AlbumArtwork(url: model.nowPlaying?.url, size: 86, lit: model.mixState == .mixing)
                    details(alignment: .leading)
                }
            } else {
                AlbumArtwork(url: model.nowPlaying?.url, size: 188, lit: model.mixState == .mixing)
                    .padding(.top, 4)
                details(alignment: .center)
            }
            if model.mixState == .mixing {
                KnobMixBanner(progress: model.blendProgress)
            }
            timeline
            transport
        }
        .screenCard(radius: 20, padding: compact ? 16 : 22)
        .onAppear { scrubPosition = model.playbackTime }
        .onChange(of: model.playbackTime) { _, time in if !isScrubbing { scrubPosition = time } }
        .animation(Motion.gentle, value: model.mixState)
    }

    private func details(alignment: HorizontalAlignment) -> some View {
        let track = model.nowPlaying
        return VStack(alignment: alignment, spacing: 5) {
            Text(track?.name ?? "Nothing playing")
                .font(.system(size: compact ? 17 : 21, weight: .bold))
                .foregroundStyle(track == nil ? Screen.textSecondary : Screen.text)
                .lineLimit(1)
            Text(track?.artist ?? (track == nil ? "Pick a song from the queue" : "Local music"))
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(Screen.textSecondary)
                .lineLimit(1)
            if let track {
                HStack(spacing: 6) {
                    if let tempo = track.analysis.tempo { chip(String(format: "%.0f BPM", tempo), lit: false) }
                    statusChip
                }
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    @ViewBuilder private var statusChip: some View {
        switch model.mixState {
        case .mixing: chip("KNOBMIX", lit: true)
        case .preservingEnding: chip("FULL ENDING", lit: false)
        case .analyzing: chip("PREPARING", lit: false)
        default: EmptyView()
        }
    }

    private func chip(_ text: String, lit: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold)).tracking(0.7)
            .foregroundStyle(lit ? Color.white : Screen.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(lit ? Palette.accent : Screen.tabTrack))
            .shadow(color: lit ? Palette.accentGlow.opacity(0.6) : .clear, radius: 5)
    }

    /// The native slider with elapsed and remaining time.
    private var timeline: some View {
        let duration = max(model.playbackDuration, 1)
        return VStack(spacing: 4) {
            Slider(value: $scrubPosition, in: 0...duration, onEditingChanged: { editing in
                isScrubbing = editing
                if !editing { model.seek(to: scrubPosition) }
            })
            .tint(Palette.accent)
            .disabled(model.nowPlaying == nil)
            .accessibilityLabel("Position in song")
            HStack {
                Text(Self.clock(scrubPosition))
                Spacer()
                Text(Self.clock(max(0, model.playbackDuration - scrubPosition)) + " left")
            }
            .font(.system(size: 10, weight: .semibold).monospacedDigit())
            .foregroundStyle(Screen.textTertiary)
        }
    }

    private var transport: some View {
        HStack(spacing: compact ? 26 : 34) {
            Button { model.previous() } label: {
                Image(systemName: "backward.fill").font(.system(size: 17))
            }
            .accessibilityLabel("Previous")
            Button { model.pauseOrResume() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 19 : 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: compact ? 46 : 54, height: compact ? 46 : 54)
                    .background(Circle().fill(Palette.accent))
                    .shadow(color: Palette.accentGlow.opacity(0.55), radius: 9)
            }
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
            Button { model.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 17))
            }
            .accessibilityLabel("Next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.tracks.isEmpty ? Screen.textTertiary : Screen.text)
        .disabled(model.tracks.isEmpty)
        .frame(maxWidth: .infinity)
    }

    static func clock(_ value: TimeInterval) -> String {
        String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
    }
}

/// Shown while a mix is happening: a breathing KNOBMIX badge and how far the mix has gone.
struct KnobMixBanner: View {
    let progress: Double
    @State private var breathe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(Palette.accent)
                    .frame(width: 8, height: 8)
                    .shadow(color: Palette.accentGlow, radius: breathe ? 7 : 2)
                    .opacity(breathe ? 1 : 0.55)
                Text("KNOBMIX").font(.system(size: 11, weight: .heavy)).tracking(1.2).foregroundStyle(Palette.accent)
                Spacer(minLength: 0)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Screen.grid)
                    Capsule().fill(LinearGradient(colors: [Palette.accent, Palette.accentGlow], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geometry.size.width * min(max(progress, 0), 1))
                        .shadow(color: Palette.accentGlow.opacity(0.7), radius: 4)
                }
            }
            .frame(height: 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Palette.accent.opacity(0.35), lineWidth: 1))
        .onAppear { withAnimation(Motion.pulse) { breathe = true } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("KnobMix, \(Int(progress * 100)) percent")
    }
}
