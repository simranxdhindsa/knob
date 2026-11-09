import Foundation

/// Unit tests for KnobShift's Spotify import, run by `--knobshift-spotify-check selftest`:
/// reading spotDL's messages, progress, which songs start ticked, save files, the line
/// collector, the job lane, stopping process trees, and speed with thousands of songs.
extension KnobShiftSpotifyCheck {
    static func unitTests() async {
        print("Messages")
        let landed = KnobShiftImport.parse(#"Downloaded "Karan Aujla - Jee Karuga (feat. Sargi Maan)": https://music.youtube.com/watch?v=x"#)
        expect(landed?.event == "landed" && landed?.display == "Karan Aujla - Jee Karuga (feat. Sargi Maan)", "Downloaded line")
        let quoted = KnobShiftImport.parse(#"Downloaded "Shubh - Say "Hi"": https://x"#)
        expect(quoted?.display == #"Shubh - Say "Hi""#, "Downloaded line with quotes in the name")
        expect(KnobShiftImport.parse("Skipping Shubh - Why So (file already exists) (duplicate)")?.event == "landed", "already downloaded counts as landed")
        expect(KnobShiftImport.parse("Skipping Shubh - Why So (skip file found) x")?.display == "Shubh - Why So", "skip file")
        expect(KnobShiftImport.parse("LookupError: No results found for song: Shubh - No Luck")?.event == "notFound", "not found")
        expect(KnobShiftImport.parse("Skipping explicit song: Shubh - No Luck")?.event == "notFound", "explicit song left out")
        expect(KnobShiftImport.parse("Skipping result due to time match lower than 25%") == nil, "matching chatter ignored")
        expect(KnobShiftImport.parse("Saved 12 songs") == nil, "other lines ignored")
        expect(KnobShiftImport.key("Shubh - Daaru Sasti [Remix]") == KnobShiftImport.key("Shubh  -  Daaru Sasti "), "brackets and spacing do not matter")
        expect(KnobShiftImport.key("ਖੀਰ ਤੇ ਵੈਰ") == "ਖੀਰ ਤੇ ਵੈਰ", "Gurmukhi names kept")

        print("Progress")
        let list = (0..<10).map { song($0) }
        var progress = KnobShiftImport.Progress(songs: list + [list[0]])
        expect(progress.total == 10, "a song listed twice counts once")
        expect(progress.current.isEmpty, "nothing current before it starts")
        progress.started = true
        expect(progress.current == ["Song 0", "Song 1", "Song 2", "Song 3"], "current is the first four not finished")
        expect(progress.consume(#"Downloaded "Artist 1 - Song 1": u"#) == .landed(list[1].song_id), "landed event")
        expect(progress.consume(#"Downloaded "Artist 1 - Song 1": u"#) == nil, "the same song never counts twice")
        expect(progress.consume("No results found for song: Artist 2 - Song 2") == .notFound(list[2].song_id), "not found event")
        expect(progress.consume(#"Downloaded "Someone - Else": u"#) == nil, "songs of other lists ignored")
        expect(progress.finished == 2 && abs(progress.fraction - 0.2) < 0.001, "two of ten finished")
        expect(progress.current == ["Song 0", "Song 3", "Song 4", "Song 5"], "current moves past finished songs")
        progress.markLanded(list[2].song_id)
        expect(progress.finished == 2, "a missing song is not counted again as landed")
        expect(KnobShiftImport.Progress(songs: []).fraction == 0, "an empty list is 0 percent, not a division by zero")

        print("Picking songs")
        let ids = list.map(\.song_id)
        let initial = KnobShiftImport.initialSelection(songs: list, skipped: [ids[3]])
        expect(initial.count == 9 && !initial.contains(ids[3]), "songs unticked before start unticked")
        let skipped = KnobShiftImport.skipped(songs: list, selected: Set(ids.prefix(5)), queued: [ids[7]])
        expect(skipped == [ids[5], ids[6], ids[8], ids[9]], "unticked songs remembered, queued ones never")
        let rows = KnobShiftImport.newRows(songs: list + [list[1]], selected: Set(ids), queued: [ids[0]])
        expect(rows.map(\.song_id) == Array(ids.dropFirst()), "new rows: in order, once each, none already queued")
        await streamingTests(list)
        expect(KnobShiftImport.hasRoom(for: 40, available: 2_000_000_000), "room for 40 songs in 2 GB")
        expect(!KnobShiftImport.hasRoom(for: 100, available: 2_000_000_000), "no room for 100 songs in 2 GB")
        expect(KnobShiftImport.hasRoom(for: 1_000, available: nil), "unknown space does not block")

        print("Save files")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knobshift-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let rawList = list.map { #"{"name":"\#($0.name)","artists":["\#($0.artist)"],"artist":"\#($0.artist)","album_name":null,"duration":200,"song_id":"\#($0.song_id)","url":"u","list_name":"L","list_position":1,"isrc":"KEEP"}"# }
        let listing = KnobShiftSpotDL.listing(from: Data("[\(rawList.joined(separator: ","))]".utf8))
        expect(listing?.songs.count == 10 && listing?.raw.count == 10, "save file read")
        let wrapped = KnobShiftSpotDL.listing(from: Data(#"{"songs":[\#(rawList[0])]}"#.utf8))
        expect(wrapped?.songs.count == 1, "sync file with songs inside read")
        expect(KnobShiftSpotDL.listing(from: Data("not json".utf8)) == nil, "broken file refused")
        expect(KnobShiftSpotDL.listing(from: Data(#"[{"name":1}]"#.utf8)) == nil, "file without songs refused")
        let out = folder.appendingPathComponent("chosen.spotdl")
        try? KnobShiftSpotDL.writeSaveFile([ids[2], ids[0], "unknown"], raw: listing?.raw ?? [:], to: out)
        let back = (try? Data(contentsOf: out)).flatMap(KnobShiftSpotDL.listing(from:))
        expect(back?.songs.map(\.song_id) == [ids[2], ids[0]], "chosen songs written in order, unknown ones left out")
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        expect(text.contains("\"isrc\":\"KEEP\""), "every spotDL field kept, so spotDL can read it back")

        print("Line collector")
        let heard = Box<[String]>([])
        let collector = KnobShiftHelperProcess.LineCollector { line in heard.update { $0.append(line) } }
        collector.append(Data("\u{1B}[32mDownloaded \"A - B\": u\u{1B}[0m\nhalf ".utf8))
        collector.append(Data("line\rnext\n".utf8))
        collector.append(Data("unfinished".utf8))
        collector.flush()
        expect(heard.value == ["Downloaded \"A - B\": u", "half line", "next", "unfinished"], "colours removed, lines split on CR and LF, last line flushed (got \(heard.value))")
        let many = KnobShiftHelperProcess.LineCollector { _ in }
        many.append(Data((0..<5_000).map { "line \($0)" }.joined(separator: "\n").appending("\n").utf8))
        expect(many.lines.count == KnobShiftHelperProcess.LineCollector.keep && many.lines.last == "line 4999", "only the last lines kept in memory")

        print("Reading failures")
        expect(KnobShiftSpotDL.classify(["HTTP Error 429: Too Many Requests"]) == .rateLimited, "rate limited")
        expect(KnobShiftSpotDL.classify(["requests.exceptions.ConnectionError: Max retries exceeded"]) == .offline, "offline")
        expect(KnobShiftSpotDL.classify(["OSError: [Errno 28] No space left on device"]) == .noSpace, "disk full")
        expect(KnobShiftSpotDL.classify(["Saved 3 songs"]) == nil, "a normal run is no failure")
        let thumbnail = "https://image-cdn-fa.spotifycdn.com/image/ab67616d00001e0201ea9f0d1cc7c6a67766b7bd"
        expect(KnobShiftArtwork.sharpLink(fromThumbnail: thumbnail)?.absoluteString == "https://i.scdn.co/image/ab67616d000082c101ea9f0d1cc7c6a67766b7bd",
               "a cover's link gives its largest size")
        expect(KnobShiftArtwork.sharpLink(fromThumbnail: "https://example.com/image/notacover") == nil, "anything else gives no link")
        // YouTube says this once, early in a long run, and hundreds of lines follow it.
        let long = KnobShiftHelperProcess.LineCollector { _ in }
        long.append(Data("Sign in to confirm you're not a bot\n".utf8))
        for number in 0..<400 { long.append(Data("403 line \(number)\n".utf8)) }
        expect(KnobShiftSpotDL.classify(long.lines) == .youtubeBlocked, "a bot check early in a long run still counts")

        await laneTests()
        await processTests()
        await speedTests(folder: folder)
    }

    private static func laneTests() async {
        print("Job lane")
        let lane = KnobShiftLane()
        let order = Box<[String]>([])
        let gate = Box(false)
        lane.enqueue("a") {
            order.update { $0.append("a start") }
            while !gate.value { try? await Task.sleep(for: .milliseconds(10)) }
            order.update { $0.append("a end") }
        }
        expect(lane.enqueue("b") { order.update { $0.append("b") } }, "second job queued")
        expect(!lane.enqueue("b") { order.update { $0.append("b again") } }, "same job never queued twice")
        expect(lane.enqueue("c") { order.update { $0.append("c") } }, "third job queued")
        expect(lane.removeWaiting("c"), "a waiting job can be called off")
        try? await Task.sleep(for: .milliseconds(50))
        expect(lane.running == "a" && order.value == ["a start"], "one job at a time")
        expect(lane.enqueue("a") { order.update { $0.append("a again") } }, "a running job can be queued again for more work")
        gate.value = true
        for _ in 0..<100 where lane.running != nil { try? await Task.sleep(for: .milliseconds(20)) }
        expect(order.value == ["a start", "a end", "b", "a again"], "jobs run in order, called off ones never (got \(order.value))")
    }

    private static func processTests() async {
        print("Stopping spotDL and everything it started")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/sleep 60 & /bin/sh -c '/bin/sleep 60; true' & wait"]
        try? process.run()
        try? await Task.sleep(for: .milliseconds(300))
        let tree = KnobShiftHelperProcess.descendants(of: process.processIdentifier)
        expect(tree.count >= 3, "children and grandchildren found (\(tree.count))")
        KnobShiftHelperProcess.stopTree(process.processIdentifier, grace: 0.5, wait: true)
        try? await Task.sleep(for: .milliseconds(200))
        let alive = (tree + [process.processIdentifier]).filter { kill($0, 0) == 0 }
        expect(alive.isEmpty, "the whole tree is gone (still alive: \(alive))")
    }

    private static func speedTests(folder: URL) async {
        print("A thousand songs")
        let count = 1_000
        let songs = (0..<count).map { song($0) }
        var started = Date()
        var progress = KnobShiftImport.Progress(songs: songs)
        progress.started = true
        for index in stride(from: 0, to: count, by: 1) { _ = progress.consume(#"Downloaded "Artist \#(index) - Song \#(index)": u"#) }
        let consumeTime = Date().timeIntervalSince(started)
        expect(progress.finished == count && consumeTime < 2, String(format: "1000 download lines read in %.2fs", consumeTime))
        started = Date()
        _ = KnobShiftImport.newRows(songs: songs, selected: Set(songs.map(\.song_id)), queued: Set(songs.prefix(500).map(\.song_id)))
        let rowsTime = Date().timeIntervalSince(started)
        expect(rowsTime < 0.2, String(format: "1000 songs checked against 500 queued in %.3fs", rowsTime))

        let model = KnobShiftModel(restoresQueue: false)
        let urls = (0..<count).map { folder.appendingPathComponent("song \($0).m4a") }
        started = Date()
        model.enqueueFiles(urls)
        model.enqueueFiles(urls)
        let addTime = Date().timeIntervalSince(started)
        expect(model.pending.count == count && addTime < 1, String(format: "1000 files added, and again as duplicates, in %.2fs", addTime))
        var rows = model.pending
        for index in rows.indices { rows[index].playlistId = "p"; rows[index].spotifyId = songs[index].song_id; rows[index].waitingForDownload = true }
        model.pending = rows
        started = Date()
        model.markRows(of: "p", ids: Set(songs.map(\.song_id)), failure: "Not found")
        let markTime = Date().timeIntervalSince(started)
        expect(markTime < 0.2 && model.pending.allSatisfy { $0.failure == "Not found" },
               String(format: "1000 rows marked at once in %.3fs", markTime))
        started = Date()
        _ = model.queuedSpotifyIds()
        expect(Date().timeIntervalSince(started) < 0.1, "queued ids of 1000 rows in one pass")
    }

    /// A long list arrives in two parts (the first 100, then the rest), and Add All runs in the
    /// background: nothing may be added twice, songs in the queue stay put, and songs unticked
    /// before stay out.
    @MainActor
    private static func streamingTests(_ list: [KnobShiftSpotDL.Song]) async {
        print("Long lists arriving in parts")
        let ids = list.map(\.song_id)
        let first = Array(list.prefix(4)), rest = Array(list[3...])
        let merged = KnobShiftImport.merged(first, rest)
        expect(merged.map(\.song_id) == ids, "the rest joins the first part once, overlap dropped, in list order")
        expect(KnobShiftImport.merged(first, rest.reversed()).map(\.song_id) == ids, "songs arriving out of order go back in list order")
        expect(KnobShiftImport.merged(first, first).map(\.song_id) == Array(ids.prefix(4)), "the same part twice changes nothing")
        expect(KnobShiftImport.merged(list + [list[2]], []).map(\.song_id) == ids, "a song listed twice in one list shows once")
        expect(KnobShiftImport.merged([], list).count == 10, "nothing first, all of the rest")

        print("Add All")
        let all = KnobShiftImport.addAllSelection(songs: list, skipped: [ids[4]])
        expect(all.count == 9 && !all.contains(ids[4]), "a song unticked before stays out of Add All")
        let rows = KnobShiftImport.newRows(songs: list + [list[1]], selected: all, queued: [ids[0], ids[1]])
        expect(rows.map(\.song_id) == [ids[2], ids[3], ids[5], ids[6], ids[7], ids[8], ids[9]], "Add All skips songs already in the queue, unticked ones and repeats")
        expect(KnobShiftImport.newSongCount(songs: list + [list[5]], queued: [ids[0], ids[1]], skipped: [ids[4]]) == 7,
               "new songs counted once each, without queued or unticked ones")
        expect(KnobShiftImport.newSongCount(songs: list, queued: Set(ids), skipped: []) == 0, "a list fully in the queue has nothing new")

        print("The picker filling up")
        let model = KnobShiftModel(restoresQueue: false)
        model.showSpotifyReview(playlistId: "p1", name: "Long list", kind: .playlist, query: "q", songs: first, queued: [ids[0]],
                                skipped: [], isUpdate: true, loadingMore: true)
        expect(model.spotifyReview?.songs.count == 4 && model.spotifyReview?.loadingMore == true, "the first part shows at once, still loading")
        expect(model.spotifyReview?.initial.contains(ids[0]) == true, "a queued song starts ticked")
        model.addToSpotifyReview(playlistId: "other", songs: rest, skipped: [], finished: true)
        expect(model.spotifyReview?.songs.count == 4, "songs of another list never join this one")
        model.addToSpotifyReview(playlistId: "p1", songs: rest, skipped: [ids[6]], finished: true)
        expect(model.spotifyReview?.songs.map(\.song_id) == ids, "the rest joins once, in order")
        expect(model.spotifyReview?.initial.contains(ids[6]) == false && model.spotifyReview?.initial.contains(ids[7]) == true,
               "new songs start ticked unless unticked before")
        expect(model.spotifyReview?.loadingMore == false, "loading ends with the last part")
        model.addToSpotifyReview(playlistId: "p1", songs: rest, skipped: [], finished: true)
        expect(model.spotifyReview?.songs.count == 10, "the rest arriving again adds nothing")
    }

    static func song(_ index: Int) -> KnobShiftSpotDL.Song {
        let json = #"{"name":"Song \#(index)","artists":["Artist \#(index)"],"artist":"Artist \#(index)","album_name":null,"duration":200,"song_id":"id\#(String(format: "%020d", index))","url":"u","list_name":"L","list_position":\#(index + 1)}"#
        return try! JSONDecoder().decode(KnobShiftSpotDL.Song.self, from: Data(json.utf8))
    }
}

/// A value shared with test closures.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
    func update(_ change: (inout Value) -> Void) { lock.lock(); change(&stored); lock.unlock() }
}
