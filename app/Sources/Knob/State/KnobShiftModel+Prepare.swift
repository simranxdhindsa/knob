import Foundation

/// Preparing the songs waiting in the queue: two at a time on the Mac, so a big playlist is ready
/// sooner, and one at a time during a mix and on the iPhone, so the music always comes first.
/// Finished songs join the queue in their order, whichever was done first.
extension KnobShiftModel {
    private typealias Outcome = Swift.Result<KnobShiftAnalyser.Result, Error>

    private var preparingAtOnce: Int {
        #if os(macOS)
        mixState == .mixing ? 1 : analysers.count
        #else
        1
        #endif
    }

    /// Prepares waiting songs in order. A second call while this runs returns at once; the
    /// running loop picks up anything added meanwhile.
    func processPending() async {
        guard !isProcessing else { return }
        isProcessing = true
        isPreparing = true
        if !isPlaying, !isMixPaused { mixState = .analyzing }
        defer {
            isProcessing = false
            isPreparing = false
        }
        while true {
            let batch = Array(pending.lazy.filter { $0.failure == nil && !$0.waitingForDownload }.prefix(preparingAtOnce))
            guard !batch.isEmpty else { break }
            await prepare(batch)
        }
        for track in tracks where track.voiceUnread && !track.voiceRetried { await reread(track) }
        if !tracks.isEmpty, !isPlaying, !isMixPaused {
            mixState = .ready
            transitionDescription = "Ready. Choose a song to begin."
            log("READY", "Prepared \(tracks.count) song(s).")
        }
    }

    /// Prepares these songs side by side, below the music's priority, and hands each one over as
    /// soon as every song before it is done.
    private func prepare(_ batch: [PendingSong]) async {
        for song in batch {
            if let index = pending.firstIndex(where: { $0.id == song.id }) {
                pending[index].isActive = true
                pending[index].progress = 0.02
            }
            log("ANALYSIS", "Analysing \(song.url.lastPathComponent).")
        }
        let progress: @Sendable (UUID, Double) -> Void = { [weak self] id, value in
            Task { @MainActor [weak self] in
                self?.setProgress(value, for: id)
                self?.readCover(for: id)
            }
        }
        await withTaskGroup(of: (UUID, Outcome).self) { group in
            for (slot, song) in batch.enumerated() {
                let analyser = analysers[slot]
                let (id, url) = (song.id, song.url)
                group.addTask(priority: .utility) {
                    do {
                        return (id, .success(try await analyser.analyse(url) { progress(id, $0) }))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            var done: [UUID: Outcome] = [:]
            var next = 0
            for await (id, outcome) in group {
                done[id] = outcome
                while next < batch.count, let ready = done[batch[next].id] {
                    await finish(batch[next], ready)
                    next += 1
                }
            }
        }
    }

    /// Only a song being measured reports progress, so a big queue coming back from saved
    /// results never reads every cover. Measuring takes seconds and a cover milliseconds, so
    /// nothing has to wait for it.
    private func readCover(for id: UUID) {
        guard coverLoads[id] == nil, let url = pending.first(where: { $0.id == id })?.url else { return }
        coverLoads[id] = Task { _ = await KnobShiftArtwork.load(url) }
    }

    private func finish(_ song: PendingSong, _ outcome: Outcome) async {
        let cover = coverLoads.removeValue(forKey: song.id)
        switch outcome {
        case .success(let result):
            var track = result.track
            track.voiceUnread = !result.complete
            track.tags = await KnobShiftTags.read(song.url)
            // Removed from the queue (or its playlist removed) while it was being prepared.
            guard pending.contains(where: { $0.id == song.id }) else { return }
            let origin = KnobShiftPlaylists.origin(of: song.url, in: playlists)
            track.spotifyId = song.spotifyId ?? origin?.spotifyId
            track.playlistId = song.playlistId ?? origin?.playlistId
            // A playlist only song is prepared for later: its result is saved, so adding it from
            // its playlist is instant. It may have been added to the queue meanwhile.
            guard pending.first(where: { $0.id == song.id })?.joinsQueue ?? true else {
                cover?.cancel()
                pending.removeAll { $0.id == song.id }
                logAnalysis(result)
                return
            }
            if let cover {
                await cover.value
                reveal(track.id)
            }
            pending.removeAll { $0.id == song.id }
            place(track, at: song.placement)
            logAnalysis(result)
            refreshPlanIfNeeded()
        case .failure(let error):
            if let failed = pending.firstIndex(where: { $0.id == song.id }) {
                pending[failed].isActive = false
                pending[failed].failure = "Could not read this file"
                // A Spotify or YouTube download that broke off: delete it, so Retry downloads it again.
                if song.spotifyId != nil, KnobShiftPlaylists.isDownload(song.url) {
                    try? FileManager.default.removeItem(at: song.url)
                    pending[failed].waitingForDownload = true
                    pending[failed].failure = "Download broke"
                }
            }
            log("ERROR", "Analysis failed for \(song.url.lastPathComponent): \(error.localizedDescription)")
        }
        persistQueue()
    }

    /// Marks a song's cover to fade in, long enough for its row to appear.
    private func reveal(_ id: UUID) {
        justPrepared.insert(id)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.justPrepared.remove(id)
        }
    }

    /// Retry on a song whose voice could not be read.
    func rereadVoice(_ track: Track) {
        Task { await reread(track) }
    }

    /// Measures the song again and updates it where it stands, so its place in the queue, the
    /// player and any plan for it all keep working.
    private func reread(_ track: Track) async {
        guard rereading.insert(track.id).inserted else { return }
        defer { rereading.remove(track.id) }
        log("ANALYSIS", "Reading the voice of \(track.title) again.")
        let (analyser, url) = (analysers[0], track.url)
        let result = try? await Task(priority: .utility) { try await analyser.analyse(url, fresh: true) }.value
        func update(_ song: inout Track) {
            song.voiceRetried = true
            guard let result else { return }
            song.analysis = result.track.analysis
            song.voiceUnread = !result.complete
        }
        if let index = tracks.firstIndex(where: { $0.id == track.id }) { update(&tracks[index]) }
        if let index = unshuffled.firstIndex(where: { $0.id == track.id }) { update(&unshuffled[index]) }
        if nowPlaying?.id == track.id, var playing = nowPlaying {
            update(&playing)
            nowPlaying = playing
        }
        if let result { logAnalysis(result) }
        refreshPlanIfNeeded()
    }

    /// Adds a prepared song where it was planned to go: next to a song of its playlist, or last.
    private func place(_ track: Track, at placement: KnobShiftSyncPlan.Placement?) {
        func index(in list: [Track]) -> Int {
            switch placement {
            case .after(let id)?: return list.lastIndex { $0.spotifyId == id }.map { $0 + 1 } ?? list.count
            case .before(let id)?: return list.firstIndex { $0.spotifyId == id } ?? list.count
            default: return list.count
            }
        }
        let at = index(in: tracks)
        // The song playing keeps its place in the order: one added before it moves it along.
        if at <= currentIndex, !tracks.isEmpty, nowPlaying != nil { currentIndex += 1 }
        tracks.insert(track, at: at)
        if isShuffled { unshuffled.insert(track, at: index(in: unshuffled)) }
    }

    private func setProgress(_ value: Double, for id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].progress = max(pending[index].progress, value)
    }
}
