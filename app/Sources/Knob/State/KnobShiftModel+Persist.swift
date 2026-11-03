import Foundation

/// The queue across launches: saved as file paths (at most about once a second), restored on
/// the next launch with missing files left out, and Spotify downloads picked up where they
/// stopped.
extension KnobShiftModel {
    /// Knob is not sandboxed, so a user-selected local path remains readable after relaunch.
    /// Missing or moved files are quietly removed from the saved queue on restore.
    func restoreQueue() async {
        let paths = UserDefaults.standard.stringArray(forKey: PersistKey.knobShiftQueue.rawValue) ?? []
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
