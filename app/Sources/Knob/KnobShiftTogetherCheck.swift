import AppKit
import AVFoundation

/// `--knobshift-together-check selftest` runs the self test. `--knobshift-together-check local
/// A B` plays a real mix muted through this device's own Listen Together path and measures it:
/// the sound must come out the stated delay after it left the mix, with no dropouts.
@MainActor
enum KnobShiftTogetherCheck {
    static func run(_ arguments: [String]) {
        if arguments.first == "selftest" { KnobShiftTogetherTests.run() }
        if arguments.first == "pair", arguments.count >= 3 {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in await pair(URL(fileURLWithPath: arguments[1]), URL(fileURLWithPath: arguments[2])) }
            app.run()
        }
        if arguments.first == "guest" {
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in await guest() }
            app.run()
        }
        guard arguments.first == "local", arguments.count >= 3 else {
            print("Use: selftest, or local SONG_A SONG_B")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            await local(URL(fileURLWithPath: arguments[1]), URL(fileURLWithPath: arguments[2]))
        }
        app.run()
    }

    /// The host half of two real processes talking over a real connection.
    private static func pair(_ first: URL, _ second: URL) async {
        let model = KnobShiftModel(restoresQueue: false)
        await model.addTracks([first, second])
        guard let track = model.tracks.first else { print("FAIL could not add the songs"); exit(1) }
        model.playForCheck(volume: 0, bySelecting: track)
        let sound = KnobModel(engine: DemoEngine(), volume: DemoVolume())
        sound.eq = [Double](repeating: 0, count: 10)
        let session = KnobShiftTogetherSession.shared
        session.startHosting(model)
        print("Hosting: \(session.role == .hosting), \(session.status ?? "no problem")")
        try? await Task.sleep(for: .seconds(14))
        sound.setEffect(.clarity, 7)
        sound.setEQ(band: 2, 0.5)
        print("Host set Clarity 7 and EQ band 3 to 0.5")
        try? await Task.sleep(for: .seconds(20))
        print("Host sees Ambience \(sound.effects[EffectSlot.ambience.rawValue])")
        print("People at the end: \(session.people)")
        session.leave()
        try? await Task.sleep(for: .seconds(1))
        exit(0)
    }

    /// The listener half: finds the host, joins, presses a button, and reports how it held.
    private static func guest() async {
        let model = KnobShiftModel(restoresQueue: false)
        model.playForCheck(volume: 0)
        let sound = KnobModel(engine: DemoEngine(), volume: DemoVolume())
        sound.eq = [Double](repeating: 0, count: 10)
        sound.setEffect(.surround, 2)
        let session = KnobShiftTogetherSession.shared
        session.startLooking()
        for _ in 0..<40 where session.nearby.isEmpty { try? await Task.sleep(for: .milliseconds(250)) }
        guard let found = session.nearby.first else { print("FAIL nobody found"); exit(1) }
        print("Found \(found.name)")
        session.join(found, model: model)
        try? await Task.sleep(for: .seconds(14))
        session.send(.playPause)
        try? await Task.sleep(for: .seconds(2))
        print("After pause, host says playing: \(session.state?.isPlaying as Any)")
        session.send(.playPause)
        try? await Task.sleep(for: .seconds(8))
        if let shared = session.debugRing {
            print(String(format: "Guest error %.3f ms, speed %.0f ppm, underruns %d, jumps %d, song %@, playing %@", shared.error * 1000, shared.correction * 1e6, shared.underruns, shared.jumps,
                         session.state?.title ?? "none", String(describing: session.state?.isPlaying)))
        }
        print("Cover received: \(session.cover != nil)")
        print("Guest sees Clarity \(sound.effects[EffectSlot.clarity.rawValue]), EQ band 3 \(sound.eq[2]), Surround \(sound.effects[EffectSlot.surround.rawValue])")
        sound.setEffect(.ambience, 3)
        print("Guest set Ambience 3")
        try? await Task.sleep(for: .seconds(2))
        session.leave()
        print("After leaving: Clarity \(sound.effects[EffectSlot.clarity.rawValue]), Ambience \(sound.effects[EffectSlot.ambience.rawValue]), EQ band 3 \(sound.eq[2]), Surround \(sound.effects[EffectSlot.surround.rawValue])")
        exit(0)
    }

    /// Thread safe list of each block's start and sound, one value per millisecond.
    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var points: [(host: Int64, level: Float)] = []
        func add(host: Int64, rate: Double, mono: (Int) -> Float, frames: Int) {
            let step = max(1, Int(rate / 1_000))
            lock.lock()
            var at = 0
            while at + step <= frames {
                var sum: Float = 0
                for frame in max(0, at - step * 4)..<(at + step) { sum += abs(mono(frame)) }
                points.append((host + Int64(Double(at) / rate * 1e9), sum / Float(step)))
                at += step
            }
            lock.unlock()
        }
        var snapshot: [(host: Int64, level: Float)] { lock.lock(); defer { lock.unlock() }; return points }
    }

    private static func local(_ first: URL, _ second: URL) async {
        let model = KnobShiftModel(restoresQueue: false)
        await model.addTracks([first, second])
        guard let track = model.tracks.first else { print("FAIL could not add the songs"); exit(1) }
        model.playForCheck(volume: 0, bySelecting: track)
        try? await Task.sleep(for: .seconds(3))
        let before = Trace(), after = Trace()
        do {
            try model.startTogetherSound(outputDelay: 0) { block in
                before.add(host: block.hostNanoseconds, rate: block.rate, mono: { Float(block.samples[$0 * 2]) / 32_768 }, frames: block.samples.count / 2)
            }
        } catch {
            print("FAIL could not start: \(error)")
            exit(1)
        }
        if let node = model.together?.sourceNode { listen(to: node, into: after) }
        for second in stride(from: 2, through: 30, by: 2) {
            try? await Task.sleep(for: .seconds(2))
            if let state = model.together?.ring.shared.pointee {
                let rate = state.target.line.framesPerNanosecond * 1e9
                print(String(format: "%2ds error %+.3f ms, speed %+.0f ppm, mix rate %.2f, step %.6f", second, state.error * 1000, state.correction * 1e6, rate, state.target.step))
            }
        }
        let shared = model.together?.ring.shared.pointee
        model.together?.sourceNode?.removeTap(onBus: 0)
        print(String(format: "Last error %.3f ms, speed change %.0f parts per million, underruns %d, jumps %d", (shared?.error ?? 0) * 1000,
                     (shared?.correction ?? 0) * 1e6, shared?.underruns ?? -1, shared?.jumps ?? -1))
        let lag = measure(before.snapshot, after.snapshot)
        print(String(format: "Sound came out %.1f ms after leaving the mix, match %.3f (%d and %d points)", lag.milliseconds, lag.match,
                     before.snapshot.count, after.snapshot.count))
        model.stopTogetherSound()
        try? await Task.sleep(for: .seconds(1))
        let gateOpen = model.deckGate.outputVolume == 1 && model.together == nil
        // The lag is only a rough check, because a tap's times drift: the real test of when sound
        // is heard is the microphone. What must hold exactly is the lock.
        let locked = abs(shared?.error ?? 1) < 0.001 && abs(shared?.correction ?? 1) < 0.0001
        let good = lag.milliseconds > 450 && lag.milliseconds < 750 && lag.match > 0.75 && locked && shared?.underruns == 0 && shared?.jumps == 0 && gateOpen
        print(good ? "Listen Together local check passed" : "Listen Together local check FAILED")
        exit(good ? 0 : 1)
    }

    /// Not on the main actor: a tap runs on its own thread.
    private nonisolated static func listen(to node: AVAudioNode, into trace: Trace) {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(timebase.denom)
        node.installTap(onBus: 0, bufferSize: 2_048, format: nil) { buffer, time in
            guard let data = buffer.floatChannelData else { return }
            trace.add(host: Int64(Double(time.hostTime) * scale), rate: buffer.format.sampleRate, mono: { data[0][$0] }, frames: Int(buffer.frameLength))
        }
    }

    /// Slides one level trace over the other to find the delay, one millisecond at a time.
    private static func measure(_ a: [(host: Int64, level: Float)], _ b: [(host: Int64, level: Float)]) -> (milliseconds: Double, match: Double) {
        guard let start = a.first?.host, let end = b.last?.host, end > start else { return (0, 0) }
        let length = Int((end - start) / 1_000_000) + 2
        func grid(_ list: [(host: Int64, level: Float)]) -> [Float?] {
            var cells = [Float?](repeating: nil, count: length)
            for point in list {
                let index = Int((point.host - start) / 1_000_000)
                if index >= 0, index < length { cells[index] = point.level }
            }
            return cells
        }
        let x = grid(a), y = grid(b)
        var best = (milliseconds: 0.0, match: -2.0)
        for lag in 300...800 {
            var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumYY = 0.0, sumXY = 0.0, count = 0.0
            for index in 0..<(length - lag) {
                guard let p = x[index], let q = y[index + lag], q > 0 else { continue }
                let u = Double(p), v = Double(q)
                sumX += u; sumY += v; sumXX += u * u; sumYY += v * v; sumXY += u * v; count += 1
            }
            guard count > 1_000 else { continue }
            let top = count * sumXY - sumX * sumY
            let bottom = ((count * sumXX - sumX * sumX) * (count * sumYY - sumY * sumY)).squareRoot()
            let match = bottom > 0 ? top / bottom : 0
            if match > best.match { best = (Double(lag), match) }
        }
        return best
    }
}
