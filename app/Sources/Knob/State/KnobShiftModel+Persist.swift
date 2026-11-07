import Combine
import Foundation

/// The queue across launches: saved as file paths (at most about once a second), restored on
/// the next launch with missing files left out, and Spotify downloads picked up where they
/// stopped. The song last in the player comes back too, paused where it was, ready to play.
extension KnobShiftModel {
    /// Knob is not sandboxed, so a user-selected local path remains readable after relaunch.
    /// Missing or moved files are quietly removed from the saved queue on restore.
    func restoreQueue() async {
        // On the iPhone the app's folders move with every install, so saved paths are relocated.
        let paths = (UserDefaults.standard.stringArray(forKey: PersistKey.knobShiftQueue.rawValue) ?? []).map(Platform.relocated)
        log("RESTORE", "Restoring \(paths.count) song(s).")
        shuffleToRestore = UserDefaults.standard.stringArray(forKey: PersistKey.knobShiftShuffledQueue.rawValue)?.map(Platform.relocated)
        mixOrderToRestore = UserDefaults.standard.bool(forKey: PersistKey.knobShiftMixOrdered.rawValue)
        let found = await Task.detached(priority: .userInitiated) {
            paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }.value
        if found.count < paths.count {
            log("RESTORE", "Skipped \(paths.count - found.count) song(s) whose files are no longer there.")
        }
        enqueueFiles(found)
        // The song last in the player is prepared first, so it is there behind the iPhone's
        // opening instead of waiting for the whole queue.
        if let last = pending.firstIndex(where: { $0.url.path == lastSongPath }) {
            pending.insert(pending.remove(at: last), at: 0)
        }
        #if os(macOS)
        // Spotify songs that were still downloading come back and continue.
        resumeDownloads()
        #endif
        let firstReady = Task { [weak self] in
            guard let updates = self?.$tracks.values else { return }
            for await list in updates where !list.isEmpty {
                self?.restoreNowPlaying()
                return
            }
        }
        await processPending()
        firstReady.cancel()
        restoreOrder(of: found)
        restoreShuffle()
        restoreNowPlaying()
    }

    /// Turns shuffle (or Mix Order) back on in its saved order, once the songs are back in the
    /// user's own order. Songs the saved order does not know go last.
    func restoreShuffle() {
        guard let order = shuffleToRestore else { return }
        shuffleToRestore = nil
        guard !isShuffled, !isMixOrdered else { return }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        unshuffled = tracks
        tracks = tracks.enumerated().sorted {
            (rank[$0.element.url.path] ?? .max, $0.offset) < (rank[$1.element.url.path] ?? .max, $1.offset)
        }.map(\.element)
        isMixOrdered = mixOrderToRestore
        isShuffled = !mixOrderToRestore
        if let playing = nowPlaying, let index = tracks.firstIndex(of: playing) { currentIndex = index }
        log("RESTORE", (isMixOrdered ? "Mix Order" : "Shuffle") + " is back on, in its saved order.")
        refreshPlanIfNeeded()
        persistQueue()
    }

    private var lastSongPath: String? {
        UserDefaults.standard.string(forKey: PersistKey.knobShiftLastSong.rawValue).map(Platform.relocated)
    }

    /// Puts the queue back in its saved order, once the song prepared first has joined it.
    private func restoreOrder(of files: [URL]) {
        guard !isShuffled, !isMixOrdered else { return }
        let rank = Dictionary(files.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { first, _ in first })
        tracks = tracks.enumerated().sorted {
            (rank[$0.element.url.path] ?? .max, $0.offset) < (rank[$1.element.url.path] ?? .max, $1.offset)
        }.map(\.element)
        if let playing = nowPlaying, let index = tracks.firstIndex(of: playing) { currentIndex = index }
        refreshPlanIfNeeded()
        persistQueue()
    }

    /// Puts the song last in the player back in it, paused where it was, so Play carries on
    /// from there. If that song left the queue, the first song waits ready from its start.
    /// Nothing happens if something already plays.
    func restoreNowPlaying() {
        guard nowPlaying == nil, !tracks.isEmpty else { return }
        let saved = tracks.firstIndex { $0.url.path == lastSongPath }
        let index = saved ?? 0
        let track = tracks[index]
        // A song that had (almost) finished starts again from the top.
        let position = saved == nil ? 0 : UserDefaults.standard.double(forKey: PersistKey.knobShiftLastPosition.rawValue)
        let from = position < track.duration - 5 ? max(0, position) : 0
        currentIndex = index
        do {
            try schedulePrimary(track, from: from, play: false)
            log("RESTORE", "\(track.title) is back in the player, ready to play from \(Analysis.clock(from)).")
        } catch {
            log("RESTORE", "\(track.title) could not be put back in the player: \(error.localizedDescription)")
        }
    }

    /// Remembers the song in the player and where it is. Cheap enough to call every few seconds.
    func rememberNowPlaying() {
        guard !isMirroring, let track = nowPlaying else { return }
        UserDefaults.standard.set(track.url.path, forKey: PersistKey.knobShiftLastSong.rawValue)
        UserDefaults.standard.set(playbackTime, forKey: PersistKey.knobShiftLastPosition.rawValue)
        rememberedAt = Date()
    }

    /// Saves the user's own order, at most about once a second however many songs change;
    /// the shuffled order is saved beside it while shuffle is on.
    func persistQueue() {
        guard !persistScheduled else { return }
        persistScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            self.persistScheduled = false
            self.persistQueueNow()
        }
    }

    /// Spotify songs still downloading are not saved: their list in the playlist folder brings
    /// them back.
    func persistQueueNow() {
        // The other device's songs are only shown here; this device's own queue stays saved.
        guard !isMirroring else { return }
        let paths = (isArranged ? unshuffled : tracks).map { $0.url.path }
            + pending.filter { !$0.waitingForDownload && $0.joinsQueue }.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: PersistKey.knobShiftQueue.rawValue)
        // While a queue is being restored its shuffle is not back yet, so the saved one stays.
        if shuffleToRestore == nil {
            UserDefaults.standard.set(isArranged ? tracks.map(\.url.path) : nil, forKey: PersistKey.knobShiftShuffledQueue.rawValue)
            UserDefaults.standard.set(isMixOrdered ? true : nil, forKey: PersistKey.knobShiftMixOrdered.rawValue)
        }
        rememberNowPlaying()
    }

    /// Spotify and YouTube playlists in the queue and ones removed lately, shared by both apps.
    func loadPlaylists() {
        var index = KnobShiftPlaylists.load()
        KnobShiftPlaylists.purgeExpired(&index)
        KnobShiftPlaylists.save(index)
        playlists = index.playlists
        removedPlaylists = index.removed
        #if os(macOS)
        spotifyLoggedIn = KnobShiftSpotDL.isLoggedIn
        youtubeSignedIn = KnobShiftGoogleAuth.isSignedIn
        KnobShiftYouTube.removeOldBrowserSignIn()
        #endif
    }

    func savePlaylists() {
        KnobShiftPlaylists.save(KnobShiftPlaylists.Index(playlists: playlists, removed: removedPlaylists))
    }
}
