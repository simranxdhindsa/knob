import Foundation

/// The parts of a Spotify import that need no network or UI, so the Spotify self test can check
/// them directly: reading spotDL's messages, counting progress, choosing which songs start ticked,
/// and running spotDL jobs one at a time.
enum KnobShiftImport {
    /// What one line of spotDL's output says about a song.
    enum Event: Equatable {
        case landed(String)
        case notFound(String)
    }

    /// spotDL names songs "First artist - Name" in its messages. Its terminal display drops text
    /// in square brackets and may change spacing, so names are compared in a loose form.
    static func key(_ display: String) -> String {
        display.replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func display(_ song: KnobShiftSpotDL.Song) -> String { "\(song.artist) - \(song.name)" }

    /// The song a line is about and what happened to it, or nil for any other line.
    static func parse(_ line: String) -> (event: String, display: String)? {
        if let start = line.range(of: "Downloaded \"") {
            let rest = line[start.upperBound...]
            let end = rest.range(of: "\":", options: .backwards)?.lowerBound ?? rest.lastIndex(of: "\"") ?? rest.endIndex
            return ("landed", String(rest[..<end]))
        }
        if let start = line.range(of: "Skipping ") {
            let rest = line[start.upperBound...]
            for marker in [" (file already exists)", " (skip file found)"] {
                if let end = rest.range(of: marker) { return ("landed", String(rest[..<end.lowerBound])) }
            }
            if rest.hasPrefix("explicit song: ") { return ("notFound", String(rest.dropFirst("explicit song: ".count))) }
        }
        if let start = line.range(of: "No results found for song: ") {
            return ("notFound", String(line[start.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Progress of one playlist's download: how many songs are done, and which are on their way.
    struct Progress: Equatable {
        /// The songs being downloaded, in the order spotDL works through them.
        private(set) var order: [String] = []
        private(set) var names: [String: String] = [:]
        private var ids: [String: String] = [:]
        private(set) var landed: Set<String> = []
        private(set) var missing: Set<String> = []
        /// spotDL downloads four songs at once, taking them in order.
        static let threads = 4
        /// False while it waits for another playlist's download to finish.
        var started = false

        init(songs: [KnobShiftSpotDL.Song]) {
            for song in songs where names[song.song_id] == nil {
                order.append(song.song_id)
                names[song.song_id] = song.name
                ids[KnobShiftImport.key(KnobShiftImport.display(song)), default: song.song_id] = song.song_id
            }
        }

        var total: Int { order.count }
        var finished: Int { landed.count + missing.count }
        var fraction: Double { total == 0 ? 0 : Double(finished) / Double(total) }

        /// The songs spotDL is working on now: the first ones in order not finished yet.
        var current: [String] {
            guard started else { return [] }
            var found: [String] = []
            for id in order where !landed.contains(id) && !missing.contains(id) {
                found.append(names[id] ?? id)
                if found.count == Self.threads { break }
            }
            return found
        }

        /// Reads one line; returns the song it finished, if any.
        mutating func consume(_ line: String) -> Event? {
            guard let parsed = KnobShiftImport.parse(line), let id = ids[KnobShiftImport.key(parsed.display)],
                  !landed.contains(id), !missing.contains(id) else { return nil }
            if parsed.event == "landed" {
                landed.insert(id)
                return .landed(id)
            }
            missing.insert(id)
            return .notFound(id)
        }

        mutating func markLanded(_ id: String) {
            guard names[id] != nil, !missing.contains(id) else { return }
            landed.insert(id)
        }

        /// For YouTube, which reports each song by id rather than in spotDL's messages.
        mutating func markMissing(_ id: String) {
            guard names[id] != nil, !landed.contains(id) else { return }
            missing.insert(id)
        }
    }

    /// Which songs start ticked when a list is read: everything not ticked off before. Songs
    /// already in the queue stay ticked and cannot be unticked here (remove them in the queue).
    static func initialSelection(songs: [KnobShiftSpotDL.Song], skipped: Set<String>) -> Set<String> {
        Set(songs.map(\.song_id).filter { !skipped.contains($0) })
    }

    /// The songs left out by a selection, kept so Update playlist does not tick them again.
    static func skipped(songs: [KnobShiftSpotDL.Song], selected: Set<String>, queued: Set<String>) -> [String] {
        songs.map(\.song_id).filter { !selected.contains($0) && !queued.contains($0) }
    }

    /// Songs worth a new queue row: selected, not in the queue already, each once, in order.
    static func newRows(songs: [KnobShiftSpotDL.Song], selected: Set<String>, queued: Set<String>) -> [KnobShiftSpotDL.Song] {
        var seen = queued
        return songs.filter { selected.contains($0.song_id) && seen.insert($0.song_id).inserted }
    }

    /// About 6 MB a song (KNOB_SONG_MB changes it for the command line checks, whose songs are tiny).
    static var bytesPerSong: Int64 {
        Int64((Double(ProcessInfo.processInfo.environment["KNOB_SONG_MB"] ?? "") ?? 6) * 1_000_000)
    }

    static func spaceNeeded(for songs: Int) -> Int64 { Int64(songs) * bytesPerSong + 500_000_000 }

    /// Room for the songs plus 500 MB spare.
    static func hasRoom(for songs: Int, available: Int64?) -> Bool {
        guard let available else { return true }
        return available > spaceNeeded(for: songs)
    }
}

/// Runs jobs one at a time in the order they were asked for, so two spotDL downloads never
/// write into the same folders or compete for YouTube at once. Each job has a key; asking for a
/// key already waiting or running does nothing, and a waiting job can be called off.
@MainActor
final class KnobShiftLane {
    private var waiting: [(key: String, work: () async -> Void)] = []
    private(set) var running: String?

    var waitingKeys: [String] { waiting.map(\.key) }

    func contains(_ key: String) -> Bool { running == key || waiting.contains { $0.key == key } }

    /// Adds a job; returns false when the same key is already waiting. A key that is running
    /// can be queued again, for work added while it runs.
    @discardableResult
    func enqueue(_ key: String, _ work: @escaping () async -> Void) -> Bool {
        guard !waiting.contains(where: { $0.key == key }) else { return false }
        waiting.append((key, work))
        if running == nil { startNext() }
        return true
    }

    /// Calls off a job that has not started; a running one is stopped by its owner.
    @discardableResult
    func removeWaiting(_ key: String) -> Bool {
        let before = waiting.count
        waiting.removeAll { $0.key == key }
        return waiting.count != before
    }

    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let job = waiting.removeFirst()
        running = job.key
        Task { @MainActor [weak self] in
            await job.work()
            self?.running = nil
            self?.startNext()
        }
    }
}
