import AppKit

/// Signing in to YouTube without a web page inside Knob (Google refuses sign ins from those):
/// the person picks the browser they already use YouTube in, yt-dlp reads its sign in once, and
/// Knob keeps only YouTube's cookies in a file only this Mac user can read. Signing in lets Knob
/// add Liked videos and private playlists, and YouTube pauses signed in downloads far less.
/// Signing out deletes the file.
extension KnobShiftYouTube {
    struct Browser: Identifiable, Equatable {
        /// yt-dlp's name for it.
        let id: String
        let name: String
        let apps: [String]
        /// Where it keeps its sign ins, inside the home folder.
        let data: String
    }

    static let browsers: [Browser] = [
        Browser(id: "chrome", name: "Chrome", apps: ["Google Chrome.app"], data: "Library/Application Support/Google/Chrome"),
        Browser(id: "brave", name: "Brave", apps: ["Brave Browser.app"], data: "Library/Application Support/BraveSoftware/Brave-Browser"),
        Browser(id: "edge", name: "Edge", apps: ["Microsoft Edge.app"], data: "Library/Application Support/Microsoft Edge"),
        Browser(id: "firefox", name: "Firefox", apps: ["Firefox.app"], data: "Library/Application Support/Firefox"),
        Browser(id: "opera", name: "Opera", apps: ["Opera.app"], data: "Library/Application Support/com.operasoftware.Opera"),
        Browser(id: "vivaldi", name: "Vivaldi", apps: ["Vivaldi.app"], data: "Library/Application Support/Vivaldi"),
        Browser(id: "safari", name: "Safari", apps: ["Safari.app"], data: "Library/Containers/com.apple.Safari/Data/Library/Cookies"),
    ]

    /// yt-dlp's name for each browser, by the app's bundle id.
    private static let bundleIds: [String: String] = [
        "com.google.Chrome": "chrome", "com.brave.Browser": "brave", "com.microsoft.edgemac": "edge",
        "org.mozilla.firefox": "firefox", "com.operasoftware.Opera": "opera", "com.vivaldi.Vivaldi": "vivaldi",
        "com.apple.Safari": "safari",
    ]

    /// The Mac's default browser, where the person most likely uses YouTube. One yt-dlp cannot
    /// read (Arc, for example) falls back to the first one installed.
    static var defaultBrowser: Browser {
        if let app = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://www.youtube.com")!),
           let bundle = Bundle(url: app)?.bundleIdentifier, let name = bundleIds[bundle],
           let browser = browsers.first(where: { $0.id == name }) {
            return browser
        }
        return installedBrowsers.first ?? browsers[browsers.count - 1]
    }

    /// The browsers on this Mac, in the order above; Safari is always there.
    static var installedBrowsers: [Browser] {
        let folders = ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        return browsers.filter { browser in
            browser.id == "safari" || browser.apps.contains { app in
                folders.contains { FileManager.default.fileExists(atPath: "\($0)/\(app)") }
            }
        }
    }

    /// Reads the browser's sign in and keeps YouTube's part of it. Chrome style browsers make
    /// macOS ask once whether yt-dlp may read their keychain entry.
    func signIn(with browser: Browser, id: UUID, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        Self.makeHome()
        Self.removeLeftovers(runCopies: false)
        // macOS keeps one app's data from other apps unless the person allows it (Full Disk
        // Access). Asking here, as Knob, also lets macOS show its own question for Knob.
        let data = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(browser.data)
        if FileManager.default.fileExists(atPath: data.path) {
            do { _ = try FileManager.default.contentsOfDirectory(atPath: data.path) } catch {
                throw KnobShiftYouTubeParsing.SignInProblem.fullDiskAccess
            }
        }
        // yt-dlp writes the browser's whole cookie file here; it is cut down and deleted at once.
        // Made first, owner only, so yt-dlp writes into a file nobody else can read. It starts
        // with the cookie file's header line, because yt-dlp refuses an empty one.
        let whole = Self.home.appendingPathComponent("browser-cookies-\(id.uuidString).txt")
        guard FileManager.default.createFile(atPath: whole.path, contents: Data("# Netscape HTTP Cookie File\n".utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw KnobShiftYouTubeParsing.SignInProblem.failed
        }
        defer { try? FileManager.default.removeItem(at: whole) }
        let result = await run(KnobShiftYouTubeParsing.signInArguments(browser: browser.id, into: whole), id: id, idleLimit: 120,
                               realHome: true) { line in
            // Only yt-dlp's own errors and warnings; it never prints cookie values in them.
            if line.hasPrefix("ERROR") || line.hasPrefix("WARNING") { onLine(line) }
        }
        if result.cancelled { throw CancellationError() }
        guard let jar = try? String(contentsOf: whole, encoding: .utf8), jar.contains("\t") else {
            throw KnobShiftYouTubeParsing.signInProblem(result.lines)
        }
        let youtube = KnobShiftYouTubeParsing.youtubeCookies(from: jar)
        guard youtube.signedIn else { throw KnobShiftYouTubeParsing.SignInProblem.notSignedIn }
        // Owner only from the first byte: written beside, then moved into place.
        let fresh = Self.home.appendingPathComponent("youtube-cookies-\(id.uuidString).txt")
        guard FileManager.default.createFile(atPath: fresh.path, contents: Data(youtube.text.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw KnobShiftYouTubeParsing.SignInProblem.failed
        }
        _ = try? FileManager.default.removeItem(at: Self.cookiesFile)
        try FileManager.default.moveItem(at: fresh, to: Self.cookiesFile)
    }

    /// A browser's full cookie copy left behind if Knob stopped halfway through signing in.
    /// `runCopies` also clears the per run copies, which only a crash leaves behind: done when
    /// KnobShift opens, never while a download may still be using one.
    static func removeLeftovers(runCopies: Bool = true) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        for name in names where name.hasPrefix("browser-cookies-")
            || (runCopies && name.hasPrefix("youtube-cookies-") && name != cookiesFile.lastPathComponent) {
            try? FileManager.default.removeItem(at: home.appendingPathComponent(name))
        }
    }

    static func signOut() {
        try? FileManager.default.removeItem(at: cookiesFile)
    }
}
