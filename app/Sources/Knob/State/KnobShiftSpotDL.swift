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
        case unavailable, privateList, offline, rateLimited, nothingFound, failed, stalled, noSpace, paused, youtubeBlocked

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
            }
        }
    }

    private let lock = NSLock()
    private var running: [UUID: Process] = [:]
    /// Jobs stopped on purpose, so their result says so.
    private var cancelled: Set<UUID> = []

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
    func download(saveFile: URL, into folder: URL, userAuth: Bool, id: UUID,
                  onLine: @escaping @Sendable (String) -> Void) async -> RunResult {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A save file carries everything spotDL needs, so downloading asks Spotify nothing: no
        // login, and Spotify pausing its key never stops a download (checked with a broken key).
        let arguments = ["download", saveFile.path,
                         "--format", "m4a", "--bitrate", "disable",
                         "--output", folder.appendingPathComponent("{list-position} {title} - {artists} [{track-id}].{output-ext}").path,
                         "--threads", "\(KnobShiftImport.Progress.threads)", "--print-errors"]
        return await run(arguments, id: id, onLine: onLine)
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

    private func isCancelled(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled.contains(id)
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }

    /// Stops a job and everything it started (spotDL runs Python, which runs FFmpeg), so no
    /// helper keeps writing a half finished file after Knob stopped caring.
    func cancel(_ id: UUID) {
        lock.lock()
        let process = running[id]
        // Remembered even before the job starts, so a Cancel pressed that early still holds.
        cancelled.insert(id)
        lock.unlock()
        guard let process, process.isRunning else { return }
        Self.stopTree(process.processIdentifier, grace: 3)
    }

    func cancelAll() {
        lock.lock()
        let all = Array(running.values)
        cancelled.formUnion(running.keys)
        lock.unlock()
        // Knob is quitting: no time to wait politely.
        for process in all where process.isRunning { Self.stopTree(process.processIdentifier, grace: 0.3, wait: true) }
    }

    /// SIGTERM to a process and all its descendants (found before any of them exits, since
    /// orphans are handed to launchd), then SIGKILL to whatever is still alive after `grace`.
    static func stopTree(_ root: pid_t, grace: TimeInterval, wait: Bool = false) {
        let tree = descendants(of: root) + [root]
        for pid in tree { kill(pid, SIGTERM) }
        let finish = { for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        if wait {
            Thread.sleep(forTimeInterval: grace)
            finish()
        } else {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace, execute: finish)
        }
    }

    /// Children first, deepest last, so the list can be signalled in order.
    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var stack = [root]
        while let parent = stack.popLast() {
            var buffer = [pid_t](repeating: 0, count: 512)
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
            guard bytes > 0 else { continue }
            let children = buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 && $0 != parent }
            found.append(contentsOf: children)
            stack.append(contentsOf: children)
        }
        return found
    }

    // MARK: Running

    struct RunResult: Sendable {
        let status: Int32
        /// spotDL's last lines, for working out what went wrong.
        let lines: [String]
        /// Stopped by `cancel` or Knob quitting.
        let cancelled: Bool
        /// Stopped because spotDL printed nothing for too long.
        let stalled: Bool
    }

    /// Runs spotDL and waits for it. Never blocks a thread on its output: the result comes once
    /// the process has exited and its output has ended, or 2 seconds after it exited when a
    /// stray child still holds the output open. `idleLimit` stops a job that prints nothing for
    /// that long (a stuck network call); reading a few thousand Liked Songs prints nothing for
    /// minutes, so the limit is generous.
    private func run(_ arguments: [String], id: UUID, idleLimit: TimeInterval? = 900,
                     onLine: @escaping @Sendable (String) -> Void) async -> RunResult {
        guard let helper = Self.helper, let ffmpeg = Self.ffmpeg else {
            return RunResult(status: -1, lines: [], cancelled: false, stalled: false)
        }
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = helper
        // DEBUG, because YouTube's reason for refusing a download only shows there; LineCollector
        // reads those lines for it and passes none of them on.
        process.arguments = arguments + ["--ffmpeg", ffmpeg.path, "--simple-tui", "--log-level", "DEBUG"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Self.home.path
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
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collected = LineCollector(onLine: onLine)
        let ending = Ending()
        let stalled = Flag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<RunResult, Never>) in
            let finish: @Sendable () -> Void = { [weak self] in
                guard let status = ending.takeResult() else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                collected.flush()
                var wasCancelled = false
                if let self {
                    self.lock.lock()
                    self.running[id] = nil
                    wasCancelled = self.cancelled.remove(id) != nil
                    self.lock.unlock()
                }
                continuation.resume(returning: RunResult(status: status, lines: collected.lines,
                                                         cancelled: wasCancelled, stalled: stalled.isSet))
            }
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    ending.outputEnded()
                    finish()
                } else {
                    collected.append(data)
                }
            }
            process.terminationHandler = { finished in
                ending.exited(finished.terminationStatus)
                finish()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    ending.outputEnded()
                    finish()
                }
            }
            lock.lock()
            if cancelled.contains(id) {
                lock.unlock()
                ending.exited(-1)
                ending.outputEnded()
                finish()
                return
            }
            running[id] = process
            lock.unlock()
            do {
                try process.run()
            } catch {
                lock.lock()
                running[id] = nil
                lock.unlock()
                ending.exited(-1)
                ending.outputEnded()
                collected.append(Data("Could not start spotDL: \(error.localizedDescription)\n".utf8))
                finish()
                return
            }
            // KNOB_SPOTDL_IDLE shortens the limit for the command line checks.
            if let idleLimit = idleLimit.map({ Double(ProcessInfo.processInfo.environment["KNOB_SPOTDL_IDLE"] ?? "") ?? $0 }) {
                let pid = process.processIdentifier
                Task.detached(priority: .utility) {
                    while process.isRunning {
                        try? await Task.sleep(for: .seconds(5))
                        if process.isRunning, Date().timeIntervalSince(collected.lastOutput) > idleLimit {
                            stalled.set()
                            Self.stopTree(pid, grace: 3)
                            return
                        }
                    }
                }
            }
        }
    }

    /// Waits for both the exit and the end of output, and lets the result through once.
    private final class Ending: @unchecked Sendable {
        private let lock = NSLock()
        private var status: Int32?
        private var ended = false
        private var delivered = false

        func exited(_ value: Int32) { lock.lock(); status = value; lock.unlock() }
        func outputEnded() { lock.lock(); ended = true; lock.unlock() }

        func takeResult() -> Int32? {
            lock.lock()
            defer { lock.unlock() }
            guard let status, ended, !delivered else { return nil }
            delivered = true
            return status
        }
    }

    /// Splits spotDL's output into lines without the colour codes of its terminal display. Only
    /// the last lines are kept: a download of thousands of songs prints thousands of them.
    final class LineCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var kept: [String] = []
        private var lastOutputAt = Date()
        private let onLine: @Sendable (String) -> Void
        private var sawBotCheck = false
        private var inDebugRecord = false
        static let keep = 300
        /// Kept in place of YouTube's own message, which comes in a DEBUG line.
        static let botCheckMarker = "Knob: YouTube asks to confirm this is not a bot (youtube_bot_check)."

        /// spotDL's DEBUG lines, "[17:39:20] DEBUG ...": read, never shown or kept.
        static func isDebug(_ line: String) -> Bool { level(line) == "DEBUG" || line.hasPrefix("DEBUG") }

        /// The level of a log record's first line ("[12:57:05] INFO MainThread - ..."), or nil
        /// for any other line.
        static func level(_ line: String) -> String? {
            guard let match = line.range(of: #"^\[\d{1,2}:\d{2}:\d{2}\] [A-Z]+"#, options: .regularExpression) else { return nil }
            return line[match].split(separator: " ").last.map(String.init)
        }

        /// A wrapped continuation of the record above it: spotDL indents those.
        static func isIndented(_ raw: String) -> Bool {
            let visible = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            return visible.hasPrefix("    ")
        }

        /// A record without its time, level, thread and source file, so the log reads as plain
        /// messages: "[12:57:05] INFO MainThread - Processing query: X   cli.py:73" becomes
        /// "Processing query: X".
        static func plain(_ line: String) -> String {
            guard level(line) != nil else { return line }
            let text = line.replacingOccurrences(of: #"^\[\d{1,2}:\d{2}:\d{2}\] [A-Z]+\s+\S+ - "#, with: "", options: .regularExpression)
            return text.replacingOccurrences(of: #"\s+[\w./-]+\.py:\d+$"#, with: "", options: .regularExpression)
        }

        init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        var lines: [String] { lock.lock(); defer { lock.unlock() }; return kept }
        var lastOutput: Date { lock.lock(); defer { lock.unlock() }; return lastOutputAt }

        func append(_ data: Data) {
            lock.lock()
            lastOutputAt = Date()
            buffer.append(data)
            var ready: [String] = []
            while let newline = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                let clean = Self.clean(line)
                // YouTube's bot check: it refuses downloads until the Mac's connection cools down.
                if !sawBotCheck, clean.contains("not a bot") {
                    sawBotCheck = true
                    ready.append(Self.botCheckMarker)
                }
                // A log record starts "[12:57:05] LEVEL"; its wrapped lines start with spaces and
                // belong to it, so a DEBUG record is dropped whole, wrapped lines included.
                if let level = Self.level(clean) {
                    inDebugRecord = level == "DEBUG"
                } else if !Self.isIndented(line) {
                    inDebugRecord = false
                }
                if !clean.isEmpty, !inDebugRecord { ready.append(Self.plain(clean)) }
            }
            keep(ready)
            lock.unlock()
            ready.forEach(onLine)
        }

        func flush() {
            lock.lock()
            let rest = Self.clean(String(decoding: buffer, as: UTF8.self))
            buffer.removeAll()
            if !rest.isEmpty { keep([rest]) }
            lock.unlock()
            if !rest.isEmpty { onLine(rest) }
        }

        private func keep(_ new: [String]) {
            kept.append(contentsOf: new)
            if kept.count > Self.keep { kept.removeFirst(kept.count - Self.keep) }
        }

        static func clean(_ line: String) -> String {
            line.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// What went wrong, read from spotDL's messages.
    static func classify(_ lines: [String]) -> Failure? {
        let text = lines.joined(separator: "\n").lowercased()
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
