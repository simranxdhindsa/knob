import Foundation

/// YouTube in KnobShift: a pasted video, playlist or YouTube Music album is read with yt-dlp and
/// shown in the same song picker as a Spotify list. The ticked songs join the queue at once in the
/// list's order and download in the background, one at a time with a short pause between them,
/// in the same lane as Spotify downloads (spotDL downloads from YouTube too). A video that is gone,
/// private or blocked is searched by its artist and name. Everything after the picker (queue rows,
/// progress, update, remove and restore, resume after a relaunch) is the Spotify code.
extension KnobShiftModel {
    typealias YouTubeFailure = KnobShiftYouTubeParsing.Failure

    var youtubeAvailable: Bool { KnobShiftYouTube.isAvailable }

    // MARK: Reading a list

    func addFromYouTube(_ text: String) async {
        guard youtubeAvailable else { spotifyStatus = YouTubeFailure.missingHelper.message; return }
        guard let link = KnobShiftYouTubeParsing.parseLink(text) else {
            spotifyStatus = "Paste a YouTube video, playlist or album link."
            return
        }
        if link.kind == .liked, !youtubeSignedIn {
            spotifyStatus = "Sign in to YouTube to add your Liked videos."
            return
        }
        await readYouTube(link)
    }

    /// Reads a link's songs (no download) and shows them for ticking. One read at a time, shared
    /// with Spotify; Cancel stops it.
    func readYouTube(_ link: KnobShiftYouTubeParsing.Link) async {
        guard spotifyReadJob == nil, spotifyLoginJob == nil, !youtubeSigningIn else {
            spotifyStatus = "Still busy with the last step. Cancel it or wait for it to finish."
            return
        }
        let job = UUID()
        spotifyReadJob = job
        spotifyBusy = true
        spotifyReview = nil
        let existing = playlists.first { $0.id == link.id }
        spotifyStatus = "Reading \(existing?.name ?? "the songs") from YouTube."
        log("YOUTUBE", "Reading \(link.url) from YouTube\(youtubeSignedIn ? ", signed in" : "").")
        defer {
            if spotifyReadJob == job {
                spotifyReadJob = nil
                spotifyBusy = false
            }
        }
        let read: KnobShiftYouTubeParsing.Read
        do {
            read = try await KnobShiftYouTube.shared.list(link, id: job)
        } catch is CancellationError {
            return
        } catch let failure as YouTubeFailure {
            guard spotifyReadJob == job else { return }
            log("YOUTUBE", "Could not read \(link.url): \(failure).")
            if failure == .signInExpired { signOutOfYouTube(expired: true) } else { spotifyStatus = failure.message }
            return
        } catch {
            guard spotifyReadJob == job else { return }
            spotifyStatus = YouTubeFailure.failed.message
            return
        }
        guard spotifyReadJob == job else { return }

        let songs = read.listing.songs
        spotifyRaw[link.id, default: [:]].merge(read.listing.raw) { _, new in new }
        let queued = queuedSpotifyIds(in: link.id)
        let name = existing?.name ?? read.name ?? (link.kind == .liked ? "Liked videos" : "YouTube playlist")
        let initial = KnobShiftImport.initialSelection(songs: songs, skipped: Set(existing?.skipped ?? [])).union(queued)
        spotifyReview = SpotifyReview(playlistId: link.id, name: name, kind: link.kind, query: link.url, songs: songs,
                                      queued: queued, initial: initial, isUpdate: existing != nil)
        spotifyStatus = read.skipped == 0 ? nil
            : "\(read.skipped) video\(read.skipped == 1 ? " was" : "s were") left out because \(read.skipped == 1 ? "it is" : "they are") private, deleted or for members only."
        log("YOUTUBE", "\(name): \(songs.count) song(s) read, \(read.skipped) left out, \(queued.count) already in the queue.")
    }

    // MARK: Downloading

    /// Downloads a YouTube playlist's songs one at a time, inside the download lane (runDownload).
    /// A bot check, no internet or a full disk stops the rest, since every song would fail the same way.
    func runYouTubeDownload(_ playlist: KnobShiftPlaylist, songs fetch: [KnobShiftSpotDL.Song]) async {
        let folder = KnobShiftPlaylists.folder(for: playlist)
        // One id for the whole run: each song's yt-dlp runs under it, so Cancel stops whichever is running.
        let job = UUID()
        spotifyJobs[playlist.id] = job
        log("YOUTUBE", "Downloading \(fetch.count) song(s) of \(playlist.name) into \(folder.path)\(youtubeSignedIn ? ", signed in" : "").")
        var stoppedBy: YouTubeFailure?
        var missing = 0
        for (index, song) in fetch.enumerated() {
            guard spotifyJobs[playlist.id] == job else { return }
            // Songs taken out of the queue meanwhile are not downloaded.
            guard pending.contains(where: { $0.playlistId == playlist.id && $0.spotifyId == song.song_id
                && $0.waitingForDownload && $0.failure == nil }) else { continue }
            let problem = await downloadYouTubeSong(song, into: folder, playlist: playlist, job: job)
            guard spotifyJobs[playlist.id] == job else { return }
            if let problem {
                downloadProgress[playlist.id]?.markMissing(song.song_id)
                markRows(of: playlist.id, ids: [song.song_id], failure: problem.rowText)
                missing += 1
                if [.botCheck, .offline, .noSpace, .signInExpired].contains(problem) {
                    stoppedBy = problem
                    break
                }
            } else {
                downloadProgress[playlist.id]?.markLanded(song.song_id)
                collectSoon(playlist.id)
            }
            publishProgressSoon()
            // A short, uneven pause between songs, so YouTube is not asked too fast.
            if index < fetch.count - 1 { try? await Task.sleep(for: .seconds(Double.random(in: 2...4))) }
        }
        guard spotifyJobs[playlist.id] == job else { return }
        spotifyJobs[playlist.id] = nil
        if let stoppedBy {
            let left = Set(fetch.map(\.song_id))
            markRows(of: playlist.id, ids: left, failure: stoppedBy.rowText)
            missing = pending.reduce(0) { $0 + ($1.playlistId == playlist.id && $1.failure != nil && left.contains($1.spotifyId ?? "") ? 1 : 0) }
            if stoppedBy == .signInExpired { signOutOfYouTube(expired: true) }
            spotifyStatus = "\(playlist.name) stopped early: \(stoppedBy.message)"
        } else {
            spotifyStatus = missing == 0
                ? "\(playlist.name) is downloaded."
                : "\(playlist.name) is downloaded. \(missing) song\(missing == 1 ? "" : "s") could not be found. Retry them from the queue."
        }
        await collectDownloads(playlist.id, finishedOnly: false)
        finishProgress(playlist.id)
        log("YOUTUBE", "Download of \(playlist.name) finished, \(missing) song(s) missing\(stoppedBy.map { " (\($0))" } ?? "").")
    }

    /// Retry for one YouTube song, in the retry lane (runRetry).
    func runYouTubeRetry(songId: String, playlist: KnobShiftPlaylist) async {
        guard let song = songs(for: playlist).first(where: { $0.song_id == songId }) else {
            markRows(of: playlist.id, ids: [songId], failure: YouTubeFailure.unavailable.rowText)
            return
        }
        let problem = await downloadYouTubeSong(song, into: KnobShiftPlaylists.folder(for: playlist), playlist: playlist, job: UUID())
        await collectDownloads(playlist.id, finishedOnly: false)
        if let problem { markRows(of: playlist.id, ids: [songId], failure: problem.rowText) }
    }

    /// Downloads one song; nil when its file is there. A video YouTube will not give (gone,
    /// private, blocked in this country, or needing a sign in that is missing) is searched by
    /// artist and name, and the closest match is saved in its place.
    private func downloadYouTubeSong(_ song: KnobShiftSpotDL.Song, into folder: URL, playlist: KnobShiftPlaylist,
                                     job: UUID) async -> YouTubeFailure? {
        setStage("Downloading", for: playlist.id, ids: [song.song_id])
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            // Progress lines arrive many times a second; the log keeps the rest.
            guard !(line.hasPrefix("[download]") && line.contains("%")) else { return }
            Task { @MainActor in self?.log("YOUTUBE", line) }
        }
        var result = await KnobShiftYouTube.shared.download(song, into: folder, search: false, id: job, onLine: onLine)
        if result.cancelled { return .stalled }
        if KnobShiftPlaylists.files(in: folder)[song.song_id] != nil { return nil }
        var problem = result.stalled ? .stalled : KnobShiftYouTubeParsing.classify(result.lines) ?? .failed
        guard [.unavailable, .privateVideo, .ageRestricted, .failed].contains(problem) else { return problem }
        log("YOUTUBE", "\(song.name) is not available (\(problem)); searching YouTube for \(song.artist) \(song.name).")
        setStage("Finding", for: playlist.id, ids: [song.song_id])
        result = await KnobShiftYouTube.shared.download(song, into: folder, search: true, id: job, onLine: onLine)
        if result.cancelled { return .stalled }
        if KnobShiftPlaylists.files(in: folder)[song.song_id] != nil {
            log("YOUTUBE", "Found another upload of \(song.name).")
            return nil
        }
        problem = result.stalled ? .stalled : KnobShiftYouTubeParsing.classify(result.lines) ?? .unavailable
        return problem == .failed ? .unavailable : problem
    }

    // MARK: Signing in

    /// Copies the YouTube sign in from the browser the person picked. One step at a time, like
    /// reading a list.
    func signInToYouTube(with browser: KnobShiftYouTube.Browser) async {
        guard youtubeAvailable, !youtubeSigningIn, spotifyReadJob == nil else { return }
        youtubeSigningIn = true
        defer { youtubeSigningIn = false }
        spotifyStatus = browser.id == "safari"
            ? "Reading your YouTube sign in from Safari."
            : "Reading your YouTube sign in from \(browser.name). If macOS asks, choose Allow."
        log("YOUTUBE", "Signing in with \(browser.name).")
        do {
            try await KnobShiftYouTube.shared.signIn(with: browser, id: UUID())
            youtubeSignedIn = true
            spotifyStatus = "Signed in to YouTube with \(browser.name). Liked videos and private playlists can be added now."
            log("YOUTUBE", "Signed in to YouTube with \(browser.name).")
        } catch is CancellationError {
            spotifyStatus = nil
        } catch let problem as KnobShiftYouTubeParsing.SignInProblem {
            spotifyStatus = problem.message(browser.name)
            log("YOUTUBE", "Signing in with \(browser.name) did not work: \(problem).")
        } catch {
            spotifyStatus = KnobShiftYouTubeParsing.SignInProblem.failed.message(browser.name)
            log("YOUTUBE", "Signing in with \(browser.name) did not work: \(error.localizedDescription)")
        }
    }

    func signOutOfYouTube(expired: Bool = false) {
        KnobShiftYouTube.signOut()
        youtubeSignedIn = false
        spotifyStatus = expired ? YouTubeFailure.signInExpired.message : "Signed out of YouTube. Knob's copy of the sign in is deleted."
        log("YOUTUBE", expired ? "The YouTube sign in ran out; signed out." : "Signed out of YouTube.")
    }

    // MARK: Snapshots

    /// Screenshot only: signed in, with a YouTube playlist downloading.
    func showYouTubePreviewForSnapshot() {
        youtubeSignedIn = true
        let id = KnobShiftPlaylists.youtubePrefix + "PLroad"
        playlists = [KnobShiftPlaylist(id: id, name: "Punjabi Hits 2026", link: "", kind: .playlist,
                                       folderName: "Punjabi Hits 2026", spotifyOrder: [], addedAt: Date())]
        var progress = KnobShiftImport.Progress(songs: Self.previewSongs(["Kya Baat Aa", "Sardaari", "Bodyguard", "Lalkaara"]))
        progress.started = true
        progress.markLanded(Self.previewSongs(["Kya Baat Aa"])[0].song_id)
        spotifyProgress[id] = progress
        spotifyStatus = "4 songs from Punjabi Hits 2026 are downloading."
    }

    /// Screenshot only: the song picker for a YouTube list, with one song already in the queue.
    func showYouTubePickerForSnapshot() {
        let songs = Self.previewSongs(["Kya Baat Aa", "Sardaari", "Bodyguard", "Lalkaara", "Ghaint", "Jee Karuga (feat. Sargi Maan)",
                                       "Why So", "No Luck", "Shaukeen"])
        spotifyReview = SpotifyReview(playlistId: KnobShiftPlaylists.youtubePrefix + "PLroad", name: "Punjabi Hits 2026", kind: .playlist,
                                      query: "", songs: songs, queued: [songs[0].song_id],
                                      initial: Set(songs.map(\.song_id)), isUpdate: true)
    }

    /// yt-dlp's own temporary files ("….part", "….ytdl", a cover not yet embedded) left by a
    /// download that was stopped halfway.
    nonisolated static func removeYouTubeLeftovers(in folder: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in names where file.lastPathComponent.contains("[yt-") {
            let name = file.lastPathComponent
            if ["part", "ytdl", "jpg", "webp", "webm"].contains(file.pathExtension.lowercased()) || name.contains(".temp.") || name.contains(".part-") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
