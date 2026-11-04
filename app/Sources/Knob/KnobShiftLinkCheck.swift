import AppKit
import Network

/// `Knob --knobshift-link-check`: the iPhone sync's clashes (KnobShiftSyncPlan), the link's
/// framing and who may connect, then the real server and client talking over this Mac's own
/// network: a playlist read, two songs copied byte for byte, and bad requests refused.
/// `Knob --knobshift-link-serve` offers this Mac's real playlists on the network until stopped,
/// for trying the iPhone app (or its simulator) against it, without opening Knob's panel.
@MainActor
enum KnobShiftLinkCheck {
    private static var failures = 0

    static func expect(_ condition: Bool, _ name: String) {
        print(condition ? "  ok    \(name)" : "  FAIL  \(name)")
        if !condition { failures += 1 }
    }

    static func run() {
        planTests()
        framingTests()
        Task { @MainActor in
            await loopback()
            print(failures == 0 ? "All link checks passed." : "\(failures) link check(s) failed.")
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    static func serve() {
        let model = KnobShiftModel(restoresQueue: false)
        KnobShiftLinkServer.shared.start(model: model) { port in
            print("Offering \(model.playlists.count) playlist(s) on port \(port). Press Ctrl C to stop.")
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.run()
    }

    // MARK: Sync plan

    private static let root = URL(fileURLWithPath: "/phone/KnobShift/Spotify", isDirectory: true)
    private static func folder(_ playlist: KnobShiftPlaylist) -> URL { root.appendingPathComponent(playlist.folderName) }
    private static func id(_ n: Int) -> String { String(repeating: "a", count: 21) + String(n) }
    private static func playlist(_ id: String, _ name: String, songs: [String], folder: String? = nil, skipped: [String]? = nil) -> KnobShiftPlaylist {
        KnobShiftPlaylist(id: id, name: name, link: "https://open.spotify.com/playlist/\(id)", kind: .playlist,
                          folderName: folder ?? name, spotifyOrder: songs, addedAt: Date(timeIntervalSince1970: 0), skipped: skipped)
    }
    private static func song(_ id: String, size: Int64? = 1_000) -> KnobShiftLink.Library.Song {
        .init(id: id, file: size == nil ? nil : "01 Song - Artist [\(id)].m4a", size: size, name: "Song \(id.suffix(1))", artist: "Artist")
    }
    private static func library(_ entries: [(KnobShiftPlaylist, [KnobShiftLink.Library.Song])], downloading: Bool = false) -> KnobShiftLink.Library {
        .init(version: KnobShiftLink.version, mac: "Test Mac", playlists: entries.map { .init(playlist: $0.0, songs: $0.1, downloading: downloading) })
    }
    private static func plan(_ library: KnobShiftLink.Library, _ phone: KnobShiftSyncPlan.Phone) -> KnobShiftSyncPlan.Result {
        KnobShiftSyncPlan.plan(library, phone: phone, folder: folder) { name, taken, _ in
            var candidate = name, number = 2
            while taken.contains(candidate) { candidate = "\(name) \(number)"; number += 1 }
            return candidate
        }
    }

    static func planTests() {
        let (a, b, c, x) = (id(1), id(2), id(3), id(4))
        print("Placement")
        expect(KnobShiftSyncPlan.placement(of: x, in: [a, x, b], queue: [b, a], adding: []) == .after(a), "after the song before it in the playlist")
        expect(KnobShiftSyncPlan.placement(of: a, in: [a, x, b], queue: [b], adding: []) == .before(b), "before the next one when it is first")
        expect(KnobShiftSyncPlan.placement(of: a, in: [a, b], queue: [], adding: []) == .end, "at the end of an empty queue")
        expect(KnobShiftSyncPlan.insert(x, at: .after(a), into: [b, a, c]) == [b, a, x, c], "inserted after its anchor in a rearranged queue")
        expect(KnobShiftSyncPlan.insert(x, at: .before(c), into: [c, b]) == [x, c, b], "inserted before its anchor")
        expect(KnobShiftSyncPlan.insert(x, at: .after("gone"), into: [b]) == [b, x], "an anchor no longer queued puts it last")

        print("New playlist")
        let road = playlist("road00000000000000000a", "Road Trip", songs: [a, b, c])
        var result = plan(library([(road, [song(a), song(b), song(c)])]), .init(playlists: []))
        expect(result.transfers.map(\.songId) == [a, b, c], "every song copied, in the playlist's order")
        expect(result.rows.map(\.songId) == [a, b, c] && result.rows.allSatisfy(\.waiting), "rows show at once and wait for their files")
        expect(result.rows.map(\.placement) == [.end, .after(a), .after(b)], "rows chain after one another")
        expect(result.playlists.map(\.folderName) == ["Road Trip"], "the Mac's folder name is kept when it is free")

        print("Same playlist on both, queue rearranged on the iPhone")
        var onPhone = road
        onPhone.folderName = "Road Trip (phone)"
        let mine = (url: folder(onPhone).appendingPathComponent("01 Song - Artist [\(a)].m4a"), size: Int64(1_000))
        let mineB = (url: folder(onPhone).appendingPathComponent("02 Song - Artist [\(b)].m4a"), size: Int64(1_000))
        var renamed = road
        renamed.name = "Road Trip 2026"
        renamed.spotifyOrder = [a, x, b]
        result = plan(library([(renamed, [song(a), song(x), song(b)])]),
                      .init(playlists: [onPhone], files: [road.id: [a: mine, b: mineB]], queued: [b, a]))
        expect(result.transfers.map(\.songId) == [x], "only the missing song is copied")
        expect(result.rows.count == 1 && result.rows[0].placement == .after(a), "the new song goes after the one before it, wherever it was moved")
        expect(result.playlists[0].name == "Road Trip 2026" && result.playlists[0].folderName == "Road Trip (phone)", "Mac's name wins, the iPhone keeps its folder")
        expect(result.playlists[0].spotifyOrder == [a, x, b], "Mac's order wins")

        print("Same song in two playlists")
        let gym = playlist("gym000000000000000000a", "Gym", songs: [c, a])
        result = plan(library([(road, [song(a), song(b)]), (gym, [song(c), song(a)])]), .init(playlists: []))
        expect(result.transfers.filter { $0.songId == a }.count == 1, "copied from the Mac once")
        expect(result.copies.map(\.songId) == [a] && result.copies[0].to.path.contains("/Gym/"), "then copied on the iPhone into the other playlist")
        expect(result.rows.filter { $0.songId == a }.count == 1, "queued once")
        expect(result.duplicates == 1, "counted as a duplicate")

        print("Removed, taken out, and still downloading")
        result = plan(library([(road, [song(a)])]), .init(playlists: [], removedIds: [road.id]))
        expect(result.transfers.isEmpty && result.rows.isEmpty && result.keptRemoved == 1, "a playlist removed on the iPhone stays removed")
        result = plan(library([(onPhone, [song(a), song(b)])]),
                      .init(playlists: [onPhone], files: [road.id: [a: mine]], queued: [], declined: ["\(road.id)/\(a)"]))
        expect(!result.rows.contains { $0.songId == a } && result.rows.map(\.songId) == [b], "a song taken out of the queue is not added again")
        result = plan(library([(road, [song(a), song(b, size: nil)])], downloading: true), .init(playlists: []))
        expect(result.onMac == 1 && result.rows.last?.songId == b && result.rows.last?.waiting == true, "a song still downloading on the Mac waits in the queue")
        expect(!result.transfers.contains { $0.songId == b }, "and is not asked for yet")
        var refused = song(b, size: nil)
        refused.file = nil
        refused.problem = "YouTube paused"
        let failedList = library([(road, [song(a), refused])])
        result = plan(failedList, .init(playlists: []))
        expect(result.failedOnMac == 1 && result.onMac == 0 && !result.rows.contains { $0.songId == b }, "a song the Mac could not get is not added")
        expect(KnobShiftSyncPlan.problem(songId: b, playlistId: road.id, in: failedList) == "YouTube paused on your Mac", "a song waiting here shows the Mac's reason")
        expect(KnobShiftSyncPlan.problem(songId: a, playlistId: road.id, in: failedList) == nil, "a song on its way shows no problem")
        expect(KnobShiftSyncPlan.problem(songId: c, playlistId: road.id, in: failedList) == "Not on your Mac", "a song the Mac dropped says so")
        expect(KnobShiftSyncPlan.problem(songId: a, playlistId: "gone", in: failedList) == "Not on your Mac", "and so does one from a playlist it removed")
        let unticked = playlist(road.id, "Road Trip", songs: [a, b], skipped: [b])
        result = plan(library([(unticked, [song(a), song(b)])]), .init(playlists: []))
        expect(result.rows.map(\.songId) == [a], "songs unticked on the Mac are left out")

        print("Files already here")
        result = plan(library([(onPhone, [song(a)])]), .init(playlists: [onPhone], files: [road.id: [a: mine]], queued: [a]))
        expect(result.transfers.isEmpty && result.rows.isEmpty, "a whole copy is not copied again")
        let broken = (url: mine.url, size: Int64(400))
        result = plan(library([(onPhone, [song(a)])]), .init(playlists: [onPhone], files: [road.id: [a: broken]], queued: [a]))
        expect(result.transfers.map(\.destination) == [mine.url], "a copy of the wrong size is copied again in place")
        result = plan(library([(onPhone, [song(a)])]), .init(playlists: [onPhone], files: [road.id: [a: broken]], queued: [a], playing: mine.url))
        expect(result.transfers.isEmpty, "never replaced while it plays")

        print("Space and names")
        result = plan(library([(road, [song(a, size: 200 * 1024 * 1024), song(b, size: 200 * 1024 * 1024)])]),
                      .init(playlists: [], freeSpace: KnobShiftSyncPlan.spareSpace + 250 * 1024 * 1024))
        expect(result.transfers.count == 1 && result.noRoom == 1, "stops copying before the iPhone is full")
        let other = playlist("other0000000000000000a", "Road Trip", songs: [c])
        result = plan(library([(other, [song(c)])]), .init(playlists: [road]))
        expect(result.playlists.last?.folderName == "Road Trip 2", "a different playlist with the same folder name gets a free one")
        expect(KnobShiftSyncPlan.safeName("../../evil [\(a)].m4a", songId: a) == "\(a) [\(a)].m4a", "a path from the Mac is never used as one")
        expect(KnobShiftSyncPlan.safeName("01 Song [\(b)].m4a", songId: a) == "\(a) [\(a)].m4a", "a name with another song's id is replaced")
        expect(KnobShiftSyncPlan.safeName("song.exe", songId: a) == nil, "only audio files are taken")
        expect(KnobShiftSyncPlan.safeName("01 Song [yt-dQw4w9WgXcQ].m4a", songId: "dQw4w9WgXcQ") == "01 Song [yt-dQw4w9WgXcQ].m4a", "YouTube names kept")
    }

    static func framingTests() {
        print("Framing")
        let get = Data("GET /v1/library HTTP/1.1\r\nHost: knob\r\n\r\n".utf8)
        expect((try? KnobShiftLink.parseRequest(get))??.path == "/v1/library", "a whole request is read")
        expect((try? KnobShiftLink.parseRequest(get.prefix(20))) == .some(nil), "half a request waits for the rest")
        let post = Data("POST /v1/add HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345".utf8)
        expect((try? KnobShiftLink.parseRequest(post)) == .some(nil), "a body still arriving waits")
        let huge = Data("POST /v1/add HTTP/1.1\r\nContent-Length: 999999\r\n\r\n".utf8)
        expect((try? KnobShiftLink.parseRequest(huge)) == nil, "an oversized body is refused")
        expect((try? KnobShiftLink.parseRequest(Data("nonsense\r\n\r\n".utf8))) == nil, "a broken request is refused")
        let head = KnobShiftLink.responseHead(status: 200, type: "audio/mp4", length: 5) + Data("hello".utf8)
        let parsed = KnobShiftLink.parseResponseHead(head)
        expect(parsed?.status == 200 && parsed?.length == 5 && parsed?.bodyStart == Data("hello".utf8), "a reply's head and body split")
        func host(_ text: String) -> NWEndpoint { .hostPort(host: NWEndpoint.Host(text), port: 1) }
        expect(KnobShiftLink.isLocal(host("192.168.1.20")) && KnobShiftLink.isLocal(host("10.0.0.4")) && KnobShiftLink.isLocal(host("fe80::1")),
               "home network addresses are answered")
        expect(!KnobShiftLink.isLocal(host("8.8.8.8")) && !KnobShiftLink.isLocal(host("2001:4860::8888")), "addresses outside the home are not")
        expect(KnobShiftLink.filePath(playlistId: "yt:PL_a-b", songId: "dQw4w9WgXcQ") == "/v1/file/yt%3APL%5Fa%2Db/dQw4w9WgXcQ", "ids travel as one path part")
    }

    // MARK: Server and client together

    static func loopback() async {
        print("Server and client")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("knob-link-\(UUID().uuidString)")
        setenv("KNOB_SPOTIFY_ROOT", temp.appendingPathComponent("Spotify").path, 1)
        setenv("KNOB_YOUTUBE_ROOT", temp.appendingPathComponent("YouTube").path, 1)
        defer { try? FileManager.default.removeItem(at: temp) }
        let (a, b, c) = (id(1), id(2), id(3))
        let list = playlist("road00000000000000000a", "Road Trip", songs: [a, b, c, id(4)])
        let folder = KnobShiftPlaylists.folder(for: list)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let second = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try? first.write(to: folder.appendingPathComponent("01 Song One - Artist [\(a)].m4a"))
        try? second.write(to: folder.appendingPathComponent("02 Song Two - Artist [\(b)].m4a"))
        // spotDL writes straight into the folder, so a song on its way can already have a file.
        try? Data("half a song".utf8).write(to: folder.appendingPathComponent("03 Song Three - Artist [\(c)].m4a"))
        try? Data("secret".utf8).write(to: temp.appendingPathComponent("private.txt"))
        KnobShiftPlaylists.save(.init(playlists: [list]))

        let model = KnobShiftModel(restoresQueue: false)
        var row = KnobShiftModel.PendingSong(url: folder.appendingPathComponent("\(c).pending"))
        row.spotifyId = c
        row.playlistId = list.id
        row.spotifyName = "Song Three"
        row.waitingForDownload = true
        let d = id(4)
        var broken = row
        broken.spotifyId = d
        broken.spotifyName = "Song Four"
        broken.failure = "YouTube paused"
        model.pending = [row, broken]
        let port: UInt16 = await withCheckedContinuation { continuation in
            KnobShiftLinkServer.shared.start(model: model, advertise: false) { continuation.resume(returning: $0) }
        }
        let client = KnobShiftLinkClient(endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        do {
            let library = try KnobShiftLink.decoder().decode(KnobShiftLink.Library.self, from: try await client.get("/v1/library"))
            let songs = library.playlists.first?.songs ?? []
            expect(library.version == KnobShiftLink.version && library.playlists.count == 1, "the library is read")
            expect(songs.map(\.id) == [a, b, c, d], "its songs come in the playlist's order")
            expect(songs.first?.size == Int64(first.count) && songs.first?.name == "Song One" && songs.first?.artist == "Artist", "with sizes and names")
            expect(songs[2].file == nil && songs[2].name == "Song Three" && library.playlists.first?.downloading == true,
                   "a song still downloading is listed without a file")
            expect(songs[3].file == nil && songs[3].problem == "YouTube paused", "a song the Mac could not get carries the reason")
            do {
                try await client.download(KnobShiftLink.filePath(playlistId: list.id, songId: c), to: temp.appendingPathComponent("half.part"), expected: nil)
                expect(false, "a half written song is not sent")
            } catch { expect(true, "a half written song is not sent") }

            let target = temp.appendingPathComponent("copy.part")
            try await client.download(KnobShiftLink.filePath(playlistId: list.id, songId: a), to: target, expected: songs.first?.size)
            expect((try? Data(contentsOf: target)) == first, "a 1.5 MB song arrives byte for byte")
            try? FileManager.default.removeItem(at: target)
            try await client.download(KnobShiftLink.filePath(playlistId: list.id, songId: b), to: target, expected: songs.dropFirst().first?.size)
            expect((try? Data(contentsOf: target)) == second, "a second song too")
            try? FileManager.default.removeItem(at: target)
            do {
                try await client.download(KnobShiftLink.filePath(playlistId: list.id, songId: a), to: target, expected: 12)
                expect(false, "a size that does not match is refused")
            } catch { expect(true, "a size that does not match is refused") }
        } catch {
            expect(false, "the library and songs are read (\(error))")
        }
        for path in ["/v1/file/\(KnobShiftLink.encode(list.id))/..%2F..%2Fprivate.txt", "/v1/file/nope/\(a)", "/../private.txt"] {
            do {
                _ = try await client.get(path)
                expect(false, "\(path) is refused")
            } catch { expect(true, "\(path) is refused") }
        }
        do {
            _ = try await client.post("/v1/add", body: Data("not json".utf8))
            expect(false, "a broken add request is refused")
        } catch { expect(true, "a broken add request is refused") }
        do {
            let reply = try JSONDecoder().decode(KnobShiftLink.AddReply.self,
                                                 from: try await client.post("/v1/add", body: try JSONEncoder().encode(KnobShiftLink.AddRequest(link: "https://example.com/x"))))
            expect(!reply.ok && reply.message.contains("Spotify or YouTube"), "a link that is not Spotify or YouTube is turned down in words")
        } catch { expect(false, "an add reply comes back (\(error))") }
        KnobShiftLinkServer.shared.stop()
    }
}
