import AVFoundation
import Foundation

/// `--knobshift-spotify-check uat [COUNT]`: the whole Spotify import as a user goes through it,
/// against tests/fake-spotdl.py instead of the network, in a temporary music folder. It picks
/// songs, downloads, cancels, queues two playlists, recovers from a stalled spotDL, retries,
/// and continues after a relaunch, while measuring the longest stall of the main thread (what
/// the user feels as lag).
extension KnobShiftSpotifyCheck {
    static func uat(count: Int) async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("knobshift-uat-\(UUID().uuidString)")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fake = repo.appendingPathComponent("tests/fake-spotdl.py")
        guard FileManager.default.isExecutableFile(atPath: fake.path) else {
            print("Missing \(fake.path) (chmod +x it).")
            exit(1)
        }
        let audio = work.appendingPathComponent("tone.wav")
        guard writeTone(to: audio) else { print("Could not write the test tone."); exit(1) }
        setenv("KNOB_SPOTIFY_ROOT", work.appendingPathComponent("Spotify").path, 1)
        setenv("KNOB_SPOTDL", fake.path, 1)
        setenv("KNOB_FFMPEG", "/bin/cat", 1)
        setenv("FAKE_AUDIO", audio.path, 1)
        setenv("KNOB_SONG_MB", "0.6", 1)
        UserDefaults.standard.removeObject(forKey: PersistKey.knobShiftQueue.rawValue)
        uatFolder = work

        let lag = LagMonitor()
        lag.start()
        let model = KnobShiftModel(restoresQueue: false)

        print("1. Pick songs from a \(count) song playlist and download them")
        configure(count: count, delay: 0.02, missing: "3")
        // A made up id: a real one reads the real list from Spotify's public player, not the fake.
        await model.addFromSpotify("https://open.spotify.com/playlist/0000000000000000000009?si=x")
        guard let review = model.spotifyReview else {
            expect(false, "the song picker opens (status: \(model.spotifyStatus ?? "none"))")
            return await finishUAT(lag)
        }
        expect(review.songs.count == count && review.initial.count == count, "every song listed and ticked")
        let unticked = Set(review.songs[4...5].map(\.song_id))
        model.confirmSpotifyReview(selected: review.initial.subtracting(unticked))
        expect(model.pending.count == count - 2, "ticked songs show in the queue at once (\(model.pending.count))")
        var sawCurrent = false
        await waitUntil(seconds: 120) {
            if model.spotifyProgress.values.contains(where: { !$0.current.isEmpty }) { sawCurrent = true }
            return model.downloadProgress.isEmpty && model.spotifyLane.running == nil
        }
        expect(sawCurrent, "progress named the song downloading")
        let playlist = model.playlists.first
        expect(playlist?.skipped.map(Set.init) == unticked, "unticked songs remembered")
        let missingRow = model.pending.first { $0.spotifyName == review.songs[2].name }
        expect(missingRow?.failure == "Not found", "a song spotDL cannot find says Not found (\(missingRow?.failure ?? "none"))")
        await waitUntil(seconds: Double(count) * 3 + 30) { model.pending.allSatisfy { $0.failure != nil } }
        expect(model.tracks.count == count - 3, "every downloaded song prepared (\(model.tracks.count) of \(count - 3))")
        expect(!model.pending.contains { $0.failure == "Download broke" || $0.failure == "Could not read this file" },
               "no half written file reached the queue")
        expect(Set(model.tracks.compactMap(\.spotifyId)).count == count - 3, "every prepared song knows its Spotify id")

        lag.phase("step 1")
        print("2. Update the playlist: nothing new, unticked songs stay unticked")
        await model.updatePlaylist(playlist!)
        if let again = model.spotifyReview {
            expect(again.initial.isDisjoint(with: unticked), "songs unticked last time start unticked")
            expect(again.queued.count == count - 2, "songs in the queue marked In queue")
            model.confirmSpotifyReview(selected: again.initial)
            expect(model.pending.count + model.tracks.count == count - 2, "nothing added twice")
        } else {
            expect(false, "update opens the picker")
        }

        lag.phase("step 2")
        print("3. Cancel a download halfway")
        configure(count: 30, delay: 0.25, missing: "")
        await model.addFromSpotify("https://open.spotify.com/album/1A2GTWGtFfWp7KSQTwWOyo")
        if let album = model.spotifyReview {
            model.confirmSpotifyReview(selected: album.initial)
            let id = album.playlistId
            await waitUntil(seconds: 30) { (model.downloadProgress[id]?.finished ?? 0) >= 3 }
            if let target = model.playlists.first(where: { $0.id == id }) { model.cancelDownload(target) }
            expect(model.downloadProgress[id] == nil, "progress gone at once")
            try? await Task.sleep(for: .seconds(5))
            let left = model.pending.filter { $0.playlistId == id && $0.waitingForDownload }
            expect(left.isEmpty, "songs still waiting left the queue (\(left.map { $0.stage ?? $0.failure ?? "?" }))")
            expect(helpersRunning() == 0, "no spotDL left running")
            if let target = model.playlists.first(where: { $0.id == id }) {
                let kept = model.songs(for: target).count
                expect(kept < 30, "stopped songs are not resumed after a relaunch (\(kept) kept)")
            }
        }

        lag.phase("step 3")
        print("4. Two playlists at once: the second waits its turn")
        configure(count: 8, delay: 0.1, missing: "")
        await model.addFromSpotify("https://open.spotify.com/playlist/0000000000000000000001")
        let first = model.spotifyReview
        if let first { model.confirmSpotifyReview(selected: first.initial) }
        await model.addFromSpotify("https://open.spotify.com/playlist/0000000000000000000002")
        let second = model.spotifyReview
        if let first, let second {
            model.confirmSpotifyReview(selected: second.initial)
            expect(model.downloadProgress[second.playlistId]?.started == false, "the second waits for the first")
            expect(model.pending.contains { $0.playlistId == second.playlistId && $0.stage == "Waiting for another download" },
                   "its songs say they wait for another download")
        }
        await waitUntil(seconds: 60) { model.downloadProgress.isEmpty && model.spotifyLane.running == nil }
        expect(helpersRunning() == 0, "both finished, nothing left running")

        lag.phase("step 4")
        print("5. spotDL goes silent: it is stopped, then Retry finishes the songs")
        setenv("KNOB_SPOTDL_IDLE", "3", 1)
        configure(count: 6, delay: 0.05, missing: "")
        setenv("FAKE_HANG", "2", 1)
        await model.addFromSpotify("https://open.spotify.com/playlist/0000000000000000000003")
        if let stuck = model.spotifyReview {
            model.confirmSpotifyReview(selected: stuck.initial)
            let started = Date()
            await waitUntil(seconds: 40) { model.downloadProgress[stuck.playlistId] == nil }
            expect(Date().timeIntervalSince(started) < 20, String(format: "stopped after %.0fs of silence", Date().timeIntervalSince(started)))
            let stopped = model.pending.filter { $0.playlistId == stuck.playlistId && $0.failure == "Stopped" }.count
            expect(stopped == 4, "songs after the stall say Stopped (\(stopped))")
            unsetenv("FAKE_HANG")
            if let target = model.playlists.first(where: { $0.id == stuck.playlistId }) {
                expect(model.failedCount(in: target) == 4, "the playlist row offers Retry for 4")
                model.retryFailed(target)
                await waitUntil(seconds: 40) { model.downloadProgress[stuck.playlistId] == nil && model.spotifyLane.running == nil }
                expect(model.failedCount(in: target) == 0, "Retry downloaded them")
            }
        }
        unsetenv("KNOB_SPOTDL_IDLE")

        lag.phase("step 5")
        print("6. A helper that leaves a child holding its output does not hang the download")
        configure(count: 3, delay: 0.02, missing: "")
        setenv("FAKE_CHILD", "1", 1)
        await model.addFromSpotify("https://open.spotify.com/playlist/0000000000000000000004")
        if let child = model.spotifyReview {
            model.confirmSpotifyReview(selected: child.initial)
            let started = Date()
            await waitUntil(seconds: 30) { model.downloadProgress[child.playlistId] == nil }
            expect(Date().timeIntervalSince(started) < 10, String(format: "finished in %.1fs", Date().timeIntervalSince(started)))
        }
        unsetenv("FAKE_CHILD")

        lag.phase("step 6")
        print("7. Quit in the middle, open again: the download continues")
        configure(count: 10, delay: 0.3, missing: "")
        await model.addFromSpotify("https://open.spotify.com/playlist/0000000000000000000005")
        if let resume = model.spotifyReview {
            model.confirmSpotifyReview(selected: resume.initial)
            await waitUntil(seconds: 20) { (model.downloadProgress[resume.playlistId]?.finished ?? 0) >= 2 }
            lag.phase("step 7 downloading")
            // What Knob does on quit; it waits up to 0.3s on purpose while quitting.
            KnobShiftSpotDL.shared.cancelAll()
            model.persistQueueNow()
            try? await Task.sleep(for: .seconds(1))
            lag.phase("quitting (expected)")
            lag.resetWorst()
            configure(count: 10, delay: 0.02, missing: "")
            let reopened = KnobShiftModel(restoresQueue: true)
            lag.phase("opening Knob again")
            await waitUntil(seconds: 60) {
                reopened.pending.contains { $0.playlistId == resume.playlistId } && reopened.downloadProgress.isEmpty
                    && reopened.spotifyLane.running == nil
            }
            let folder = reopened.playlists.first { $0.id == resume.playlistId }.map(KnobShiftPlaylists.folder(for:))
            let files = folder.map { KnobShiftPlaylists.files(in: $0).count } ?? 0
            expect(files == 10, "all 10 songs downloaded after reopening (\(files))")

            lag.phase("step 7")
            print("8. Open again, remove a playlist before its songs are prepared: they leave with it")
            let waiting = KnobShiftModel(restoresQueue: false)
            if let playlist = waiting.playlists.first(where: { $0.id == resume.playlistId }) {
                // Songs come back after a relaunch as bare file paths, through this same call.
                waiting.enqueueFiles(Array(KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist)).values))
                expect(waiting.pending.count == 10 && waiting.pending.allSatisfy { $0.playlistId == playlist.id && $0.spotifyId != nil },
                       "songs back from a relaunch know their playlist")
                waiting.removePlaylist(playlist)
                expect(waiting.pending.isEmpty, "no song is left pointing at the moved files (\(waiting.pending.count) left)")
            } else {
                expect(false, "the playlist is there after reopening")
            }

            lag.phase("step 8")
            print("9. Shuffle on, open again: shuffle and its order come back")
            let present = { (paths: [String]) in paths.filter { FileManager.default.fileExists(atPath: $0) } }
            // Real songs in the queue, or an empty one would pass this by itself.
            let songs = model.playlists.flatMap { KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: $0)).values }
            await model.addTracks(Array(songs.prefix(8)))
            expect(model.tracks.count >= 4, "songs in the queue to shuffle (\(model.tracks.count))")
            if !model.isShuffled { model.toggleShuffle() }
            let shuffled = present(model.tracks.map(\.url.path))
            let ownOrder = present(model.unshuffled.map(\.url.path))
            model.persistQueueNow()
            let shuffledBack = KnobShiftModel(restoresQueue: true)
            await waitUntil(seconds: 60) { shuffledBack.isShuffled && shuffledBack.pending.allSatisfy { $0.failure != nil || $0.waitingForDownload } }
            expect(shuffledBack.isShuffled, "shuffle is still on after reopening")
            expect(shuffledBack.tracks.map(\.url.path) == shuffled, "in the same shuffled order")
            expect(shuffledBack.unshuffled.map(\.url.path) == ownOrder, "and turning it off still gives your own order")

            lag.phase("step 9")
            print("10. All Songs: every playlist's songs in one list, Shuffle All keeps your own order")
            let library = KnobShiftModel(restoresQueue: false)
            let all = library.allPlaylistSongs().filter { $0.url != nil }
            expect(Set(all.map(\.id)).count == all.count && all.count >= 4, "each song listed once (\(all.count))")
            await library.shuffleAll(all, plays: false)
            expect(library.isShuffled && library.tracks.count == all.count, "they all join the queue with shuffle on (\(library.tracks.count))")
            expect(library.unshuffled.map(\.url.path) == all.compactMap(\.url?.path), "and turning it off gives their own order")

            lag.phase("step 10")
            print("11. A song not found gets its YouTube link pasted by hand")
            // yt-dlp gets a clean environment, so the stand in carries its test audio with it.
            let fakeDownloader = work.appendingPathComponent("fake-yt-dlp.sh")
            try? """
            #!/bin/sh
            out=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --dump-single-json) echo '{"entries":[{"id":"fOT0BUpITw8","title":"Song","channel":"Artist","duration":200},{"id":"aaaaaaaaaaa","title":"Long mix","duration":3600}]}'; exit 0 ;;
                    --output) out="$2"; shift ;;
                esac
                shift
            done
            cp "\(audio.path)" "$(printf '%s' "$out" | sed 's/%(ext)s/m4a/; s/%%/%/g')"
            """.write(to: fakeDownloader, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeDownloader.path)
            setenv("KNOB_YTDLP", fakeDownloader.path, 1)
            let picked = KnobShiftModel(restoresQueue: true)
            await waitUntil(seconds: 30) { picked.pending.contains { $0.failure == "Not found" } }
            if let row = picked.pending.first(where: { $0.failure == "Not found" }), let id = row.spotifyId, let list = picked.playlists.first(where: { $0.id == row.playlistId }) {
                expect(picked.useYouTubeLink("https://www.youtube.com/playlist?list=PLabc", forSong: id) != nil, "a playlist link is refused with a reason")
                let found = (try? await KnobShiftYouTube.shared.matches(for: "Artist Song", id: UUID())) ?? []
                expect(found.map(\.id) == ["fOT0BUpITw8"], "the search lists the song and leaves out a long mix (\(found.count))")
                expect(picked.useYouTubeVideo(found.first?.id ?? "", forSong: id) == nil, "clicking a match starts its download")
                let folder = KnobShiftPlaylists.folder(for: list)
                await waitUntil(seconds: 30) { KnobShiftPlaylists.files(in: folder)[id] != nil && !picked.pending.contains { $0.spotifyId == id && $0.waitingForDownload } }
                expect(KnobShiftPlaylists.files(in: folder)[id] != nil, "the video is saved under that song")
                expect(picked.playlistSongs(list).first { $0.id == id }?.url != nil, "and the song is ready in its playlist")
                expect(picked.playlists.first { $0.id == list.id }?.unavailable?.contains(id) != true, "and is no longer marked not found")
            } else {
                expect(false, "a not found song to test with")
            }
        }

        await finishUAT(lag)
    }

    private static func finishUAT(_ lag: LagMonitor) async {
        lag.phase("the last step")
        lag.stop()
        // exit() skips defer blocks, so the test files are removed here.
        KnobShiftSpotDL.shared.cancelAll()
        if let work = uatFolder { try? FileManager.default.removeItem(at: work) }
        UserDefaults.standard.removeObject(forKey: PersistKey.knobShiftQueue.rawValue)
        if let cache = KnobShiftAnalysisCache.folder { try? FileManager.default.removeItem(at: cache) }
        expect(lag.worst < 0.25, String(format: "longest main thread stall %.0f ms", lag.worst * 1_000))
        print(failures == 0 ? "KnobShift Spotify UAT passed" : "KnobShift Spotify UAT: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    private static var uatFolder: URL?

    private static func configure(count: Int, delay: Double, missing: String) {
        setenv("FAKE_COUNT", "\(count)", 1)
        setenv("FAKE_DELAY", "\(delay)", 1)
        setenv("FAKE_MISSING", missing, 1)
    }

    private static func waitUntil(seconds: Double, _ done: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private static func helpersRunning() -> Int {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "fake-spotdl.py"]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        try? pgrep.run()
        pgrep.waitUntilExit()
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").count
    }

    /// Three seconds of a 220 Hz tone with a beat, enough for the analysis to read it.
    private static func writeTone(to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2),
              let file = try? AVAudioFile(forWriting: url, settings: format.settings),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3) else { return false }
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            let data = buffer.floatChannelData![channel]
            for frame in 0..<Int(buffer.frameLength) {
                let time = Double(frame) / 44_100
                let kick = time.truncatingRemainder(dividingBy: 0.5) < 0.05 ? 0.6 : 0
                data[frame] = Float(0.3 * sin(2 * .pi * 220 * time) + kick * sin(2 * .pi * 60 * time))
            }
        }
        return (try? file.write(from: buffer)) != nil
    }
}

/// Measures how late the main thread wakes up: a long delay is a stall the user would feel.
@MainActor
final class LagMonitor {
    private(set) var worst: TimeInterval = 0
    private var phaseWorst: TimeInterval = 0
    private var task: Task<Void, Never>?

    /// The worst stall since the last call, for finding which step stalls.
    func phase(_ name: String) {
        print(String(format: "  (longest stall during %@: %.0f ms)", name, phaseWorst * 1_000))
        phaseWorst = 0
    }

    func start() {
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let asked = Date()
                try? await Task.sleep(for: .milliseconds(20))
                let late = Date().timeIntervalSince(asked) - 0.02
                if let self {
                    self.worst = max(self.worst, late)
                    self.phaseWorst = max(self.phaseWorst, late)
                }
            }
        }
    }

    func stop() { task?.cancel() }

    /// Forgets stalls so far, after a step that is allowed to stall (quitting).
    func resetWorst() { worst = 0 }
}
