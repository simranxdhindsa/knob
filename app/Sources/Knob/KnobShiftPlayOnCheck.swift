import AppKit
import AVFoundation

/// `--knobshift-playon-check selftest` runs the rules. `receiver` and `sender SONG...` are two
/// real copies of Knob moving music between them over a real connection, each with its own
/// library (KNOB_SPOTIFY_ROOT, KNOB_PLAYON_NAME). KNOB_PLAYON_ANSWER says how the receiver
/// answers Allow. Everything plays muted.
@MainActor
enum KnobShiftPlayOnCheck {
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func run(_ arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        if arguments.first == "selftest" { KnobShiftPlayOnTests.run() }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        switch arguments.first {
        case "receiver": Task { @MainActor in await receiver() }
        case "sender": Task { @MainActor in await sender(arguments.dropFirst().map { URL(fileURLWithPath: $0) }) }
        case "refused": Task { @MainActor in await refused(arguments.dropFirst().map { URL(fileURLWithPath: $0) }) }
        case "intruder": Task { @MainActor in await intruder() }
        case "dropped": Task { @MainActor in await dropped(arguments.dropFirst().map { URL(fileURLWithPath: $0) }) }
        default:
            print("Use: selftest, receiver, sender, refused or dropped")
            exit(1)
        }
        app.run()
    }

    private static func quietModel() -> KnobShiftModel {
        let model = KnobShiftModel(restoresQueue: false)
        model.outputVolume = 0
        return model
    }

    private static func receiver() async {
        let model = quietModel()
        let sound = KnobModel(engine: DemoEngine(), volume: DemoVolume())
        sound.eq = [Double](repeating: 0, count: 10)
        let session = KnobShiftPlayOnSession.shared
        session.start(model: model)
        let answer = ProcessInfo.processInfo.environment["KNOB_PLAYON_ANSWER"] ?? "allow"
        print("Receiver ready")
        var last = ""
        for _ in 0..<1_000 {
            if session.asking != nil {
                print("Asked by \(session.asking ?? ""), answering \(answer)")
                session.answerAsking(allow: answer == "allow")
            }
            let line = "song \(model.nowPlaying?.name ?? "none"), playing \(model.isPlaying), queue \(model.tracks.count), playlists \(model.playlists.map(\.name)), role \(KnobShiftTogetherSession.shared.role), clarity \(sound.effects[EffectSlot.clarity.rawValue]), receiving \(session.receiving ?? "nothing")"
            if line != last {
                print("RECEIVER \(line), at \(Int(model.playbackTime))s")
                last = line
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        exit(0)
    }

    private static func prepared(_ urls: [URL]) async -> (KnobShiftModel, KnobModel, KnobShiftPlayOnSession.Device?) {
        let model = quietModel()
        let sound = KnobModel(engine: DemoEngine(), volume: DemoVolume())
        sound.eq = [Double](repeating: 0, count: 10)
        let session = KnobShiftPlayOnSession.shared
        session.start(model: model)
        // The songs sit in a real playlist, the way downloaded ones do.
        let list = model.adoptPlaylist(id: "37i9dQZF1DXtest000000", name: "ਪੰਜਾਬੀ Test", link: "https://open.spotify.com/playlist/37i9dQZF1DXtest000000")
        let folder = KnobShiftPlaylists.folder(for: list)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var placed: [URL] = []
        for url in urls {
            let target = folder.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: target)
            placed.append(target)
            if let id = KnobShiftPlaylists.songId(inFileName: target.deletingPathExtension().lastPathComponent),
               let index = model.playlists.firstIndex(where: { $0.id == list.id }) { model.playlists[index].spotifyOrder.append(id) }
        }
        model.savePlaylists()
        await model.addTracks(placed)
        session.startLooking()
        for _ in 0..<120 where session.devices.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        return (model, sound, session.devices.first)
    }

    private static func wait(_ seconds: Double = 20, until done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private static func finish() -> Never {
        print(failures == 0 ? "Play On journey passed" : "Play On journey: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func stageTrail(_ session: KnobShiftPlayOnSession, into trail: Trail) -> Task<Void, Never> {
        Task { @MainActor in
            while !Task.isCancelled {
                if let text = session.handoff?.stage.text, trail.seen.last != text { trail.seen.append(text) }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    final class Trail { var seen: [String] = [] }

    /// The whole journey: there with a missing song, control it, back, there again with no asking.
    private static func sender(_ urls: [URL]) async {
        let (model, sound, found) = await prepared(urls)
        let session = KnobShiftPlayOnSession.shared, together = KnobShiftTogetherSession.shared
        print("Moving with no song playing")
        guard let device = found else { expect(false, "found the other device"); finish() }
        expect(true, "found \(device.name)")
        session.move(to: device)
        expect(session.handoff?.stage == .failed("Play a song first."), "says to play a song first")
        session.clearFailure()

        print("Listen Together blocks it")
        guard let track = model.tracks.first else { expect(false, "songs added"); finish() }
        model.playForCheck(volume: 0, bySelecting: track)
        try? await Task.sleep(for: .seconds(2))
        together.startHosting(model)
        session.move(to: device)
        expect(session.handoff?.stage == .failed("Leave Listen Together first."), "asks to leave Listen Together first")
        together.leave()
        session.clearFailure()
        try? await Task.sleep(for: .seconds(1))

        print("Moving it there with songs to copy")
        model.seek(to: 40)
        sound.setEffect(.clarity, 6)
        try? await Task.sleep(for: .seconds(2))
        let trail = Trail()
        let watcher = stageTrail(session, into: trail)
        let before = model.playbackTime
        let started = Date()
        session.move(to: device)
        expect(model.isPlaying, "music keeps playing here while it starts")
        let moved = await wait(60) { session.handoff?.stage == .playingThere }
        let took = Date().timeIntervalSince(started)
        expect(moved, "the music moved (took \(String(format: "%.1f", took))s)")
        print("  stages seen: \(trail.seen)")
        expect(trail.seen.contains { $0.hasPrefix("Copying song") }, "it showed copying")
        expect(trail.seen.first == "Waiting for Allow", "it waited for Allow first")
        try? await Task.sleep(for: .seconds(1))
        expect(!model.isPlaying, "it stopped here, so only one device plays")
        expect(together.isRemote, "this device became the remote")
        print("  position was \(Int(before))s before, \(took)s took")

        print("Controlling it from here")
        let waited = await wait(6) { together.state?.isPlaying == true && together.state?.title != nil }
        expect(waited, "the remote shows it playing: \(together.state?.title ?? "none")")
        let there = together.state?.time ?? 0
        expect(abs(there - (before + took)) < 3, "it carried on from the same moment (\(Int(there))s, expected about \(Int(before + took))s)")
        expect(await wait(8) { together.queue.count == urls.count }, "the remote shows the whole queue (\(together.queue.count) of \(urls.count))")
        together.send(.playPause)
        expect(await wait(5) { together.state?.isPlaying == false }, "pause from here works")
        together.send(.playPause)
        expect(await wait(5) { together.state?.isPlaying == true }, "play from here works")
        together.send(.seek, time: 70)
        expect(await wait(5) { (together.state?.time ?? 0) >= 68 }, "seek from here works")
        let next = together.queue.first { $0.id != together.state?.song }
        if let next {
            together.send(.pick, song: next.id)
            expect(await wait(6) { together.state?.song == next.id }, "picking a song from here plays it there")
            together.send(.seek, time: 70)
            _ = await wait(5) { (together.state?.time ?? 0) >= 68 }
        }
        together.send(.shuffle)
        expect(await wait(5) { together.state?.isShuffled == true }, "shuffle from here works")
        sound.setEffect(.ambience, 4)
        try? await Task.sleep(for: .seconds(1))

        print("Bringing it back")
        trail.seen.removeAll()
        session.bringBack()
        expect(await wait(30) { model.isPlaying && !together.isRemote }, "the music came back here")
        watcher.cancel()
        try? await Task.sleep(for: .seconds(1))
        expect(model.isPlaying, "and plays here")
        expect(model.playbackTime >= 68, "from where it had got to (\(Int(model.playbackTime))s)")

        print("Moving it there a second time")
        session.clearFailure()
        session.handoffReset()
        let again = Date()
        session.move(to: device)
        expect(await wait(30) { session.handoff?.stage == .playingThere }, "it moved without asking")
        let second = Date().timeIntervalSince(again)
        expect(second < 8, "and quicker, with nothing to copy (\(String(format: "%.1f", second))s)")
        try? await Task.sleep(for: .seconds(2))
        expect(!model.isPlaying, "and stopped here again")
        finish()
    }

    /// The receiver says Don't Allow.
    private static func refused(_ urls: [URL]) async {
        let (model, _, found) = await prepared(urls)
        let session = KnobShiftPlayOnSession.shared
        print("Don't Allow")
        guard let device = found, let track = model.tracks.first else { expect(false, "found the device and song"); finish() }
        model.playForCheck(volume: 0, bySelecting: track)
        try? await Task.sleep(for: .seconds(2))
        session.move(to: device)
        let done = await wait(15) { if case .failed = session.handoff?.stage { return true } else { return false } }
        expect(done, "it failed cleanly")
        expect(session.handoff?.stage.text == "\(device.name) didn't allow this.", "says so: \(session.handoff?.stage.text ?? "nothing")")
        expect(model.isPlaying, "the music stayed here")
        finish()
    }

    /// A stranger who was never allowed tries everything, on a device that says Don't Allow.
    private static func intruder() async {
        let session = KnobShiftPlayOnSession.shared
        session.start(model: quietModel())
        session.startLooking()
        for _ in 0..<120 where session.devices.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        print("A stranger tries everything")
        guard let device = session.devices.first else { expect(false, "found the device"); finish() }
        let link = KnobShiftPlayOnLink(to: device.endpoint)
        link.start()
        typealias Wire = KnobShiftTogether
        func send<Value: Encodable>(_ kind: Wire.Kind, _ value: Value) { if let message = Wire.json(kind, value) { link.send(message) } }
        let song = KnobShiftPlayOn.Song(key: "file:1", title: "Evil", artist: nil, fileName: "../../evil.m4a", size: 4, playlist: nil)
        // With no hello at all, then again after asking and being refused.
        for round in 0..<2 {
            send(.handover, KnobShiftPlayOn.Handover(songs: [song], current: 0, position: 0, isPlaying: true, isShuffled: false, sentAt: 0, effects: nil))
            send(.need, ["file:1"])
            send(.fileStart, KnobShiftPlayOnSession.FileStart(key: "file:1", fileName: "evil.m4a", size: 4, playlist: nil))
            link.send(Wire.Message(kind: .fileChunk, body: Data([1, 2, 3, 4])))
            link.send(Wire.Message(kind: .fileEnd, body: Data()))
            link.send(Wire.Message(kind: .ready, body: Data()))
            send(.go, KnobShiftPlayOnSession.Go(position: 0, isPlaying: true, startIn: 0))
            send(.command, Wire.Command(action: .next))
            link.send(Wire.Message(kind: .takeBack, body: Data()))
            send(.state, Wire.State(title: "Fake", artist: nil, time: 0, duration: 1, isPlaying: true))
            if round == 0 { send(.playHello, KnobShiftPlayOn.Hello(version: KnobShiftPlayOn.version, deviceId: "stranger", name: "Stranger")) }
            try? await Task.sleep(for: .seconds(2))
        }
        expect(true, "sent every message without being allowed")
        finish()
    }

    /// The other device vanishes in the middle of copying.
    private static func dropped(_ urls: [URL]) async {
        let (model, _, found) = await prepared(urls)
        let session = KnobShiftPlayOnSession.shared
        print("Connection lost while copying")
        guard let device = found, let track = model.tracks.first else { expect(false, "found the device and song"); finish() }
        model.playForCheck(volume: 0, bySelecting: track)
        try? await Task.sleep(for: .seconds(2))
        session.move(to: device)
        let copying = await wait(20) { if case .copying = session.handoff?.stage { return true } else { return false } }
        expect(copying, "copying started")
        print("KILL RECEIVER NOW")
        let done = await wait(25) { if case .failed = session.handoff?.stage { return true } else { return false } }
        expect(done, "it noticed: \(session.handoff?.stage.text ?? "nothing")")
        expect(model.isPlaying, "the music stayed here")
        finish()
    }
}
