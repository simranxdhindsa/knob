import Foundation

/// Runs the yt-dlp bundled in Knob.app (Contents/Resources/yt-dlp, fetched at build time by
/// packaging/fetch-spotdl.sh) to read YouTube links and download their audio. It uses the FFmpeg
/// and Deno in Contents/Helpers, and has a home folder of its own inside Knob's Application
/// Support for its cache, so nothing mixes with anything else on the Mac. It never signs in:
/// the Google sign in (KnobShiftGoogleAuth) only reads lists, and downloads are anonymous.
/// What the arguments are and how the answers read lives in KnobShiftYouTubeParsing.
final class KnobShiftYouTube: @unchecked Sendable {
    static let shared = KnobShiftYouTube()
    private let processes = KnobShiftHelperProcess(name: "yt-dlp")

    private init() {}

    // MARK: Where things are

    /// The bundled yt-dlp; Apple silicon only, like FFmpeg and Deno, so Intel Macs hide the
    /// feature. KNOB_YTDLP points at another copy, in development builds only.
    static var helper: URL? {
        #if arch(arm64)
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["KNOB_YTDLP"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        #endif
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/yt-dlp/yt-dlp_macos")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
        #else
        return nil
        #endif
    }

    static var isAvailable: Bool { helper != nil && KnobShiftSpotDL.ffmpeg != nil }

    /// yt-dlp's own home: its cache (YouTube's player code, read once).
    static var home: URL {
        #if DEBUG
        // The YouTube UAT keeps everything, the Google key included, in a temporary folder.
        if let path = ProcessInfo.processInfo.environment["KNOB_YOUTUBE_HOME"] {
            return URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent("yt-dlp", isDirectory: true)
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.simranxdhindsa.knob")
            .appendingPathComponent("yt-dlp", isDirectory: true)
    }

    /// Deletes what the earlier browser sign in left: the copied YouTube cookies. Signing in is
    /// now with Google (KnobShiftGoogleAuth), so nothing is read from browsers any more.
    static func removeOldBrowserSignIn() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in names where name.hasSuffix(".txt") && (name.hasPrefix("youtube-cookies") || name.hasPrefix("browser-cookies-")) {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(name))
        }
    }

    // MARK: Commands

    /// Reads a link's songs without downloading anything.
    func list(_ link: KnobShiftYouTubeParsing.Link, id: UUID) async throws -> KnobShiftYouTubeParsing.Read {
        let result = await run(KnobShiftYouTubeParsing.listArguments(link.url), id: id, idleLimit: 180) { _ in }
        if result.cancelled { throw CancellationError() }
        if result.stalled { throw KnobShiftYouTubeParsing.Failure.stalled }
        // The list is the one line of JSON yt-dlp prints; everything else is a warning or an error.
        guard let json = result.lines.last(where: { $0.hasPrefix("{") }),
              let read = KnobShiftYouTubeParsing.listing(from: Data(json.utf8), kind: link.kind) else {
            throw KnobShiftYouTubeParsing.classify(result.lines) ?? .failed
        }
        guard !read.listing.songs.isEmpty else { throw KnobShiftYouTubeParsing.classify(result.lines) ?? .nothingFound }
        return read
    }

    /// Downloads one song into `folder`, or with `search` the closest match YouTube finds for its
    /// artist and name. Each line of yt-dlp's output goes to `onLine` as it arrives.
    func download(_ song: KnobShiftSpotDL.Song, into folder: URL, search: Bool, id: UUID, browser: KnobShiftYouTubeBrowser? = nil,
                  onLine: @escaping @Sendable (String) -> Void) async -> KnobShiftHelperProcess.Result {
        guard let ffmpeg = KnobShiftSpotDL.ffmpeg, KnobShiftYouTubeParsing.isVideoId(song.song_id) else {
            return KnobShiftHelperProcess.Result(status: -1, lines: [], cancelled: false, stalled: false)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = search
            ? KnobShiftYouTubeParsing.searchArguments(for: song, into: folder, ffmpeg: ffmpeg.path, browser: browser)
            : KnobShiftYouTubeParsing.downloadArguments(for: song, into: folder, ffmpeg: ffmpeg.path, browser: browser)
        return await run(arguments, id: id, idleLimit: 300, browser: browser, onLine: onLine)
    }

    // MARK: Stopping

    func cancel(_ id: UUID) { processes.cancel(id) }

    func cancelAll() { processes.cancelAll() }

    // MARK: Running

    /// Knob's yt-dlp folder, made readable by this Mac user only.
    static func makeHome() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }

    /// Runs yt-dlp with its own home, so its cache stays inside Knob, and with Helpers first on
    /// its PATH, where it finds Deno (needed to read YouTube's pages). It gets only the settings
    /// it needs, never the rest of Knob's environment.
    func run(_ arguments: [String], id: UUID, idleLimit: TimeInterval?, browser: KnobShiftYouTubeBrowser? = nil,
             onLine: @escaping @Sendable (String) -> Void) async -> KnobShiftHelperProcess.Result {
        guard let helper = Self.helper, let ffmpeg = KnobShiftSpotDL.ffmpeg else {
            return KnobShiftHelperProcess.Result(status: -1, lines: [], cancelled: false, stalled: false)
        }
        Self.makeHome()
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            // The browser is found under the real home; yt-dlp's cache stays in Knob's folder.
            "HOME": browser == nil ? Self.home.path : KnobShiftYouTubeBrowser.realHome,
            "XDG_CACHE_HOME": Self.home.appendingPathComponent("cache").path,
            "PATH": "\(ffmpeg.deletingLastPathComponent().path):/usr/bin:/bin",
            "PYTHONUNBUFFERED": "1", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "TERM": "dumb",
        ]
        for key in ["TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"] { environment[key] = inherited[key] }
        return await processes.run(helper, arguments: arguments, environment: environment, id: id, idleLimit: idleLimit, onLine: onLine)
    }
}
