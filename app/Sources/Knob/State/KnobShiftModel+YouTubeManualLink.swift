import Foundation

/// A song Knob could not find can be given its YouTube video by hand, picked from a search or
/// pasted as a link: the audio is downloaded and saved under the song itself, so its row finishes
/// like any other download.
extension KnobShiftModel {
    /// Starts the download. Returns a sentence for the person when the link cannot be used.
    func useYouTubeLink(_ text: String, forSong id: String) -> String? {
        guard let video = KnobShiftYouTubeParsing.videoId(inLink: text) else { return "Paste a link to one YouTube video." }
        return useYouTubeVideo(video, forSong: id)
    }

    /// Same, for a video already known, such as one picked from the search.
    func useYouTubeVideo(_ video: String, forSong id: String) -> String? {
        guard let row = pending.first(where: { $0.spotifyId == id && $0.waitingForDownload }),
              let playlist = playlists.first(where: { $0.id == row.playlistId }),
              let song = songs(for: playlist).first(where: { $0.song_id == id }) else {
            return "This song is no longer in its playlist."
        }
        guard KnobShiftYouTube.helper != nil else { return "YouTube downloads are unavailable in this copy of Knob." }
        var rows = pending
        for index in rows.indices where rows[index].id == row.id {
            rows[index].failure = nil
            rows[index].stage = "Downloading"
        }
        pending = rows
        log("YOUTUBE", "Using the pasted video \(video) for \(song.name).")
        Task { await download(song, video: video, playlist: playlist) }
        return nil
    }

    private func download(_ song: KnobShiftSpotDL.Song, video: String, playlist: KnobShiftPlaylist) async {
        let folder = KnobShiftPlaylists.folder(for: playlist)
        let onLine: @Sendable (String) -> Void = { [weak self] line in
            guard !(line.hasPrefix("[download]") && line.contains("%")) else { return }
            Task { @MainActor in self?.log("YOUTUBE", line) }
        }
        let result = await KnobShiftYouTube.shared.download(song, into: folder, search: false, id: UUID(),
                                                            browser: downloadBrowser, video: video, onLine: onLine)
        if KnobShiftPlaylists.files(in: folder)[song.song_id] != nil {
            forgetUnavailable(song.song_id, in: playlist.id)
            await collectDownloads(playlist.id, finishedOnly: false)
            return
        }
        let problem = result.stalled ? .stalled : KnobShiftYouTubeParsing.classify(result.lines) ?? .failed
        if problem == .botCheck, useBrowserAfterBlock() {
            await download(song, video: video, playlist: playlist)
            return
        }
        markRows(of: playlist.id, ids: [song.song_id], failure: problem.rowText)
        log("YOUTUBE", "The pasted video for \(song.name) did not download (\(problem)).")
    }

    /// Retries every failed song of every playlist.
    func retryAllFailed() {
        for playlist in playlists where failedCount(in: playlist) > 0 { retryFailed(playlist) }
    }

    private func forgetUnavailable(_ id: String, in playlistId: String) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistId }),
              playlists[index].unavailable?.contains(id) == true else { return }
        playlists[index].unavailable?.removeAll { $0 == id }
        savePlaylists()
    }
}
