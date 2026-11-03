import AppKit
import Foundation

/// The YouTube dashboard: the person's own Google key, signing in with a code like a TV, and the
/// rows of their YouTube (Liked music, their playlists, new music from subscriptions, popular
/// music in their country). A row or playlist opens in the same song picker as a pasted link, and
/// everything after it (downloads, queue, retry, update, remove) is the code pasted links use.
extension KnobShiftModel {
    typealias YouTubeShelf = KnobShiftYouTubeHub.Shelf
    private typealias APIProblem = KnobShiftYouTubeAPIParsing.Problem

    /// Music only, unless the person turned the dashboard's switch off.
    var youtubeMusicOnly: Bool {
        UserDefaults.standard.object(forKey: PersistKey.knobShiftYouTubeMusicOnly.rawValue) as? Bool ?? true
    }

    // MARK: The Google key

    /// Checks the key with Google and keeps it; false (with the reason in the status line) when
    /// Google refuses it.
    func saveGoogleKey(id: String, secret: String) async -> Bool {
        do {
            try await KnobShiftGoogleAuth.saveKey(id: id, secret: secret)
            youtubeHub.hasKey = true
            spotifyStatus = "Google key saved. Sign in with Google next."
            log("YOUTUBE", "Google key saved.")
            return true
        } catch let problem as KnobShiftGoogleAuth.Problem {
            spotifyStatus = problem.message
            log("YOUTUBE", "Google key refused: \(problem).")
        } catch {
            spotifyStatus = KnobShiftGoogleAuth.Problem.failed.message
        }
        return false
    }

    func removeGoogleKey() {
        cancelYouTubeSignIn(quietly: true)
        youtubeSignedIn = false
        youtubeHub.hasKey = false
        youtubeHub.clear()
        KnobShiftYouTubeAPI.forget()
        spotifyStatus = "Google key removed, and you are signed out of YouTube."
        log("YOUTUBE", "Google key removed.")
        let refresh = KnobShiftGoogleAuth.removeKey()
        Task { [weak self] in
            if await !KnobShiftGoogleAuth.revoke(refresh) { self?.spotifyStatus = Self.notForgotten }
        }
    }

    // MARK: Signing in

    /// Shows a code, copies it, and opens Google's page to enter it; signed in once it is entered.
    func signInWithGoogle() {
        guard youtubeHub.hasKey, !youtubeSigningIn, spotifyReadJob == nil else { return }
        youtubeSigningIn = true
        spotifyStatus = "Asking Google for a code."
        log("YOUTUBE", "Signing in with Google.")
        youtubeHub.signInTask = Task { [weak self] in
            do {
                let code = try await KnobShiftGoogleAuth.start()
                guard let self, !Task.isCancelled else { return }
                self.youtubeHub.code = code
                if !Self.youtubeUAT {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code.userCode, forType: .string)
                    NSWorkspace.shared.open(code.verificationURL)
                }
                self.spotifyStatus = "Enter the code on Google's page. It is copied, so you can paste it."
                try await KnobShiftGoogleAuth.waitForApproval(code)
                guard !Task.isCancelled else { return }
                self.finishSignIn(nil)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishSignIn(error)
            }
        }
    }

    private func finishSignIn(_ error: Error?) {
        youtubeSigningIn = false
        youtubeHub.code = nil
        youtubeHub.signInTask = nil
        guard let error else {
            youtubeHub.clear()
            youtubeSignedIn = true
            spotifyStatus = "Signed in to YouTube. Your music is loading."
            log("YOUTUBE", "Signed in with Google.")
            loadYouTubeDashboard(force: true)
            return
        }
        let problem = error as? KnobShiftGoogleAuth.Problem ?? .failed
        spotifyStatus = problem.message
        log("YOUTUBE", "Signing in with Google did not work: \(problem).")
    }

    func cancelYouTubeSignIn(quietly: Bool = false) {
        guard youtubeSigningIn else { return }
        youtubeHub.signInTask?.cancel()
        youtubeHub.signInTask = nil
        youtubeHub.code = nil
        youtubeSigningIn = false
        if !quietly { spotifyStatus = "Stopped signing in to YouTube." }
        log("YOUTUBE", "Signing in cancelled.")
    }

    func signOutOfYouTube(expired: Bool = false) {
        youtubeSignedIn = false
        youtubeHub.clear()
        KnobShiftYouTubeAPI.forget()
        spotifyStatus = expired ? APIProblem.signedOut.message : "Signed out of YouTube. Google no longer gives Knob access."
        log("YOUTUBE", expired ? "The YouTube sign in ran out; signed out." : "Signed out of YouTube.")
        Task { [weak self] in
            if await !KnobShiftGoogleAuth.signOut(), !expired { self?.spotifyStatus = Self.notForgotten }
        }
    }

    /// The YouTube UAT signs in against a fake Google: no browser page, no clipboard.
    private static var youtubeUAT: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["KNOB_YOUTUBE_UAT"] != nil
        #else
        return false
        #endif
    }

    private static var notForgotten: String {
        "Signed out here, but Google could not be reached. To end Knob's access there too, remove Knob at myaccount.google.com/permissions."
    }

    // MARK: The dashboard

    /// Reads every row at once, at most every two hours unless `force`.
    func loadYouTubeDashboard(force: Bool = false) {
        let hub = youtubeHub
        guard youtubeSignedIn, !hub.loading else { return }
        if !force, let at = hub.loadedAt, Date().timeIntervalSince(at) < 2 * 3600 { return }
        hub.loading = true
        let generation = hub.generation
        log("YOUTUBE", "Loading the YouTube dashboard.")
        hub.loadTask = Task { [weak self] in
            async let liked = Self.attempt { try await KnobShiftYouTubeAPI.liked() }
            async let lists = Self.attempt { try await KnobShiftYouTubeAPI.playlists() }
            async let popular = Self.attempt { try await KnobShiftYouTubeAPI.popularMusic() }
            async let fresh = Self.attempt { try await KnobShiftYouTubeAPI.newFromSubscriptions() }
            let results = await (liked, lists, popular, fresh)
            // Signed out (or in again) meanwhile: these rows belong to that earlier sign in.
            guard let self, hub.generation == generation, !Task.isCancelled else { return }
            hub.loading = false
            hub.loadTask = nil
            hub.loadedAt = Date()
            if case .success(let videos) = results.0 { hub.shelves[.liked] = videos }
            if case .success(let found) = results.1 { hub.playlists = found }
            if case .success(let videos) = results.2 { hub.shelves[.popular] = videos }
            if case .success(let videos) = results.3 { hub.shelves[.new] = videos }
            let problems = [results.0.problem, results.1.problem, results.2.problem, results.3.problem].compactMap { $0 }
            if problems.contains(.signedOut) {
                self.signOutOfYouTube(expired: true)
            } else if let first = problems.first {
                hub.loadedAt = nil
                self.spotifyStatus = first.message
                self.log("YOUTUBE", "The dashboard did not fully load: \(problems).")
            } else {
                if self.spotifyStatus?.hasPrefix("Signed in to YouTube") == true { self.spotifyStatus = nil }
                self.log("YOUTUBE", "Dashboard loaded: \(results.0.count) liked, \(results.1.count) playlists, "
                         + "\(results.2.count) popular, \(results.3.count) new.")
            }
        }
    }

    private enum Attempt<Value: Collection> {
        case success(Value), failure(APIProblem)
        var problem: APIProblem? { if case .failure(let problem) = self { return problem }; return nil }
        var count: Int { if case .success(let value) = self { return value.count }; return 0 }
    }

    private nonisolated static func attempt<Value: Collection>(_ work: () async throws -> Value) async -> Attempt<Value> {
        do { return .success(try await work()) } catch { return .failure(error as? APIProblem ?? .failed) }
    }

    // MARK: Opening a row

    /// Opens a row in the song picker. Liked videos are read again in full; the other rows are
    /// used as loaded.
    func openYouTubeShelf(_ shelf: YouTubeShelf, refetch: Bool = false) async {
        let musicOnly = youtubeMusicOnly
        let name = KnobShiftYouTubeHub.title(shelf, musicOnly: musicOnly)
            .replacingOccurrences(of: " from your subscriptions", with: "")
        await readFromGoogle(name: name) { [hub = youtubeHub] in
            let videos: [KnobShiftYouTubeAPI.Video]
            if refetch || shelf == .liked || hub.shelves[shelf] == nil {
                videos = try await Self.fetch(shelf)
                await MainActor.run { hub.shelves[shelf] = videos }
            } else {
                videos = hub.shelves[shelf] ?? []
            }
            return (KnobShiftYouTubeAPIParsing.filtered(videos, musicOnly: musicOnly && shelf != .popular), 0)
        } show: { listing, skipped in
            self.showYouTubeReview(id: KnobShiftYouTubeHub.playlistId(shelf), name: name, kind: shelf == .liked ? .liked : .playlist,
                                   query: shelf == .liked ? "https://www.youtube.com/playlist?list=LL" : "", listing: listing, skipped: skipped)
        }
    }

    private nonisolated static func fetch(_ shelf: YouTubeShelf) async throws -> [KnobShiftYouTubeAPI.Video] {
        switch shelf {
        case .liked: return try await KnobShiftYouTubeAPI.liked()
        case .new: return try await KnobShiftYouTubeAPI.newFromSubscriptions()
        case .popular: return try await KnobShiftYouTubeAPI.popularMusic()
        }
    }

    /// Opens one of the person's playlists (theirs, so never filtered) in the song picker.
    func openYouTubePlaylist(id: String, name: String?) async {
        await readFromGoogle(name: name ?? "YouTube playlist") {
            try await KnobShiftYouTubeAPI.playlist(id)
        } show: { listing, skipped in
            self.showYouTubeReview(id: KnobShiftPlaylists.youtubePrefix + id, name: name ?? "YouTube playlist", kind: .playlist,
                                   query: "https://www.youtube.com/playlist?list=\(id)", listing: listing, skipped: skipped)
        }
    }

    /// Update for a list added from the dashboard; false when it is an ordinary link.
    func updateYouTubeFromGoogle(_ playlist: KnobShiftPlaylist) async -> Bool {
        if let shelf = KnobShiftYouTubeHub.shelf(forPlaylistId: playlist.id) {
            guard youtubeSignedIn else {
                spotifyStatus = "Sign in with Google to update \(playlist.name)."
                return true
            }
            await openYouTubeShelf(shelf, refetch: true)
            return true
        }
        return false
    }

    /// One read at a time, shared with pasted links, so CANCEL in the status line stops it.
    private func readFromGoogle(name: String, _ read: @escaping () async throws -> (videos: [KnobShiftYouTubeAPI.Video], skipped: Int),
                                show: @escaping (KnobShiftSpotDL.Listing, Int) -> Void) async {
        guard spotifyReadJob == nil, spotifyLoginJob == nil, !youtubeSigningIn else {
            spotifyStatus = "Still busy with the last step. Cancel it or wait for it to finish."
            return
        }
        let job = UUID()
        spotifyReadJob = job
        spotifyBusy = true
        spotifyReview = nil
        spotifyStatus = "Reading \(name) from YouTube."
        defer {
            if spotifyReadJob == job {
                spotifyReadJob = nil
                spotifyBusy = false
            }
        }
        // Its own task, so CANCEL (cancelSpotifyRead) stops the requests, not only the result.
        let task = Task { try await read() }
        youtubeHub.cancelRead = { task.cancel() }
        defer { youtubeHub.cancelRead = nil }
        do {
            let found = try await task.value
            guard spotifyReadJob == job else { return }
            guard !found.videos.isEmpty else {
                spotifyStatus = youtubeMusicOnly ? "No music here yet. Turn off Music only to see every video." : "Nothing here yet."
                return
            }
            show(KnobShiftYouTubeAPIParsing.listing(found.videos, listName: name), found.skipped)
        } catch {
            guard spotifyReadJob == job else { return }
            let problem = error as? APIProblem ?? .failed
            log("YOUTUBE", "Could not read \(name) from YouTube: \(problem).")
            if problem == .signedOut { signOutOfYouTube(expired: true) } else { spotifyStatus = problem.message }
        }
    }
}
