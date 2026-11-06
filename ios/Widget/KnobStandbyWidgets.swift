import ActivityKit
import SwiftUI
import WidgetKit

/// Knob's StandBy extension: the Live Activity for the playing song and a small widget with
/// the last song. Neither can spin the record: iOS only lets widgets and Live Activities in
/// StandBy, and they show a still picture.
@main
struct KnobStandbyBundle: WidgetBundle {
    var body: some Widget {
        KnobPlayingActivity()
        KnobLastSongWidget()
    }
}

// MARK: Live Activity

struct KnobPlayingActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: KnobStandbyAttributes.self) { context in
            StandbyCardHost(state: context.state)
                .activityBackgroundTint(Vinyl.base)
                .activitySystemActionForegroundColor(Vinyl.shine)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StandbyRecord(cover: context.state.cover, diameter: 64)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StandbyButtons(isPlaying: context.state.isPlaying, size: 14)
                        .padding(.top, 8)
                }
                DynamicIslandExpandedRegion(.center) {
                    StandbyTitles(state: context.state, size: 15)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    StandbyProgress(state: context.state, size: 11)
                }
            } compactLeading: {
                StandbyRecord(cover: context.state.cover, diameter: 22)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(Palette.accent)
            } minimal: {
                StandbyRecord(cover: context.state.cover, diameter: 22)
            }
            .keylineTint(Palette.accent)
        }
    }
}

// MARK: Home screen and StandBy widget

struct LastSongEntry: TimelineEntry {
    let date: Date
    let song: StandbySong?
}

struct LastSongProvider: TimelineProvider {
    func placeholder(in context: Context) -> LastSongEntry {
        LastSongEntry(date: .now, song: StandbySong(title: "Your song", artist: "Artist", cover: nil))
    }

    func getSnapshot(in context: Context, completion: @escaping (LastSongEntry) -> Void) {
        completion(LastSongEntry(date: .now, song: StandbySong.read()))
    }

    /// One entry. The app asks for a new one whenever the song changes.
    func getTimeline(in context: Context, completion: @escaping (Timeline<LastSongEntry>) -> Void) {
        completion(Timeline(entries: [LastSongEntry(date: .now, song: StandbySong.read())], policy: .never))
    }
}

struct KnobLastSongWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "KnobLastSong", provider: LastSongProvider()) { entry in
            LastSongView(song: entry.song)
                .containerBackground(for: .widget) { Vinyl.base }
        }
        .configurationDisplayName("Knob")
        .description("The record and name of the last song you played.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

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
