import AVFoundation

/// What Play On needs from the player on the device the music moves to.
extension KnobShiftModel {
    /// Whether sound can really reach the output. Playing with none, as on a Mac with its lid
    /// closed, would freeze waiting for a cycle that never comes, so it's checked first.
    func outputIsWorking() async -> Bool {
        do { try startEngineIfNeeded() } catch { return false }
        let first = audioEngine.outputNode.lastRenderTime?.sampleTime
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            if let now = audioEngine.outputNode.lastRenderTime?.sampleTime, now != first { return true }
        }
        return false
    }

    /// The queue that came over, in its order, replacing this device's, as Spotify does.
    func takeQueue(_ urls: [URL]) async {
        if isPlaying { pauseOrResume() }
        removeAll()
        await addTracks(urls)
    }

    func startPlayOn(_ track: Track, at position: TimeInterval, playing: Bool) {
        guard let index = tracks.firstIndex(of: track) else { return }
        currentIndex = index
        do {
            try schedulePrimary(track, from: min(max(position, 0), track.duration), play: playing)
            if playing { scheduleNext() }
        } catch {
            log("ERROR", "Play On could not start \(track.title): \(error.localizedDescription)")
            notice = "KnobShift could not start this song."
        }
    }

    /// A playlist from another device, made here under the same id and name.
    func adoptPlaylist(id: String, name: String, link: String) -> KnobShiftPlaylist {
        let source: KnobShiftPlaylist.Source = id.hasPrefix(KnobShiftPlaylists.youtubePrefix) ? .youtube : .spotify
        let playlist = KnobShiftPlaylist(id: id, name: name, link: link, kind: .playlist,
                                         folderName: KnobShiftPlaylists.folderName(for: name, taken: Set(playlists.map(\.folderName)), source: source),
                                         spotifyOrder: [], addedAt: Date())
        playlists.append(playlist)
        savePlaylists()
        return playlist
    }

    /// A copied song joins its playlist, so it stays there after a relaunch.
    func addPlayOnSong(_ url: URL, song: KnobShiftPlayOn.Song?) {
        if let id = song?.playlist?.id, let key = song?.key, key.hasPrefix("id:"),
           let index = playlists.firstIndex(where: { $0.id == id }) ?? playlists.firstIndex(where: { $0.name == song?.playlist?.name }) {
            let songId = String(key.dropFirst(3))
            if !playlists[index].spotifyOrder.contains(songId) {
                playlists[index].spotifyOrder.append(songId)
                savePlaylists()
            }
        }
    }
}
