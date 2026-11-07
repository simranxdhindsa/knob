import Foundation

/// `--knobshift-playon-check selftest`: every rule of moving the music to another device that
/// needs no network or sound card.
enum KnobShiftPlayOnTests {
    typealias On = KnobShiftPlayOn
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func run() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("knob-playon-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        matching(folder)
        allowing()
        ordering()
        names()
        receiving(folder)
        handovers()
        timing()
        journeys()
        print(failures == 0 ? "Play On self test passed" : "Play On self test: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func song(_ key: String, playlist: On.Playlist? = nil) -> On.Song {
        On.Song(key: key, title: key, artist: nil, fileName: "\(key).m4a", size: 1_000, playlist: playlist)
    }

    private static func matching(_ folder: URL) {
        print("Which songs are the same")
        let spotify = folder.appendingPathComponent("06 No Luck - TEJAY [2uBAFvIOvyOm4Glz7LwehN].flac")
        let sameOther = folder.appendingPathComponent("Different name [2uBAFvIOvyOm4Glz7LwehN].m4a")
        let youtube = folder.appendingPathComponent("Song [yt-fOT0BUpITw8].m4a")
        for url in [spotify, sameOther, youtube] { try? Data([1, 2, 3]).write(to: url) }
        expect(On.key(for: spotify) == "id:2uBAFvIOvyOm4Glz7LwehN", "a Spotify song is known by its id")
        expect(On.key(for: spotify) == On.key(for: sameOther), "the same song matches whatever its file is called, m4a or FLAC")
        expect(On.key(for: youtube) == "id:fOT0BUpITw8", "a YouTube song is known by its id")
        let mine = folder.appendingPathComponent("my song.mp3"), copy = folder.appendingPathComponent("renamed.mp3")
        let other = folder.appendingPathComponent("other.mp3"), longer = folder.appendingPathComponent("longer.mp3")
        let bytes = Data((0..<5_000).map { UInt8($0 % 251) })
        try? bytes.write(to: mine)
        try? bytes.write(to: copy)
        try? Data(bytes.reversed()).write(to: other)
        try? (bytes + Data([1])).write(to: longer)
        expect(On.key(for: mine)?.hasPrefix("file:") == true, "a song of your own is known by its contents")
        expect(On.key(for: mine) == On.key(for: copy), "a renamed copy of your own song matches")
        expect(On.key(for: mine) != On.key(for: other), "different sound of the same size does not match")
        expect(On.key(for: mine) != On.key(for: longer), "the same start with a different size does not match")
        expect(On.key(for: folder.appendingPathComponent("missing.mp3")) == nil, "a missing file has no key")
    }

    private static func allowing() {
        print("Asking once")
        var allowed = On.Allowed()
        expect(!allowed.contains("phone"), "a new device has to ask")
        allowed.allow("phone")
        expect(allowed.contains("phone"), "after Allow it never asks again")
        expect(!allowed.contains("stranger"), "another device still has to ask")
        allowed.allow("")
        expect(!allowed.contains(""), "an empty id is never allowed")
        expect(allowed.ids.count == 1, "and isn't remembered")
    }

    private static func ordering() {
        print("What gets copied, and in what order")
        let songs = (0..<20).map { song("s\($0)") }
        var order = On.sendOrder(songs, current: 4, have: [])
        expect(order.first?.key == "s4", "the song playing goes first")
        expect(order.map(\.key) == ["s4", "s5", "s6", "s7", "s8", "s9"], "then only the next five, not all 20")
        order = On.sendOrder(songs, current: 4, have: ["s4", "s6"])
        expect(order.map(\.key) == ["s5", "s7", "s8", "s9"], "songs it already has are skipped")
        expect(On.sendOrder(songs, current: 18, have: []).map(\.key) == ["s18", "s19"], "the end of the queue stops there")
        expect(On.sendOrder(songs, current: 0, have: Set(songs.map(\.key))).isEmpty, "nothing to copy when it has them all")
        expect(On.sendOrder([], current: 0, have: []).isEmpty, "an empty queue copies nothing")
        expect(On.sendOrder(songs, current: 99, have: []).isEmpty, "a position past the end copies nothing")
        expect(On.sendOrder(songs, current: -1, have: []).isEmpty, "a position before the start copies nothing")
        expect(On.sendOrder([song("a"), song("a"), song("b")], current: 0, have: []).map(\.key) == ["a", "b"], "the same song twice copies once")
    }

    private static func names() {
        print("File names from another device")
        let key = "id:2uBAFvIOvyOm4Glz7LwehN"
        expect(On.safeFileName("06 No Luck [2uBAFvIOvyOm4Glz7LwehN].flac", key: key) == "06 No Luck [2uBAFvIOvyOm4Glz7LwehN].flac", "a good name stays")
        expect(On.safeFileName("ਸੁਫ਼ਨਾ.m4a", key: "file:abc") == "ਸੁਫ਼ਨਾ.m4a", "Gurmukhi names stay")
        for bad in ["../../evil.m4a", "/etc/passwd.m4a", "a/b.m4a", "..", ".hidden.m4a", "bad\u{0}.m4a", ""] {
            let safe = On.safeFileName(bad, key: "file:abc")
            expect(safe.map { !$0.contains("/") && !$0.hasPrefix(".") && !$0.contains("\u{0}") } ?? true, "no way out of the folder from \(bad.debugDescription)")
        }
        for bad in ["virus.app", "script.sh", "song.m4a.exe", "noextension", "page.html"] {
            expect(On.safeFileName(bad, key: "file:abc") == nil, "\(bad) is not a song, so it is refused")
        }
        expect(On.safeFileName("LOUD.FLAC", key: "file:abc") != nil, "capital letters in the type are fine")
        let long = String(repeating: "ਖ", count: 400) + ".m4a"
        expect((On.safeFileName(long, key: "file:abc")?.utf8.count ?? 999) <= 255, "a very long name is cut to fit a file name")
    }

    private static func receiving(_ folder: URL) {
        print("Receiving a file")
        func start(_ name: String = "song.m4a", size: Int64 = 10, free: Int64 = 10_000_000_000) throws -> On.Incoming {
            try On.Incoming(name: name, key: "file:abc", size: size, folder: folder, freeSpace: free)
        }
        func fails(_ failure: On.Incoming.Failure, _ what: String, _ body: () throws -> Void) {
            do { try body(); expect(false, what) } catch { expect(error as? On.Incoming.Failure == failure, what) }
        }
        fails(.tooBig, "a file over 300 MB is refused") { _ = try start(size: On.longestFile + 1) }
        fails(.tooBig, "a negative size is refused") { _ = try start(size: -1) }
        fails(.noSpace, "a file with no room for it is refused") { _ = try start(size: 1_000, free: 500_000_000) }
        fails(.badName, "a file that isn't a song is refused") { _ = try start("virus.app") }
        do {
            var file = try start()
            try file.add(Data(repeating: 1, count: 4))
            try file.add(Data(repeating: 2, count: 6))
            let final = try file.finish()
            expect((try? Data(contentsOf: final))?.count == 10, "pieces join up into the whole file")
            expect(final.lastPathComponent == "song.m4a" && final.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL, "it lands in the playlist folder")
            var again = try start()
            try again.add(Data(repeating: 3, count: 10))
            let second = try again.finish()
            expect(second != final, "a name already taken is never overwritten")
        } catch { expect(false, "receiving worked: \(error)") }
        do {
            var file = try start("short.m4a")
            try file.add(Data(repeating: 1, count: 4))
            fails(.wrongSize, "a file that stops short is refused") { _ = try file.finish() }
            expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("short.m4a").path), "and never appears as a song")
            var long = try start("long.m4a")
            fails(.tooLong, "more bytes than promised is refused") { try long.add(Data(repeating: 1, count: 11)) }
            long.cancel()
            var stopped = try start("stopped.m4a")
            try stopped.add(Data(repeating: 1, count: 2))
            stopped.cancel()
            try? Data([1]).write(to: folder.appendingPathComponent(".crashed.part"))
            try? Data([1]).write(to: folder.appendingPathComponent("keep.m4a"))
            On.Incoming.clearLeftovers(in: folder)
            expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("keep.m4a").path), "real songs are left alone")
            let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            expect(!left.contains { $0.contains(".part") }, "a cancelled copy or a crash leaves nothing behind")
        } catch { expect(false, "stopping worked: \(error)") }
    }

    private static func handovers() {
        print("Checking a handover")
        func handover(_ songs: Int = 2, current: Int = 0, position: Double = 10) -> On.Handover {
            On.Handover(songs: (0..<songs).map { song("s\($0)") }, current: current, position: position, isPlaying: true, isShuffled: false, sentAt: 0, effects: nil)
        }
        expect(On.isValid(handover()), "a normal handover is accepted")
        expect(!On.isValid(handover(0)), "an empty queue is refused")
        expect(!On.isValid(handover(current: 2)), "a song past the end is refused")
        expect(!On.isValid(handover(current: -1)), "a song before the start is refused")
        expect(!On.isValid(handover(position: -1)), "a time before the start is refused")
        expect(!On.isValid(handover(position: .nan)), "a time that isn't a number is refused")
        expect(!On.isValid(handover(position: .infinity)), "an endless time is refused")
        expect(!On.isValid(handover(20_001)), "an absurdly long queue is refused")
        var wire = handover()
        wire.songs[0].playlist = On.Playlist(id: "37i9", name: "ਪੰਜਾਬੀ Hits", link: "https://x")
        let decoded = (try? JSONEncoder().encode(wire)).flatMap { try? JSONDecoder().decode(On.Handover.self, from: $0) }
        expect(decoded == wire, "a handover survives the trip, playlist name included")
    }

    private static func timing() {
        print("Carrying on from the same moment")
        var playing = On.Handover(songs: [song("a")], current: 0, position: 60, isPlaying: true, isShuffled: false, sentAt: 1_000_000_000, effects: nil)
        expect(abs(On.startPosition(playing, goAt: 6_000_000_000, duration: 200) - 65) < 0.001, "a playing song moves on by the time that passed")
        expect(abs(On.startPosition(playing, goAt: 1_000_000_000, duration: 200) - 60) < 0.001, "no time passed, same place")
        expect(abs(On.startPosition(playing, goAt: 0, duration: 200) - 60) < 0.001, "a clock running backwards never moves it back")
        expect(On.startPosition(playing, goAt: 900_000_000_000, duration: 200) <= 199, "never past the end of the song")
        playing.isPlaying = false
        expect(abs(On.startPosition(playing, goAt: 6_000_000_000, duration: 200) - 60) < 0.001, "a paused song stays where it was")
    }

    /// Whole journeys through the handover, including every line of the plan's failure table.
    private static func journeys() {
        print("Journeys")
        func run(_ events: [On.Event]) -> On.Handoff {
            var handoff = On.Handoff(device: "Simran's iPhone")
            for event in events { handoff.handle(event) }
            return handoff
        }
        var state = run([.start])
        expect(state.stage == .waitingForAllow && state.stage.text == "Waiting for Allow", "first time, it waits for Allow")
        expect(state.stage.musicIsHere, "with the music still playing here")
        state = run([.start, .allowed, .needs(0)])
        expect(state.stage == .gettingReady && state.stage.text == "Getting ready", "a device with the songs goes straight to ready")
        state = run([.start, .allowed, .needs(3)])
        expect(state.stage == .copying(0) && state.stage.text == "Copying song, 0%", "a missing song shows copying")
        state = run([.start, .allowed, .needs(1), .copied(0.4)])
        expect(state.stage.text == "Copying song, 40%" && state.stage.musicIsHere, "copying shows its progress and music keeps playing")
        state = run([.start, .allowed, .needs(1), .copied(1), .ready, .switched])
        expect(state.stage == .playingThere && !state.stage.musicIsHere, "after the switch the music is only there")
        state = run([.start, .allowed, .needs(0), .mixRunning, .ready])
        expect(state.stage == .waitingForMix && state.stage.musicIsHere, "a running mix finishes before the switch")
        state = run([.start, .allowed, .needs(0), .mixRunning, .ready, .mixEnded])
        expect(state.stage == .gettingReady, "and the switch carries on after it")
        state = run([.start, .refused])
        expect(state.stage == .failed("Simran's iPhone didn't allow this.") && state.stage.musicIsHere, "Don't Allow leaves the music here")
        state = run([.start, .allowed, .needs(2), .copied(0.5), .connectionLost])
        expect(state.stage == .failed("Couldn't reach Simran's iPhone.") && state.stage.musicIsHere, "a lost connection while copying leaves the music here")
        state = run([.start, .allowed, .needs(0), .ready, .switched, .connectionLost])
        expect(state.stage == .lost && state.stage.text == "Lost the connection." && !state.stage.musicIsHere, "a lost connection after the switch: music plays on there")
        state = run([.start, .allowed, .noSpace])
        expect(state.stage == .failed("Not enough space on Simran's iPhone."), "no space leaves the music here")
        state = run([.start, .allowed, .needs(0), .noOutput])
        expect(state.stage == .failed("Simran's iPhone can't play sound right now.") && state.stage.musicIsHere, "no working output refuses the switch")
        state = run([.start, .refused, .ready, .switched])
        expect(state.stage == .failed("Simran's iPhone didn't allow this."), "nothing moves the music after a failure")
        state = run([.switched])
        expect(state.stage == .idle, "a switch with no handover is ignored")
        state = run([.start, .allowed, .needs(1), .copied(2)])
        expect(state.stage == .copying(1), "progress never shows over 100%")
        for stage in [On.Stage.waitingForAllow, .copying(0.5), .gettingReady, .waitingForMix, .playingThere, .lost] {
            expect(!stage.text.isEmpty && !stage.text.contains("-") && !stage.text.contains("—"), "\(stage) has words with no dashes")
        }
    }
}
