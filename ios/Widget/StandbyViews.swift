import AppIntents
import SwiftUI
import WidgetKit

/// The still record for the lock screen, StandBy and the Dynamic Island: Knob's own record
/// (drawn once by the app into the shared folder) with the song's cover on its label. The
/// layout follows the Music Player Card on 21st.dev (ravikatiyar162): cover, title and artist,
/// a progress bar with the time, and the three transport buttons, here in Knob's own finish.
struct StandbyRecord: View {
    let cover: String?
    let diameter: CGFloat
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        ZStack {
            if let face = Self.picture(StandbyGroup.recordFile) {
                Image(uiImage: face).resizable()
            } else {
                Circle().fill(Vinyl.disc).overlay(Circle().stroke(Vinyl.rim, lineWidth: 1))
            }
            label
                .frame(width: diameter * 0.35, height: diameter * 0.35)
                .clipShape(Circle())
            Circle().fill(Vinyl.discCore).frame(width: diameter * 0.03, height: diameter * 0.03)
        }
        .frame(width: diameter, height: diameter)
        // At night the whole record goes down, so it does not light the room.
        .opacity(dim ? 0.55 : 1)
        .saturation(dim ? 0.5 : 1)
        .accessibilityHidden(true)
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

/// Song name and artist.
struct StandbyTitles: View {
    let state: KnobStandbyAttributes.ContentState
    var size: CGFloat = 17
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
            time
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

    @ViewBuilder private var time: some View {
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
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: size * 1.3) {
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
        }
        .buttonStyle(.plain)
        .foregroundStyle(Vinyl.shine)
    }
}

/// The Lock Screen card, which StandBy shows full screen. In StandBy there is room, so
/// everything grows and nothing is drawn behind it.
struct StandbyCard: View {
    let state: KnobStandbyAttributes.ContentState
    var fullscreen = false
    @Environment(\.isLuminanceReduced) private var dim

    var body: some View {
        let scale: CGFloat = fullscreen ? 1.7 : 1
        HStack(spacing: 16 * scale) {
            StandbyRecord(cover: state.cover, diameter: 104 * scale)
            VStack(spacing: 10 * scale) {
                StandbyTitles(state: state, size: 17 * scale)
                StandbyProgress(state: state, size: 12 * scale)
                StandbyButtons(isPlaying: state.isPlaying, size: 20 * scale)
            }
        }
        .padding(fullscreen ? 20 : 14)
        .opacity(dim ? 0.9 : 1)
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
