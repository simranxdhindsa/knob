import Foundation

/// Reads a Spotify playlist, album or song with no key and no login, from Spotify's public embed
/// player (open.spotify.com/embed/...), the page websites show a playlist in. Its data carries
/// every song's name, artists, length and Spotify id, which is all spotDL needs to find and
/// download each song: a song list built here downloads with no Spotify request at all. So
/// adding music works for everyone, even while Spotify pauses the shared key.
///
/// Spotify shows at most 100 songs of a list this way; a longer list comes back as `truncated`,
/// and the full list is read through spotDL when Spotify allows it.
enum KnobShiftSpotifyEmbed {
    struct Result {
        let listing: KnobShiftSpotDL.Listing
        let name: String?
        let truncated: Bool
    }

    static let limit = 100

    static func read(kind: KnobShiftPlaylist.Kind, id: String, session: URLSession = .shared) async throws -> Result {
        let type: String
        switch kind {
        case .playlist: type = "playlist"
        case .album: type = "album"
        case .song: type = "track"
        case .liked: throw KnobShiftSpotDL.Failure.privateList
        }
        guard let url = URL(string: "https://open.spotify.com/embed/\(type)/\(id)") else { throw KnobShiftSpotDL.Failure.failed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // The page a Mac's browser gets; Spotify serves the player to it like to any website.
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw KnobShiftSpotDL.Failure.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 || status == 403 { throw KnobShiftSpotDL.Failure.privateList }
        guard status == 200, let entity = entity(in: data) else { throw KnobShiftSpotDL.Failure.failed }
        return try result(from: entity, kind: kind, id: id)
    }

    /// The embed page's own data: the JSON in its __NEXT_DATA__ script.
    static func entity(in page: Data) -> [String: Any]? {
        guard let html = String(data: page, encoding: .utf8),
              let start = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let json = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let props = json["props"] as? [String: Any], let pageProps = props["pageProps"] as? [String: Any],
              let state = pageProps["state"] as? [String: Any], let data = state["data"] as? [String: Any],
              let entity = data["entity"] as? [String: Any] else { return nil }
        return entity
    }

    /// Songs in spotDL's own save file shape, so the picker, downloads and retries treat them
    /// exactly like a list spotDL read. Album and year are unknown for a playlist's songs; an
    /// album's songs get its name and cover.
    static func result(from entity: [String: Any], kind: KnobShiftPlaylist.Kind, id: String) throws -> Result {
        let name = entity["name"] as? String ?? entity["title"] as? String
        let tracks: [[String: Any]] = kind == .song ? [entity] : (entity["trackList"] as? [[String: Any]] ?? [])
        let cover = kind == .playlist ? nil : largestCover(entity)
        var entries: [[String: Any]] = []
        for (index, track) in tracks.enumerated() {
            guard let uri = track["uri"] as? String, let songId = uri.split(separator: ":").last.map(String.init), songId.count == 22,
                  let title = (track["title"] as? String) ?? (track["name"] as? String) else { continue }
            let artistText = (track["subtitle"] as? String) ?? artists(of: track)
            let artists = artistText.replacingOccurrences(of: "\u{00A0}", with: " ")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let milliseconds = (track["duration"] as? Double) ?? ((track["duration"] as? [String: Any])?["totalMilliseconds"] as? Double) ?? 0
            let album = kind == .album ? (name ?? title) : title
            let first = artists.first ?? "Unknown artist"
            var entry: [String: Any] = [:]
            entry["name"] = title
            entry["artists"] = artists.isEmpty ? [first] : artists
            entry["artist"] = first
            entry["genres"] = [String]()
            entry["disc_number"] = 1
            entry["disc_count"] = 1
            entry["album_name"] = album
            entry["album_artist"] = first
            entry["duration"] = Int((milliseconds / 1000).rounded())
            entry["year"] = 0
            entry["date"] = ""
            entry["track_number"] = index + 1
            entry["tracks_count"] = tracks.count
            entry["song_id"] = songId
            entry["explicit"] = track["isExplicit"] as? Bool ?? false
            entry["publisher"] = ""
            entry["url"] = "https://open.spotify.com/track/\(songId)"
            entry["isrc"] = NSNull()
            entry["cover_url"] = cover ?? NSNull()
            entry["copyright_text"] = NSNull()
            entry["list_name"] = name ?? NSNull()
            entry["list_url"] = "https://open.spotify.com/\(kind == .song ? "track" : kind.rawValue)/\(id)"
            entry["list_position"] = index + 1
            entry["list_length"] = tracks.count
            entries.append(entry)
        }
        guard !entries.isEmpty, let data = try? JSONSerialization.data(withJSONObject: entries),
              let listing = KnobShiftSpotDL.listing(from: data), !listing.songs.isEmpty else {
            throw KnobShiftSpotDL.Failure.nothingFound
        }
        return Result(listing: listing, name: name, truncated: kind == .playlist && tracks.count >= limit)
    }

    private static func artists(of track: [String: Any]) -> String {
        let list = track["artists"] as? [[String: Any]] ?? []
        return list.compactMap { $0["name"] as? String }.joined(separator: ", ")
    }

    private static func largestCover(_ entity: [String: Any]) -> String? {
        let sources = ((entity["coverArt"] as? [String: Any])?["sources"] as? [[String: Any]])
            ?? ((entity["visualIdentity"] as? [String: Any])?["image"] as? [[String: Any]]) ?? []
        return sources.max { ($0["width"] as? Int ?? 0) < ($1["width"] as? Int ?? 0) }?["url"] as? String
    }
}
