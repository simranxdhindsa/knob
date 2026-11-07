import Foundation

/// How long the queue has left and when it ends, from the songs' lengths. Pure, so it is easy to check.
enum QueueTiming {
    /// The rest of the playing song plus every song after it in the order on screen. With no
    /// playing song, the whole queue is still ahead.
    static func remaining(durations: [TimeInterval], playingIndex: Int?, position: TimeInterval) -> TimeInterval {
        guard let i = playingIndex, durations.indices.contains(i) else { return durations.reduce(0, +) }
        return max(0, durations[i] - position) + durations[(i + 1)...].reduce(0, +)
    }

    /// "5 hr 12 min left", "42 min left", "Less than a minute left".
    static func leftText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "Less than a minute left" }
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min left" }
        return rest == 0 ? "\(hours) hr left" : "\(hours) hr \(rest) min left"
    }

    private static let clockFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        f.amSymbol = "AM"
        f.pmSymbol = "PM"
        return f
    }()

    /// "Ends at 3:40 AM".
    static func endsText(from now: Date, remaining: TimeInterval) -> String {
        "Ends at " + clockFormat.string(from: now.addingTimeInterval(remaining))
    }
}
