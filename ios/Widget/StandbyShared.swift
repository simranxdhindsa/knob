import ActivityKit
import AppIntents
import Foundation

// What Knob and its StandBy extension both know: the Live Activity's state, the folder they
// share, the last song, and the three buttons. Compiled into both, so keep it small.

/// The Live Activity for the playing song. Apple allows 4 KB of state, so it carries words and
/// times only. The cover is a file in the shared folder, named here.
struct KnobStandbyAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String?
        var isPlaying: Bool
        /// Where the song would have started, so the bar and the time left move on their own.
        var started: Date
        var duration: TimeInterval
        /// Where the song is while paused.
        var elapsed: TimeInterval
        /// The cover file in the shared folder, or nothing if there is none yet.
        var cover: String?

        var ends: Date { started.addingTimeInterval(duration) }
        var range: ClosedRange<Date> { started...max(ends, started.addingTimeInterval(1)) }
        /// The time left as `-0:36`, for a song that is paused.
        var timeLeft: String {
            let left = max(Int((duration - elapsed).rounded()), 0)
            return String(format: "-%d:%02d", left / 60, left % 60)
        }
    }
}

/// The folder Knob and its extension both read, through the App Group.
enum StandbyGroup {
    static let id = "group.io.github.simranxdhindsa.knob.phone"

    static var folder: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) }
    static var songFile: URL? { folder?.appendingPathComponent("last-song.json") }
    static var recordFile: URL? { folder?.appendingPathComponent("record.png") }

    static func coverFile(_ name: String?) -> URL? { name.flatMap { folder?.appendingPathComponent($0) } }
}

/// The last song, for the home screen and StandBy widget.
struct StandbySong: Codable, Equatable {
    var title: String
    var artist: String?
    var cover: String?

    static func read() -> StandbySong? {
        guard let file = StandbyGroup.songFile, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(StandbySong.self, from: data)
    }
}

/// What the card's buttons ask for. The app sets `handler` and the intents call it, which only
/// happens inside the app: a Live Activity button runs in Knob, never in the extension.
enum StandbyActions {
    enum Kind { case playPause, previous, next }
    @MainActor static var handler: ((Kind) -> Void)?
}

struct StandbyPlayPauseIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Play or pause"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { StandbyActions.handler?(.playPause) }
        return .result()
    }
}

struct StandbyPreviousIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Previous song"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { StandbyActions.handler?(.previous) }
        return .result()
    }
}

/// Next while playing is a KnobMix into the next song, like everywhere else in Knob.
struct StandbyNextIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Next song"
    static var isDiscoverable = false
    func perform() async throws -> some IntentResult {
        await MainActor.run { StandbyActions.handler?(.next) }
        return .result()
    }
}
