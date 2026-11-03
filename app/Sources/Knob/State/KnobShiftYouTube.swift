import Foundation

/// Runs the yt-dlp bundled in Knob.app (Contents/Resources/yt-dlp, fetched at build time by
/// packaging/fetch-spotdl.sh) to read YouTube links and download their audio. It uses the FFmpeg
/// and Deno in Contents/Helpers, and has a home folder of its own inside Knob's Application
/// Support for its cache and the YouTube sign in, so nothing mixes with anything else on the Mac.
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

    /// yt-dlp's own home: its cache (YouTube's player code, read once) and the sign in.
    static var home: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.simranxdhindsa.knob")
            .appendingPathComponent("yt-dlp", isDirectory: true)
    }

    /// The YouTube sign in, copied once from the user's browser (KnobShiftYouTube+SignIn).
    static var cookiesFile: URL { home.appendingPathComponent("youtube-cookies.txt") }

    static var isSignedIn: Bool { FileManager.default.fileExists(atPath: cookiesFile.path) }

    /// A copy of the sign in for one run, deleted afterwards. yt-dlp writes its cookies back
    /// when it ends, so with the real file a run still going could bring back a sign in the
    /// person just signed out of.
    private static func runCookies(_ id: UUID) -> URL? {
        guard isSignedIn, let data = try? Data(contentsOf: cookiesFile) else { return nil }
        let copy = home.appendingPathComponent("youtube-cookies-run-\(id.uuidString)-\(UUID().uuidString).txt")
        return FileManager.default.createFile(atPath: copy.path, contents: data, attributes: [.posixPermissions: 0o600]) ? copy : nil
    }

    // MARK: Commands

    /// Reads a link's songs without downloading anything.
    func list(_ link: KnobShiftYouTubeParsing.Link, id: UUID) async throws -> KnobShiftYouTubeParsing.Read {
        let cookies = Self.runCookies(id)
        defer { cookies.map { try? FileManager.default.removeItem(at: $0) } }
        let result = await run(KnobShiftYouTubeParsing.listArguments(link.url, cookies: cookies), id: id, idleLimit: 180) { _ in }
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
    func download(_ song: KnobShiftSpotDL.Song, into folder: URL, search: Bool, id: UUID,
                  onLine: @escaping @Sendable (String) -> Void) async -> KnobShiftHelperProcess.Result {
        guard let ffmpeg = KnobShiftSpotDL.ffmpeg, KnobShiftYouTubeParsing.isVideoId(song.song_id) else {
            return KnobShiftHelperProcess.Result(status: -1, lines: [], cancelled: false, stalled: false)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cookies = Self.runCookies(id)
        defer { cookies.map { try? FileManager.default.removeItem(at: $0) } }
        let arguments = search
            ? KnobShiftYouTubeParsing.searchArguments(for: song, into: folder, ffmpeg: ffmpeg.path, cookies: cookies)
            : KnobShiftYouTubeParsing.downloadArguments(for: song, into: folder, ffmpeg: ffmpeg.path, cookies: cookies)
        return await run(arguments, id: id, idleLimit: 300, onLine: onLine)
    }

    // MARK: Stopping

    func cancel(_ id: UUID) { processes.cancel(id) }

    func cancelAll() { processes.cancelAll() }

    // MARK: Running

    /// Knob's yt-dlp folder, made readable by this Mac user only: it holds the sign in.
    static func makeHome() {
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }

    /// Runs yt-dlp with its own home, so its cache and sign in stay inside Knob, and with
    /// Helpers first on its PATH, where it finds Deno (needed to read YouTube's pages). It gets
    /// only the settings it needs, never the rest of Knob's environment (a proxy setting there
    /// would route the sign in through someone else). Signing in uses the real home folder,
    /// where the browsers keep their sign ins.
    func run(_ arguments: [String], id: UUID, idleLimit: TimeInterval?, realHome: Bool = false,
             onLine: @escaping @Sendable (String) -> Void) async -> KnobShiftHelperProcess.Result {
        guard let helper = Self.helper, let ffmpeg = KnobShiftSpotDL.ffmpeg else {
            return KnobShiftHelperProcess.Result(status: -1, lines: [], cancelled: false, stalled: false)
        }
        Self.makeHome()
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [
            "HOME": realHome ? FileManager.default.homeDirectoryForCurrentUser.path : Self.home.path,
            "XDG_CACHE_HOME": Self.home.appendingPathComponent("cache").path,
            "PATH": "\(ffmpeg.deletingLastPathComponent().path):/usr/bin:/bin",
            "PYTHONUNBUFFERED": "1", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1",
            "TERM": "dumb",
        ]
        for key in ["TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"] { environment[key] = inherited[key] }
        return await processes.run(helper, arguments: arguments, environment: environment, id: id, idleLimit: idleLimit, onLine: onLine)
    }
}
