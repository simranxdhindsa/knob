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
    /// feature. KNOB_YTDLP points at another copy, for development.
    static var helper: URL? {
        #if arch(arm64)
        if let path = ProcessInfo.processInfo.environment["KNOB_YTDLP"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
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

    private static var cookies: URL? { isSignedIn ? cookiesFile : nil }

    // MARK: Commands

    /// Reads a link's songs without downloading anything.
    func list(_ link: KnobShiftYouTubeParsing.Link, id: UUID) async throws -> KnobShiftYouTubeParsing.Read {
        let result = await run(KnobShiftYouTubeParsing.listArguments(link.url, cookies: Self.cookies), id: id, idleLimit: 180) { _ in }
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
        guard let ffmpeg = KnobShiftSpotDL.ffmpeg else {
            return KnobShiftHelperProcess.Result(status: -1, lines: [], cancelled: false, stalled: false)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = search
            ? KnobShiftYouTubeParsing.searchArguments(for: song, into: folder, ffmpeg: ffmpeg.path, cookies: Self.cookies)
            : KnobShiftYouTubeParsing.downloadArguments(for: song, into: folder, ffmpeg: ffmpeg.path, cookies: Self.cookies)
        return await run(arguments, id: id, idleLimit: 300, onLine: onLine)
    }

    // MARK: Stopping

    func cancel(_ id: UUID) { processes.cancel(id) }

    func cancelAll() { processes.cancelAll() }

    // MARK: Running

    /// Runs yt-dlp with its own home, so its cache and sign in stay inside Knob, and with
    /// Helpers first on its PATH, where it finds Deno (needed to read YouTube's pages).
    func run(_ arguments: [String], id: UUID, idleLimit: TimeInterval?,
             onLine: @escaping @Sendable (String) -> Void) async -> KnobShiftHelperProcess.Result {
        guard let helper = Self.helper, let ffmpeg = KnobShiftSpotDL.ffmpeg else {
            return KnobShiftHelperProcess.Result(status: -1, lines: [], cancelled: false, stalled: false)
        }
        try? FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = Self.home.path
        environment["XDG_CACHE_HOME"] = Self.home.appendingPathComponent("cache").path
        environment["PATH"] = "\(ffmpeg.deletingLastPathComponent().path):/usr/bin:/bin"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TERM"] = "dumb"
        return await processes.run(helper, arguments: arguments, environment: environment, id: id, idleLimit: idleLimit, onLine: onLine)
    }
}
