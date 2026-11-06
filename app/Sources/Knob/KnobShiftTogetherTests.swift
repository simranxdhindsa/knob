import Foundation

/// `--knobshift-together-check selftest`: Listen Together's clock, sound buffer and messages,
/// with no network or sound card, on simulated clocks that drift and connections that drop.
enum KnobShiftTogetherTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func run() {
        var random = SystemRandomNumberGenerator()
        clock(&random)
        timeline(&random)
        ring(&random)
        messages(&random)
        print(failures == 0 ? "Listen Together self test passed" : "Listen Together self test: \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func clock(_ random: inout SystemRandomNumberGenerator) {
        print("Clock")
        var clock = KnobShiftTogetherClock()
        expect(clock.offset == nil, "no offset before a ping")
        let truth: Int64 = -124_626_213_000_000
        var now: Int64 = 1_000_000_000_000
        // Like the Wi-Fi measured: mostly slow and lopsided, now and then quick.
        func ping(_ clock: inout KnobShiftTogetherClock, drift: Int64 = 0, _ random: inout SystemRandomNumberGenerator) {
            let quick = Int.random(in: 0..<10, using: &random) == 0
            let out = Int64.random(in: 3_400_000...(quick ? 3_800_000 : 90_000_000), using: &random)
            let back = Int64.random(in: 3_400_000...(quick ? 3_800_000 : 60_000_000), using: &random)
            clock.add(sent: now, hostAnswered: now + out + truth + drift, received: now + out + back)
            now += 200_000_000
        }
        for _ in 0..<150 { ping(&clock, &random) }
        let error = abs((clock.offset ?? 0) - truth)
        expect(error < 1_000_000, "within 1 ms through 7 to 150 ms replies (\(Double(error) / 1e6) ms)")
        expect((clock.bestTrip ?? 0) < 8_000_000, "best trip found")
        var drifting = KnobShiftTogetherClock()
        var drift: Int64 = 0
        for _ in 0..<1_500 { ping(&drifting, drift: drift, &random); drift += 6_000 } // 30 parts per million
        let late = abs((drifting.offset ?? 0) - (truth + drift))
        expect(late < 1_000_000, "follows a clock 30 parts per million off for 5 minutes (\(Double(late) / 1e6) ms)")
        var stale = KnobShiftTogetherClock()
        stale.add(sent: 0, hostAnswered: 1_000_000, received: 2_000_000)
        stale.add(sent: 20_000_000_000, hostAnswered: 20_050_000_000 + 7, received: 20_100_000_000)
        expect(stale.bestTrip == 100_000_000, "old pings leave the window")
        var backwards = KnobShiftTogetherClock()
        backwards.add(sent: 10, hostAnswered: 5, received: 1)
        expect(backwards.offset == nil, "a reply from before it was sent is ignored")
    }

    private static func timeline(_ random: inout SystemRandomNumberGenerator) {
        print("Timeline")
        var line = KnobShiftTogetherTimeline()
        let rate = 48_000.0, truth = 48_000.0 * 1.00003
        var host: Int64 = 5_000_000_000
        for _ in 0..<60 {
            let frame = Int64(Double(host - 5_000_000_000) * truth / 1e9)
            line.add(frame: frame, hostNanoseconds: host + Int64.random(in: -500_000...500_000, using: &random), rate: rate)
            host += 1_000_000_000
        }
        let fit = line.line!
        let foundRate = fit.framesPerNanosecond * 1e9
        expect(abs(foundRate / truth - 1) < 0.00001, "finds a sound card's true rate through noisy anchors")
        let at = host + 500_000_000
        let frame = Double(fit.frame) + Double(at - fit.host) * fit.framesPerNanosecond
        let wrong = abs(frame - Double(at - 5_000_000_000) * truth / 1e9) / truth * 1000
        expect(wrong < 0.5, "says where the mix is to within half a millisecond (\(wrong) ms)")
        var wild = KnobShiftTogetherTimeline()
        for index in 0..<20 { wild.add(frame: Int64(index) * 96_000, hostNanoseconds: Int64(index) * 1_000_000_000, rate: rate) }
        expect(wild.line?.framesPerNanosecond == rate / 1e9, "a rate twice too fast is not believed")
        wild.restart()
        expect(wild.line == nil, "a restart forgets the old line")
        wild.add(frame: 5, hostNanoseconds: 99, rate: rate)
        expect(wild.line?.frame == 5 && wild.line?.host == 99, "and picks up from the next anchor")
    }

    /// Plays a tone through the ring on a simulated sound card and returns how it went.
    private static func play(seconds: Double, sourceRate: Double, outputRate: Double, parts: Double, delay: Int64 = 500_000_000,
                             ring: KnobShiftTogetherRing, stopSendingAt: Double? = nil,
                             jumpAt: (seconds: Double, by: Int64)? = nil) -> (tail: [Float], worst: Double) {
        let block = 512
        var sent: Int64 = 0
        let plain = ring.plain
        var plainCopy = plain
        var left = [Float](repeating: 0, count: block), right = left
        var tail: [Float] = []
        var worst = 0.0
        var heard: Int64 = 0
        var offset: Int64 = 0
        let trueRate = sourceRate * (1 + parts / 1_000_000)
        ring.start()
        var target = KnobShiftTogetherRing.Target()
        target.line = .init(frame: 0, host: 0, framesPerNanosecond: trueRate / 1e9)
        target.delay = delay
        target.step = sourceRate / outputRate
        ring.update(target)
        let blocks = Int(seconds * outputRate) / block
        for index in 0..<blocks {
            let time = Double(heard) / 1e9
            let due = Int64(time * trueRate) + 4_096
            if stopSendingAt.map({ time < $0 }) ?? true, due > sent {
                let count = Int(due - sent)
                var samples = [Int16](repeating: 0, count: count * 2)
                for frame in 0..<count {
                    let value = Int16(sin(2 * .pi * 440 * Double(sent + Int64(frame)) / sourceRate) * 20_000)
                    samples[frame * 2] = value
                    samples[frame * 2 + 1] = value
                }
                samples.withUnsafeBufferPointer { ring.write(firstFrame: sent, samples: $0) }
                sent = due
            }
            if let jumpAt, time >= jumpAt.seconds, offset == 0 {
                offset = jumpAt.by
                target.clockOffset = offset
                ring.update(target)
            }
            _ = KnobShiftTogetherRing.render(&plainCopy, left: &left, right: &right, frames: block, outputRate: outputRate, heardAt: heard)
            if index > blocks * 3 / 4 { worst = max(worst, abs(ring.shared.pointee.error)) }
            if index >= blocks - 8 { tail.append(contentsOf: left) }
            heard += Int64(Double(block) / outputRate * 1e9)
        }
        return (tail, worst)
    }

    private static func ring(_ random: inout SystemRandomNumberGenerator) {
        print("Sound buffer")
        let drifting = KnobShiftTogetherRing()
        let result = play(seconds: 60, sourceRate: 48_000, outputRate: 48_000, parts: 40, ring: drifting)
        expect(result.worst < 0.0002, "locks onto a clock 40 parts per million off (\(result.worst * 1000) ms)")
        expect(drifting.shared.pointee.underruns == 0 && drifting.shared.pointee.jumps == 0, "no dropouts or jumps while locked")
        expect((result.tail.map(abs).max() ?? 0) > 0.55, "the tone comes through at full level")
        let rates = KnobShiftTogetherRing()
        let converted = play(seconds: 60, sourceRate: 44_100, outputRate: 48_000, parts: -25, ring: rates)
        expect(converted.worst < 0.0002, "44.1 kHz into 48 kHz stays locked (\(converted.worst * 1000) ms)")
        let peak = converted.tail.map(abs).max() ?? 0
        expect(peak > 0.55 && peak < 0.65, "and keeps its level")
        let pure = KnobShiftTogetherRing()
        let clean = play(seconds: 10, sourceRate: 44_100, outputRate: 48_000, parts: 0, ring: pure)
        var noise = 0.0, signal = 0.0
        let turn: Double = 2 * Double.pi * 440 / 48_000
        let bend = Float(cos(turn))
        for index in 1..<(clean.tail.count - 1) {
            let wobble = Double(clean.tail[index - 1] + clean.tail[index + 1] - 2 * clean.tail[index] * bend)
            noise += wobble * wobble
            signal += Double(clean.tail[index] * clean.tail[index])
        }
        let distortion = 10 * log10(max(noise, 1e-20) / max(signal, 1e-20))
        expect(distortion < -60, "converting rates adds no audible noise (\(distortion) dB)")
        let lost = KnobShiftTogetherRing()
        let dropped = play(seconds: 5, sourceRate: 48_000, outputRate: 48_000, parts: 0, ring: lost, stopSendingAt: 2)
        expect(dropped.tail.allSatisfy { $0 == 0 } && lost.shared.pointee.underruns == 1, "a lost connection goes silent, once, with no noise")
        let moved = KnobShiftTogetherRing()
        _ = play(seconds: 10, sourceRate: 48_000, outputRate: 48_000, parts: 0, ring: moved, jumpAt: (5, 200_000_000))
        expect(moved.shared.pointee.jumps == 1, "a big change jumps instead of crawling")
        let holes = KnobShiftTogetherRing()
        var first = [Int16](repeating: 1_000, count: 200)
        first.withUnsafeMutableBufferPointer { holes.write(firstFrame: 0, samples: UnsafeBufferPointer($0)) }
        first.withUnsafeMutableBufferPointer { holes.write(firstFrame: 300, samples: UnsafeBufferPointer($0)) }
        expect(holes.left[150] == 0 && holes.left[350] != 0, "frames lost on the way are silence")
        first.withUnsafeMutableBufferPointer { holes.write(firstFrame: 0, samples: UnsafeBufferPointer($0)) }
        expect(holes.shared.pointee.written == 400, "frames arriving late are ignored")
        first.withUnsafeMutableBufferPointer { holes.write(firstFrame: Int64(holes.capacity) * 3, samples: UnsafeBufferPointer($0)) }
        expect(holes.shared.pointee.written == Int64(holes.capacity) * 3 + 100, "a huge leap forward stays inside the buffer")
    }

    private static func messages(_ random: inout SystemRandomNumberGenerator) {
        print("Messages")
        typealias Wire = KnobShiftTogether
        let samples: [Int16] = [1, -2, 3, -4]
        let sound = samples.withUnsafeBufferPointer { Wire.sound(firstFrame: 77, samples: $0) }
        let anchor = Wire.anchor(frame: 123, hostNanoseconds: -456, rate: 48_000)
        let hello = Wire.Message(kind: .hello, body: Data("{}".utf8))
        let stream = Wire.encode(sound) + Wire.encode(anchor) + Wire.encode(hello)
        var whole = Wire.Reader()
        expect((try? whole.add(stream)) == [sound, anchor, hello], "messages come back whole")
        for _ in 0..<50 {
            var pieces = Wire.Reader(), found: [Wire.Message] = [], at = 0
            while at < stream.count {
                let size = min(Int.random(in: 1...9, using: &random), stream.count - at)
                found += (try? pieces.add(Data(stream[at..<(at + size)]))) ?? []
                at += size
            }
            if found != [sound, anchor, hello] { expect(false, "messages split at any point") }
        }
        expect(true, "messages split at any point")
        expect(Wire.soundFrame(sound.body) == 77, "sound knows its place")
        expect(Wire.soundFrame(Data([1, 2, 3])) == nil, "short sound refused")
        expect(Wire.soundFrame(Data(repeating: 0, count: 13)) == nil, "half a frame refused")
        let read = Wire.readAnchor(anchor.body)
        expect(read?.frame == 123 && read?.hostNanoseconds == -456 && read?.rate == 48_000, "anchor comes back")
        expect(Wire.readAnchor(Data(count: 3)) == nil, "short anchor refused")
        let nonsense = Wire.anchor(frame: 0, hostNanoseconds: 0, rate: .infinity)
        expect(Wire.readAnchor(nonsense.body) == nil, "impossible rate refused")
        var long = Wire.Reader()
        do { _ = try long.add(Data([0xFF, 0xFF, 0xFF, 0xFF])); expect(false, "too long refused") } catch { expect(error as? Wire.Reader.Failure == .tooLong, "too long refused") }
        var empty = Wire.Reader()
        do { _ = try empty.add(Data([0, 0, 0, 0])); expect(false, "empty refused") } catch { expect(error as? Wire.Reader.Failure == .empty, "empty refused") }
        var future = Wire.Reader()
        let unknown = Data([0, 0, 0, 2, 200, 9]) + Wire.encode(hello)
        expect((try? future.add(unknown)) == [hello], "a kind from a newer Knob is skipped")
    }
}
