import ActivityKit
import SwiftUI
import WidgetKit

/// Knob's StandBy extension: the Live Activity for the playing song and a small widget with
/// the last song. iOS only lets widgets and Live Activities in StandBy.
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
                .activitySystemActionForegroundColor(Vinyl.shine)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StandbyRecord(cover: context.state.cover, diameter: 72, spinning: context.state.isPlaying)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    StandbyTitles(state: context.state, size: 16, showsNext: true)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        StandbyProgress(state: context.state, size: 11)
                        StandbyButtons(isPlaying: context.state.isPlaying, mixing: context.state.mixing, size: 17)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                StandbyRingedRecord(state: context.state, diameter: 26)
            } compactTrailing: {
                StandbyTimeLeft(state: context.state)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.accent)
                    .frame(width: 42)
            } minimal: {
                StandbyRingedRecord(state: context.state, diameter: 24)
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
