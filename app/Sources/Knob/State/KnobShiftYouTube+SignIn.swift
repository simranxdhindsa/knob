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
        Self.makeHome()
        Self.removeLeftovers(runCopies: false)
        // yt-dlp writes the browser's whole cookie file here; it is cut down and deleted at once.
        // Made first, owner only, so yt-dlp writes into a file nobody else can read.
        let whole = Self.home.appendingPathComponent("browser-cookies-\(id.uuidString).txt")
        guard FileManager.default.createFile(atPath: whole.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw KnobShiftYouTubeParsing.SignInProblem.failed
        }
        defer { try? FileManager.default.removeItem(at: whole) }
        let result = await run(KnobShiftYouTubeParsing.signInArguments(browser: browser.id, into: whole), id: id, idleLimit: 120,
                               realHome: true) { _ in }
        if result.cancelled { throw CancellationError() }
        guard let jar = try? String(contentsOf: whole, encoding: .utf8), !jar.isEmpty else {
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
