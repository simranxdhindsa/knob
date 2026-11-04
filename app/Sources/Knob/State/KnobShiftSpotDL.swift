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
        case unavailable, privateList, offline, rateLimited, nothingFound, failed, stalled, noSpace, paused, youtubeBlocked, browserSignIn

        /// Plain sentences for the player; no dashes.
        var message: String {
            switch self {
            case .unavailable: return "Spotify import is unavailable in this copy of Knob."
            case .privateList: return "This playlist is private. Log in to Spotify to add it."
            case .offline: return "No internet connection. Try again when you are back online."
            case .rateLimited: return "Spotify is busy. Try again in a minute."
            case .nothingFound: return "Spotify returned no songs for this link."
            case .failed: return "Spotify import did not finish. Try again."
            case .stalled: return "Spotify stopped answering, so the import was stopped. Try again."
            case .noSpace: return "Not enough space on this Mac for these songs."
            case .paused: return KnobShiftSpotifyAccount.pausedMessage
            case .youtubeBlocked: return "YouTube is pausing downloads from this Mac for now. Try again in a few hours."
            case .browserSignIn: return KnobShiftYouTubeParsing.Failure.browserSignIn.message
            }
        }
    }

    private let processes = KnobShiftHelperProcess(name: "spotDL")

    private init() {}

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
        let candidates = [ProcessInfo.processInfo.environment["KNOB_FFMPEG"] ?? "",
                          Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg").path,
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

    /// A list read from Spotify: its songs in order, and each song exactly as spotDL wrote it,
    /// so the songs picked can be handed back to spotDL without asking Spotify again.
    struct Listing: Sendable {
        let songs: [Song]
        let raw: [String: Data]
    }

    /// Reads a list's songs from Spotify without downloading anything (`spotdl save`).
    func list(_ query: String, userAuth: Bool, id: UUID = UUID()) async throws -> Listing {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("knobshift-\(UUID().uuidString).spotdl")
        defer { try? FileManager.default.removeItem(at: file) }
        if await KnobShiftSpotifyAccount.pausedUntil(userAuth: userAuth) != nil { throw Failure.paused }
        let result = await run(["save", query, "--save-file", file.path] + (userAuth ? ["--user-auth"] : []), id: id) { _ in }
        if result.cancelled { throw CancellationError() }
        if result.stalled { throw Failure.stalled }
        guard let data = try? Data(contentsOf: file) else { throw Self.classify(result.lines) ?? .failed }
        guard let listing = Self.listing(from: data) else { throw Failure.failed }
        guard !listing.songs.isEmpty else { throw Self.classify(result.lines) ?? .nothingFound }
        return listing
    }

    /// Songs and their raw entries from a save file (a list, or an object with "songs").
    static func listing(from data: Data) -> Listing? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["songs"] as? [[String: Any]]) ?? []
        var songs: [Song] = []
        var raw: [String: Data] = [:]
        songs.reserveCapacity(entries.count)
        for entry in entries {
            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  let song = try? JSONDecoder().decode(Song.self, from: data) else { continue }
            songs.append(song)
            raw[song.song_id] = data
        }
        if songs.isEmpty, !entries.isEmpty { return nil }
        return Listing(songs: songs, raw: raw)
    }

    /// Writes the chosen songs as a save file spotDL downloads from directly, without reading
    /// Spotify again. Songs with no raw entry are left out.
    static func writeSaveFile(_ ids: [String], raw: [String: Data], to url: URL) throws {
        var out = Data("[".utf8)
        var first = true
        for id in ids {
            guard let entry = raw[id] else { continue }
            if !first { out.append(Data(",".utf8)) }
            out.append(entry)
            first = false
        }
        out.append(Data("]".utf8))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }

    /// Downloads the songs of a save file into `folder`. Songs already there are skipped, so
    /// running it again only fetches what is missing. Each line of spotDL's output goes to
    /// `onLine` as it arrives.
    func download(saveFile: URL, into folder: URL, userAuth: Bool, id: UUID, browser: KnobShiftYouTubeBrowser? = nil,
                  onLine: @escaping @Sendable (String) -> Void) async -> RunResult {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A save file carries everything spotDL needs, so downloading asks Spotify nothing: no
        // login, and Spotify pausing its key never stops a download (checked with a broken key).
        let arguments = ["download", saveFile.path,
                         "--format", "m4a", "--bitrate", "disable",
                         "--output", folder.appendingPathComponent("{list-position} {title} - {artists} [{track-id}].{output-ext}").path,
                         "--threads", "\(KnobShiftImport.Progress.threads)", "--print-errors"]
        return await run(arguments + Self.browserArguments(browser), id: id, browser: browser, onLine: onLine)
    }

    /// What tells spotDL's YouTube downloader to use a browser's sign in; nothing without one.
    static func browserArguments(_ browser: KnobShiftYouTubeBrowser?) -> [String] {
        browser.map { ["--yt-dlp-args", "--cookies-from-browser \($0.rawValue)"] } ?? []
    }

    /// Logs in through Spotify's page in the browser. spotDL saves the token as soon as the user
    /// agrees, then would go on reading their whole Liked Songs, so it is stopped the moment the
    /// token appears. Gives up after `timeout` or when `cancel(id)` stops it.
    func logIn(id: UUID, timeout: TimeInterval = 180) async -> Bool {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("knobshift-login-\(id.uuidString).spotdl")
        let finished = Flag()
        let login = Task {
            _ = await run(["save", "saved", "--save-file", file.path, "--user-auth"], id: id, idleLimit: nil) { _ in }
            finished.set()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !Self.isLoggedIn, !finished.isSet, !isCancelled(id), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
        }
        cancel(id)
        await login.value
        try? FileManager.default.removeItem(at: file)
        return Self.isLoggedIn
    }

    // MARK: Stopping

    /// Stops a job and everything it started (spotDL runs Python, which runs FFmpeg).
    func cancel(_ id: UUID) { processes.cancel(id) }

    func cancelAll() { processes.cancelAll() }

    private func isCancelled(_ id: UUID) -> Bool { processes.isCancelled(id) }

    // MARK: Running

    typealias RunResult = KnobShiftHelperProcess.Result
    typealias Flag = KnobShiftHelperProcess.Flag

    /// Runs spotDL through the shared runner, with its own home, FFmpeg and unpacked libraries.
    /// Reading a few thousand Liked Songs prints nothing for minutes, so the idle limit is generous.
    private func run(_ arguments: [String], id: UUID, idleLimit: TimeInterval? = 900, browser: KnobShiftYouTubeBrowser? = nil,
                     onLine: @escaping @Sendable (String) -> Void) async -> RunResult {
        guard let helper = Self.helper, let ffmpeg = Self.ffmpeg else {
            return RunResult(status: -1, lines: [], cancelled: false, stalled: false)
        }
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Self.home.path
        if browser != nil {
            // The browser is found under the real home; spotDL's own files still stay in Knob's.
            environment["HOME"] = KnobShiftYouTubeBrowser.realHome
            environment["XDG_CACHE_HOME"] = Self.home.appendingPathComponent(".cache").path
            environment["XDG_DATA_HOME"] = Self.home.appendingPathComponent(".local/share").path
            environment["XDG_CONFIG_HOME"] = Self.home.appendingPathComponent(".config").path
        }
        environment["PATH"] = "\(ffmpeg.deletingLastPathComponent().path):/usr/bin:/bin"
        environment["PYTHONUNBUFFERED"] = "1"
        // spotDL's display wraps at 80 columns when not in a terminal, which would split song
        // names across lines.
        environment["COLUMNS"] = "1000"
        environment["TERM"] = "dumb"
        // spotDL also comes unpacked in Resources (build-app.sh), so PyInstaller's "already
        // unpacked" mode skips unpacking hundreds of libraries on every start: about 2s, not 20s.
        let unpacked = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/spotdl-runtime")
        if FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("base_library.zip").path) {
            environment["_PYI_APPLICATION_HOME_DIR"] = unpacked.path
            environment["_PYI_ARCHIVE_FILE"] = helper.path
            environment["_PYI_PARENT_PROCESS_LEVEL"] = "1"
        }
        // DEBUG, because YouTube's reason for refusing a download only shows there; the line
        // collector reads those lines for it and passes none of them on.
        let all = arguments + ["--ffmpeg", ffmpeg.path, "--simple-tui", "--log-level", "DEBUG"]
        // KNOB_SPOTDL_IDLE shortens the limit for the command line checks.
        let limit = idleLimit.map { Double(ProcessInfo.processInfo.environment["KNOB_SPOTDL_IDLE"] ?? "") ?? $0 }
        return await processes.run(helper, arguments: all, environment: environment, id: id, idleLimit: limit, onLine: onLine)
    }

    /// What went wrong, read from spotDL's messages.
    static func classify(_ lines: [String]) -> Failure? {
        let text = lines.joined(separator: "\n").lowercased()
        if KnobShiftYouTubeParsing.isBrowserFailure(text) { return .browserSignIn }
        if text.contains("youtube_bot_check") { return .youtubeBlocked }
        if text.contains("quota_exceeded") { return .paused }
        if text.contains("429") || text.contains("rate limit") || text.contains("too many requests") { return .rateLimited }
        if text.contains("connectionerror") || text.contains("max retries") || text.contains("nodename nor servname")
            || text.contains("network is unreachable") || text.contains("temporary failure in name resolution")
            || text.contains("timed out") { return .offline }
        if text.contains("no space left") { return .noSpace }
        if text.contains("401") || text.contains("403") || text.contains("404") || text.contains("private")
            || text.contains("user-auth") || text.contains("unauthorized") { return .privateList }
        return nil
    }
}
