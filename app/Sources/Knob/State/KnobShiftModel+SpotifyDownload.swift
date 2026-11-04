import Foundation

/// Spotify downloads: one playlist at a time through KnobShiftLane, with live progress (how many
/// songs are done and which ones spotDL is on), Cancel, Retry, and downloads that continue after
/// Knob relaunches. A song's file is handed to the queue only once spotDL says it finished, or
/// once spotDL has exited, because spotDL writes straight into the playlist folder while it
/// converts.
extension KnobShiftModel {
    func isDownloading(_ playlist: KnobShiftPlaylist) -> Bool { spotifyProgress[playlist.id] != nil }

    // MARK: Queueing

    /// Adds songs to the playlist's next download and queues that download behind any other.
    func enqueueDownload(_ playlist: KnobShiftPlaylist, songs: [KnobShiftSpotDL.Song]) {
        guard !songs.isEmpty else { return }
        let ids = Set(songs.map(\.song_id))
        let space = try? KnobShiftPlaylists.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        guard KnobShiftImport.hasRoom(for: songs.count, available: space) else {
            markRows(of: playlist.id, ids: ids, failure: "No space")
            let gigabytes = { (bytes: Int64) in String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
            spotifyStatus = "Not enough space: \(songs.count) songs need about \(gigabytes(KnobShiftImport.spaceNeeded(for: songs.count))) and this Mac has \(gigabytes(space ?? 0)) free. Free up space or tick fewer songs, then Retry."
            log("SPOTIFY", "Not enough space for \(songs.count) song(s) of \(playlist.name).")
            return
        }
        queuedDownloads[playlist.id, default: []].append(contentsOf: songs)
        if downloadProgress[playlist.id] == nil {
            downloadProgress[playlist.id] = KnobShiftImport.Progress(songs: queuedDownloads[playlist.id] ?? songs)
        }
        let busy = spotifyLane.running != nil && spotifyLane.running != playlist.id
        setStage(busy ? "Waiting for another download" : "Waiting to download", for: playlist.id, ids: ids)
        spotifyStatus = "\(songs.count) song\(songs.count == 1 ? "" : "s") from \(playlist.name) \(busy ? "will download next" : "are downloading")."
        publishProgressSoon()
        let id = playlist.id
        spotifyLane.enqueue(id) { [weak self] in await self?.runDownload(id) }
    }

    private func runDownload(_ playlistId: String) async {
        guard let songs = queuedDownloads.removeValue(forKey: playlistId),
              let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        // Only songs still waiting in the queue: some may have been removed meanwhile.
        let waiting = Set(pending.filter { $0.playlistId == playlistId && $0.waitingForDownload && $0.failure == nil }.compactMap(\.spotifyId))
        var seen = Set<String>()
        let fetch = songs.filter { waiting.contains($0.song_id) && seen.insert($0.song_id).inserted }
        guard !fetch.isEmpty else {
            finishProgress(playlistId)
            return
        }
        var progress = KnobShiftImport.Progress(songs: fetch)
        progress.started = true
        downloadProgress[playlistId] = progress
        setStage("Downloading", for: playlistId, ids: Set(fetch.map(\.song_id)))
        publishProgressSoon()
        if playlist.source == .youtube {
            await runYouTubeDownload(playlist, songs: fetch)
            return
        }

        let folder = KnobShiftPlaylists.folder(for: playlist)
        let saveFile = folder.appendingPathComponent(".knobshift-download.spotdl")
        do {
            try KnobShiftSpotDL.writeSaveFile(fetch.map(\.song_id), raw: raw(for: playlist), to: saveFile)
        } catch {
            markRows(of: playlistId, ids: Set(fetch.map(\.song_id)), failure: "Could not start")
            finishProgress(playlistId)
            log("ERROR", "Could not write the download list for \(playlist.name): \(error.localizedDescription)")
            return
        }
        let job = UUID()
        spotifyJobs[playlistId] = job
        log("SPOTIFY", "Downloading \(fetch.count) song(s) of \(playlist.name) into \(folder.path).")
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.spotifyLine(line, playlistId: playlistId, job: job) }
        }
        let result = await KnobShiftSpotDL.shared.download(saveFile: saveFile, into: folder, userAuth: spotifyLoggedIn,
                                                            id: job, browser: downloadBrowser, onLine: onLine)
        try? FileManager.default.removeItem(at: saveFile)
        await downloadFinished(playlist, job: job, fetched: fetch, result: result)
    }

    // MARK: Using a browser's sign in

    /// The browser to use for downloads now: none until YouTube has blocked one.
    var downloadBrowser: KnobShiftYouTubeBrowser? {
        youtubeBrowserInUse && KnobShiftYouTubeBrowser.chosen != .off ? KnobShiftYouTubeBrowser.chosen : nil
    }

    /// YouTube blocked a download: turns the chosen browser on, once a session. True means try the
    /// blocked songs again, so a block that goes on anyway does not repeat for ever.
    func useBrowserAfterBlock() -> Bool {
        let chosen = KnobShiftYouTubeBrowser.chosen
        guard !youtubeBrowserInUse, chosen != .off else { return false }
        youtubeBrowserInUse = true
        log("SPOTIFY", "YouTube blocked a download; using the YouTube sign in from \(chosen.title).")
        return true
    }

    // MARK: Following spotDL

    private func spotifyLine(_ line: String, playlistId: String, job: UUID) {
        guard spotifyJobs[playlistId] == job else { return }
        log("SPOTIFY", line)
        guard var progress = downloadProgress[playlistId] else { return }
        let event = progress.consume(line)
        downloadProgress[playlistId] = progress
        switch event {
        case .landed: collectSoon(playlistId)
        case .notFound(let id): markRows(of: playlistId, ids: [id], failure: "Not found")
        case nil: break
        }
        publishProgressSoon()
    }

    /// Progress reaches the views at most twice a second, however fast spotDL prints.
    func publishProgressSoon() {
        guard !progressPublishScheduled else { return }
        progressPublishScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self else { return }
            self.progressPublishScheduled = false
            if self.spotifyProgress != self.downloadProgress { self.spotifyProgress = self.downloadProgress }
        }
    }

    /// Finished files reach the queue at most once a second, in one change.
    func collectSoon(_ playlistId: String) {
        guard collectScheduled.insert(playlistId).inserted else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.collectScheduled.remove(playlistId)
            await self?.collectDownloads(playlistId, finishedOnly: true)
        }
    }

    /// Hands downloaded files to the queue, which prepares them. `finishedOnly` takes only songs
    /// spotDL said it finished; once spotDL has exited every file is complete.
    func collectDownloads(_ playlistId: String, finishedOnly: Bool) async {
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else { return }
        let folder = KnobShiftPlaylists.folder(for: playlist)
        let files = await Task.detached(priority: .utility) { KnobShiftPlaylists.files(in: folder) }.value
        let landed = downloadProgress[playlistId]?.landed ?? []
        var rows = pending
        var count = 0
        for index in rows.indices where rows[index].playlistId == playlistId && rows[index].waitingForDownload {
            guard let id = rows[index].spotifyId, let file = files[id], !finishedOnly || landed.contains(id) else { continue }
            rows[index].url = file
            rows[index].waitingForDownload = false
            rows[index].failure = nil
            rows[index].stage = nil
            count += 1
        }
        guard count > 0 else { return }
        pending = rows
        persistQueue()
        Task { await processPending() }
    }

    private func downloadFinished(_ playlist: KnobShiftPlaylist, job: UUID, fetched: [KnobShiftSpotDL.Song],
                                  result: KnobShiftSpotDL.RunResult) async {
        guard spotifyJobs[playlist.id] == job, !result.cancelled else { return }
        spotifyJobs[playlist.id] = nil
        await collectDownloads(playlist.id, finishedOnly: false)
        let problem: KnobShiftSpotDL.Failure? = result.stalled ? .stalled : KnobShiftSpotDL.classify(result.lines)
        let rowText: String
        switch problem {
        case .offline: rowText = "No internet"
        case .rateLimited: rowText = "Spotify busy"
        case .paused: rowText = "Spotify paused"
        case .youtubeBlocked: rowText = "YouTube paused"
        case .browserSignIn: rowText = "Browser sign in failed"
        case .noSpace: rowText = "No space"
        case .stalled: rowText = "Stopped"
        default: rowText = "Not found"
        }
        let fetchedIds = Set(fetched.map(\.song_id))
        let missing = pending.filter { $0.playlistId == playlist.id && $0.waitingForDownload && $0.failure == nil
            && fetchedIds.contains($0.spotifyId ?? "") }.count
        markRows(of: playlist.id, ids: fetchedIds, failure: rowText)
        finishProgress(playlist.id)
        if problem == .youtubeBlocked, missing > 0, useBrowserAfterBlock() {
            retryFailed(playlist)
            return
        }
        if let problem, missing > 0, problem != .privateList {
            spotifyStatus = "\(playlist.name) stopped early: \(problem.message)"
        } else {
            spotifyStatus = missing == 0
                ? "\(playlist.name) is downloaded."
                : "\(playlist.name) is downloaded. \(missing) song\(missing == 1 ? "" : "s") could not be found. Retry them from the queue."
        }
        log("SPOTIFY", "Download of \(playlist.name) finished with status \(result.status), \(missing) song(s) missing\(problem.map { " (\($0))" } ?? "").")
    }

    /// Drops the playlist's progress, unless more of its songs wait for another run.
    func finishProgress(_ playlistId: String) {
        if let more = queuedDownloads[playlistId], !more.isEmpty {
            downloadProgress[playlistId] = KnobShiftImport.Progress(songs: more)
        } else {
            downloadProgress[playlistId] = nil
        }
        publishProgressSoon()
    }

    // MARK: Cancel

    /// Stops the playlist's download (running or waiting). Downloaded songs stay; songs still
    /// waiting leave the queue, and Update playlist offers them again.
    func cancelDownload(_ playlist: KnobShiftPlaylist, quietly: Bool = false) {
        spotifyLane.removeWaiting(playlist.id)
        if playlist.source == .youtube { cancelYouTubeRetry(playlist) }
        queuedDownloads[playlist.id] = nil
        let progress = downloadProgress.removeValue(forKey: playlist.id)
        if let job = spotifyJobs.removeValue(forKey: playlist.id) {
            if playlist.source == .youtube { KnobShiftYouTube.shared.cancel(job) } else { KnobShiftSpotDL.shared.cancel(job) }
            // Songs the helper was in the middle of may have left half written files behind.
            let unfinished = Set(progress?.order ?? []).subtracting(progress?.landed ?? [])
            let folder = KnobShiftPlaylists.folder(for: playlist)
            let youtube = playlist.source == .youtube
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(4))
                Self.removeRecentFiles(in: folder, ids: unfinished)
                if youtube { Self.removeYouTubeLeftovers(in: folder, ids: unfinished) }
            }
        }
        let landed = progress?.landed ?? []
        // Stopped songs are not downloaded again after a relaunch; Update playlist offers them.
        let stopped = Set(pending.filter { $0.playlistId == playlist.id && $0.waitingForDownload && !landed.contains($0.spotifyId ?? "") }.compactMap(\.spotifyId))
        if !stopped.isEmpty {
            let keep = songs(for: playlist).filter { !stopped.contains($0.song_id) }
            try? KnobShiftSpotDL.writeSaveFile(keep.map(\.song_id), raw: raw(for: playlist), to: KnobShiftPlaylists.songsFile(for: playlist))
        }
        var rows = pending
        rows.removeAll { $0.playlistId == playlist.id && $0.waitingForDownload && !landed.contains($0.spotifyId ?? "") }
        pending = rows
        persistQueue()
        publishProgressSoon()
        if !landed.isEmpty { Task { await collectDownloads(playlist.id, finishedOnly: false) } }
        guard !quietly else { return }
        let done = landed.count
        spotifyStatus = "Stopped downloading \(playlist.name). \(done) song\(done == 1 ? " was" : "s were") downloaded."
        log("SPOTIFY", "Download of \(playlist.name) cancelled after \(done) song(s).")
    }

    /// Deletes files of unfinished songs written in the last few minutes (half written ones).
    nonisolated static func removeRecentFiles(in folder: URL, ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for (id, file) in KnobShiftPlaylists.files(in: folder) where ids.contains(id) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) < 600 { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Retry

    /// Retry for one Spotify song that could not be found or downloaded, in its own lane so it
    /// does not wait behind a long playlist download.
    func retryDownload(_ song: PendingSong) {
        guard let id = song.spotifyId, let playlistId = song.playlistId,
              let playlist = playlists.first(where: { $0.id == playlistId }),
              let index = pending.firstIndex(where: { $0.id == song.id }) else { return }
        pending[index].failure = nil
        pending[index].waitingForDownload = true
        pending[index].stage = spotifyRetryLane.running == nil ? "Downloading" : "Waiting to retry"
        log("SPOTIFY", "Retrying \(song.name).")
        spotifyRetryLane.enqueue("\(playlistId)/\(id)") { [weak self] in
            await self?.runRetry(spotifyId: id, rowId: song.id, playlist: playlist)
        }
    }

    private func runRetry(spotifyId: String, rowId: UUID, playlist: KnobShiftPlaylist) async {
        guard pending.contains(where: { $0.id == rowId && $0.waitingForDownload }) else { return }
        if playlist.source == .youtube {
            await runYouTubeRetry(songId: spotifyId, playlist: playlist)
            return
        }
        setStage("Downloading", for: playlist.id, ids: [spotifyId])
        let folder = KnobShiftPlaylists.folder(for: playlist)
        let saveFile = folder.appendingPathComponent(".knobshift-retry-\(spotifyId).spotdl")
        do {
            try KnobShiftSpotDL.writeSaveFile([spotifyId], raw: raw(for: playlist), to: saveFile)
        } catch {
            markRows(of: playlist.id, ids: [spotifyId], failure: "Could not start")
            return
        }
        let job = UUID()
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.log("SPOTIFY", line) }
        }
        let result = await KnobShiftSpotDL.shared.download(saveFile: saveFile, into: folder, userAuth: spotifyLoggedIn,
                                                            id: job, browser: downloadBrowser, onLine: onLine)
        try? FileManager.default.removeItem(at: saveFile)
        await collectDownloads(playlist.id, finishedOnly: false)
        let problem = result.stalled ? .stalled : KnobShiftSpotDL.classify(result.lines)
        markRows(of: playlist.id, ids: [spotifyId], failure: problem == .offline ? "No internet" : problem == .paused ? "Spotify paused"
                    : problem == .youtubeBlocked ? "YouTube paused"
                    : problem == .browserSignIn ? "Browser sign in failed" : "Not found")
    }

    /// Retries every song of a playlist that failed, as one download.
    func retryFailed(_ playlist: KnobShiftPlaylist) {
        let failed = Set(pending.filter { $0.playlistId == playlist.id && $0.waitingForDownload && $0.failure != nil }.compactMap(\.spotifyId))
        guard !failed.isEmpty else { return }
        let songs = songs(for: playlist).filter { failed.contains($0.song_id) }
        var rows = pending
        for index in rows.indices where rows[index].playlistId == playlist.id && failed.contains(rows[index].spotifyId ?? "") {
            rows[index].failure = nil
        }
        pending = rows
        enqueueDownload(playlist, songs: songs)
    }

    func failedCount(in playlist: KnobShiftPlaylist) -> Int {
        pending.reduce(0) { $0 + ($1.playlistId == playlist.id && $1.waitingForDownload && $1.failure != nil ? 1 : 0) }
    }

    // MARK: After a relaunch

    /// Puts back the songs that were still on their way when Knob quit and downloads them,
    /// from the list kept in each playlist's folder; Spotify is not asked again.
    func resumeDownloads() {
        for playlist in playlists {
            let wanted = songs(for: playlist)
            guard !wanted.isEmpty else { continue }
            let skipped = Set(playlist.skipped ?? [])
            let files = KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist))
            let missing = wanted.filter { files[$0.song_id] == nil && !skipped.contains($0.song_id) }
            guard !missing.isEmpty else { continue }
            log("SPOTIFY", "Continuing the download of \(missing.count) song(s) of \(playlist.name).")
            addSpotifyRows(for: missing, playlist: playlist)
        }
    }

    // MARK: Helpers

    /// The playlist's songs as spotDL describes them: from memory, or from its folder.
    func raw(for playlist: KnobShiftPlaylist) -> [String: Data] {
        if let raw = spotifyRaw[playlist.id], !raw.isEmpty { return raw }
        let folder = KnobShiftPlaylists.folder(for: playlist)
        for file in [KnobShiftPlaylists.songsFile(for: playlist), folder.appendingPathComponent("playlist.spotdl")] {
            if let data = try? Data(contentsOf: file), let listing = KnobShiftSpotDL.listing(from: data), !listing.raw.isEmpty {
                spotifyRaw[playlist.id] = listing.raw
                return listing.raw
            }
        }
        return [:]
    }

    /// The playlist's chosen songs, in order, from the list kept in its folder.
    func songs(for playlist: KnobShiftPlaylist) -> [KnobShiftSpotDL.Song] {
        guard let data = try? Data(contentsOf: KnobShiftPlaylists.songsFile(for: playlist)),
              let listing = KnobShiftSpotDL.listing(from: data) else { return [] }
        if spotifyRaw[playlist.id]?.isEmpty ?? true { spotifyRaw[playlist.id] = listing.raw }
        return listing.songs
    }

    /// Changes the matching rows in one go: one update of the queue, not one per row.
    func markRows(of playlistId: String, ids: Set<String>, failure: String) {
        var rows = pending
        var changed = false
        for index in rows.indices where rows[index].playlistId == playlistId && rows[index].waitingForDownload
            && rows[index].failure == nil && ids.contains(rows[index].spotifyId ?? "") {
            rows[index].failure = failure
            rows[index].stage = nil
            changed = true
        }
        if changed { pending = rows }
    }

    func setStage(_ stage: String, for playlistId: String, ids: Set<String>) {
        var rows = pending
        var changed = false
        for index in rows.indices where rows[index].playlistId == playlistId && rows[index].waitingForDownload
            && rows[index].failure == nil && ids.contains(rows[index].spotifyId ?? "") && rows[index].stage != stage {
            rows[index].stage = stage
            changed = true
        }
        if changed { pending = rows }
    }
}
