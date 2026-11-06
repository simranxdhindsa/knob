import AppIntents
import SwiftUI
import WidgetKit

/// The record for the lock screen, StandBy and the Dynamic Island: the deck's own vinyl, drawn by
/// the same code as the app, with the song's cover on its label. Face and label spin together
/// while the light stays still, as on the deck, turned by iOS itself with the effect clock widgets
/// use for their hands, so the app sends nothing and it stays steady. Only a playing record spins. The
/// layout follows the Music Player Card on 21st.dev (ravikatiyar162): cover, title and artist,
/// a progress bar with the time, and the three transport buttons, here in Knob's own finish.
struct StandbyRecord: View {
    let cover: String?
    let diameter: CGFloat
    var spinning = false
    @Environment(\.isLuminanceReduced) private var dim
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if spinning && !reduceMotion {
                turning._clockHandRotationEffect(.custom(Motion.standbyTurnSeconds), in: .current, anchor: .center)
            } else {
                turning
            }
            VinylTexture.liveLight.allowsHitTesting(false)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        // At night the whole record goes down, so it does not light the room.
        .opacity(dim ? 0.55 : 1)
        .saturation(dim ? 0.5 : 1)
        .accessibilityHidden(true)
    }

    private var turning: some View {
        ZStack {
            VinylTexture.liveFace
            label
                .frame(width: diameter * VinylTexture.label, height: diameter * VinylTexture.label)
                .clipShape(Circle())
            Circle().fill(Vinyl.discCore).frame(width: diameter * 0.03, height: diameter * 0.03)
        }
    }

    @ViewBuilder private var label: some View {
        if let picture = Self.picture(StandbyGroup.coverFile(cover)) {
            Image(uiImage: picture).resizable().scaledToFill()
        } else {
            ZStack {
                Palette.accent
                Image(systemName: "music.note")
                    .font(.system(size: diameter * 0.14, weight: .semibold))
                    .foregroundStyle(Glass.onAccent)
            }
        }
    }

    static func picture(_ file: URL?) -> UIImage? {
        file.flatMap { try? Data(contentsOf: $0) }.flatMap { UIImage(data: $0) }
    }
}

/// The record inside a ring that fills as the song plays. iOS moves the ring by itself, so it
/// stays true between Knob's updates. For the Dynamic Island, where there is no room for a bar.
struct StandbyRingedRecord: View {
    private static let gap: CGFloat = 5

    let state: KnobStandbyAttributes.ContentState
    let diameter: CGFloat

    var body: some View {
        ZStack {
            ring
                .progressViewStyle(.circular)
                .tint(Palette.accent)
                .frame(width: diameter, height: diameter)
            StandbyRecord(cover: state.cover, diameter: diameter - Self.gap, spinning: state.isPlaying)
        }
        .frame(width: diameter, height: diameter)
    }

    @ViewBuilder private var ring: some View {
        if state.isPlaying {
            ProgressView(timerInterval: state.range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
        } else {
            ProgressView(value: min(state.elapsed, state.duration), total: max(state.duration, 1))
        }
    }
}

/// Song name and artist.
struct StandbyTitles: View {
    let state: KnobStandbyAttributes.ContentState
    var size: CGFloat = 17
    var showsNext = false
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.title)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(Vinyl.shine)
                .lineLimit(1)
            if let artist = state.artist {
                Text(artist)
                    .font(.system(size: size * 0.82))
                    .foregroundStyle(Vinyl.shine.opacity(dim ? 0.75 : 0.6))
                    .lineLimit(1)
            }
            if showsNext, let next = state.next {
                Text("Next: \(next)")
                    .font(.system(size: size * 0.62, weight: .medium))
                    .foregroundStyle(Palette.accent.opacity(dim ? 0.7 : 1))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The orange bar and the time left. While playing both are driven by timers the system runs,
/// so they move without the app sending anything. Paused, they hold still.
struct StandbyProgress: View {
    let state: KnobStandbyAttributes.ContentState
    var size: CGFloat = 12
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        HStack(spacing: 8) {
            bar.tint(Palette.accent.opacity(dim ? 0.7 : 1))
            StandbyTimeLeft(state: state)
                .font(.system(size: size, weight: .medium).monospacedDigit())
                .foregroundStyle(Vinyl.shine.opacity(dim ? 0.8 : 0.65))
                .frame(width: size * 3.6, alignment: .trailing)
        }
    }

    @ViewBuilder private var bar: some View {
        if state.isPlaying {
            ProgressView(timerInterval: state.range, countsDown: false) { EmptyView() } currentValueLabel: { EmptyView() }
        } else {
            ProgressView(value: min(state.elapsed, state.duration), total: max(state.duration, 1))
        }
    }
}

/// The time left, like -2:07, which iOS counts down by itself while the song plays.
struct StandbyTimeLeft: View {
    let state: KnobStandbyAttributes.ContentState

    var body: some View {
        if state.isPlaying {
            Text("-") + Text(timerInterval: state.range, pauseTime: nil, countsDown: true, showsHours: false)
        } else {
            Text(state.timeLeft)
        }
    }
}

/// Previous, play or pause, next. They run in Knob, so they work with the phone locked.
struct StandbyButtons: View {
    let isPlaying: Bool
    var mixing = false
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 1.1) {
            Button(intent: StandbyPreviousIntent()) {
                Image(systemName: "backward.fill").font(.system(size: size * 0.8))
            }
            .accessibilityLabel("Previous song")
            Button(intent: StandbyPlayPauseIntent()) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.8))
                    .foregroundStyle(Glass.onAccent)
                    .frame(width: size * 1.9, height: size * 1.9)
                    .background(Circle().fill(Palette.accent))
            }
            .accessibilityLabel(isPlaying ? "Pause" : "Play")
            Button(intent: StandbyNextIntent()) {
                Image(systemName: "forward.fill").font(.system(size: size * 0.8))
            }
            .accessibilityLabel("Next song")
            Button(intent: StandbyMixIntent()) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: size * 0.7, weight: .bold))
                    .foregroundStyle(mixing ? Palette.accent : Vinyl.shine)
                    .opacity(isPlaying || mixing ? 1 : 0.45)
            }
            .accessibilityLabel("KnobMix Now")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Vinyl.shine)
    }
}

/// The Lock Screen card, which StandBy shows full screen. iOS enlarges the card there by itself,
/// about 1.85 times on a Pro Max, and cuts off anything over about 160 points tall, so StandBy's
/// sizes are for that same small space, with the record as big as it fits and black behind it.
struct StandbyCard: View {
    let state: KnobStandbyAttributes.ContentState
    var fullscreen = false
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        HStack(spacing: fullscreen ? 18 : 16) {
            StandbyRecord(cover: state.cover, diameter: fullscreen ? 132 : 104, spinning: state.isPlaying)
            VStack(spacing: fullscreen ? 8 : 10) {
                StandbyTitles(state: state, size: fullscreen ? 20 : 17, showsNext: fullscreen)
                StandbyProgress(state: state, size: fullscreen ? 13 : 12)
                StandbyButtons(isPlaying: state.isPlaying, mixing: state.mixing, size: fullscreen ? 18 : 20)
            }
        }
        .padding(fullscreen ? 12 : 14)
        .opacity(dim ? 0.9 : 1)
        .background { if fullscreen && !dim { wash } }
        .activityBackgroundTint(fullscreen ? Bedside.night : Vinyl.base)
    }

    /// The cover's colours, spread soft behind the card, as the player does. Gone at night.
    @ViewBuilder private var wash: some View {
        if let picture = StandbyRecord.picture(StandbyGroup.coverFile(state.cover)) {
            // Fading out before the card's edge, so no box shows on StandBy's black.
            Image(uiImage: picture).resizable().scaledToFill().blur(radius: 40).opacity(0.35).clipped()
                .mask(RadialGradient(colors: [Bedside.night, .clear], center: .center, startRadius: 30, endRadius: 200))
        }
    }
}

/// Reads whether StandBy has the card full screen, which iOS 18 says and iOS 17 does not.
struct StandbyCardHost: View {
    let state: KnobStandbyAttributes.ContentState

    var body: some View {
        if #available(iOS 18, *) {
            Fullscreen(state: state)
        } else {
            StandbyCard(state: state)
        }
    }

    @available(iOS 18, *)
    private struct Fullscreen: View {
        let state: KnobStandbyAttributes.ContentState
        @Environment(\.isActivityFullscreen) private var fullscreen

        var body: some View { StandbyCard(state: state, fullscreen: fullscreen) }
    }
}

/// The small widget's face: the record with its cover and the song's name.
struct LastSongView: View {
    let song: StandbySong?
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        VStack(spacing: 8) {
            StandbyRecord(cover: song?.cover, diameter: 84)
            VStack(spacing: 1) {
                Text(song?.title ?? "Play a song in Knob")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Vinyl.shine)
                    .lineLimit(1)
                if let artist = song?.artist {
                    Text(artist)
                        .font(.system(size: 11))
                        .foregroundStyle(Vinyl.shine.opacity(dim ? 0.75 : 0.6))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetAccentable()
    }
}
