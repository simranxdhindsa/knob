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

        /// The same picker shows YouTube lists; their ids start with "yt:".
        var source: KnobShiftPlaylist.Source {
            playlistId.hasPrefix(KnobShiftPlaylists.youtubePrefix) ? .youtube : .spotify
        }
    }

    var spotifyAvailable: Bool { KnobShiftSpotDL.isAvailable }

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
        if playlist.source == .youtube {
            if await updateYouTubeFromGoogle(playlist) { return }
            guard let link = KnobShiftYouTubeParsing.parseLink(playlist.link) else { return }
            await readYouTube(link)
            return
        }
        await readList(query: playlist.link, id: playlist.id, kind: playlist.kind)
    }

    /// Reads a list's songs (no download) and shows them for ticking. One read at a time; Cancel
    /// stops it.
    /// How long spotDL may take over the songs after the first 100 before those 100 are used.
    private static let restOfListLimit: TimeInterval = 60

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
        var listing: KnobShiftSpotDL.Listing
        var listTitle = title
        // Playlists, albums and songs read first from Spotify's public player, with no key and no
        // login, so they work for everyone. Only Liked Songs, or a playlist longer than the
        // player shows (100 songs), goes through spotDL and the Spotify key.
        var embedded: KnobShiftSpotifyEmbed.Result?
        if kind != .liked {
            do {
                embedded = try await KnobShiftSpotifyEmbed.read(kind: kind, id: id)
            } catch is CancellationError {
                return
            } catch {
                log("SPOTIFY", "Spotify's public player could not show \(query) (\(error)); reading it through spotDL.")
            }
            guard spotifyReadJob == job else { return }
        }
        do {
            if let embedded, !embedded.truncated {
                listing = embedded.listing
                log("SPOTIFY", "Read \(listing.songs.count) song(s) from Spotify's public player, no key needed.")
            } else {
                // With the first 100 songs already in hand, waiting long for the rest isn't worth it.
                if embedded != nil {
                    spotifyStatus = "Reading the rest of \(title ?? embedded?.name ?? "the playlist"). It has more than 100 songs."
                    log("SPOTIFY", "The public player shows only the first 100 songs, so spotDL reads the rest, for at most \(Int(Self.restOfListLimit)) seconds.")
                }
                listing = try await KnobShiftSpotDL.shared.list(query, userAuth: spotifyLoggedIn, id: job,
                                                                idleLimit: embedded != nil ? Self.restOfListLimit : 900)
            }
            if listTitle == nil { listTitle = embedded?.name }
        } catch is CancellationError {
            return
        } catch let failure as KnobShiftSpotDL.Failure {
            guard spotifyReadJob == job else { return }
            // A long playlist whose full list Spotify will not give right now: its first 100 songs.
            if let embedded {
                listing = embedded.listing
                if listTitle == nil { listTitle = embedded.name }
                log("SPOTIFY", "Could not read all of \(query) (\(failure)); using the first \(listing.songs.count) songs Spotify's public player shows.")
            } else {
                spotifyStatus = failure == .privateList && spotifyLoggedIn ? "Spotify did not allow access to this list." : failure.message
                log("SPOTIFY", "Could not read \(query): \(failure).")
                return
            }
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
            case .playlist: name = listTitle ?? ordered.first?.list_name ?? "Spotify playlist"
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
        // The read may be Spotify's or YouTube's; stopping an id the other never ran does nothing.
        KnobShiftSpotDL.shared.cancel(job)
        KnobShiftYouTube.shared.cancel(job)
        youtubeHub.cancelRead?()
        spotifyStatus = "Stopped reading the list."
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
                                         folderName: KnobShiftPlaylists.folderName(for: review.name, taken: Set(playlists.map(\.folderName)),
                                                                                   source: review.playlistId.hasPrefix(KnobShiftPlaylists.youtubePrefix) ? .youtube : .spotify),
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

    /// Rows for the playlist's songs: downloaded ones are prepared, the rest wait for their
    /// download. They stay out of the queue and wait in the playlist once ready, where the
    /// Playlists view adds them. All rows are added in one change, so thousands appear without a stall.
    func addSpotifyRows(for songs: [KnobShiftSpotDL.Song], playlist: KnobShiftPlaylist, unavailable: Set<String> = []) {
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
            row.joinsQueue = false
            if files[song.song_id] == nil {
                row.waitingForDownload = true
                if unavailable.contains(song.song_id) {
                    // Not found last time: shown with Retry, not searched for again.
                    row.failure = "Not found"
                } else {
                    row.stage = "Waiting to download"
                    toDownload.append(song)
                }
            }
            rows.append(row)
        }
        if !rows.isEmpty {
            pending.append(contentsOf: rows)
            persistQueue()
        }
        if rows.count > toDownload.count { Task { await processPending() } }
        if toDownload.isEmpty {
            spotifyStatus = rows.isEmpty ? "\(playlist.name) is up to date." : "\(rows.count) song\(rows.count == 1 ? " is" : "s are") ready in \(playlist.name). Open it from Playlists to add them."
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
            if error as? KnobShiftSpotifyAccount.Problem == .rateLimited {
                spotifyStatus = KnobShiftSpotifyAccount.pausedMessage
            } else if spotifyAccount == nil {
                spotifyStatus = "Could not read your playlists. Check the internet and open this again."
            }
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
        let waiting = pending.filter { $0.playlistId == playlist.id }.count
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
        log("SPOTIFY", "Removed \(playlist.name) with \(leaving.count + waiting) song(s).")
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

    /// Checks and saves the person's own Spotify key. The login belongs to the key it was made
    /// with, so it ends and asks to be done again. Returns true when the key was saved.
    func saveSpotifyKey(id: String, secret: String) async -> Bool {
        do {
            try await KnobShiftSpotifyAccount.saveOwnKey(id: id, secret: secret)
        } catch KnobShiftSpotifyAccount.KeyProblem.wrong {
            spotifyStatus = "Spotify did not accept that Client ID and secret. Copy both again from your app's settings."
            return false
        } catch KnobShiftSpotifyAccount.KeyProblem.offline {
            spotifyStatus = KnobShiftSpotDL.Failure.offline.message
            return false
        } catch {
            spotifyStatus = "Could not save your key. Try again."
            log("SPOTIFY", "Saving the Spotify key failed: \(error).")
            return false
        }
        KnobShiftSpotDL.logOut()
        spotifyLoggedIn = false
        spotifyAccount = nil
        spotifyStatus = "Your key is saved. Log in to Spotify again to use it."
        log("SPOTIFY", "Using the person's own Spotify key now.")
        return true
    }

    /// Goes back to the shared key, which also ends the login made with the own key.
    func removeSpotifyKey() {
        do {
            try KnobShiftSpotifyAccount.removeOwnKey()
        } catch {
            spotifyStatus = "Could not remove your key. Try again."
            return
        }
        KnobShiftSpotDL.logOut()
        spotifyLoggedIn = false
        spotifyAccount = nil
        spotifyStatus = "Back on the shared key. Log in to Spotify again."
        log("SPOTIFY", "Back on the shared Spotify key.")
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
