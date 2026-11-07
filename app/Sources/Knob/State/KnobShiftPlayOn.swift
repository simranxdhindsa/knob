import CryptoKit
import Foundation

/// Play On: moves the music to one other device on the same Wi-Fi, from the same moment, and
/// copies over any song that device doesn't have. Unlike Listen Together, only one device plays.
/// This file is the rules, with no network or sound, so every case can be tested on its own.
enum KnobShiftPlayOn {
    /// The Bonjour service (Info.plist NSBonjourServices on the iPhone).
    static let service = "_knobplay._tcp"
    static let version = 1
    /// No song comes close: a long FLAC is about 60 MB.
    static let longestFile: Int64 = 300_000_000
    /// How many songs after the one playing are copied ahead, so a long queue isn't copied whole.
    static let songsAhead = 5
    static let longestQueue = 20_000
    private static let spareSpace: Int64 = 500_000_000
    private static let audioTypes: Set<String> = ["m4a", "mp3", "opus", "ogg", "flac", "wav", "aac", "aif", "aiff", "caf"]
    private static let longestName = 240
    private static let hashedBytes = 1_000_000

    struct Hello: Codable, Equatable {
        var version: Int
        var deviceId: String
        var name: String
    }

    /// The playlist a song belongs to, so it lands under the same name on the other device.
    struct Playlist: Codable, Equatable {
        var id: String
        var name: String
        var link: String
    }

    struct Song: Codable, Equatable, Identifiable {
        var key: String
        var title: String
        var artist: String?
        var fileName: String
        var size: Int64
        var playlist: Playlist?
        var id: String { key }
    }

    /// Everything the other device needs to carry on from here.
    struct Handover: Codable, Equatable {
        var songs: [Song]
        var current: Int
        var position: Double
        var isPlaying: Bool
        var isShuffled: Bool
        /// When `position` was read, on the shared clock.
        var sentAt: Int64
        var effects: KnobShiftTogether.Effects?
    }

    // MARK: Which songs are the same

    /// What makes a song the same on two devices. Spotify and YouTube songs have an id in their
    /// file name, so the m4a on one device matches the FLAC on another. Your own files are known
    /// by their size and first megabyte, whatever they're called.
    static func key(for url: URL) -> String? {
        if let id = KnobShiftPlaylists.songId(inFileName: url.deletingPathExtension().lastPathComponent) { return "id:\(id)" }
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let start = try? handle.read(upToCount: hashedBytes) else { return nil }
        let hash = SHA256.hash(data: start).map { String(format: "%02x", $0) }.joined()
        return "file:\(size)-\(hash)"
    }

    // MARK: What gets copied

    /// The song playing first, then the next few, leaving out what the other device has.
    static func sendOrder(_ songs: [Song], current: Int, have: Set<String>) -> [Song] {
        guard songs.indices.contains(current) else { return [] }
        var seen = have
        let end = min(current + songsAhead + 1, songs.count)
        return songs[current..<end].filter { seen.insert($0.key).inserted }
    }

    // MARK: Checking what arrives

    /// A name from another device, made safe: no way out of the folder, songs only. Nil when it
    /// isn't a song at all.
    static func safeFileName(_ name: String, key: String) -> String? {
        let clean = name.replacingOccurrences(of: "\0", with: "")
        var plain = (clean as NSString).lastPathComponent
        while plain.hasPrefix(".") { plain.removeFirst() }
        let kind = (plain as NSString).pathExtension
        guard audioTypes.contains(kind.lowercased()), !plain.contains("/") else { return nil }
        var stem = (plain as NSString).deletingPathExtension
        guard !stem.isEmpty else { return nil }
        // Cut from the front of the name's words, keeping an id on the end: it's how the song is known.
        var tag = ""
        if key.hasPrefix("id:"), stem.hasSuffix("]"), let open = stem.range(of: " [", options: .backwards) {
            tag = String(stem[open.lowerBound...])
            stem = String(stem[..<open.lowerBound])
        }
        while stem.utf8.count + tag.utf8.count > longestName { stem.removeLast() }
        return "\(stem)\(tag).\(kind)"
    }

    static func isValid(_ handover: Handover) -> Bool {
        !handover.songs.isEmpty && handover.songs.count <= longestQueue && handover.songs.indices.contains(handover.current)
            && handover.position.isFinite && handover.position >= 0 && (handover.effects?.isValid ?? true)
    }

    /// Where the song should be at `goAt`: a playing song has moved on, a paused one hasn't.
    static func startPosition(_ handover: Handover, goAt: Int64, duration: Double) -> Double {
        guard handover.isPlaying else { return handover.position }
        let passed = max(0, Double(goAt - handover.sentAt) / 1e9)
        return min(handover.position + passed, max(0, duration - 1))
    }

    // MARK: Asking once

    struct Allowed: Equatable {
        var ids: Set<String> = []

        func contains(_ id: String) -> Bool { !id.isEmpty && ids.contains(id) }

        mutating func allow(_ id: String) {
            if !id.isEmpty { ids.insert(id) }
        }
    }

    // MARK: The handover

    enum Stage: Equatable {
        case idle, waitingForAllow, copying(Double), gettingReady, waitingForMix, playingThere, failed(String), lost

        var text: String {
            switch self {
            case .idle: return ""
            case .waitingForAllow: return "Waiting for Allow"
            case .copying(let share): return "Copying song, \(Int((share * 100).rounded()))%"
            case .gettingReady: return "Getting ready"
            case .waitingForMix: return "Waiting for the mix to finish"
            case .playingThere: return "Playing there"
            case .failed(let message): return message
            case .lost: return "Lost the connection."
            }
        }

        /// Until the switch itself, nothing stops playing here.
        var musicIsHere: Bool { self != .playingThere && self != .lost }
    }

    enum Event: Equatable {
        case start, allowed, refused, needs(Int), copied(Double), ready, mixRunning, mixEnded, switched, connectionLost, noSpace, noOutput
    }

    /// One handover from start to finish, on the sending device.
    struct Handoff: Equatable {
        var device: String
        private(set) var stage = Stage.idle
        private var isReady = false
        private var mixing = false

        init(device: String) { self.device = device }

        /// Ends with these exact words.
        mutating func fail(_ message: String) { stage = .failed(message) }

        private var isOver: Bool {
            if case .failed = stage { return true }
            return stage == .lost
        }

        mutating func handle(_ event: Event) {
            guard !isOver else { return }
            switch event {
            case .start:
                if stage == .idle { stage = .waitingForAllow }
            case .allowed:
                if stage == .waitingForAllow { stage = .gettingReady }
            case .refused:
                if stage == .waitingForAllow { stage = .failed("\(device) didn't allow this.") }
            case .needs(let songs):
                guard stage == .gettingReady else { return }
                if songs > 0 { stage = .copying(0) }
            case .copied(let share):
                if case .copying = stage { stage = .copying(min(max(share, 0), 1)) }
            case .ready:
                guard stage == .gettingReady || isCopying else { return }
                isReady = true
                stage = mixing ? .waitingForMix : .gettingReady
            case .mixRunning:
                mixing = true
                if isReady, stage == .gettingReady { stage = .waitingForMix }
            case .mixEnded:
                mixing = false
                if stage == .waitingForMix { stage = .gettingReady }
            case .switched:
                if isReady, stage == .gettingReady { stage = .playingThere }
            case .connectionLost:
                if stage == .playingThere {
                    stage = .lost
                } else if stage != .idle {
                    stage = .failed("Couldn't reach \(device).")
                }
            case .noSpace:
                if stage.musicIsHere, stage != .idle { stage = .failed("Not enough space on \(device).") }
            case .noOutput:
                if stage.musicIsHere, stage != .idle { stage = .failed("\(device) can't play sound right now.") }
            }
        }

        private var isCopying: Bool {
            if case .copying = stage { return true }
            return false
        }
    }

    // MARK: Receiving a file

    /// One song arriving. It's written to a hidden file and only appears under its real name once
    /// every byte has come, so a broken copy never shows up as a song.
    struct Incoming {
        enum Failure: Error, Equatable { case tooBig, noSpace, badName, wrongSize, tooLong }

        let url: URL
        private let part: URL
        private let size: Int64
        private var received: Int64 = 0
        private var handle: FileHandle?

        init(name: String, key: String, size: Int64, folder: URL, freeSpace: Int64) throws {
            guard size >= 0, size <= longestFile else { throw Failure.tooBig }
            guard freeSpace > size + spareSpace else { throw Failure.noSpace }
            guard let safe = safeFileName(name, key: key) else { throw Failure.badName }
            url = Self.free(safe, in: folder)
            self.size = size
            part = folder.appendingPathComponent(".\(UUID().uuidString).part")
            guard FileManager.default.createFile(atPath: part.path, contents: nil) else { throw Failure.noSpace }
            handle = try FileHandle(forWritingTo: part)
        }

        /// Copies a crash left behind. They're hidden, so nothing else would ever clear them.
        static func clearLeftovers(in folder: URL) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasPrefix(".") && name.hasSuffix(".part") {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }

        /// The name, or "name 2" and so on: a song already there is never overwritten.
        private static func free(_ name: String, in folder: URL) -> URL {
            let first = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: first.path) else { return first }
            let stem = (name as NSString).deletingPathExtension, kind = (name as NSString).pathExtension
            var number = 2
            while true {
                let next = folder.appendingPathComponent("\(stem) \(number).\(kind)")
                if !FileManager.default.fileExists(atPath: next.path) { return next }
                number += 1
            }
        }

        mutating func add(_ data: Data) throws {
            guard received + Int64(data.count) <= size else {
                cancel()
                throw Failure.tooLong
            }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
        }

        mutating func finish() throws -> URL {
            guard received == size else {
                cancel()
                throw Failure.wrongSize
            }
            try handle?.close()
            handle = nil
            try FileManager.default.moveItem(at: part, to: url)
            return url
        }

        mutating func cancel() {
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: part)
        }
    }
}
