import Foundation

/// The parts of KnobShift's YouTube import that need no network, so the YouTube self test can
/// check them directly: reading pasted links, turning video titles into song names, reading
/// yt-dlp's lists into the same song shape Spotify uses, naming files, the arguments yt-dlp is
/// given, and reading what went wrong.
///
/// YouTube songs reuse everything built for Spotify (the picker, queue rows, progress, retry,
/// resume, update and remove). A YouTube playlist's id starts with "yt:", and its songs' files end
/// with "[yt-VIDEOID]".
enum KnobShiftYouTubeParsing {
    struct Link: Equatable {
        /// The clean link handed to yt-dlp, rebuilt from the ids: never the pasted text itself.
        let url: String
        /// The playlist id in KnobShift: "yt:" and YouTube's id.
        let id: String
        let kind: KnobShiftPlaylist.Kind
    }

    /// A list read by yt-dlp: its name, its songs, and how many videos were left out because
    /// they are private, deleted or for members only.
    struct Read {
        let name: String?
        let listing: KnobShiftSpotDL.Listing
        let skipped: Int
    }

    enum Failure: Error, Equatable {
        case unavailable, privateVideo, ageRestricted, botCheck, offline, noSpace, nothingFound, failed, stalled, missingHelper

        /// Plain sentences for the player; no dashes.
        var message: String {
            switch self {
            case .unavailable: return "YouTube says this video or playlist is not available."
            case .privateVideo: return "This is private on YouTube. Sign in to YouTube in Knob to add it."
            case .ageRestricted: return "YouTube needs you to sign in for this one. Sign in to YouTube in Knob and try again."
            case .botCheck: return "YouTube is pausing downloads from this Mac for now. Sign in to YouTube in Knob, or try again in a few hours."
            case .offline: return "No internet connection. Try again when you are back online."
            case .noSpace: return "Not enough space on this Mac for these songs."
            case .nothingFound: return "YouTube returned no songs for this link."
            case .failed: return "YouTube import did not finish. Try again."
            case .stalled: return "YouTube stopped answering, so the import was stopped. Try again."
            case .missingHelper: return "YouTube import is unavailable in this copy of Knob."
            }
        }

        /// The short text a queue row shows.
        var rowText: String {
            switch self {
            case .privateVideo: return "Private"
            case .ageRestricted: return "Needs sign in"
            case .botCheck: return "YouTube paused"
            case .offline: return "No internet"
            case .noSpace: return "No space"
            case .stalled: return "Stopped"
            default: return "Not found"
            }
        }
    }

    // MARK: Links

    private static let hosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"]

    private static func isIdCharacter(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
    }

    static func isVideoId(_ text: String) -> Bool { text.count == 11 && text.allSatisfy(isIdCharacter) }

    private static func isListId(_ text: String) -> Bool { (2...80).contains(text.count) && text.allSatisfy(isIdCharacter) }

    /// What a pasted link points to: a video, a playlist, a YouTube Music album, or Liked videos.
    /// A video opened inside a playlist means the playlist, except a mix ("RD..."), which never
    /// ends. Nil for anything that is not a YouTube link, including look alike sites.
    static func parseLink(_ text: String) -> Link? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), hosts.contains(host) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] where query[item.name] == nil { query[item.name] = item.value }
        let path = components.path.split(separator: "/").map(String.init)

        func video(_ id: String?) -> Link? {
            guard let id, isVideoId(id) else { return nil }
            return Link(url: "https://www.youtube.com/watch?v=\(id)", id: KnobShiftPlaylists.youtubePrefix + id, kind: .song)
        }

        if host.hasSuffix("youtu.be") { return video(path.first) }
        let page = path.first ?? ""
        if page == "watch" || page == "playlist", let list = query["list"], isListId(list), !list.hasPrefix("RD") {
            let kind: KnobShiftPlaylist.Kind = list == "LL" ? .liked : list.hasPrefix("OLAK5uy_") ? .album : .playlist
            return Link(url: "https://www.youtube.com/playlist?list=\(list)", id: KnobShiftPlaylists.youtubePrefix + list, kind: kind)
        }
        switch page {
        case "watch": return video(query["v"])
        case "shorts", "live", "embed": return video(path.count > 1 ? path[1] : nil)
        case "browse":
            guard path.count > 1, path[1].hasPrefix("MPREb_"), isListId(path[1]) else { return nil }
            return Link(url: "https://music.youtube.com/browse/\(path[1])", id: KnobShiftPlaylists.youtubePrefix + path[1], kind: .album)
        default: return nil
        }
    }

    // MARK: Song names

    /// Words that mark a bracketed note as about the video rather than the song:
    /// "(Official Video)", "[Lyric Video]", "(Video Oficial)", "(HD)".
    private static let noiseWords: Set<String> = ["official", "oficial", "video", "videoclip", "audio", "lyric", "lyrics", "letra",
                                                  "visualizer", "visualiser", "hd", "4k", "mv", "performance"]

    /// The song's name and artists from a video's title and channel. "Artist - Song" and
    /// "Song - Artist" are told apart by which side names the channel; notes about the video are
    /// dropped, featured artists are written "(feat. ...)" like Spotify, and a channel ending in
    /// " - Topic" (YouTube Music's own) or "VEVO" is the artist.
    static func song(_ title: String, _ channel: String?) -> (name: String, artists: [String]) {
        let owner = cleanChannel(channel ?? "")
        var text = withoutNoise(title)
        var barArtist: String?
        if text.contains(" | ") {
            let parts = text.components(separatedBy: " | ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            text = parts.first ?? text
            barArtist = parts.count > 1 ? parts[1] : nil
        }
        var name = text
        var artistText = barArtist ?? owner
        var featured: String?
        if let separator = [" - ", " – ", " — "].compactMap({ text.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
            let left = splitFeatured(String(text[..<separator.lowerBound]))
            let right = splitFeatured(String(text[separator.upperBound...]))
            let ownerKey = loose(owner)
            let rightIsArtist = !ownerKey.isEmpty && loose(right.core).contains(ownerKey) && !loose(left.core).contains(ownerKey)
            let (song, artist) = rightIsArtist ? (left, right) : (right, left)
            name = song.core
            artistText = artist.core
            featured = song.featured ?? artist.featured
        } else {
            let split = splitFeatured(text)
            name = split.core
            featured = split.featured
        }
        if let featured { name += " (feat. \(featured))" }
        let artists = artistText.components(separatedBy: ", ").flatMap { $0.components(separatedBy: " & ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return (tidy(name).isEmpty ? tidy(title) : tidy(name), artists.isEmpty ? [owner.isEmpty ? "Unknown artist" : owner] : artists)
    }

    private static func cleanChannel(_ channel: String) -> String {
        var text = channel.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Topic", "VEVO", " Official", " Oficial"] where text.hasSuffix(suffix) && text.count > suffix.count {
            text = String(text.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// The title without bracketed notes about the video; notes about the song ("(Remix)",
    /// "(feat. X)") stay.
    private static func withoutNoise(_ title: String) -> String {
        var text = title
        let pattern = try? NSRegularExpression(pattern: #"\s*[\(\[][^\)\]]*[\)\]]"#)
        let matches = pattern?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let words = text[range].lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            if words.contains(where: noiseWords.contains) { text.removeSubrange(range) }
        }
        return tidy(text)
    }

    /// "Song ft. X, Y" as the song and "X, Y". Only outside brackets: "(feat. X)" is kept as is.
    private static func splitFeatured(_ text: String) -> (core: String, featured: String?) {
        for marker in [" ft. ", " feat. ", " featuring ", " ft "] {
            if let range = text.range(of: marker, options: .caseInsensitive) {
                let featured = tidy(String(text[range.upperBound...]))
                return (tidy(String(text[..<range.lowerBound])), featured.isEmpty ? nil : featured)
            }
        }
        return (tidy(text), nil)
    }

    private static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—|")))
    }

    /// Letters and digits only, without accents or case: "Arcángel" and "Arcangel" match.
    private static func loose(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: Lists

    /// Reads yt-dlp's `--flat-playlist -J` output (a list) or `-J` output (one video). Private,
    /// deleted and members only videos are left out and counted. Each song is also kept as a
    /// save file entry, which the Spotify code reads back for resume and retry.
    static func listing(from data: Data, kind: KnobShiftPlaylist.Kind) -> Read? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let isList = json["_type"] as? String == "playlist" || json["entries"] != nil
        let entries = isList ? ((json["entries"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] } : [json]
        var listTitle = isList ? json["title"] as? String : nil
        if kind == .album, let title = listTitle, title.hasPrefix("Album - ") { listTitle = String(title.dropFirst("Album - ".count)) }
        var songs: [KnobShiftSpotDL.Song] = []
        var raw: [String: Data] = [:]
        var skipped = 0
        for entry in entries {
            guard let id = entry["id"] as? String, isVideoId(id), let title = entry["title"] as? String, isPlayable(entry, title: title),
                  raw[id] == nil else {
                skipped += 1
                continue
            }
            let named: (name: String, artists: [String])
            if let track = entry["track"] as? String, !track.isEmpty,
               let artists = (entry["artists"] as? [String]) ?? (entry["artist"] as? String).map({ [$0] }), !artists.isEmpty {
                named = (track, artists)
            } else {
                named = song(title, (entry["channel"] as? String) ?? (entry["uploader"] as? String))
            }
            var row: [String: Any] = [:]
            row["name"] = named.name
            row["artists"] = named.artists
            row["artist"] = named.artists[0]
            row["album_name"] = (entry["album"] as? String) ?? (kind == .album ? listTitle : nil) ?? NSNull()
            row["duration"] = (entry["duration"] as? NSNumber)?.doubleValue ?? NSNull()
            row["song_id"] = id
            row["url"] = "https://www.youtube.com/watch?v=\(id)"
            row["list_name"] = listTitle ?? NSNull()
            row["list_position"] = songs.count + 1
            guard let encoded = try? JSONSerialization.data(withJSONObject: row),
                  let decoded = try? JSONDecoder().decode(KnobShiftSpotDL.Song.self, from: encoded) else {
                skipped += 1
                continue
            }
            songs.append(decoded)
            raw[id] = encoded
        }
        let name = isList ? listTitle : songs.first.map { "\($0.name) by \($0.artist)" }
        return Read(name: name, listing: KnobShiftSpotDL.Listing(songs: songs, raw: raw), skipped: skipped)
    }

    private static func isPlayable(_ entry: [String: Any], title: String) -> Bool {
        if ["[Private video]", "[Deleted video]", "[Unavailable video]"].contains(title) { return false }
        let availability = entry["availability"] as? String ?? ""
        return !["private", "premium_only", "subscriber_only", "needs_auth"].contains(availability)
    }

    // MARK: Files

    /// "03 Song - Artists [yt-VIDEOID]", safe for Finder. Knob shows it as the song and its
    /// artists (Track.split), and finds the song again by the id at the end.
    static func fileName(for song: KnobShiftSpotDL.Song) -> String {
        let artists = song.artists.isEmpty ? song.artist : song.artists.joined(separator: ", ")
        let text = "\(song.name.prefix(120)) - \(artists.prefix(80))"
            .components(separatedBy: CharacterSet(charactersIn: "/:\\\0\n\r")).joined(separator: " ")
        let position = song.list_position.map { String(format: "%02d ", $0) } ?? ""
        return "\(position)\(text) [yt-\(song.song_id)]"
    }

    /// The file name as a yt-dlp output template: "%" means a field there, so it is doubled.
    static func outputTemplate(for song: KnobShiftSpotDL.Song) -> String {
        fileName(for: song).replacingOccurrences(of: "%", with: "%%") + ".%(ext)s"
    }

    // MARK: Arguments

    /// Printed by yt-dlp once a song's file is finished.
    static let doneMarker = "KNOB_DONE"

    private static func cookieArguments(_ cookies: URL?) -> [String] {
        cookies.map { ["--cookies", $0.path] } ?? []
    }

    /// Reads a list quickly (`--flat-playlist`), without downloading anything. The link always
    /// comes last, after "--", so nothing in it is ever read as an option.
    static func listArguments(_ url: String, cookies: URL?) -> [String] {
        ["--ignore-config", "--no-color", "--flat-playlist", "--dump-single-json"] + cookieArguments(cookies) + ["--", url]
    }

    /// Downloads one song's audio as m4a with its cover, named by `fileName(for:)`. Songs whose
    /// file is already there are not downloaded again.
    static func downloadArguments(for song: KnobShiftSpotDL.Song, into folder: URL, ffmpeg: String, cookies: URL?) -> [String] {
        let url = isVideoId(song.song_id) ? "https://www.youtube.com/watch?v=\(song.song_id)" : song.url
        return audioArguments(for: song, into: folder, ffmpeg: ffmpeg, cookies: cookies) + ["--no-playlist", "--", url]
    }

    /// For a video that is gone or blocked: the closest match found by searching YouTube for the
    /// song's artist and name, saved under the original song's id so it lands in the same row.
    static func searchArguments(for song: KnobShiftSpotDL.Song, into folder: URL, ffmpeg: String, cookies: URL?) -> [String] {
        audioArguments(for: song, into: folder, ffmpeg: ffmpeg, cookies: cookies)
            + ["--match-filter", "duration < 900", "--", "ytsearch1:\(song.artist) \(song.name)"]
    }

    private static func audioArguments(for song: KnobShiftSpotDL.Song, into folder: URL, ffmpeg: String, cookies: URL?) -> [String] {
        let output = folder.path.replacingOccurrences(of: "%", with: "%%") + "/" + outputTemplate(for: song)
        return ["--ignore-config", "--no-color", "--newline",
                "--format", "bestaudio[ext=m4a]/bestaudio/best", "--extract-audio", "--audio-format", "m4a", "--audio-quality", "0",
                "--ffmpeg-location", ffmpeg, "--embed-thumbnail", "--convert-thumbnails", "jpg",
                "--retries", "3", "--sleep-requests", "1", "--no-mtime",
                "--print", "after_move:\(doneMarker) %(id)s", "--no-simulate",
                "--output", output] + cookieArguments(cookies)
    }

    // MARK: Problems

    /// What went wrong, read from yt-dlp's messages; nil when nothing did.
    static func classify(_ lines: [String]) -> Failure? {
        let text = lines.joined(separator: "\n").lowercased()
        if text.contains("not a bot") || text.contains("youtube_bot_check") || text.contains("http error 429")
            || text.contains("too many requests") { return .botCheck }
        if text.contains("confirm your age") || text.contains("age restricted") || text.contains("age-restricted") { return .ageRestricted }
        if text.contains("private video") || text.contains("granted access") || text.contains("playlist is private") { return .privateVideo }
        if text.contains("no space left") { return .noSpace }
        if text.contains("video unavailable") || text.contains("available in your country") || text.contains("has been removed")
            || text.contains("does not exist") || text.contains("is not available") || text.contains("account associated with this video has been terminated") {
            return .unavailable
        }
        if text.contains("nodename nor servname") || text.contains("network is unreachable") || text.contains("timed out")
            || text.contains("urlopen error") || text.contains("temporary failure in name resolution") { return .offline }
        return nil
    }
}
