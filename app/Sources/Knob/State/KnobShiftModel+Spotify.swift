import AppKit

/// Spotify in KnobShift: a pasted playlist, album or song, one of the user's own playlists, or
/// their Liked Songs is read from Spotify and shown with a tick box per song. The ticked songs
/// appear in the queue at once in Spotify's order and spotDL downloads them in the background
/// (KnobShiftModel+SpotifyDownload.swift). Removing a playlist keeps its files restorable for
/// 30 days.
extension KnobShiftModel {
    /// A list just read from Spotify, waiting for the user to tick the songs to add.
    struct SpotifyReview: Equatable {
        let playlistId: String
        let name: String
        let kind: KnobShiftPlaylist.Kind
        let query: String
        let songs: [KnobShiftSpotDL.Song]
        /// Songs of this list already in the queue: they stay ticked here.
        let queued: Set<String>
        /// What starts ticked: everything except songs unticked last time.
        let initial: Set<String>
        let isUpdate: Bool
    }

    var spotifyAvailable: Bool { KnobShiftSpotDL.isAvailable }

    func loadPlaylists() {
        var index = KnobShiftPlaylists.load()
        KnobShiftPlaylists.purgeExpired(&index)
        KnobShiftPlaylists.save(index)
        playlists = index.playlists
        removedPlaylists = index.removed
        spotifyLoggedIn = KnobShiftSpotDL.isLoggedIn
    }

    func savePlaylists() {
        KnobShiftPlaylists.save(KnobShiftPlaylists.Index(playlists: playlists, removed: removedPlaylists))
    }

    /// Songs of a playlist in the queue, ready or on their way.
    func songCount(in playlist: KnobShiftPlaylist) -> (ready: Int, total: Int) {
        let ready = tracks.reduce(0) { $0 + ($1.playlistId == playlist.id ? 1 : 0) }
        let waiting = pending.reduce(0) { $0 + ($1.playlistId == playlist.id ? 1 : 0) }
        return (ready, ready + waiting)
    }

    /// Spotify ids already in the queue, ready or on their way; one pass, so checking thousands
    /// of songs stays instant.
    func queuedSpotifyIds(in playlistId: String? = nil) -> Set<String> {
        var ids = Set<String>()
        for track in tracks where playlistId == nil || track.playlistId == playlistId {
            if let id = track.spotifyId { ids.insert(id) }
        }
        for song in pending where playlistId == nil || song.playlistId == playlistId {
            if let id = song.spotifyId { ids.insert(id) }
        }
        return ids
    }

    // MARK: Reading a list

    func addFromSpotify(_ text: String) async {
        guard spotifyAvailable else { spotifyStatus = KnobShiftSpotDL.Failure.unavailable.message; return }
        guard let link = KnobShiftPlaylists.parseLink(text) else {
            spotifyStatus = "Paste a Spotify playlist, album or song link."
            return
        }
        await readList(query: link.link, id: link.id, kind: link.kind)
    }

    func addLikedSongs() async {
        guard spotifyLoggedIn else { spotifyStatus = "Log in to Spotify to add your Liked Songs."; return }
        await readList(query: "saved", id: "liked", kind: .liked)
    }

    func addAccountPlaylist(_ playlist: KnobShiftSpotifyAccount.Playlist) async {
        await readList(query: playlist.link, id: playlist.id, kind: .playlist)
    }

    func updatePlaylist(_ playlist: KnobShiftPlaylist) async {
        await readList(query: playlist.link, id: playlist.id, kind: playlist.kind)
    }

    /// Reads a list's songs (no download) and shows them for ticking. One read at a time; Cancel
    /// stops it.
    private func readList(query: String, id: String, kind: KnobShiftPlaylist.Kind) async {
        guard spotifyReadJob == nil, spotifyLoginJob == nil else {
            spotifyStatus = "Spotify is still busy with the last step. Cancel it or wait for it to finish."
            return
        }
        let job = UUID()
        spotifyReadJob = job
        spotifyBusy = true
        spotifyReview = nil
        let title = playlists.first { $0.id == id }?.name ?? spotifyAccount?.playlists.first { $0.id == id }?.name
        spotifyStatus = kind == .liked
            ? "Reading your Liked Songs. Long lists take a few minutes."
            : "Reading \(title ?? "the songs") from Spotify."
        log("SPOTIFY", "Reading \(query) from Spotify.")
        defer {
            if spotifyReadJob == job {
                spotifyReadJob = nil
                spotifyBusy = false
            }
        }
        let listing: KnobShiftSpotDL.Listing
        do {
            listing = try await KnobShiftSpotDL.shared.list(query, userAuth: spotifyLoggedIn, id: job)
        } catch is CancellationError {
            return
        } catch let failure as KnobShiftSpotDL.Failure {
            guard spotifyReadJob == job else { return }
            spotifyStatus = failure == .privateList && spotifyLoggedIn ? "Spotify did not allow access to this list." : failure.message
            log("SPOTIFY", "Could not read \(query): \(failure).")
            return
        } catch {
            guard spotifyReadJob == job else { return }
            spotifyStatus = KnobShiftSpotDL.Failure.failed.message
            return
        }
        guard spotifyReadJob == job else { return }

        let ordered = listing.songs.enumerated()
            .sorted { ($0.element.list_position ?? $0.offset) < ($1.element.list_position ?? $1.offset) }
            .map(\.element)
        spotifyRaw[id, default: [:]].merge(listing.raw) { _, new in new }
        let existing = playlists.first { $0.id == id }
        let queued = queuedSpotifyIds(in: id)
        let name: String
        if let existing {
            name = existing.name
        } else {
            switch kind {
            case .liked: name = "Liked Songs"
            case .album: name = ordered.first?.album_name ?? "Spotify album"
            case .song: name = ordered.first.map { "\($0.name) by \($0.artist)" } ?? "Spotify song"
            case .playlist: name = title ?? ordered.first?.list_name ?? "Spotify playlist"
            }
        }
        let initial = KnobShiftImport.initialSelection(songs: ordered, skipped: Set(existing?.skipped ?? [])).union(queued)
        spotifyReview = SpotifyReview(playlistId: id, name: name, kind: kind, query: query, songs: ordered,
                                      queued: queued, initial: initial, isUpdate: existing != nil)
        spotifyStatus = nil
        log("SPOTIFY", "\(name): \(ordered.count) song(s) read, \(queued.count) already in the queue.")
    }

    func cancelSpotifyRead() {
        guard let job = spotifyReadJob else { return }
        spotifyReadJob = nil
        spotifyBusy = false
        KnobShiftSpotDL.shared.cancel(job)
        spotifyStatus = "Stopped reading from Spotify."
        log("SPOTIFY", "Reading cancelled.")
    }

    func dismissSpotifyReview() {
        spotifyReview = nil
    }

    /// Adds the ticked songs: they show in the queue at once in Spotify's order, songs already
    /// on the Mac go straight to preparing, and the rest are downloaded.
    func confirmSpotifyReview(selected: Set<String>) {
        guard let review = spotifyReview else { return }
        spotifyReview = nil
        let chosen = selected.union(review.queued)
        let skipped = KnobShiftImport.skipped(songs: review.songs, selected: chosen, queued: review.queued)
        var playlist: KnobShiftPlaylist
        if let index = playlists.firstIndex(where: { $0.id == review.playlistId }) {
            playlists[index].spotifyOrder = review.songs.map(\.song_id)
            playlists[index].skipped = skipped
            playlist = playlists[index]
        } else {
            playlist = KnobShiftPlaylist(id: review.playlistId, name: review.name, link: review.query, kind: review.kind,
                                         folderName: KnobShiftPlaylists.folderName(for: review.name, taken: Set(playlists.map(\.folderName))),
                                         spotifyOrder: review.songs.map(\.song_id), addedAt: Date(), skipped: skipped)
            playlists.append(playlist)
        }
        savePlaylists()
        let wanted = review.songs.filter { chosen.contains($0.song_id) }
        // The chosen songs are kept on disk, so downloads continue after a relaunch.
        try? KnobShiftSpotDL.writeSaveFile(wanted.map(\.song_id), raw: spotifyRaw[playlist.id] ?? [:],
                                           to: KnobShiftPlaylists.songsFile(for: playlist))
        log("SPOTIFY", "\(playlist.name): \(wanted.count) of \(review.songs.count) song(s) ticked.")
        addSpotifyRows(for: wanted, playlist: playlist)
    }

    /// Queue rows for songs not in the queue yet: downloaded ones are prepared, the rest wait for
    /// their download. All rows are added in one change, so thousands appear without a stall.
    func addSpotifyRows(for songs: [KnobShiftSpotDL.Song], playlist: KnobShiftPlaylist) {
        let folder = KnobShiftPlaylists.folder(for: playlist)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = KnobShiftPlaylists.files(in: folder)
        let fresh = KnobShiftImport.newRows(songs: songs, selected: Set(songs.map(\.song_id)), queued: queuedSpotifyIds())
        var rows: [PendingSong] = []
        var toDownload: [KnobShiftSpotDL.Song] = []
        for song in fresh {
            var row = PendingSong(url: files[song.song_id] ?? folder.appendingPathComponent("\(song.song_id).pending"))
            row.spotifyId = song.song_id
            row.playlistId = playlist.id
            row.spotifyName = song.name
            row.spotifyArtist = song.artists.joined(separator: ", ")
            if files[song.song_id] == nil {
                row.waitingForDownload = true
                row.stage = "Waiting to download"
                toDownload.append(song)
            }
            rows.append(row)
        }
        if !rows.isEmpty {
            pending.append(contentsOf: rows)
            persistQueue()
        }
        if rows.count > toDownload.count { Task { await processPending() } }
        if toDownload.isEmpty {
            spotifyStatus = rows.isEmpty ? "\(playlist.name) is up to date." : "Added \(rows.count) song\(rows.count == 1 ? "" : "s") from \(playlist.name)."
        } else {
            enqueueDownload(playlist, songs: toDownload)
        }
    }

    // MARK: Account

    /// Reads the account's name and playlists for the sheet. Quietly keeps the last list when
    /// Spotify cannot be reached.
    func loadSpotifyAccount() async {
        guard spotifyLoggedIn, !spotifyAccountLoading else { return }
        spotifyAccountLoading = true
        defer { spotifyAccountLoading = false }
        do {
            let account = try await KnobShiftSpotifyAccount.load()
            spotifyAccount = account
            log("SPOTIFY", "Account \(account.name ?? "unnamed"): \(account.playlists.count) playlist(s).")
        } catch KnobShiftSpotifyAccount.Problem.loggedOut {
            KnobShiftSpotDL.logOut()
            spotifyLoggedIn = false
            spotifyAccount = nil
            spotifyStatus = "Your Spotify login ran out. Log in again."
        } catch {
            log("SPOTIFY", "Could not read the account's playlists: \(error).")
            if spotifyAccount == nil { spotifyStatus = "Could not read your playlists. Check the internet and open this again." }
        }
    }

    // MARK: Removing and restoring

    /// Stops its download, takes its songs out of the queue and keeps its folder restorable for
    /// 30 days. The confirmation is asked by the view first.
    func removePlaylist(_ playlist: KnobShiftPlaylist) {
        cancelDownload(playlist, quietly: true)
        if let playing = nowPlaying, playing.playlistId == playlist.id { stop() }
        let leaving = tracks.filter { $0.playlistId == playlist.id }
        for track in leaving { remove(track) }
        pending.removeAll { $0.playlistId == playlist.id }
        spotifyRaw[playlist.id] = nil
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
        guard !playlists.contains(where: { $0.id == removed.playlist.id }) else {
            spotifyStatus = "\(removed.playlist.name) is already in the queue. Remove it first to restore the old one."
            return
        }
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

    // MARK: Spotify login

    /// spotDL opens Spotify's login page in the browser and keeps the token in its own home.
    /// Login ends the moment the token arrives, and Knob comes back to the front.
    func logInToSpotify() async {
        guard spotifyAvailable, spotifyReadJob == nil, spotifyLoginJob == nil else { return }
        let job = UUID()
        spotifyLoginJob = job
        spotifyStatus = "Finish logging in to Spotify in your browser."
        log("SPOTIFY", "Logging in to Spotify.")
        let loggedIn = await KnobShiftSpotDL.shared.logIn(id: job)
        guard spotifyLoginJob == job else { return }
        spotifyLoginJob = nil
        spotifyLoggedIn = loggedIn
        spotifyStatus = loggedIn ? "Logged in to Spotify." : "Spotify login did not finish. Try again."
        log("SPOTIFY", loggedIn ? "Logged in to Spotify." : "Spotify login did not finish.")
        if loggedIn {
            NSApp.activate(ignoringOtherApps: true)
            await loadSpotifyAccount()
        }
    }

    func cancelSpotifyLogin() {
        guard let job = spotifyLoginJob else { return }
        spotifyLoginJob = nil
        KnobShiftSpotDL.shared.cancel(job)
        spotifyStatus = nil
        log("SPOTIFY", "Spotify login cancelled.")
    }

    func logOutOfSpotify() {
        KnobShiftSpotDL.logOut()
        spotifyLoggedIn = false
        spotifyAccount = nil
        spotifyStatus = "Logged out of Spotify."
        log("SPOTIFY", "Logged out of Spotify.")
    }

    func showSpotifyPreviewForSnapshot() {
        spotifyLoggedIn = true
        spotifyAccount = KnobShiftSpotifyAccount.Account(name: "Simran", playlists: [
            .init(id: "a1", name: "Punjabi Road Trip", songs: 18, owner: "Simran"),
            .init(id: "a2", name: "Late Night Drive", songs: 42, owner: "Simran"),
            .init(id: "a3", name: "Gym Bangers", songs: 1_204, owner: "Spotify"),
        ])
        playlists = [KnobShiftPlaylist(id: "a1", name: "Punjabi Road Trip", link: "", kind: .playlist,
                                       folderName: "Punjabi Road Trip", spotifyOrder: [], addedAt: Date())]
        var progress = KnobShiftImport.Progress(songs: Self.previewSongs(["Sardaari", "Kya Baat Aa", "Bodyguard", "Lalkaara"]))
        progress.started = true
        _ = progress.consume(#"Downloaded "Artist - Sardaari": u"#)
        spotifyProgress["a1"] = progress
    }

    /// Screenshot only: the song picker for a list, with two songs already in the queue.
    func showSpotifyPickerForSnapshot() {
        let songs = Self.previewSongs(["Sardaari", "Kya Baat Aa", "Bodyguard", "Lalkaara", "Ghaint", "Jee Karuga (feat. Sargi Maan)",
                                       "Why So", "No Luck", "Shaukeen", "Daaru Sasti", "Ghostface Killah", "Majhail", "Khayaal"])
        let queued: Set<String> = [songs[0].song_id, songs[1].song_id]
        spotifyReview = SpotifyReview(playlistId: "a2", name: "Late Night Drive", kind: .playlist, query: "", songs: songs,
                                      queued: queued, initial: Set(songs.map(\.song_id)).subtracting([songs[4].song_id]), isUpdate: true)
    }
}
