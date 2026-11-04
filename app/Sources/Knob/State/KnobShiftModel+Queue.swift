import Foundation

/// Shuffle and drag to reorder. The queue on screen is always the real play order, so what is
/// shown next is what plays next. Shuffle keeps the playing song first and shuffles the rest;
/// turning it off brings back the user's own order. Dragging reorders whichever order is showing.
extension KnobShiftModel {
    /// The song that plays next: the planned mix's, or simply the next one in the queue, so it
    /// shows the same whether music is playing, paused or stopped.
    var upNext: Track? {
        if let planned = nextMix?.next { return planned }
        guard tracks.count > 1 else { return nil }
        return tracks[(min(currentIndex, tracks.count - 1) + 1) % tracks.count]
    }

    func toggleShuffle() {
        if isShuffled {
            tracks = unshuffled
            unshuffled = []
            isShuffled = false
            log("QUEUE", "Shuffle off, back to your order.")
        } else {
            unshuffled = tracks
            if let playing = nowPlaying, tracks.contains(playing) {
                tracks = [playing] + tracks.filter { $0 != playing }.shuffled()
            } else {
                tracks.shuffle()
            }
            isShuffled = true
            log("QUEUE", "Shuffle on: " + tracks.map(\.name).joined(separator: ", ") + ".")
        }
        queueReordered()
    }

    /// Moves songs in the order that is showing. In shuffle the user's own order is left as it
    /// was, so turning shuffle off still restores it.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        tracks.move(fromOffsets: source, toOffset: destination)
        log("QUEUE", "Reordered: " + tracks.map(\.name).joined(separator: ", ") + ".")
        queueReordered()
    }

    /// Keeps the playing song current at its new place and plans the mix into whatever is now next.
    private func queueReordered() {
        if let playing = nowPlaying, let index = tracks.firstIndex(of: playing) {
            currentIndex = index
        }
        persistQueue()
        refreshPlanIfNeeded()
    }

    /// Removes many songs at once, ready or still preparing: a selection, or the whole queue.
    /// One change and one save, however many songs. The files stay on the Mac; a Spotify song
    /// still waiting to download is not downloaded again later.
    func remove(ids: Set<UUID>, remembers: Bool = true) {
        guard !ids.isEmpty else { return }
        if let playing = nowPlaying, ids.contains(playing.id) { stop() }
        let leaving = tracks.filter { ids.contains($0.id) }.count
        #if os(iOS)
        // Songs synced from the Mac and taken out here stay out on the next sync (emptying the
        // whole queue is not taken as not wanting them).
        if remembers {
        let leavingSongs = tracks.filter { ids.contains($0.id) }.map { ($0.playlistId, $0.spotifyId) }
            + pending.filter { ids.contains($0.id) }.map { ($0.playlistId, $0.spotifyId) }
        KnobShiftSyncPlan.decline(leavingSongs.compactMap { pair in pair.0.flatMap { p in pair.1.map { "\(p)/\($0)" } } })
        }
        #endif
        tracks.removeAll { ids.contains($0.id) }
        unshuffled.removeAll { ids.contains($0.id) }
        var skippedByPlaylist: [String: [String]] = [:]
        for song in pending where ids.contains(song.id) && song.waitingForDownload {
            if let playlistId = song.playlistId, let spotifyId = song.spotifyId {
                skippedByPlaylist[playlistId, default: []].append(spotifyId)
            }
        }
        let waiting = pending.filter { ids.contains($0.id) }.count
        pending.removeAll { ids.contains($0.id) }
        if !skippedByPlaylist.isEmpty {
            for (playlistId, songIds) in skippedByPlaylist {
                guard let index = playlists.firstIndex(where: { $0.id == playlistId }) else { continue }
                playlists[index].skipped = (playlists[index].skipped ?? []) + songIds
            }
            savePlaylists()
        }
        log("QUEUE", "Removed \(leaving) song(s) and \(waiting) still preparing.")
        currentIndex = min(currentIndex, max(0, tracks.count - 1))
        persistQueue()
        if tracks.isEmpty {
            mixState = .idle
            transitionDescription = "Add local music to begin."
        }
    }

    /// Empties the queue.
    func removeAll() {
        remove(ids: Set(tracks.map(\.id)).union(queuePending.map(\.id)), remembers: false)
    }
}
