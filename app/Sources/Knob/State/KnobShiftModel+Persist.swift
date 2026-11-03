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
        let found = await Task.detached(priority: .userInitiated) {
            paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        }.value
        if found.count < paths.count {
            log("RESTORE", "Skipped \(paths.count - found.count) song(s) whose files are no longer there.")
        }
        enqueueFiles(found)
        #if os(macOS)
        // Spotify songs that were still downloading come back and continue.
        resumeDownloads()
        #endif
        await processPending()
        restoreNowPlaying()
    }

    /// Puts the song last in the player back in it, paused where it was, so Play carries on
    /// from there. Nothing happens if something already plays or the song left the queue.
    func restoreNowPlaying() {
        guard nowPlaying == nil, let saved = UserDefaults.standard.string(forKey: PersistKey.knobShiftLastSong.rawValue) else { return }
        let path = Platform.relocated(saved)
        guard let index = tracks.firstIndex(where: { $0.url.path == path }) else { return }
        let track = tracks[index]
        // A song that had (almost) finished starts again from the top.
        let position = UserDefaults.standard.double(forKey: PersistKey.knobShiftLastPosition.rawValue)
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
        guard let track = nowPlaying else { return }
        UserDefaults.standard.set(track.url.path, forKey: PersistKey.knobShiftLastSong.rawValue)
        UserDefaults.standard.set(playbackTime, forKey: PersistKey.knobShiftLastPosition.rawValue)
        rememberedAt = Date()
    }

    /// Saves the user's own order, at most about once a second however many songs change;
    /// shuffle starts off again on the next launch.
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
        let paths = (isShuffled ? unshuffled : tracks).map { $0.url.path }
            + pending.filter { !$0.waitingForDownload }.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: PersistKey.knobShiftQueue.rawValue)
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
