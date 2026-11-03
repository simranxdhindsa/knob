import Foundation

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
    }

    static let browsers: [Browser] = [
        Browser(id: "chrome", name: "Chrome", apps: ["Google Chrome.app"]),
        Browser(id: "brave", name: "Brave", apps: ["Brave Browser.app"]),
        Browser(id: "edge", name: "Edge", apps: ["Microsoft Edge.app"]),
        Browser(id: "firefox", name: "Firefox", apps: ["Firefox.app"]),
        Browser(id: "opera", name: "Opera", apps: ["Opera.app"]),
        Browser(id: "vivaldi", name: "Vivaldi", apps: ["Vivaldi.app"]),
        Browser(id: "safari", name: "Safari", apps: ["Safari.app"]),
    ]

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
    func signIn(with browser: Browser, id: UUID) async throws {
        try FileManager.default.createDirectory(at: Self.home, withIntermediateDirectories: true)
        // yt-dlp writes the browser's whole cookie file here; it is cut down and deleted at once.
        let whole = Self.home.appendingPathComponent("browser-cookies-\(id.uuidString).txt")
        defer { try? FileManager.default.removeItem(at: whole) }
        let result = await run(KnobShiftYouTubeParsing.signInArguments(browser: browser.id, into: whole), id: id, idleLimit: 120) { _ in }
        if result.cancelled { throw CancellationError() }
        guard let jar = try? String(contentsOf: whole, encoding: .utf8) else {
            throw KnobShiftYouTubeParsing.signInProblem(result.lines)
        }
        let youtube = KnobShiftYouTubeParsing.youtubeCookies(from: jar)
        guard youtube.signedIn else { throw KnobShiftYouTubeParsing.SignInProblem.notSignedIn }
        try Data(youtube.text.utf8).write(to: Self.cookiesFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.cookiesFile.path)
    }

    static func signOut() {
        try? FileManager.default.removeItem(at: cookiesFile)
    }
}
