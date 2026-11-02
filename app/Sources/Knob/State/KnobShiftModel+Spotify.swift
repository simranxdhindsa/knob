import Foundation

/// Spotify in KnobShift: a pasted playlist, album or song (or the user's Liked Songs) is read
/// from Spotify, its songs appear in the queue at once in Spotify's order, and spotDL downloads
/// them in the background into one folder per playlist. Each song is prepared and mixed like any
/// other as soon as its file lands. Removing a playlist keeps its files restorable for 30 days.
extension KnobShiftModel {
    var spotifyAvailable: Bool { KnobShiftSpotDL.isAvailable }

    func loadPlaylists() {
        var index = KnobShiftPlaylists.load()
        KnobShiftPlaylists.purgeExpired(&index)
        KnobShiftPlaylists.save(index)
        playlists = index.playlists
        removedPlaylists = index.removed
        spotifyLoggedIn = KnobShiftSpotDL.isLoggedIn
    }

    private func savePlaylists() {
        KnobShiftPlaylists.save(KnobShiftPlaylists.Index(playlists: playlists, removed: removedPlaylists))
    }

    /// Songs of a playlist in the queue, ready or on their way.
    func songCount(in playlist: KnobShiftPlaylist) -> (ready: Int, total: Int) {
        let ready = tracks.filter { $0.playlistId == playlist.id }.count
        return (ready, ready + pending.filter { $0.playlistId == playlist.id }.count)
    }

    func isDownloading(_ playlist: KnobShiftPlaylist) -> Bool { spotifyJobs[playlist.id] != nil }

    // MARK: Adding

    func addFromSpotify(_ text: String) async {
        guard spotifyAvailable else { spotifyStatus = KnobShiftSpotDL.Failure.unavailable.message; return }
        guard let link = KnobShiftPlaylists.parseLink(text) else {
            spotifyStatus = "Paste a Spotify playlist, album or song link."
            return
        }
        await importList(query: link.link, id: link.id, kind: link.kind)
    }

    func addLikedSongs() async {
        guard spotifyLoggedIn else { spotifyStatus = "Log in to Spotify to add your Liked Songs."; return }
        await importList(query: "saved", id: "liked", kind: .liked)
    }

    func updatePlaylist(_ playlist: KnobShiftPlaylist) async {
        await importList(query: playlist.link, id: playlist.id, kind: playlist.kind)
    }

    private func importList(query: String, id: String, kind: KnobShiftPlaylist.Kind) async {
        guard !spotifyBusy else { return }
        spotifyBusy = true
        defer { spotifyBusy = false }
        spotifyStatus = "Reading the songs from Spotify"
        log("SPOTIFY", "Reading \(query) from Spotify.")
        let songs: [KnobShiftSpotDL.Song]
        do {
            songs = try await KnobShiftSpotDL.shared.list(query, userAuth: spotifyLoggedIn)
        } catch let failure as KnobShiftSpotDL.Failure {
            spotifyStatus = failure == .privateList && spotifyLoggedIn ? "Spotify did not allow access to this list." : failure.message
            log("SPOTIFY", "Could not read \(query): \(failure).")
            return
        } catch {
            spotifyStatus = KnobShiftSpotDL.Failure.failed.message
            return
        }
        let ordered = songs.enumerated()
            .sorted { ($0.element.list_position ?? $0.offset) < ($1.element.list_position ?? $1.offset) }
            .map(\.element)

        var playlist: KnobShiftPlaylist
        if let index = playlists.firstIndex(where: { $0.id == id }) {
            playlists[index].spotifyOrder = ordered.map(\.song_id)
            playlist = playlists[index]
        } else {
            let name: String
            switch kind {
            case .liked: name = "Liked Songs"
            case .album: name = ordered.first?.album_name ?? "Spotify album"
            case .song: name = ordered.first.map { "\($0.name) by \($0.artist)" } ?? "Spotify song"
            case .playlist: name = ordered.first?.list_name ?? "Spotify playlist"
            }
            let taken = Set(playlists.map(\.folderName))
            playlist = KnobShiftPlaylist(id: id, name: name, link: query, kind: kind,
                                         folderName: KnobShiftPlaylists.folderName(for: name, taken: taken),
                                         spotifyOrder: ordered.map(\.song_id), addedAt: Date())
            playlists.append(playlist)
        }
        savePlaylists()
        log("SPOTIFY", "\(playlist.name): \(ordered.count) song(s) in Spotify's order.")

        // Every song shows in the queue at once; ones already downloaded go straight to
        // preparing, the rest wait for their file.
        let folder = KnobShiftPlaylists.folder(for: playlist)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = KnobShiftPlaylists.files(in: folder)
        var waiting = 0
        for song in ordered where !isQueued(spotifyId: song.song_id) {
            var row = PendingSong(url: files[song.song_id] ?? folder.appendingPathComponent("\(song.song_id).pending"))
            row.spotifyId = song.song_id
            row.playlistId = playlist.id
            row.spotifyName = song.name
            row.spotifyArtist = song.artists.joined(separator: ", ")
            if files[song.song_id] == nil {
                row.waitingForDownload = true
                row.stage = "Waiting to download"
                waiting += 1
            }
            pending.append(row)
        }
        persistQueue()
        Task { await processPending() }
        if waiting > 0 {
            spotifyStatus = "Downloading \(waiting) song\(waiting == 1 ? "" : "s") from \(playlist.name)."
            startDownload(playlist)
        } else {
            spotifyStatus = "\(playlist.name) is up to date."
        }
    }

    private func isQueued(spotifyId: String) -> Bool {
        tracks.contains { $0.spotifyId == spotifyId } || pending.contains { $0.spotifyId == spotifyId }
    }

    // MARK: Downloading

    private func startDownload(_ playlist: KnobShiftPlaylist) {
        guard spotifyJobs[playlist.id] == nil else { return }
        let job = UUID()
        spotifyJobs[playlist.id] = job
        setStage("Downloading", for: playlist.id)
        let folder = KnobShiftPlaylists.folder(for: playlist)
        log("SPOTIFY", "Downloading \(playlist.name) into \(folder.path).")
        let userAuth = spotifyLoggedIn
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.spotifyLine(line, playlistId: playlist.id) }
        }
        Task { [weak self] in
            let status = await KnobShiftSpotDL.shared.download(playlist.link, into: folder, userAuth: userAuth, id: job, onLine: onLine)
            await MainActor.run { self?.downloadFinished(playlist, job: job, status: status) }
        }
    }

    private func spotifyLine(_ line: String, playlistId: String) {
        log("SPOTIFY", line)
        if line.contains("Downloaded \"") || line.contains("Skipping ") { collectDownloads(playlistId) }
        // spotDL names songs "Artist - Name" in its messages.
        if let range = line.range(of: "No results found for song: ") {
            let display = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let index = pending.firstIndex(where: {
                $0.playlistId == playlistId && $0.waitingForDownload
                    && display == "\($0.spotifyArtist?.components(separatedBy: ", ").first ?? "") - \($0.spotifyName ?? "")"
            }) {
                pending[index].failure = "Not found"
                pending[index].stage = nil
            }
        }
    }

    /// Hands every finished file of a playlist to the queue, which prepares it.
    private func collectDownloads(_ playlistId: String) {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        let files = KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist))
        var landed = 0
        for index in pending.indices where pending[index].playlistId == playlistId && pending[index].waitingForDownload {
            guard let id = pending[index].spotifyId, let file = files[id] else { continue }
            pending[index].url = file
            pending[index].waitingForDownload = false
            pending[index].failure = nil
            pending[index].stage = nil
            landed += 1
        }
        guard landed > 0 else { return }
        persistQueue()
        Task { await processPending() }
    }

    private func downloadFinished(_ playlist: KnobShiftPlaylist, job: UUID, status: Int32) {
        guard spotifyJobs[playlist.id] == job else { return }
        spotifyJobs[playlist.id] = nil
        collectDownloads(playlist.id)
        var missing = 0
        for index in pending.indices where pending[index].playlistId == playlist.id && pending[index].waitingForDownload {
            pending[index].failure = "Not found"
            pending[index].stage = nil
            missing += 1
        }
        spotifyStatus = missing == 0
            ? "\(playlist.name) is downloaded."
            : "\(playlist.name) is downloaded, \(missing) song\(missing == 1 ? "" : "s") could not be found. Retry them from the queue."
        log("SPOTIFY", "Download of \(playlist.name) finished with status \(status), \(missing) song(s) missing.")
    }

    private func setStage(_ stage: String, for playlistId: String) {
        for index in pending.indices where pending[index].playlistId == playlistId && pending[index].waitingForDownload {
            pending[index].stage = stage
        }
    }

    /// Retry for a Spotify song that could not be found or downloaded.
    func retryDownload(_ song: PendingSong) {
        guard let id = song.spotifyId, let playlistId = song.playlistId,
              let playlist = playlists.first(where: { $0.id == playlistId }),
              let index = pending.firstIndex(where: { $0.id == song.id }) else { return }
        pending[index].failure = nil
        pending[index].stage = "Downloading"
        let folder = KnobShiftPlaylists.folder(for: playlist)
        let job = UUID()
        log("SPOTIFY", "Retrying \(song.name).")
        let userAuth = spotifyLoggedIn
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.log("SPOTIFY", line) }
        }
        Task { [weak self] in
            _ = await KnobShiftSpotDL.shared.downloadSong(id, into: folder, userAuth: userAuth, id: job, onLine: onLine)
            await MainActor.run {
                guard let self else { return }
                self.collectDownloads(playlistId)
                if let row = self.pending.firstIndex(where: { $0.id == song.id }), self.pending[row].waitingForDownload {
                    self.pending[row].failure = "Not found"
                    self.pending[row].stage = nil
                }
            }
        }
    }

    // MARK: Removing and restoring

    /// Stops its download, takes its songs out of the queue and keeps its folder restorable for
    /// 30 days. The confirmation is asked by the view first.
    func removePlaylist(_ playlist: KnobShiftPlaylist) {
        if let job = spotifyJobs[playlist.id] {
            KnobShiftSpotDL.shared.cancel(job)
            spotifyJobs[playlist.id] = nil
        }
        if let playing = nowPlaying, playing.playlistId == playlist.id { stop() }
        let leaving = tracks.filter { $0.playlistId == playlist.id }
        for track in leaving { remove(track) }
        pending.removeAll { $0.playlistId == playlist.id }
        do {
            let removed = try KnobShiftPlaylists.moveToRemoved(playlist)
            removedPlaylists.insert(removed, at: 0)
            spotifyStatus = "\(playlist.name) removed. You can restore it for 30 days."
        } catch {
            spotifyStatus = "\(playlist.name) was taken out of the queue, but its files could not be moved."
            log("ERROR", "Could not move \(playlist.name): \(error.localizedDescription)")
        }
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
        persistQueue()
        log("SPOTIFY", "Removed \(playlist.name) with \(leaving.count) song(s).")
    }

    func restorePlaylist(_ removed: KnobShiftRemovedPlaylist) async {
        do {
            let playlist = try KnobShiftPlaylists.restore(removed, taken: Set(playlists.map(\.folderName)))
            playlists.append(playlist)
            removedPlaylists.removeAll { $0 == removed }
            savePlaylists()
            let files = KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist))
            let ordered = playlist.spotifyOrder.compactMap { files[$0] }
            log("SPOTIFY", "Restored \(playlist.name) with \(ordered.count) song(s).")
            spotifyStatus = "\(playlist.name) is back in the queue."
            await addTracks(ordered)
        } catch {
            spotifyStatus = "\(removed.playlist.name) could not be restored."
            log("ERROR", "Restore failed: \(error.localizedDescription)")
        }
    }

    func deleteRemovedPlaylist(_ removed: KnobShiftRemovedPlaylist) {
        KnobShiftPlaylists.deleteForGood(removed)
        removedPlaylists.removeAll { $0 == removed }
        savePlaylists()
        log("SPOTIFY", "Deleted \(removed.playlist.name) for good.")
    }

    func showSpotifyPreviewForSnapshot() {
        spotifyLoggedIn = true
        spotifyBusy = true
        spotifyStatus = "Downloading 18 songs from Punjabi Road Trip."
    }

    // MARK: Spotify login

    /// spotDL opens Spotify's login page in the browser and keeps the token in its own home.
    func logInToSpotify() async {
        guard spotifyAvailable, !spotifyBusy else { return }
        spotifyBusy = true
        defer { spotifyBusy = false }
        spotifyStatus = "Finish logging in to Spotify in your browser."
        log("SPOTIFY", "Logging in to Spotify.")
        _ = try? await KnobShiftSpotDL.shared.list("saved", userAuth: true)
        spotifyLoggedIn = KnobShiftSpotDL.isLoggedIn
        spotifyStatus = spotifyLoggedIn ? "Logged in to Spotify." : "Spotify login did not finish. Try again."
    }

    func logOutOfSpotify() {
        KnobShiftSpotDL.logOut()
        spotifyLoggedIn = false
        spotifyStatus = "Logged out of Spotify."
        log("SPOTIFY", "Logged out of Spotify.")
    }
}
