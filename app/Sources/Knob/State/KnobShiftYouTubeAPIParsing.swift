import Foundation

/// The parts of the YouTube dashboard that need no network, so the YouTube self test can check
/// them directly: reading the YouTube Data API's answers and channels' public feeds, song
/// lengths, the music filter, and turning videos into the same song shape yt-dlp's lists give.
enum KnobShiftYouTubeAPIParsing {
    /// YouTube's category for music.
    static let musicCategory = "10"

    struct Video: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let channel: String
        var categoryId: String?
        var duration: Double?
        let thumbnail: URL?
        var published: Date?

        var isMusic: Bool { categoryId == musicCategory }
    }

    struct Playlist: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let count: Int
        let thumbnail: URL?
    }

    /// One page of an answer: what it held, the next page's token, and videos left out
    /// (private or deleted).
    struct Page<Item> {
        var items: [Item]
        var next: String?
        var skipped = 0
    }

    enum Problem: Error, Equatable {
        case signedOut, quota, apiOff, notFound, offline, failed

        /// Plain sentences for the player; no dashes.
        var message: String {
            switch self {
            case .signedOut: return "Your YouTube sign in ran out. Sign in with Google again."
            case .quota: return "Your Google key has used up today's YouTube requests. It refills tomorrow."
            case .apiOff: return "Turn on YouTube Data API v3 for your Google key in Google Cloud, then try again."
            case .notFound: return "YouTube could not find this playlist."
            case .offline: return "No internet connection. Try again when you are back online."
            case .failed: return "YouTube did not answer. Try again."
            }
        }
    }

    // MARK: API answers

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// What an error answer means; nil when the answer is not an error.
    static func problem(_ data: Data, status: Int) -> Problem? {
        guard let error = object(data)?["error"] as? [String: Any] else {
            return status >= 400 ? (status == 401 ? .signedOut : .failed) : nil
        }
        let reasons = ((error["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
        if reasons.contains(where: { ["quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded"].contains($0) }) { return .quota }
        if reasons.contains(where: { ["accessNotConfigured", "SERVICE_DISABLED"].contains($0) })
            || (error["status"] as? String) == "PERMISSION_DENIED" && "\(error["message"] ?? "")".contains("has not been used") { return .apiOff }
        if reasons.contains("playlistNotFound") || status == 404 { return .notFound }
        if status == 401 || reasons.contains("authError") { return .signedOut }
        return .failed
    }

    /// `videos.list` items (liked videos, charts, or details looked up by id).
    static func videos(_ data: Data) -> Page<Video> {
        guard let json = object(data) else { return Page(items: []) }
        let items = (json["items"] as? [[String: Any]]) ?? []
        let videos: [Video] = items.compactMap { item in
            guard let id = item["id"] as? String, KnobShiftYouTubeParsing.isVideoId(id),
                  let snippet = item["snippet"] as? [String: Any], let title = snippet["title"] as? String else { return nil }
            let details = item["contentDetails"] as? [String: Any]
            return Video(id: id, title: title, channel: snippet["channelTitle"] as? String ?? "",
                         categoryId: snippet["categoryId"] as? String,
                         duration: (details?["duration"] as? String).flatMap(seconds),
                         thumbnail: thumbnail(snippet), published: (snippet["publishedAt"] as? String).flatMap(date))
        }
        return Page(items: videos, next: json["nextPageToken"] as? String, skipped: items.count - videos.count)
    }

    /// `playlistItems.list` items: the videos of a playlist in its order. Private and deleted
    /// videos are left out and counted.
    static func playlistItems(_ data: Data) -> Page<Video> {
        guard let json = object(data) else { return Page(items: []) }
        let items = (json["items"] as? [[String: Any]]) ?? []
        let videos: [Video] = items.compactMap { item in
            guard let snippet = item["snippet"] as? [String: Any],
                  let id = (snippet["resourceId"] as? [String: Any])?["videoId"] as? String, KnobShiftYouTubeParsing.isVideoId(id),
                  let title = snippet["title"] as? String, !["Private video", "Deleted video"].contains(title),
                  (item["status"] as? [String: Any])?["privacyStatus"] as? String != "private" else { return nil }
            return Video(id: id, title: title, channel: snippet["videoOwnerChannelTitle"] as? String ?? "",
                         categoryId: nil, duration: nil, thumbnail: thumbnail(snippet), published: nil)
        }
        return Page(items: videos, next: json["nextPageToken"] as? String, skipped: items.count - videos.count)
    }

    /// `playlists.list` items: the person's own playlists.
    static func playlists(_ data: Data) -> Page<Playlist> {
        guard let json = object(data) else { return Page(items: []) }
        let lists: [Playlist] = ((json["items"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty, let snippet = item["snippet"] as? [String: Any],
                  let title = snippet["title"] as? String else { return nil }
            let count = ((item["contentDetails"] as? [String: Any])?["itemCount"] as? NSNumber)?.intValue ?? 0
            return Playlist(id: id, title: title, count: count, thumbnail: thumbnail(snippet))
        }
        return Page(items: lists, next: json["nextPageToken"] as? String)
    }

    /// `subscriptions.list` items: the channel ids the person subscribes to.
    static func subscriptions(_ data: Data) -> Page<String> {
        guard let json = object(data) else { return Page(items: []) }
        let ids: [String] = ((json["items"] as? [[String: Any]]) ?? []).compactMap { item in
            ((item["snippet"] as? [String: Any])?["resourceId"] as? [String: Any])?["channelId"] as? String
        }
        return Page(items: ids, next: json["nextPageToken"] as? String)
    }

    private static func thumbnail(_ snippet: [String: Any]) -> URL? {
        let all = snippet["thumbnails"] as? [String: Any] ?? [:]
        for size in ["medium", "high", "default"] {
            if let address = (all[size] as? [String: Any])?["url"] as? String, let url = URL(string: address),
               url.scheme == "https", let host = url.host, host == "ytimg.com" || host.hasSuffix(".ytimg.com") { return url }
        }
        return nil
    }

    // MARK: Channel feeds

    /// A channel's public feed (youtube.com/feeds/videos.xml): its newest videos, newest first.
    static func feed(_ data: Data) -> [Video] {
        let reader = FeedReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return reader.videos
    }

    private final class FeedReader: NSObject, XMLParserDelegate {
        var videos: [Video] = []
        private var entry: [String: String]?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if name == "entry" { entry = [:] }
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if name == "entry", let found = entry {
                if let id = found["yt:videoId"], KnobShiftYouTubeParsing.isVideoId(id), let title = found["title"] {
                    videos.append(Video(id: id, title: title, channel: found["name"] ?? "", categoryId: nil, duration: nil,
                                        thumbnail: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"),
                                        published: found["published"].flatMap(date)))
                }
                entry = nil
            } else if entry != nil, entry?[name] == nil {
                entry?[name] = value
            }
        }
    }

    // MARK: Values

    /// "PT3M41S" as 221 seconds; nil for anything else.
    static func seconds(_ iso: String) -> Double? {
        guard iso.hasPrefix("P") else { return nil }
        var total = 0.0, number = "", inTime = false
        for character in iso.dropFirst() {
            if character == "T" { inTime = true; continue }
            if character.isNumber || character == "." { number.append(character); continue }
            guard let value = Double(number) else { return nil }
            switch (character, inTime) {
            case ("D", false): total += value * 86400
            case ("H", true): total += value * 3600
            case ("M", true): total += value * 60
            case ("S", true): total += value
            default: return nil
            }
            number = ""
        }
        return number.isEmpty ? total : nil
    }

    private static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    // MARK: Music

    /// With `musicOnly`, only music between 1 and 15 minutes (no Shorts, mixes or live streams);
    /// a video whose category is unknown stays, so nothing is dropped by mistake.
    static func filtered(_ videos: [Video], musicOnly: Bool) -> [Video] {
        guard musicOnly else { return videos }
        return videos.filter { video in
            (video.categoryId == nil || video.isMusic) && (video.duration.map { (60...900).contains($0) } ?? true)
        }
    }

    // MARK: Songs

    /// Videos as songs, in the shape a yt-dlp list gives (KnobShiftYouTubeParsing.listing), so the
    /// picker, downloads, resume and retry work the same.
    static func listing(_ videos: [Video], listName: String) -> KnobShiftSpotDL.Listing {
        var songs: [KnobShiftSpotDL.Song] = []
        var raw: [String: Data] = [:]
        for video in videos where raw[video.id] == nil {
            let named = KnobShiftYouTubeParsing.song(video.title, video.channel)
            let row: [String: Any] = [
                "name": named.name, "artists": named.artists, "artist": named.artists[0], "album_name": NSNull(),
                "duration": video.duration ?? NSNull(), "song_id": video.id,
                "url": "https://www.youtube.com/watch?v=\(video.id)", "list_name": listName, "list_position": songs.count + 1,
            ]
            guard let encoded = try? JSONSerialization.data(withJSONObject: row),
                  let song = try? JSONDecoder().decode(KnobShiftSpotDL.Song.self, from: encoded) else { continue }
            songs.append(song)
            raw[video.id] = encoded
        }
        return KnobShiftSpotDL.Listing(songs: songs, raw: raw)
    }
}
