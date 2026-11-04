import Foundation

/// One song of a playlist as the Playlists view lists it: ready to add once its file is here,
/// or still on its way, or not downloaded with the reason.
struct KnobShiftPlaylistSong: Identifiable, Equatable {
    enum State: Equatable {
        case ready(URL)
        case waiting(String)
        case failed(String)
    }

    /// The song's Spotify or YouTube id.
    let id: String
    let name: String
    let artist: String?
    let state: State

    var url: URL? {
        if case .ready(let url) = state { return url }
        return nil
    }
}

/// The playlists' songs, read from their folders, so they show and can be added whether or not
/// they are in the queue. Shared by the Mac and the iPhone.
extension KnobShiftModel {
    /// The playlist's songs in its own order. Songs it no longer lists (removed on Spotify or
    /// YouTube) still show at the end, since their files are never deleted; unticked songs
    /// and songs never downloaded or on their way are left out.
    func playlistSongs(_ playlist: KnobShiftPlaylist) -> [KnobShiftPlaylistSong] {
        let files = KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist))
        var rows: [String: PendingSong] = [:]
        for song in pending where song.playlistId == playlist.id {
            if let id = song.spotifyId, rows[id] == nil { rows[id] = song }
        }
        let skipped = Set(playlist.skipped ?? [])
        var order = playlist.spotifyOrder.filter { !skipped.contains($0) }
        let listed = Set(order)
        order += files.filter { !listed.contains($0.key) }.sorted { $0.value.lastPathComponent < $1.value.lastPathComponent }.map(\.key)
        return order.compactMap { id in
            let row = rows[id]
            if let row, row.waitingForDownload {
                if let failure = row.failure { return KnobShiftPlaylistSong(id: id, name: row.name, artist: row.artist, state: .failed(failure)) }
                return KnobShiftPlaylistSong(id: id, name: row.name, artist: row.artist, state: .waiting(row.stage ?? "Waiting to download"))
            }
            guard let url = files[id] else { return nil }
            let split = Track.split(url.deletingPathExtension().lastPathComponent)
            return KnobShiftPlaylistSong(id: id, name: row?.spotifyName ?? split.name, artist: row?.spotifyArtist ?? split.artist, state: .ready(url))
        }
    }

    /// How many of the playlist's songs are here, out of all it lists that are here or coming.
    func playlistCount(_ playlist: KnobShiftPlaylist) -> (ready: Int, total: Int) {
        let songs = playlistSongs(playlist)
        return (songs.filter { $0.url != nil }.count, songs.count)
    }

    /// Adds the playlist's ready songs to the end of the queue, skipping any already in it.
    func addToQueue(_ songs: [KnobShiftPlaylistSong]) async {
        await addTracks(songs.compactMap(\.url))
    }

    /// Adds the songs and plays the first of them, from the queue if it was already there.
    func play(_ songs: [KnobShiftPlaylistSong]) async {
        let urls = songs.compactMap(\.url)
        guard let first = urls.first?.standardizedFileURL else { return }
        enqueueFiles(urls)
        // Only the first song has to be ready to start; the rest keep preparing behind it.
        let waiting = Task { await processPending() }
        for _ in 0..<200 {
            if let track = tracks.first(where: { $0.url.standardizedFileURL == first }) {
                select(track)
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        await waiting.value
    }
}
