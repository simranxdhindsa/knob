import Foundation

/// A Spotify playlist, album, song or the user's Liked Songs brought into KnobShift. Its songs
/// live in one folder under ~/Music/KnobShift/Spotify, each file named with its Spotify id so it
/// always maps back to the right song.
struct KnobShiftPlaylist: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case playlist, album, song, liked }
    /// Spotify's id for the list ("liked" for Liked Songs).
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

    /// ~/Music/KnobShift/Spotify; KNOB_SPOTIFY_ROOT moves it for the command line checks.
    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["KNOB_SPOTIFY_ROOT"] { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/KnobShift/Spotify", isDirectory: true)
    }
    static var removedRoot: URL { root.appendingPathComponent(".Removed", isDirectory: true) }
    private static var indexURL: URL { root.appendingPathComponent("playlists.json") }

    static func folder(for playlist: KnobShiftPlaylist) -> URL {
        root.appendingPathComponent(playlist.folderName, isDirectory: true)
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
        for entry in expired {
            try? FileManager.default.removeItem(at: removedRoot.appendingPathComponent(entry.folderName))
        }
        index.removed.removeAll { expired.contains($0) }
    }

    // MARK: Folders

    /// A folder name Finder accepts and no other playlist uses.
    static func folderName(for name: String, taken: Set<String>) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\0"))
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        let base = cleaned.isEmpty ? "Spotify songs" : String(cleaned.prefix(80))
        var candidate = base
        var number = 2
        while taken.contains(candidate) || FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
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
        try FileManager.default.createDirectory(at: removedRoot, withIntermediateDirectories: true)
        let source = folder(for: playlist)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: removedRoot.appendingPathComponent(name))
        }
        return KnobShiftRemovedPlaylist(playlist: playlist, removedAt: date, folderName: name)
    }

    /// Moves a removed playlist's folder back, under a free name.
    static func restore(_ removed: KnobShiftRemovedPlaylist, taken: Set<String>) throws -> KnobShiftPlaylist {
        var playlist = removed.playlist
        playlist.folderName = folderName(for: playlist.folderName, taken: taken)
        let source = removedRoot.appendingPathComponent(removed.folderName)
        if FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.moveItem(at: source, to: folder(for: playlist))
        } else {
            try FileManager.default.createDirectory(at: folder(for: playlist), withIntermediateDirectories: true)
        }
        return playlist
    }

    static func deleteForGood(_ removed: KnobShiftRemovedPlaylist) {
        try? FileManager.default.removeItem(at: removedRoot.appendingPathComponent(removed.folderName))
    }

    // MARK: Songs and names

    /// Audio files in a playlist folder by Spotify id, read from the "[id]" in each file name.
    static func files(in folder: URL) -> [String: URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var found: [String: URL] = [:]
        for file in names where ["m4a", "mp3", "opus", "ogg", "flac", "wav"].contains(file.pathExtension.lowercased()) {
            if let id = spotifyId(inFileName: file.deletingPathExtension().lastPathComponent) { found[id] = file }
        }
        return found
    }

    /// The Spotify id at the end of a file name written as "… [id]".
    static func spotifyId(inFileName name: String) -> String? {
        guard name.hasSuffix("]"), let open = name.range(of: " [", options: .backwards) else { return nil }
        let id = String(name[open.upperBound..<name.index(before: name.endIndex)])
        return id.count == 22 && id.allSatisfy({ $0.isLetter || $0.isNumber }) ? id : nil
    }

    /// Which playlist and Spotify song a file belongs to, when it sits in a playlist folder.
    /// `playlists` saves reading the index from disk once per song.
    static func origin(of url: URL, in playlists: [KnobShiftPlaylist]? = nil) -> (playlistId: String?, spotifyId: String)? {
        guard let id = spotifyId(inFileName: url.deletingPathExtension().lastPathComponent) else { return nil }
        let folder = url.deletingLastPathComponent().lastPathComponent
        let playlist = (playlists ?? load().playlists).first { $0.folderName == folder }
        return (playlist?.id, id)
    }

    /// Where a playlist keeps its chosen songs as spotDL describes them, so downloads can
    /// continue after a relaunch without reading Spotify again.
    static func songsFile(for playlist: KnobShiftPlaylist) -> URL {
        folder(for: playlist).appendingPathComponent("knobshift-songs.spotdl")
    }

    /// "07 Title - Artists [id]" (how Spotify songs are saved) without the position and the id.
    static func plainTitle(_ title: String) -> String {
        var text = title
        if spotifyId(inFileName: text) != nil, let open = text.range(of: " [", options: .backwards) {
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
