import Foundation

/// A Spotify or YouTube playlist, album, song or the user's liked songs brought into KnobShift.
/// Its songs live in one folder under ~/Music/KnobShift/Spotify or ~/Music/KnobShift/YouTube,
/// each file named with its song id so it always maps back to the right song.
struct KnobShiftPlaylist: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case playlist, album, song, liked }
    enum Source { case spotify, youtube }
    /// Spotify's id for the list ("liked" for Liked Songs), or "yt:" and YouTube's id for it.
    let id: String
    var name: String
    /// What spotDL is asked for: the Spotify link, or "saved" for Liked Songs.
    let link: String
    let kind: Kind
    var folderName: String
    /// Song ids in Spotify's order, as last read.
    var spotifyOrder: [String]
    let addedAt: Date
    /// Songs the user left unticked, so Update playlist does not tick them again.
    var skipped: [String]? = nil

    /// Read from the id, so playlists saved before YouTube import existed load unchanged.
    var source: Source { id.hasPrefix(KnobShiftPlaylists.youtubePrefix) ? .youtube : .spotify }
}

/// A removed playlist, kept for 30 days so it can be restored with its files.
struct KnobShiftRemovedPlaylist: Codable, Identifiable, Equatable {
    var id: String { folderName }
    let playlist: KnobShiftPlaylist
    let removedAt: Date
    /// Its folder inside ~/Music/KnobShift/Spotify/.Removed.
    let folderName: String
}

enum KnobShiftPlaylists {
    struct Index: Codable {
        var playlists: [KnobShiftPlaylist] = []
        var removed: [KnobShiftRemovedPlaylist] = []
    }

    static let keepRemovedFor: TimeInterval = 30 * 24 * 60 * 60
    /// Starts the id of every YouTube playlist.
    static let youtubePrefix = "yt:"

    /// ~/Music/KnobShift/Spotify, which also keeps the index of every playlist;
    /// KNOB_SPOTIFY_ROOT moves it for the command line checks.
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["KNOB_SPOTIFY_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/KnobShift/Spotify", isDirectory: true)
    }
    /// ~/Music/KnobShift/YouTube; KNOB_YOUTUBE_ROOT moves it for the command line checks.
    static var youtubeRoot: URL {
        if let path = ProcessInfo.processInfo.environment["KNOB_YOUTUBE_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/KnobShift/YouTube", isDirectory: true)
    }
    static func folderRoot(for source: KnobShiftPlaylist.Source) -> URL { source == .youtube ? youtubeRoot : root }
    static var removedRoot: URL { removedFolderRoot(for: .spotify) }
    static func removedFolderRoot(for source: KnobShiftPlaylist.Source) -> URL {
        folderRoot(for: source).appendingPathComponent(".Removed", isDirectory: true)
    }
    private static var indexURL: URL { root.appendingPathComponent("playlists.json") }

    static func folder(for playlist: KnobShiftPlaylist) -> URL {
        folderRoot(for: playlist.source).appendingPathComponent(playlist.folderName, isDirectory: true)
    }

    /// True for a file inside any KnobShift playlist folder (a download, not the user's own file).
    static func isDownload(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return [root, youtubeRoot].contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    // MARK: Index

    static func load() -> Index {
        guard let data = try? Data(contentsOf: indexURL) else { return Index() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Index.self, from: data)) ?? Index()
    }

    static func save(_ index: Index) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(index) else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? data.write(to: indexURL, options: .atomic)
    }

    /// Deletes removed playlists older than 30 days for good.
    static func purgeExpired(_ index: inout Index, now: Date = Date()) {
        let expired = index.removed.filter { now.timeIntervalSince($0.removedAt) > keepRemovedFor }
        for entry in expired { deleteForGood(entry) }
        index.removed.removeAll { expired.contains($0) }
    }

    // MARK: Folders

    /// A folder name Finder accepts and no other playlist uses.
    static func folderName(for name: String, taken: Set<String>, source: KnobShiftPlaylist.Source = .spotify) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\0"))
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? (source == .youtube ? "YouTube songs" : "Spotify songs") : String(cleaned.prefix(80))
        let parent = folderRoot(for: source)
        var candidate = base
        var number = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: parent.appendingPathComponent(candidate).path) {
            candidate = "\(base) \(number)"
            number += 1
        }
        return candidate
    }

    /// Moves a playlist's folder into .Removed, where it stays restorable for 30 days.
    static func moveToRemoved(_ playlist: KnobShiftPlaylist, at date: Date = Date()) throws -> KnobShiftRemovedPlaylist {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd HHmmss"
        let name = "\(playlist.folderName) \(stamp.string(from: date))"
        let removed = removedFolderRoot(for: playlist.source)
        try FileManager.default.createDirectory(at: removed, withIntermediateDirectories: true)
        let source = folder(for: playlist)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: removed.appendingPathComponent(name))
        }
        return KnobShiftRemovedPlaylist(playlist: playlist, removedAt: date, folderName: name)
    }

    /// Moves a removed playlist's folder back, under a free name.
    static func restore(_ removed: KnobShiftRemovedPlaylist, taken: Set<String>) throws -> KnobShiftPlaylist {
        var playlist = removed.playlist
        playlist.folderName = folderName(for: playlist.folderName, taken: taken, source: playlist.source)
        let source = removedFolderRoot(for: playlist.source).appendingPathComponent(removed.folderName)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: folder(for: playlist))
        } else {
            try FileManager.default.createDirectory(at: folder(for: playlist), withIntermediateDirectories: true)
        }
        return playlist
    }

    static func deleteForGood(_ removed: KnobShiftRemovedPlaylist) {
        try? FileManager.default.removeItem(at: removedFolderRoot(for: removed.playlist.source).appendingPathComponent(removed.folderName))
    }

    // MARK: Songs and names

    /// Audio files in a playlist folder by song id, read from the "[id]" in each file name.
    static func files(in folder: URL) -> [String: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for file in names where ["m4a", "mp3", "opus", "ogg", "flac", "wav"].contains(file.pathExtension.lowercased()) {
            if let id = songId(inFileName: file.deletingPathExtension().lastPathComponent) { found[id] = file }
        }
        return found
    }

    /// The song id at the end of a file name: "… [id]" with a 22 character Spotify id, or
    /// "… [yt-id]" with an 11 character YouTube id. The "yt-" keeps ordinary brackets apart.
    static func songId(inFileName name: String) -> String? {
        guard name.hasSuffix("]"), let open = name.range(of: " [", options: .backwards) else { return nil }
        let id = String(name[open.upperBound..<name.index(before: name.endIndex)])
        if id.hasPrefix("yt-") {
            let video = String(id.dropFirst(3))
            return KnobShiftYouTubeParsing.isVideoId(video) ? video : nil
        }
        return id.count == 22 && id.allSatisfy({ $0.isLetter || $0.isNumber }) ? id : nil
    }

    /// Which playlist and song a file belongs to, when it sits in a playlist folder.
    /// `playlists` saves reading the index from disk once per song.
    static func origin(of url: URL, in playlists: [KnobShiftPlaylist]? = nil) -> (playlistId: String?, spotifyId: String)? {
        guard let id = songId(inFileName: url.deletingPathExtension().lastPathComponent) else { return nil }
        let folder = url.deletingLastPathComponent()
        let playlist = (playlists ?? load().playlists).first {
            $0.folderName == folder.lastPathComponent && Self.folder(for: $0).standardizedFileURL == folder.standardizedFileURL
        }
        return (playlist?.id, id)
    }

    /// Where a playlist keeps its chosen songs as spotDL describes them, so downloads can
    /// continue after a relaunch without reading Spotify again.
    static func songsFile(for playlist: KnobShiftPlaylist) -> URL {
        folder(for: playlist).appendingPathComponent("knobshift-songs.spotdl")
    }

    /// "07 Title - Artists [id]" (how Spotify and YouTube songs are saved) without the position
    /// and the id.
    static func plainTitle(_ title: String) -> String {
        var text = title
        if songId(inFileName: text) != nil, let open = text.range(of: " [", options: .backwards) {
            text = String(text[..<open.lowerBound])
            if let space = text.firstIndex(of: " "), text[..<space].allSatisfy(\.isNumber) {
                text = String(text[text.index(after: space)...])
            }
        }
        return text
    }

    /// What a pasted link points to: a playlist, album or song on open.spotify.com, or the
    /// same as a "spotify:" address. Nil when it is not a Spotify link.
    static func parseLink(_ text: String) -> (link: String, id: String, kind: KnobShiftPlaylist.Kind)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if trimmed.hasPrefix("spotify:") {
            parts = trimmed.split(separator: ":").map(String.init).dropFirst().map { $0 }
        } else if let url = URL(string: trimmed), let host = url.host, host.hasSuffix("spotify.com") {
            parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl") }
        }
        guard parts.count >= 2 else { return nil }
        let kinds: [String: KnobShiftPlaylist.Kind] = ["playlist": .playlist, "album": .album, "track": .song]
        guard let kind = kinds[parts[0]], parts[1].count == 22 else { return nil }
        let type = parts[0]
        return ("https://open.spotify.com/\(type)/\(parts[1])", parts[1], kind)
    }
}
