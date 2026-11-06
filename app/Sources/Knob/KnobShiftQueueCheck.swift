import Foundation

/// `--knobshift-queue-check`: Mix Order, Play Next and sorting on made up songs, no audio and no
/// files. Every song stays in the queue exactly once, the songs played and the one playing do not
/// move, half and double time count as close, and shuffle and Mix Order each give the user's own
/// order back.
@MainActor
enum KnobShiftQueueCheck {
    typealias Track = KnobShiftModel.Track
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func song(_ title: String, _ tempo: Double?, duration: TimeInterval = 200) -> Track {
        KnobShiftMixTests.song(title, tempo: tempo, duration: duration)
    }

    static func names(_ list: [Track]) -> [String] { list.map(\.title) }
    static func bpms(_ list: [Track]) -> String {
        list.map { $0.analysis.tempo.map { String(format: "%.0f", $0) } ?? "?" }.joined(separator: ", ")
    }

    /// A model holding these songs, with `playing` (an index) as the song on the deck.
    static func model(_ list: [Track], playing: Int?) -> KnobShiftModel {
        let model = KnobShiftModel(restoresQueue: false)
        model.tracks = list
        if let playing {
            model.nowPlaying = list[playing]
            model.currentIndex = playing
        }
        return model
    }

    /// The same numbers every time, spread over 60...190 BPM, one in ten without a tempo.
    static func randomSongs(_ count: Int, seed: UInt64 = 7) -> [Track] {
        var state = seed
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31)
        }
        return (0..<count).map { index in
            song("S\(index)", next() < 0.1 ? nil : 60 + next() * 130, duration: 120 + next() * 200)
        }
    }

    static func bigJumps(_ list: [Track]) -> Int {
        zip(list, list.dropFirst()).filter { KnobShiftMixOrder.jump(from: $0.analysis, to: $1.analysis) == .big }.count
    }

    static func run() {
        failures = 0
        realExample()
        rules()
        jumps()
        timing()
        toggles()
        playNext()
        sorting()
        persistence()
        print(failures == 0 ? "knobshift-queue-check: all ok" : "knobshift-queue-check: \(failures) FAIL")
    }

    static func realExample() {
        print("The real example")
        let list = [75, 148, 77, 172].map { song("\(Int($0))", $0) }
        let result = KnobShiftMixOrder.arranged(list, playingIndex: 0)
        print("  before: " + bpms(list) + "   after: " + bpms(result))
        let wide = [75, 172, 77, 148].map { song("\(Int($0))", $0) }
        let wideResult = KnobShiftMixOrder.arranged(wide, playingIndex: 0)
        print("  before: " + bpms(wide) + "   after: " + bpms(wideResult))
        expect(bigJumps(wideResult) <= bigJumps(wide), "the same songs in a worse order never get worse")
        let mixed = [75, 172, 148, 77, 130, 150, 98, 96, 128, 64].map { song("\(Int($0))", $0) }
        let mixedResult = KnobShiftMixOrder.arranged(mixed, playingIndex: 0)
        print("  before: " + bpms(mixed) + "\n  after:  " + bpms(mixedResult))
        expect(bigJumps(mixedResult) < bigJumps(mixed), "ten songs: fewer big tempo jumps (\(bigJumps(mixed)) before, \(bigJumps(mixedResult)) after)")
    }

    static func rules() {
        print("Rules")
        let list = randomSongs(60)
        let playing = 12
        let result = KnobShiftMixOrder.arranged(list, playingIndex: playing)
        expect(Set(names(result)) == Set(names(list)) && result.count == list.count, "every song kept exactly once")
        expect(Array(result[0...playing]) == Array(list[0...playing]), "songs played and the playing song do not move")
        let known = result[(playing + 1)...].filter { $0.analysis.tempo != nil }
        let missing = result[(playing + 1)...].filter { $0.analysis.tempo == nil }
        expect(Array(result.suffix(missing.count)) == missing && missing == list[(playing + 1)...].filter { $0.analysis.tempo == nil },
               "songs without a tempo go last in their current order (\(missing.count) of them)")
        expect(known.count + missing.count == list.count - playing - 1, "and none are dropped")
        expect(KnobShiftMixOrder.arranged(list, playingIndex: playing) == result, "the same input gives the same order")
        expect(KnobShiftMixOrder.arranged(list, playingIndex: nil)[0] == list[0], "with nothing playing the first song stays first")
        expect(bigJumps(result) < bigJumps(list), "fewer big jumps (\(bigJumps(list)) before, \(bigJumps(result)) after)")

        let octave = [song("A", 75), song("B", 172), song("C", 150), song("D", 120), song("E", 76)]
        let o = KnobShiftMixOrder.arranged(octave, playingIndex: 0)
        let posC = o.firstIndex { $0.title == "C" }!, posE = o.firstIndex { $0.title == "E" }!
        expect(abs(posC - posE) == 1, "75, 76 and 150 BPM sit together: half and double time count as close (\(bpms(o)))")
        expect(KnobShiftMixOrder.distance(75, 150)! < 0.001 && KnobShiftMixOrder.distance(100, 150)! > 0.3, "distance: 75 and 150 are close, 100 and 150 are not")

        let blind = [song("P", nil), song("Q", 120), song("R", nil), song("S", 80), song("T", 121)]
        let b = KnobShiftMixOrder.arranged(blind, playingIndex: 0)
        expect(b[0].title == "P" && names(b).sorted() == names(blind).sorted(), "a playing song with no tempo stays, and every song is kept")
        expect(names(b).suffix(1) == ["R"], "no tempo goes last")

        let none = (0..<5).map { song("N\($0)", nil) }
        expect(KnobShiftMixOrder.arranged(none, playingIndex: 1) == none, "a queue with no tempos at all is left as it is")
        expect(KnobShiftMixOrder.arranged([], playingIndex: nil).isEmpty, "an empty queue stays empty")
        let one = [song("Only", 100)]
        expect(KnobShiftMixOrder.arranged(one, playingIndex: 0) == one && KnobShiftMixOrder.arranged(one, playingIndex: nil) == one, "one song stays one song")
        expect(KnobShiftMixOrder.arranged(octave, playingIndex: 99).count == 5, "a playing index out of range is safe")
        expect(KnobShiftMixOrder.arranged(octave, playingIndex: 4) == octave, "playing the last song leaves nothing to arrange")
    }

    static func jumps() {
        print("Mix jump")
        typealias J = KnobShiftMixJump
        expect(KnobShiftMixOrder.jump(from: 120, to: 124) == J.smooth, "120 to 124 is smooth")
        expect(KnobShiftMixOrder.jump(from: 75, to: 150) == J.smooth, "75 to 150 is smooth (double time)")
        expect(KnobShiftMixOrder.jump(from: 150, to: 76) == J.smooth, "150 to 76 is smooth (half time)")
        expect(KnobShiftMixOrder.jump(from: 120, to: 135) == J.stretch, "120 to 135 stretches")
        expect(KnobShiftMixOrder.jump(from: 100, to: 130) == J.big, "100 to 130 is a big jump")
        expect(KnobShiftMixOrder.jump(from: nil, to: 130) == J.unknown && KnobShiftMixOrder.jump(from: 130, to: nil) == J.unknown, "a missing tempo is unknown")
        expect(KnobShiftMixOrder.jump(from: 0, to: 130) == J.unknown, "a tempo of zero is unknown")
    }

    static func timing() {
        print("Timing")
        let list = randomSongs(1000)
        let started = Date()
        let result = KnobShiftMixOrder.arranged(list, playingIndex: 3)
        let ms = Date().timeIntervalSince(started) * 1000
        print(String(format: "  1,000 songs arranged in %.0f ms", ms))
        expect(ms < 150, "fast enough for the main thread")
        expect(Set(names(result)).count == 1000 && result.count == 1000, "all 1,000 songs kept exactly once")
        expect(Array(result[0...3]) == Array(list[0...3]), "the first four did not move")
        var total = 0.0
        let jumpStart = Date()
        for (a, b) in zip(result, result.dropFirst()) { _ = KnobShiftMixOrder.jump(from: a.analysis, to: b.analysis); total += 1 }
        print(String(format: "  %.0f row marks in %.2f ms", total, Date().timeIntervalSince(jumpStart) * 1000))
    }

    static func toggles() {
        print("Mix Order and shuffle toggles")
        let list = randomSongs(30)
        let own = names(list)
        let m = model(list, playing: 5)
        m.toggleMixOrder()
        expect(m.isMixOrdered && !m.isShuffled, "Mix Order is on")
        expect(Array(m.tracks[0...5]) == Array(list[0...5]) && m.currentIndex == 5 && m.nowPlaying == list[5], "songs played and the playing song stayed, still playing")
        expect(names(m.tracks).sorted() == own.sorted(), "every song kept once")
        expect(m.upNext == m.tracks[6], "the next song is the one that now follows")
        m.toggleMixOrder()
        expect(!m.isMixOrdered && names(m.tracks) == own, "one more tap gives exactly your order back")

        m.toggleMixOrder()
        let arranged = names(m.tracks)
        m.toggleShuffle()
        expect(m.isShuffled && !m.isMixOrdered, "shuffle turns Mix Order off")
        expect(m.tracks[5] == list[5] || m.currentIndex == m.tracks.firstIndex(of: list[5]), "the playing song is kept")
        expect(names(m.unshuffled) == own, "your own order is still the one kept")
        m.toggleMixOrder()
        expect(m.isMixOrdered && !m.isShuffled && names(m.unshuffled) == own, "Mix Order turns shuffle off, your order still kept")
        m.toggleShuffle()
        m.toggleShuffle()
        expect(!m.isShuffled && !m.isMixOrdered && names(m.tracks) == own, "Mix Order, shuffle, shuffle off: your order is back (\(arranged.count) songs)")

        m.toggleMixOrder()
        let extra = song("Extra", 101)
        m.place(extra, at: nil)
        expect(m.tracks.contains(extra) && m.tracks.count == 31 && m.unshuffled.contains(extra), "a song added while it is on is not lost")
        m.refreshMixOrder()
        expect(m.tracks.count == 31 && Set(names(m.tracks)).count == 31, "and arranging again keeps all 31")
        m.toggleMixOrder()
        expect(names(m.tracks) == own + ["Extra"], "turning it off puts the new song last in your order")

        m.toggleMixOrder()
        m.move(fromOffsets: IndexSet(integer: 20), toOffset: 10)
        expect(m.isMixOrdered && names(m.unshuffled) == own + ["Extra"], "dragging changes the showing order only")
        m.toggleMixOrder()
        expect(names(m.tracks) == own + ["Extra"], "and your order is untouched after it")

        let idle = model(randomSongs(10), playing: nil)
        idle.toggleMixOrder()
        expect(idle.tracks.count == 10 && idle.tracks[0].title == "S0", "with nothing playing the first song stays first")
    }

    static func playNext() {
        print("Play Next")
        let list = (0..<8).map { song("P\($0)", 100 + Double($0)) }
        let m = model(list, playing: 2)
        m.playNext(ids: [list[6].id, list[5].id, list[0].id])
        expect(names(m.tracks) == ["P1", "P2", "P0", "P5", "P6", "P3", "P4", "P7"], "they go straight after the playing song in their queue order (\(names(m.tracks).joined(separator: " ")))")
        expect(m.currentIndex == 1 && m.nowPlaying == list[2], "the playing song keeps playing and its place is followed")
        expect(m.upNext == list[0], "the next song is the first moved")

        let withPlaying = model(list, playing: 2)
        withPlaying.playNext(ids: [list[2].id, list[7].id])
        expect(names(withPlaying.tracks) == ["P0", "P1", "P2", "P7", "P3", "P4", "P5", "P6"] && withPlaying.nowPlaying == list[2], "the playing song in the set stays where it is and the rest follow it")
        let onlyPlaying = model(list, playing: 2)
        onlyPlaying.playNext(ids: [list[2].id])
        expect(onlyPlaying.tracks == list, "only the playing song: nothing moves")

        let idle = model(list, playing: nil)
        idle.playNext(ids: [list[4].id, list[3].id])
        expect(names(idle.tracks).prefix(3) == ["P3", "P4", "P0"] && idle.currentIndex == 0 && idle.tracks.count == 8, "with nothing playing they go to the top")
        let unknown = model(list, playing: 1)
        unknown.playNext(ids: [UUID()])
        expect(unknown.tracks == list, "ids that are not in the queue do nothing")

        let big = randomSongs(20)
        let s = model(big, playing: 3)
        s.toggleShuffle()
        let own = names(s.unshuffled)
        let target = s.tracks[15]
        s.playNext(ids: [target.id])
        expect(s.isShuffled && s.tracks[s.currentIndex + 1] == target && names(s.unshuffled) == own, "in shuffle it moves in the showing order and your order is untouched")
        s.toggleShuffle()
        expect(names(s.tracks) == own, "and shuffle off still restores your order")
        let x = model(big, playing: 3)
        x.toggleMixOrder()
        let pick = x.tracks[17]
        x.playNext(ids: [pick.id])
        expect(x.isMixOrdered && x.tracks[x.currentIndex + 1] == pick && x.tracks.count == 20, "in Mix Order it works the same")
    }

    static func sorting() {
        print("Sorting")
        let list = [song("Zed - Cara", 120, duration: 250), song("Amy - Bea", nil, duration: 100),
                    song("Mid - Ann", 90, duration: 300), song("Low - Bea", 100, duration: 180)]
        let m = model(list, playing: 2)
        m.sortQueue(by: .bpm)
        expect(names(m.tracks) == ["Mid - Ann", "Low - Bea", "Zed - Cara", "Amy - Bea"] && m.nowPlaying == list[2] && m.tracks[m.currentIndex] == list[2],
               "BPM: slowest first, no tempo last, the playing song keeps playing (\(bpms(m.tracks)))")
        m.sortQueue(by: .length)
        expect(names(m.tracks) == ["Amy - Bea", "Low - Bea", "Zed - Cara", "Mid - Ann"] && m.tracks[m.currentIndex] == list[2], "Length: shortest first")
        m.sortQueue(by: .artist)
        expect(m.tracks.map(\.artist) == ["Ann", "Bea", "Bea", "Cara"] && m.tracks[m.currentIndex] == list[2], "Artist: A to Z")
        let before = names(m.tracks)
        m.sortQueue(by: .recentlyAdded)
        expect(names(m.tracks) == before.reversed(), "Recently added: newest first")
        expect(m.tracks[m.currentIndex] == list[2] && Set(names(m.tracks)) == Set(names(list)), "the playing song is still playing and every song is kept")

        let fresh = model(list, playing: 0)
        fresh.sortQueue(by: .recentlyAdded)
        expect(names(fresh.tracks) == names(list.reversed()), "Recently added: the last one added first")
        let shuffled = model(randomSongs(12), playing: 4)
        let own = names(shuffled.tracks)
        shuffled.toggleShuffle()
        shuffled.sortQueue(by: .recentlyAdded)
        expect(!shuffled.isShuffled && names(shuffled.tracks) == own.reversed() && shuffled.nowPlaying != nil,
               "sorting while shuffled sorts your own order and turns shuffle off")
        let empty = model([], playing: nil)
        empty.sortQueue(by: .bpm)
        empty.playNext(ids: [UUID()])
        empty.toggleMixOrder()
        expect(empty.tracks.isEmpty, "an empty queue survives every action")
        expect(KnobShiftQueueSort.allCases.map(\.title) == ["BPM", "Length", "Artist", "Recently added"] && !KnobShiftQueueSort.allCases.contains { $0.title.contains("-") },
               "the menu names have no dashes")
    }

    static func persistence() {
        print("Saved across a relaunch")
        let queueKey = PersistKey.knobShiftQueue.rawValue, arrangedKey = PersistKey.knobShiftShuffledQueue.rawValue
        let mixKey = PersistKey.knobShiftMixOrdered.rawValue
        let saved = [queueKey, arrangedKey, mixKey].map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip([queueKey, arrangedKey, mixKey], saved) { UserDefaults.standard.set(value, forKey: key) } }

        let list = randomSongs(15)
        let own = names(list)
        let m = model(list, playing: 2)
        m.toggleMixOrder()
        m.persistQueueNow()
        let arranged = names(m.tracks)
        expect(UserDefaults.standard.bool(forKey: mixKey) && UserDefaults.standard.stringArray(forKey: queueKey) == list.map(\.url.path), "Mix Order saves with your own order beside it")

        // The next launch: the songs come back in your order, then the saved arrangement is put back.
        let again = model(list, playing: 2)
        again.shuffleToRestore = UserDefaults.standard.stringArray(forKey: arrangedKey)
        again.mixOrderToRestore = UserDefaults.standard.bool(forKey: mixKey)
        again.restoreShuffle()
        expect(again.isMixOrdered && !again.isShuffled && names(again.tracks) == arranged, "it comes back on, in the same order")
        again.toggleMixOrder()
        expect(names(again.tracks) == own, "and turning it off gives your order")

        let s = model(list, playing: 2)
        s.toggleShuffle()
        s.persistQueueNow()
        expect(!UserDefaults.standard.bool(forKey: mixKey), "shuffle saves as shuffle")
        let shuffleBack = model(list, playing: 2)
        shuffleBack.shuffleToRestore = UserDefaults.standard.stringArray(forKey: arrangedKey)
        shuffleBack.mixOrderToRestore = UserDefaults.standard.bool(forKey: mixKey)
        shuffleBack.restoreShuffle()
        expect(shuffleBack.isShuffled && !shuffleBack.isMixOrdered && names(shuffleBack.tracks) == names(s.tracks), "and comes back as shuffle")

        let plain = model(list, playing: 2)
        plain.persistQueueNow()
        expect(UserDefaults.standard.stringArray(forKey: arrangedKey) == nil && !UserDefaults.standard.bool(forKey: mixKey), "with both off nothing extra is saved")
    }
}
