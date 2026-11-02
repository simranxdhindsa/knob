import AppKit
import Foundation

/// `--knobshift-spotify-check selftest [FILE...]` checks KnobShift's Spotify import without the
/// network: link parsing, Spotify ids in file names, folder names, and removing, restoring and
/// purging a playlist in a temporary folder; any FILEs given have their tags read.
/// `--knobshift-spotify-check LINK` reads a real list through the bundled spotDL (no download)
/// and prints it in Spotify's order.
@MainActor
enum KnobShiftSpotifyCheck {
    static func run(_ arguments: [String]) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            if arguments.first == "selftest" {
                await selfTest(files: Array(arguments.dropFirst()))
            } else if let link = arguments.first {
                await readList(link)
            }
            exit(0)
        }
        app.run()
    }

    private static func selfTest(files: [String]) async {
        // Links.
        let id = "37i9dQZF1E8UXBoz02kGID"
        expect(KnobShiftPlaylists.parseLink("https://open.spotify.com/playlist/\(id)?si=abc")?.kind == .playlist, "playlist link")
        expect(KnobShiftPlaylists.parseLink("https://open.spotify.com/intl-en/album/\(id)")?.kind == .album, "album link with a region")
        expect(KnobShiftPlaylists.parseLink("spotify:track:\(id)")?.link == "https://open.spotify.com/track/\(id)", "spotify: song address")
        expect(KnobShiftPlaylists.parseLink("https://youtube.com/watch?v=x") == nil, "not a Spotify link")
        expect(KnobShiftPlaylists.parseLink("hello") == nil, "plain text")
        // File names.
        let file = "07 Jee Karuga (feat. Sargi Maan) - Kulwinder Sohi [\(id)]"
        expect(KnobShiftPlaylists.spotifyId(inFileName: file) == id, "Spotify id from a file name")
        expect(KnobShiftPlaylists.plainTitle(file) == "Jee Karuga (feat. Sargi Maan) - Kulwinder Sohi", "plain title")
        expect(KnobShiftModel.Track.split(file).name == "Jee Karuga (feat. Sargi Maan)", "name without position and id")
        expect(KnobShiftPlaylists.plainTitle("18 Lakh - Rehal") == "18 Lakh - Rehal", "ordinary titles untouched")
        expect(KnobShiftPlaylists.spotifyId(inFileName: "Song [short]") == nil, "only real ids")

        // Folders, remove, restore and purge, in a temporary place.
        let root = KnobShiftPlaylists.root
        guard root.path.hasPrefix("/private/tmp") || root.path.hasPrefix("/tmp")
                || root.path.hasPrefix(FileManager.default.temporaryDirectory.path) else {
            print("  Skipping remove and restore: set KNOB_SPOTIFY_ROOT to a temporary folder to run them.")
            return await finish(files)
        }
        try? FileManager.default.removeItem(at: root)
        let name = KnobShiftPlaylists.folderName(for: "Road/Trip: Mix", taken: [])
        expect(name == "Road Trip  Mix", "unsafe characters removed from folder names (got \(name))")
        expect(KnobShiftPlaylists.folderName(for: "Road/Trip: Mix", taken: [name]) == "\(name) 2", "folder names never clash")
        let playlist = KnobShiftPlaylist(id: id, name: "Road Trip", link: "https://open.spotify.com/playlist/\(id)", kind: .playlist,
                                         folderName: name, spotifyOrder: [id], addedAt: Date())
        let folder = KnobShiftPlaylists.folder(for: playlist)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: folder.appendingPathComponent("\(file).m4a").path, contents: Data([0]))
        expect(KnobShiftPlaylists.files(in: folder)[id] != nil, "downloaded file found by its id")
        KnobShiftPlaylists.save(KnobShiftPlaylists.Index(playlists: [playlist], removed: []))
        expect(KnobShiftPlaylists.origin(of: folder.appendingPathComponent("\(file).m4a"))?.playlistId == id, "file knows its playlist")

        let removed = try? KnobShiftPlaylists.moveToRemoved(playlist)
        expect(removed != nil && !FileManager.default.fileExists(atPath: folder.path), "remove moves the folder away")
        if let removed {
            let restored = try? KnobShiftPlaylists.restore(removed, taken: [])
            expect(restored.map { KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: $0))[id] != nil } == true, "restore brings the songs back")
            let old = try? KnobShiftPlaylists.moveToRemoved(restored ?? playlist, at: Date().addingTimeInterval(-31 * 86_400))
            var index = KnobShiftPlaylists.Index(playlists: [], removed: old.map { [$0] } ?? [])
            KnobShiftPlaylists.purgeExpired(&index)
            expect(index.removed.isEmpty, "removed for over 30 days is deleted for good")
            expect(old.map { !FileManager.default.fileExists(atPath: KnobShiftPlaylists.removedRoot.appendingPathComponent($0.folderName).path) } == true,
                   "its folder is gone")
        }
        try? FileManager.default.removeItem(at: root)
        await finish(files)
    }

    private static func finish(_ files: [String]) async {
        for path in files {
            let tags = await KnobShiftTags.read(URL(fileURLWithPath: path))
            print("  Tags of \((path as NSString).lastPathComponent): title \(tags?.title ?? "none"), artists \(tags?.artist ?? "none"), album \(tags?.album ?? "none")")
        }
        print(failures == 0 ? "KnobShift Spotify self test passed" : "KnobShift Spotify self test: \(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static func readList(_ link: String) async {
        guard KnobShiftSpotDL.isAvailable else {
            print("KnobShift Spotify check: spotDL is not bundled in this build (bash packaging/fetch-spotdl.sh, then rebuild).")
            exit(1)
        }
        do {
            let songs = try await KnobShiftSpotDL.shared.list(link, userAuth: KnobShiftSpotDL.isLoggedIn)
            for song in songs {
                print(String(format: "  %3d  %@  by %@  (%@)", song.list_position ?? 0, song.name, song.artists.joined(separator: ", "), song.song_id))
            }
            print("KnobShift Spotify check passed: \(songs.count) song(s) from \(songs.first?.list_name ?? "Spotify")")
        } catch let failure as KnobShiftSpotDL.Failure {
            print("KnobShift Spotify check failed: \(failure.message)")
            exit(1)
        } catch {
            print("KnobShift Spotify check failed: \(error)")
            exit(1)
        }
    }

    private static var failures = 0

    private static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }
}
