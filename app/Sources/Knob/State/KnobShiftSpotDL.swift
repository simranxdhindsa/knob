import AppKit
import Foundation

/// Runs the spotDL helper bundled in Knob.app (Contents/Helpers/spotdl, fetched at build time
/// by packaging/fetch-spotdl.sh). spotDL reads a Spotify list and downloads each song's audio
/// from YouTube with Spotify's tags. It runs as its own process, off the main thread, with a home
/// folder of its own inside Knob's Application Support, so its settings and Spotify login stay
/// apart from anything else on the Mac.
final class KnobShiftSpotDL: @unchecked Sendable {
    static let shared = KnobShiftSpotDL()

    /// One song as spotDL describes it in a save file.
    struct Song: Decodable, Equatable {
        let name: String
        let artists: [String]
        let artist: String
        let album_name: String?
        let duration: Double?
        let song_id: String
        let url: String
        let list_name: String?
        let list_position: Int?

        /// "Artist - Name", how spotDL names songs in its own messages.
        var displayName: String { "\(artist) - \(name)" }
    }

    enum Failure: Error, Equatable {
        case unavailable, privateList, offline, rateLimited, nothingFound, failed

        /// Plain sentences for the player; no dashes.
        var message: String {
            switch self {
            case .unavailable: return "Spotify import is unavailable in this copy of Knob."
            case .privateList: return "This playlist is private. Log in to Spotify to add it."
            case .offline: return "No internet connection. Try again when you are back online."
            case .rateLimited: return "Spotify is busy. Try again in a minute."
            case .nothingFound: return "Spotify returned no songs for this link."
            case .failed: return "Spotify import did not finish. Try again."
            }
        }
    }

    private let lock = NSLock()
    private var running: [UUID: Process] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.cancelAll()
        }
    }

    // MARK: Where things are

    /// The bundled helper. spotDL ships for Apple silicon only, so Intel Macs hide the feature.
    /// KNOB_SPOTDL points at another copy, for development.
    static var helper: URL? {
        #if arch(arm64)
        if let path = ProcessInfo.processInfo.environment["KNOB_SPOTDL"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spotdl")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
        #else
        return nil
        #endif
    }

    static var ffmpeg: URL? {
        let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path,
                          "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    static var isAvailable: Bool { helper != nil && ffmpeg != nil }

    /// spotDL's own home: its settings, caches and the Spotify login token.
    static var home: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.simranxdhindsa.knob")
            .appendingPathComponent("spotDL", isDirectory: true)
    }

    private static var tokenFiles: [URL] {
        [home.appendingPathComponent(".spotdl/.spotipy"), home.appendingPathComponent(".config/spotdl/.spotipy")]
    }

    static var isLoggedIn: Bool { tokenFiles.contains { FileManager.default.fileExists(atPath: $0.path) } }

    static func logOut() {
        for file in tokenFiles { try? FileManager.default.removeItem(at: file) }
    }

    // MARK: Commands

    /// Reads a list's songs from Spotify without downloading anything (`spotdl save`).
    func list(_ query: String, userAuth: Bool) async throws -> [Song] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("knobshift-\(UUID().uuidString).spotdl")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = await run(["save", query, "--save-file", file.path] + (userAuth ? ["--user-auth"] : []),
                               id: UUID()) { _ in }
        guard let data = try? Data(contentsOf: file) else {
            throw Self.classify(result.lines) ?? .failed
        }
        let songs: [Song]
        if let list = try? JSONDecoder().decode([Song].self, from: data) {
            songs = list
        } else if let wrapped = try? JSONDecoder().decode(SyncFile.self, from: data) {
            songs = wrapped.songs
        } else {
            throw Failure.failed
        }
        guard !songs.isEmpty else { throw Self.classify(result.lines) ?? .nothingFound }
        return songs
    }

    /// Downloads a list into `folder` (`spotdl sync`), so running it again only fetches what is
    /// new. Songs removed on Spotify are never deleted here. Each line of spotDL's output goes to
    /// `onLine` as it arrives. Returns spotDL's exit status (non zero when cancelled).
    func download(_ query: String, into folder: URL, userAuth: Bool, id: UUID,
                  onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = ["sync", query,
                         "--save-file", folder.appendingPathComponent("playlist.spotdl").path,
                         "--sync-without-deleting",
                         "--format", "m4a", "--bitrate", "disable",
                         "--output", folder.appendingPathComponent("{list-position} {title} - {artists} [{track-id}].{output-ext}").path,
                         "--m3u", folder.appendingPathComponent("playlist.m3u8").path,
                         "--threads", "4", "--print-errors"] + (userAuth ? ["--user-auth"] : [])
        return await run(arguments, id: id, onLine: onLine).status
    }

    /// Downloads one song into `folder`, for Retry.
    func downloadSong(_ spotifyId: String, into folder: URL, userAuth: Bool, id: UUID,
                      onLine: @escaping @Sendable (String) -> Void) async -> Int32 {
        let arguments = ["download", "https://open.spotify.com/track/\(spotifyId)",
                         "--format", "m4a", "--bitrate", "disable",
                         "--output", folder.appendingPathComponent("{title} - {artists} [{track-id}].{output-ext}").path,
                         "--print-errors"] + (userAuth ? ["--user-auth"] : [])
        return await run(arguments, id: id, onLine: onLine).status
    }

    func cancel(_ id: UUID) {
        lock.lock()
        let process = running[id]
        lock.unlock()
        process?.terminate()
    }

    func cancelAll() {
        lock.lock()
        let all = Array(running.values)
        lock.unlock()
        all.forEach { $0.terminate() }
    }

    // MARK: Running

    private struct SyncFile: Decodable { let songs: [Song] }

    private func run(_ arguments: [String], id: UUID,
                     onLine: @escaping @Sendable (String) -> Void) async -> (status: Int32, lines: [String]) {
        guard let helper = Self.helper, let ffmpeg = Self.ffmpeg else { return (-1, []) }
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments + ["--ffmpeg", ffmpeg.path, "--simple-tui", "--log-level", "INFO"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Self.home.path
        environment["PATH"] = "\(ffmpeg.deletingLastPathComponent().path):/usr/bin:/bin"
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let collected = LineCollector(onLine: onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collected.append(data) }
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { [weak self] finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.append(pipe.fileHandleForReading.readDataToEndOfFile())
                collected.flush()
                self?.lock.lock()
                self?.running[id] = nil
                self?.lock.unlock()
                continuation.resume(returning: (finished.terminationStatus, collected.lines))
            }
            do {
                try process.run()
                lock.lock()
                running[id] = process
                lock.unlock()
            } catch {
                continuation.resume(returning: (-1, ["Could not start spotDL: \(error.localizedDescription)"]))
            }
        }
    }

    /// Splits spotDL's output into lines without the colour codes of its terminal display.
    private final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private(set) var lines: [String] = []
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            var ready: [String] = []
            while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                let clean = line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                if !clean.isEmpty { ready.append(clean) }
            }
            lines.append(contentsOf: ready)
            lock.unlock()
            ready.forEach(onLine)
        }

        func flush() {
            lock.lock()
            let rest = String(decoding: buffer, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            if !rest.isEmpty { lines.append(rest) }
            lock.unlock()
            if !rest.isEmpty { onLine(rest) }
        }
    }

    /// What went wrong, read from spotDL's messages.
    static func classify(_ lines: [String]) -> Failure? {
        let text = lines.joined(separator: "\n").lowercased()
        if text.contains("429") || text.contains("rate limit") || text.contains("too many requests") { return .rateLimited }
        if text.contains("connectionerror") || text.contains("max retries") || text.contains("nodename nor servname")
            || text.contains("network is unreachable") || text.contains("temporary failure in name resolution") { return .offline }
        if text.contains("401") || text.contains("403") || text.contains("404") || text.contains("private")
            || text.contains("user-auth") || text.contains("unauthorized") { return .privateList }
        return nil
    }
}
