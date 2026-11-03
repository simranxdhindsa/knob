import Foundation

/// `--knobshift-youtube-check uat` (development builds): the YouTube dashboard as a user goes
/// through it, through the same model calls its buttons make, against a fake Google answering
/// inside the app instead of the network, in temporary folders. It saves a key, signs in with a
/// code, loads the rows, filters music, opens rows and a playlist, adds songs to the queue,
/// updates, cancels, survives a Google hiccup, signs out when the sign in runs out, signs out
/// and removes the key.
extension KnobShiftYouTubeCheck {
    private static func expect(_ condition: Bool, _ what: String) { KnobShiftYouTubeTests.expect(condition, what) }

    static func uat() async {
        #if DEBUG
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("knobshift-youtube-uat-\(UUID().uuidString)")
        setenv("KNOB_YOUTUBE_HOME", work.appendingPathComponent("support").path, 1)
        setenv("KNOB_YOUTUBE_ROOT", work.appendingPathComponent("YouTube").path, 1)
        setenv("KNOB_SPOTIFY_ROOT", work.appendingPathComponent("Spotify").path, 1)
        setenv("KNOB_YOUTUBE_UAT", "1", 1)
        setenv("KNOB_YTDLP", "/usr/bin/false", 1)
        setenv("KNOB_FFMPEG", "/bin/cat", 1)
        let musicKey = PersistKey.knobShiftYouTubeMusicOnly.rawValue
        let musicSetting = UserDefaults.standard.object(forKey: musicKey)
        UserDefaults.standard.removeObject(forKey: musicKey)
        defer {
            UserDefaults.standard.set(musicSetting, forKey: musicKey)
            try? FileManager.default.removeItem(at: work)
        }
        URLProtocol.registerClass(FakeGoogle.self)
        let model = KnobShiftModel(restoresQueue: false)
        let hub = model.youtubeHub

        print("1. Google key")
        expect(!(await model.saveGoogleKey(id: "bad", secret: "s")), "a key Google does not know is refused")
        expect(model.spotifyStatus == KnobShiftGoogleAuth.Problem.badKey.message, "and says why (\(model.spotifyStatus ?? "none"))")
        expect(await model.saveGoogleKey(id: "good.apps.googleusercontent.com", secret: "s"), "a good key is saved")
        let mode = (try? FileManager.default.attributesOfItem(atPath: KnobShiftGoogleAuth.file.path))?[.posixPermissions] as? Int
        expect(hub.hasKey && mode == 0o600, "the key file is readable by this Mac user only (\(String(mode ?? 0, radix: 8)))")

        print("2. Cancel signing in")
        FakeGoogle.set(.alwaysPending)
        model.signInWithGoogle()
        await waitUntil(seconds: 5) { hub.code != nil }
        expect(hub.code?.userCode == "WQXK-HTRB" && model.youtubeSigningIn, "the code shows while signing in")
        model.cancelYouTubeSignIn()
        expect(!model.youtubeSigningIn && hub.code == nil && !model.youtubeSignedIn, "CANCEL stops signing in")
        try? await Task.sleep(for: .seconds(6))
        expect(!KnobShiftGoogleAuth.isSignedIn, "nothing is kept after cancelling")

        print("3. Sign in and the dashboard")
        FakeGoogle.set(.normal)
        model.signInWithGoogle()
        await waitUntil(seconds: 20) { model.youtubeSignedIn }
        expect(model.youtubeSignedIn && KnobShiftGoogleAuth.isSignedIn, "signed in once the code is entered")
        await waitUntil(seconds: 10) { !hub.loading && hub.shelves.count == 3 && hub.playlists != nil }
        expect(hub.shelves[.liked]?.count == 3 && hub.videos(.liked, musicOnly: true)?.count == 2, "Liked music leaves out the vlog")
        expect(hub.videos(.popular, musicOnly: true)?.count == 2, "popular music for the Mac's country")
        expect(hub.shelves[.new]?.count == 2, "new uploads from subscriptions (\(hub.shelves[.new]?.count ?? -1))")
        expect(hub.playlists?.first?.title == "Road trip", "your playlists")

        print("4. A row into the queue")
        await model.openYouTubeShelf(.liked)
        let review = model.spotifyReview
        expect(review?.songs.map(\.name) == ["Kya Baat Aa", "Sardaari"], "Liked music opens in the song picker (\(review?.songs.map(\.name) ?? []))")
        expect(review?.songs.first?.artist == "Karan Aujla", "artist from the channel")
        model.confirmSpotifyReview(selected: review?.initial ?? [])
        expect(model.pending.filter { $0.playlistId == KnobShiftYouTubeHub.likedId }.count == 2, "ticked songs join the queue at once")
        expect(model.playlists.contains { $0.id == KnobShiftYouTubeHub.likedId && $0.name == "Liked music" }, "the list is kept as Liked music")
        await waitUntil(seconds: 30) { model.pending.filter { $0.playlistId == KnobShiftYouTubeHub.likedId }.allSatisfy { $0.failure != nil } }
        expect(model.pending.filter { $0.playlistId == KnobShiftYouTubeHub.likedId }.allSatisfy { $0.failure != nil },
               "a download that fails says so on its row")

        print("5. Music only off, Update and a playlist")
        UserDefaults.standard.set(false, forKey: musicKey)
        await model.openYouTubeShelf(.liked)
        expect(model.spotifyReview?.songs.count == 3, "every video with Music only off")
        model.dismissSpotifyReview()
        UserDefaults.standard.set(true, forKey: musicKey)
        let likedRequests = FakeGoogle.count("myRating=like")
        if let liked = model.playlists.first(where: { $0.id == KnobShiftYouTubeHub.likedId }) { await model.updatePlaylist(liked) }
        expect(model.spotifyReview?.isUpdate == true && FakeGoogle.count("myRating=like") > likedRequests, "Update reads Liked music again from Google")
        model.dismissSpotifyReview()
        await model.openYouTubePlaylist(id: "PLroad", name: "Road trip")
        expect(model.spotifyReview?.songs.count == 2, "a playlist opens with its videos, the vlog kept (it is yours)")
        expect(model.spotifyStatus?.contains("1 video was left out") == true, "the private video is counted (\(model.spotifyStatus ?? "none"))")
        model.dismissSpotifyReview()

        print("6. Cancel a slow read")
        FakeGoogle.set(.slow)
        let before = FakeGoogle.count("playlistItems")
        let read = Task { await model.openYouTubePlaylist(id: "PLroad", name: "Road trip") }
        await waitUntil(seconds: 3) { model.spotifyReadJob != nil }
        model.cancelSpotifyRead()
        await read.value
        expect(model.spotifyReview == nil && model.spotifyReadJob == nil, "CANCEL stops the read and nothing opens")
        try? await Task.sleep(for: .seconds(2.5))
        expect(FakeGoogle.count("playlistItems") <= before + 1, "no more pages are asked for after CANCEL")

        print("7. A hiccup at Google, then the sign in running out")
        FakeGoogle.set(.refreshFails)
        KnobShiftGoogleAuth.Tokens.shared.set(nil, expiresIn: nil)
        model.loadYouTubeDashboard(force: true)
        await waitUntil(seconds: 10) { !hub.loading }
        expect(model.youtubeSignedIn && KnobShiftGoogleAuth.isSignedIn, "one failed answer does not sign out")
        expect(model.spotifyStatus == KnobShiftYouTubeAPIParsing.Problem.failed.message, "it says to try again (\(model.spotifyStatus ?? "none"))")
        FakeGoogle.set(.invalidGrant)
        model.loadYouTubeDashboard(force: true)
        await waitUntil(seconds: 10) { !model.youtubeSignedIn }
        expect(!model.youtubeSignedIn && !KnobShiftGoogleAuth.isSignedIn, "a sign in Google refuses signs out")
        expect(model.spotifyStatus == KnobShiftYouTubeAPIParsing.Problem.signedOut.message, "and says to sign in again")
        expect(hub.shelves.isEmpty && hub.playlists == nil, "the rows are cleared")

        print("8. Sign out and remove the key")
        FakeGoogle.set(.normal)
        model.signInWithGoogle()
        await waitUntil(seconds: 20) { model.youtubeSignedIn }
        let revokes = FakeGoogle.count("revoke")
        model.signOutOfYouTube()
        await waitUntil(seconds: 5) { FakeGoogle.count("revoke") > revokes }
        expect(!KnobShiftGoogleAuth.isSignedIn && KnobShiftGoogleAuth.hasKey, "sign out forgets the sign in and keeps the key")
        expect(FakeGoogle.count("revoke") > revokes, "and asks Google to forget it")
        model.removeGoogleKey()
        expect(!FileManager.default.fileExists(atPath: KnobShiftGoogleAuth.file.path) && !hub.hasKey, "REMOVE deletes the key file")

        URLProtocol.unregisterClass(FakeGoogle.self)
        print(KnobShiftYouTubeTests.failures == 0 ? "KnobShift YouTube UAT passed" : "KnobShift YouTube UAT: \(KnobShiftYouTubeTests.failures) failure(s)")
        #else
        print("The YouTube UAT runs in development builds only.")
        #endif
    }

    private static func waitUntil(seconds: Double, _ done: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }
}

#if DEBUG
/// Google and YouTube for the UAT, answering inside the app: OAuth's device flow, the YouTube
/// Data API and channel feeds, with switches for the cases the UAT tries.
final class FakeGoogle: URLProtocol, @unchecked Sendable {
    enum Mode { case normal, alwaysPending, slow, refreshFails, invalidGrant }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = Mode.normal
    nonisolated(unsafe) private static var seen: [String] = []

    static func set(_ value: Mode) { lock.withLock { mode = value } }
    static func count(_ text: String) -> Int { lock.withLock { seen.filter { $0.contains(text) }.count } }

    override class func canInit(with request: URLRequest) -> Bool {
        ["oauth2.googleapis.com", "www.googleapis.com", "www.youtube.com"].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let body = Self.body(of: request)
        let mode = Self.lock.withLock { () -> Mode in
            Self.seen.append(url.path + "?" + (url.query ?? "") + " " + body)
            return Self.mode
        }
        let (status, text) = Self.answer(url, body: body, mode: mode)
        let delay = mode == .slow && url.path.hasSuffix("playlistItems") ? 2.0 : 0.05
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func video(_ id: String, _ title: String, _ channel: String, category: String = "10") -> String {
        #"{"id":"\#(id)","snippet":{"title":"\#(title)","channelTitle":"\#(channel)","categoryId":"\#(category)","#
            + #""thumbnails":{"medium":{"url":"https://i.ytimg.com/vi/\#(id)/mqdefault.jpg"}}},"contentDetails":{"duration":"PT3M20S"}}"#
    }

    private static func answer(_ url: URL, body: String, mode: Mode) -> (Int, String) {
        let query = url.query ?? ""
        switch url.path {
        case "/device/code":
            if body.contains("client_id=bad") { return (401, #"{"error":"invalid_client","error_description":"The OAuth client was not found."}"#) }
            return (200, #"{"device_code":"dc","user_code":"WQXK-HTRB","verification_url":"https://www.google.com/device","interval":5,"expires_in":1800}"#)
        case "/token":
            if body.contains("device_code=") {
                return mode == .alwaysPending ? (428, #"{"error":"authorization_pending"}"#)
                    : (200, #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#)
            }
            if mode == .refreshFails { return (503, #"{"error":"temporarily_unavailable"}"#) }
            if mode == .invalidGrant { return (400, #"{"error":"invalid_grant"}"#) }
            return (200, #"{"access_token":"at2","expires_in":3600}"#)
        case "/revoke":
            return (200, "{}")
        case "/youtube/v3/videos":
            if query.contains("myRating=like") {
                return (200, #"{"items":["# + [video("aaaaaaaaaa1", "Kya Baat Aa", "Karan Aujla"), video("aaaaaaaaaa2", "Sardaari", "Karan Aujla"),
                                             video("aaaaaaaaaa3", "My day in Delhi", "Vlogger", category: "22")].joined(separator: ",") + "]}")
            }
            if query.contains("chart=mostPopular") {
                return (200, #"{"items":["# + [video("bbbbbbbbbb1", "Lover", "Diljit Dosanjh"), video("bbbbbbbbbb2", "Born To Shine", "Diljit Dosanjh")]
                    .joined(separator: ",") + "]}")
            }
            let ids = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
            return (200, #"{"items":["# + ids.split(separator: ",").map { video(String($0), "Song \($0.suffix(1))", "Artist",
                                                                                   category: $0.hasSuffix("3") ? "22" : "10") }
                .joined(separator: ",") + "]}")
        case "/youtube/v3/playlists":
            return (200, #"{"items":[{"id":"PLroad","snippet":{"title":"Road trip"},"contentDetails":{"itemCount":3}}]}"#)
        case "/youtube/v3/playlistItems":
            let item = { (id: String, title: String) in
                #"{"snippet":{"title":"\#(title)","videoOwnerChannelTitle":"Artist","resourceId":{"videoId":"\#(id)"}},"status":{"privacyStatus":"public"}}"#
            }
            return (200, #"{"items":["# + [item("cccccccccc1", "Ghaint"), item("cccccccccc3", "Road vlog"), item("cccccccccc2", "Private video")]
                .joined(separator: ",") + "]}")
        case "/youtube/v3/subscriptions":
            return (200, #"{"items":[{"snippet":{"resourceId":{"channelId":"UC1"}}}]}"#)
        case "/feeds/videos.xml":
            let now = ISO8601DateFormatter().string(from: Date())
            let entry = { (id: String) in
                "<entry><yt:videoId>\(id)</yt:videoId><title>New \(id)</title><author><name>Artist</name></author><published>\(now)</published></entry>"
            }
            return (200, #"<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">"#
                    + entry("dddddddddd1") + entry("dddddddddd2") + "</feed>")
        default:
            return (404, #"{"error":{"code":404,"errors":[{"reason":"notFound"}]}}"#)
        }
    }
}
#endif
