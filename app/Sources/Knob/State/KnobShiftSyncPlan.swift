import Foundation

/// Works out one sync from the Mac (KnobShiftLink) onto the iPhone, with no side effects, so
/// every clash between the two can be tested on its own:
///
/// - **Same playlist on both:** the Mac's name, order and unticked songs win; the iPhone keeps
///   its folder, so paths of songs already in its queue never change.
/// - **Two playlists wanting one folder name:** the newcomer gets " 2" (as on the Mac).
/// - **Removed on the iPhone:** a playlist the iPhone removed is left out until it is restored.
/// - **Removed on the Mac:** nothing is ever deleted from the iPhone.
/// - **Song taken out of the iPhone's queue:** stays out on later syncs (`declined`).
/// - **Same song in two playlists:** copied once from the Mac, then copied locally; queued once.
/// - **Song already on the iPhone:** skipped when its size matches; a different size (a broken
///   copy, or a newer download) is copied again, unless that song is playing right now.
/// - **Song still downloading on the Mac:** a waiting row now, its file on a later sync.
/// - **Song the Mac could not get:** not added; a row already waiting shows the Mac's reason.
/// - **Where new songs go:** after the song before them in the playlist's order that is already
///   in the queue, so a queue the person rearranged keeps its order around them; failing that,
///   before the first song after them; otherwise at the end.
enum KnobShiftSyncPlan {
    /// What the iPhone has now.
    struct Phone {
        var playlists: [KnobShiftPlaylist]
        var removedIds: Set<String> = []
        /// Song files on the iPhone, by playlist id then song id, with their size.
        var files: [String: [String: (url: URL, size: Int64)]] = [:]
        /// Song ids in the queue, ready or waiting, in queue order.
        var queued: [String] = []
        /// "playlistId/songId" taken out of the queue on the iPhone.
        var declined: Set<String> = []
        /// The song playing now, never replaced under the player.
        var playing: URL? = nil
        /// Free space on the iPhone, in bytes.
        var freeSpace: Int64 = .max
    }

    enum Placement: Equatable {
        case after(String), before(String), end
    }

    struct Transfer: Equatable {
        let playlistId: String
        let songId: String
        let size: Int64
        let destination: URL
    }

    struct Copy: Equatable {
        let playlistId: String
        let songId: String
        let from: URL
        let to: URL
    }

    struct Row: Equatable {
        let playlistId: String
        let songId: String
        let name: String?
        let artist: String?
        let url: URL
        /// Its file is not on the iPhone yet (coming in this sync or a later one).
        let waiting: Bool
        let placement: Placement
    }

    struct Result: Equatable {
        var playlists: [KnobShiftPlaylist]
        var transfers: [Transfer] = []
        var copies: [Copy] = []
        var rows: [Row] = []
        /// Songs the Mac is still downloading.
        var onMac = 0
        /// Songs the Mac could not get.
        var failedOnMac = 0
        /// Songs left on the Mac for want of space.
        var noRoom = 0
        var keptRemoved = 0
        var duplicates = 0
    }

    /// Room kept free on the iPhone for everything else.
    static let spareSpace: Int64 = 300 * 1024 * 1024

    static func plan(_ library: KnobShiftLink.Library, phone: Phone,
                     folder: (KnobShiftPlaylist) -> URL = KnobShiftPlaylists.folder(for:),
                     freeName: (String, Set<String>, KnobShiftPlaylist.Source) -> String = { KnobShiftPlaylists.folderName(for: $0, taken: $1, source: $2) }) -> Result {
        var result = Result(playlists: phone.playlists)
        var queued = Set(phone.queued)
        var order = phone.queued
        var budget = phone.freeSpace == .max ? .max : phone.freeSpace - spareSpace
        // Every copy of a song on the iPhone, from any playlist, and the ones coming this sync.
        var anyFile: [String: URL] = [:]
        for songs in phone.files.values { for (id, file) in songs where anyFile[id] == nil { anyFile[id] = file.url } }
        var coming: [String: URL] = [:]

        for entry in library.playlists {
            let mac = entry.playlist
            if phone.removedIds.contains(mac.id) { result.keptRemoved += 1; continue }
            var local: KnobShiftPlaylist
            if let index = result.playlists.firstIndex(where: { $0.id == mac.id }) {
                result.playlists[index].name = mac.name
                result.playlists[index].spotifyOrder = mac.spotifyOrder
                result.playlists[index].skipped = mac.skipped
                local = result.playlists[index]
            } else {
                local = mac
                let taken = Set(result.playlists.filter { $0.source == mac.source }.map(\.folderName))
                local.folderName = taken.contains(mac.folderName) || mac.folderName.isEmpty
                    ? freeName(mac.folderName.isEmpty ? mac.name : mac.folderName, taken, mac.source) : mac.folderName
                result.playlists.append(local)
            }
            let place = folder(local)
            let have = phone.files[mac.id] ?? [:]
            let skipped = Set(mac.skipped ?? [])
            var seen = Set<String>()
            var newInList: [String] = []

            for song in entry.songs where seen.insert(song.id).inserted && !skipped.contains(song.id) {
                if song.problem != nil, song.file == nil, have[song.id] == nil {
                    result.failedOnMac += 1
                    continue
                }
                let wanted = !queued.contains(song.id) && !phone.declined.contains("\(mac.id)/\(song.id)")
                var url = have[song.id]?.url
                var waiting = false
                if let file = song.file, let size = song.size, size > 0, let name = safeName(file, songId: song.id) {
                    if let mine = have[song.id] {
                        if mine.size != size, mine.url.standardizedFileURL != phone.playing?.standardizedFileURL, budget >= size {
                            result.transfers.append(Transfer(playlistId: mac.id, songId: song.id, size: size, destination: mine.url))
                            budget -= size
                        }
                    } else if let elsewhere = anyFile[song.id] ?? coming[song.id] {
                        // Copied on the iPhone, after this sync's transfers have landed.
                        let target = place.appendingPathComponent(name)
                        result.copies.append(Copy(playlistId: mac.id, songId: song.id, from: elsewhere, to: target))
                        result.duplicates += 1
                        url = target
                        waiting = anyFile[song.id] == nil
                    } else if budget >= size {
                        let target = place.appendingPathComponent(name)
                        result.transfers.append(Transfer(playlistId: mac.id, songId: song.id, size: size, destination: target))
                        budget -= size
                        coming[song.id] = target
                        url = target
                        waiting = true
                    } else {
                        result.noRoom += 1
                        continue
                    }
                } else if url == nil {
                    result.onMac += 1
                    waiting = true
                }
                guard wanted else { continue }
                let row = Row(playlistId: mac.id, songId: song.id, name: song.name, artist: song.artist,
                              url: url ?? place.appendingPathComponent("\(song.id).pending"),
                              waiting: waiting || url == nil,
                              placement: placement(of: song.id, in: entry.songs.map(\.id), queue: order, adding: newInList))
                result.rows.append(row)
                newInList.append(song.id)
                queued.insert(song.id)
                order = insert(song.id, at: row.placement, into: order)
            }
        }
        return result
    }

    /// Why a song waiting on the iPhone is not on its way, or nil if it is.
    static func problem(songId: String, playlistId: String, in library: KnobShiftLink.Library) -> String? {
        guard let song = library.playlists.first(where: { $0.playlist.id == playlistId })?.songs.first(where: { $0.id == songId }) else {
            return "Not on your Mac"
        }
        return song.problem.map { "\($0) on your Mac" }
    }

    /// Where a new song goes: after the nearest earlier song of its list that is in the queue
    /// (or being added), else before the nearest later one, else at the end.
    static func placement(of id: String, in list: [String], queue: [String], adding: [String]) -> Placement {
        guard let position = list.firstIndex(of: id) else { return .end }
        let present = Set(queue).union(adding)
        if let earlier = list[..<position].last(where: present.contains) { return .after(earlier) }
        if let later = list[list.index(after: position)...].first(where: present.contains) { return .before(later) }
        return .end
    }

    static func insert(_ id: String, at placement: Placement, into queue: [String]) -> [String] {
        var queue = queue
        switch placement {
        case .after(let anchor):
            if let index = queue.lastIndex(of: anchor) { queue.insert(id, at: queue.index(after: index)) } else { queue.append(id) }
        case .before(let anchor):
            if let index = queue.firstIndex(of: anchor) { queue.insert(id, at: index) } else { queue.append(id) }
        case .end:
            queue.append(id)
        }
        return queue
    }

    /// The Mac's file name kept only when it is a plain name ending in the song's own id; anything
    /// else (a path, "..", another id) is replaced with a safe name built from the id.
    static func safeName(_ file: String, songId: String) -> String? {
        let name = (file as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["m4a", "mp3", "opus", "ogg", "flac", "wav"].contains(ext) else { return nil }
        if name == file, !name.hasPrefix("."), !name.contains("\0"),
           KnobShiftPlaylists.songId(inFileName: (name as NSString).deletingPathExtension) == songId {
            return name
        }
        let tag = KnobShiftPlaylists.isYouTubeVideoId(songId) ? "yt-\(songId)" : songId
        return "\(tag) [\(tag)].\(ext)"
    }

    // MARK: Songs taken out on the iPhone

    static var declined: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: PersistKey.knobShiftPhoneDeclined.rawValue) ?? [])
    }

    static func decline(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        UserDefaults.standard.set(Array(declined.union(keys)).sorted(), forKey: PersistKey.knobShiftPhoneDeclined.rawValue)
    }

    /// Lets every song taken out come back on the next sync.
    static func forgetDeclined() {
        UserDefaults.standard.removeObject(forKey: PersistKey.knobShiftPhoneDeclined.rawValue)
    }
}
