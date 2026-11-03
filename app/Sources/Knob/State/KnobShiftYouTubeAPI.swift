import Foundation

/// The signed in person's YouTube, read with the YouTube Data API and their own Google key
/// (KnobShiftGoogleAuth): liked videos, their playlists, new uploads from the channels they
/// subscribe to, and the music chart for their country. Uploads come from each channel's public
/// feed, which uses none of the key's daily allowance; the API is only asked for the
/// subscriptions (once a day) and for categories and lengths, 50 videos to a request.
/// How the answers read lives in KnobShiftYouTubeAPIParsing.
enum KnobShiftYouTubeAPI {
    typealias Video = KnobShiftYouTubeAPIParsing.Video
    typealias Playlist = KnobShiftYouTubeAPIParsing.Playlist
    typealias Problem = KnobShiftYouTubeAPIParsing.Problem
    private typealias Parse = KnobShiftYouTubeAPIParsing

    private static let base = "https://www.googleapis.com/youtube/v3/"

    /// The Mac's country, for the music chart; India when the Mac has none.
    static var region: String {
        let code = Locale.current.region?.identifier ?? "IN"
        return code.count == 2 ? code : "IN"
    }

    static var regionName: String { Locale.current.localizedString(forRegionCode: region) ?? region }

    // MARK: Lists

    /// Liked videos, newest first, up to 200.
    static func liked(session: URLSession = .shared) async throws -> [Video] {
        try await pages(maxPages: 4) { page in
            Parse.videos(try await get("videos", ["part": "snippet,contentDetails", "myRating": "like", "maxResults": "50", "pageToken": page],
                                       session: session))
        }.items
    }

    /// The person's own playlists, up to 200.
    static func playlists(session: URLSession = .shared) async throws -> [Playlist] {
        try await pages(maxPages: 4) { page in
            Parse.playlists(try await get("playlists", ["part": "snippet,contentDetails", "mine": "true", "maxResults": "50", "pageToken": page],
                                          session: session))
        }.items
    }

    /// A playlist's videos in its order (up to 500), with their categories and lengths, and how
    /// many were left out because they are private or deleted.
    static func playlist(_ id: String, session: URLSession = .shared) async throws -> (videos: [Video], skipped: Int) {
        let read = try await pages(maxPages: 10) { page in
            Parse.playlistItems(try await get("playlistItems", ["part": "snippet,status", "playlistId": id, "maxResults": "50", "pageToken": page],
                                              session: session))
        }
        return (try await details(read.items, session: session), read.skipped)
    }

    /// The most popular music videos in the Mac's country right now.
    static func popularMusic(session: URLSession = .shared) async throws -> [Video] {
        Parse.videos(try await get("videos", ["part": "snippet,contentDetails", "chart": "mostPopular",
                                              "videoCategoryId": Parse.musicCategory, "regionCode": region, "maxResults": "50"],
                                   session: session)).items
    }

    /// Videos from the last 30 days of the 30 most relevant subscribed channels, newest first.
    static func newFromSubscriptions(session: URLSession = .shared) async throws -> [Video] {
        let channels = try await subscriptions(session: session).prefix(30)
        let since = Date().addingTimeInterval(-30 * 86400)
        let found = await withTaskGroup(of: [Video].self) { group in
            for channel in channels {
                group.addTask {
                    guard var feed = URLComponents(string: "https://www.youtube.com/feeds/videos.xml") else { return [] }
                    feed.queryItems = [URLQueryItem(name: "channel_id", value: channel)]
                    guard let url = feed.url,
                          let (data, status) = try? await KnobShiftGoogleAuth.send(URLRequest(url: url, timeoutInterval: 15), session: session),
                          status == 200 else { return [] }
                    return Parse.feed(data).filter { ($0.published ?? .distantPast) > since }
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        let newest = Array(found.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }.prefix(150))
        return try await details(newest, session: session)
    }

    /// The channels subscribed to, most relevant first, read once a day.
    private static func subscriptions(session: URLSession) async throws -> [String] {
        if let cached = SubscriptionCache.shared.fresh { return cached }
        let epoch = SubscriptionCache.shared.epoch
        let ids = try await pages(maxPages: 4) { page in
            Parse.subscriptions(try await get("subscriptions", ["part": "snippet", "mine": "true", "maxResults": "50",
                                                                "order": "relevance", "pageToken": page], session: session))
        }.items
        // Not kept when the person signed out meanwhile: the next account must not get these.
        SubscriptionCache.shared.keep(ids, ifEpoch: epoch)
        return ids
    }

    /// Forgets the subscriptions, on sign out.
    static func forget() { SubscriptionCache.shared.forget() }

    private final class SubscriptionCache: @unchecked Sendable {
        static let shared = SubscriptionCache()
        private let lock = NSLock()
        private var ids: [String]?
        private var at = Date.distantPast
        private(set) var epoch = 0

        var fresh: [String]? {
            lock.lock(); defer { lock.unlock() }
            return Date().timeIntervalSince(at) < 86400 ? ids : nil
        }

        func keep(_ value: [String], ifEpoch expected: Int) {
            lock.lock(); defer { lock.unlock() }
            guard epoch == expected else { return }
            ids = value
            at = Date()
        }

        func forget() {
            lock.lock(); defer { lock.unlock() }
            epoch += 1
            ids = nil
            at = .distantPast
        }
    }

    /// Fills in each video's category and length, 50 to a request; videos YouTube no longer has
    /// are left out.
    private static func details(_ videos: [Video], session: URLSession) async throws -> [Video] {
        var known: [String: Video] = [:]
        for start in stride(from: 0, to: videos.count, by: 50) {
            let ids = videos[start..<min(videos.count, start + 50)].map(\.id).joined(separator: ",")
            try Task.checkCancellation()
            // No maxResults: YouTube refuses it together with ids.
            for video in Parse.videos(try await get("videos", ["part": "snippet,contentDetails", "id": ids],
                                                    session: session)).items {
                known[video.id] = video
            }
        }
        return videos.compactMap { video in
            guard let found = known[video.id] else { return nil }
            var merged = video
            merged.categoryId = found.categoryId
            merged.duration = found.duration
            merged.published = merged.published ?? found.published
            return merged
        }
    }

    // MARK: Requests

    private static func pages<Item>(maxPages: Int, _ read: (String) async throws -> Parse.Page<Item>) async throws -> Parse.Page<Item> {
        var all = Parse.Page<Item>(items: [])
        var token = ""
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            let page = try await read(token)
            all.items += page.items
            all.skipped += page.skipped
            guard let next = page.next, !next.isEmpty else { break }
            token = next
        }
        return all
    }

    /// One API request with the access token. A refused token is refreshed once and tried again.
    private static func get(_ path: String, _ query: [String: String], session: URLSession) async throws -> Data {
        guard var components = URLComponents(string: base + path) else { throw Problem.failed }
        components.queryItems = query.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else { throw Problem.failed }
        for attempt in 0..<2 {
            let token: String
            do {
                token = try await KnobShiftGoogleAuth.accessToken(session: session)
            } catch KnobShiftGoogleAuth.Problem.signedOut {
                throw Problem.signedOut
            } catch KnobShiftGoogleAuth.Problem.offline {
                throw Problem.offline
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A hiccup at Google is not a sign out: the sign in is kept and the person tries again.
                throw Problem.failed
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data: Data, status: Int
            do {
                (data, status) = try await KnobShiftGoogleAuth.send(request, session: session)
            } catch KnobShiftGoogleAuth.Problem.offline {
                throw Problem.offline
            }
            guard let problem = Parse.problem(data, status: status) else { return data }
            if problem == .signedOut, attempt == 0 {
                KnobShiftGoogleAuth.Tokens.shared.set(nil, expiresIn: nil)
                continue
            }
            throw problem
        }
        throw Problem.signedOut
    }
}
