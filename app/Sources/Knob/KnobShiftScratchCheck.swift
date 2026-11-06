import AVFoundation
import Foundation

/// `--knobshift-scratch-check [SONG OUT.wav]` measures the record's sound with no audio device:
/// pitch at each speed, backward, silence when stopped, no clicks, the song's ends and how much
/// faster than real time it runs. With a song it also records a scratch to listen to.
enum KnobShiftScratchCheck {
    private static var failed = 0
    private static let rate = 48_000.0

    private static func expect(_ passed: Bool, _ what: String) {
        print("  \(passed ? "ok  " : "FAIL") \(what)")
        if !passed { failed += 1 }
    }

    /// A scratch holding a tone of this pitch, as if decoded at 44.1 kHz.
    private static func tone(_ hertz: Double, seconds: Double) -> KnobShiftScratch {
        let frames = Int(seconds * 44_100)
        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: frames * 2)
        for frame in 0..<frames {
            let value = Int16(sin(2 * .pi * hertz * Double(frame) / 44_100) * 20_000)
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        let scratch = KnobShiftScratch(outputRate: rate)
        scratch.use(samples, frames: frames, rate: 44_100)
        return scratch
    }

    private static func play(_ scratch: KnobShiftScratch, seconds: Double) -> [Float] {
        let frames = Int(seconds * rate)
        var left = [Float](repeating: 0, count: frames), right = left
        var done = 0
        while done < frames {
            let count = min(512, frames - done)
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    _ = KnobShiftScratch.render(scratch.shared, left: l.baseAddress! + done, right: r.baseAddress! + done, frames: count)
                }
            }
            done += count
        }
        return left
    }

    private static func pitch(_ samples: [Float]) -> Double {
        var crossings = 0
        for index in 1..<samples.count where samples[index - 1] < 0 && samples[index] >= 0 { crossings += 1 }
        return Double(crossings) / (Double(samples.count) / rate)
    }

    private static func loudness(_ samples: [Float]) -> Float {
        (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
    }

    private static func biggestJump(_ samples: [Float]) -> Float {
        var biggest: Float = 0
        for index in 1..<samples.count { biggest = max(biggest, abs(samples[index] - samples[index - 1])) }
        return biggest
    }

    static func run(_ arguments: [String]) {
        for (speed, expected) in [(1.0, 440.0), (0.5, 220.0), (2.0, 880.0), (-1.0, 440.0), (-0.5, 220.0)] {
            let scratch = tone(440, seconds: 20)
            scratch.grab(at: 10, speed: speed)
            _ = play(scratch, seconds: 0.2)
            let heard = pitch(play(scratch, seconds: 1))
            expect(abs(heard - expected) < expected * 0.01, String(format: "speed %.1f sounds at %.0f Hz (wanted %.0f)", speed, heard, expected))
        }

        let backward = tone(440, seconds: 20)
        backward.grab(at: 10, speed: -1)
        _ = play(backward, seconds: 2)
        expect(abs(backward.time - 8) < 0.02, String(format: "two seconds backward lands at %.2f s (wanted 8.00)", backward.time))

        let forward = tone(440, seconds: 20)
        forward.grab(at: 10, speed: 1)
        _ = play(forward, seconds: 2)
        expect(abs(forward.time - 12) < 0.02, String(format: "two seconds forward lands at %.2f s (wanted 12.00)", forward.time))

        let stopped = tone(440, seconds: 20)
        stopped.grab(at: 10, speed: 1)
        stopped.move(speed: 0)
        _ = play(stopped, seconds: 0.5)
        let silence = loudness(play(stopped, seconds: 0.5))
        expect(silence < 0.0005, String(format: "a stopped record is silent (level %.5f)", silence))

        // The hardest case: full speed one way to full speed the other, over and over.
        let shaken = tone(440, seconds: 20)
        shaken.grab(at: 10, speed: 1)
        var shakenAudio: [Float] = []
        for turn in 0..<12 {
            shaken.move(speed: turn % 2 == 0 ? -1 : 1)
            shakenAudio += play(shaken, seconds: 0.15)
        }
        let cleanStep = Float(2 * .pi * 440 / rate) * 0.61
        let jump = biggestJump(shakenAudio)
        expect(jump < cleanStep * 1.5, String(format: "changing direction makes no click (biggest step %.4f, tone alone %.4f)", jump, cleanStep))

        let start = tone(440, seconds: 2)
        start.grab(at: 0.2, speed: -3)
        _ = play(start, seconds: 1)
        expect(start.time == 0, "running backward stops at the start of the song")
        let end = tone(440, seconds: 2)
        end.grab(at: 1.8, speed: 3)
        _ = play(end, seconds: 1)
        expect(abs(end.time - 2) < 0.001, "running forward stops at the end of the song")

        let motor = tone(440, seconds: 20)
        motor.grab(at: 5, speed: 0)
        motor.letGo(to: 1)
        _ = play(motor, seconds: 0.4)
        expect(motor.speed > 0.9, String(format: "the motor is back to %.0f%% of speed in 0.4 s", motor.speed * 100))

        let fast = tone(440, seconds: 120)
        fast.grab(at: 1, speed: 1)
        let began = Date()
        _ = play(fast, seconds: 60)
        let spent = Date().timeIntervalSince(began)
        expect(spent < 3, String(format: "a minute of sound takes %.2f s to make, even in this debug build", spent))

        let deck = KnobShiftVinylGeometry(center: CGPoint(x: 300, y: 200), diameter: 340)
        var roundTrip = 0.0, rightHalf = true
        for step in 0...100 {
            let progress = Double(step) / 100
            roundTrip = max(roundTrip, abs(deck.progress(angle: deck.angle(progress: progress)) - progress))
            rightHalf = rightHalf && deck.stylus(progress: progress).x > deck.center.x
        }
        expect(roundTrip < 0.0001, String(format: "the arm's angle and the song agree (off by %.6f)", roundTrip))
        expect(rightHalf, "the stylus stays on the half the sleeve leaves showing")
        let radius = { (p: Double) in hypot(deck.stylus(progress: p).x - 300, deck.stylus(progress: p).y - 200) / 340 }
        expect(abs(radius(0) - 0.47) < 0.001 && abs(radius(1) - 0.22) < 0.001, "the stylus runs from the outer groove to the inner one")
        expect(deck.angle(progress: 1) > deck.angle(progress: 0) && deck.restAngle < deck.angle(progress: 0), "the arm swings inward as the song plays, and rests clear of the record")
        expect(abs(deck.progress(finger: deck.stylus(progress: 0.4)) - 0.4) < 0.0001, "a finger on the stylus picks the same point in the song")

        if arguments.count >= 2 { record(URL(fileURLWithPath: arguments[0]), to: URL(fileURLWithPath: arguments[1])) }
        print(failed == 0 ? "Scratch check passed" : "Scratch check FAILED: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }

    /// A real song: plays, a hand stops it, two scratches back and forth, a flick, then the motor.
    private static func record(_ song: URL, to out: URL) {
        guard let (samples, frames, fileRate) = try? KnobShiftScratch.decode(song) else { expect(false, "the song decodes"); return }
        let seconds = Double(frames) / fileRate
        expect(seconds > 30, String(format: "the real song decodes: %.1f s", seconds))
        let scratch = KnobShiftScratch(outputRate: rate)
        scratch.use(samples, frames: frames, rate: fileRate)
        scratch.grab(at: min(60, seconds / 2), speed: 1)
        var audio = play(scratch, seconds: 2.5)
        scratch.move(speed: 0)
        audio += play(scratch, seconds: 0.35)
        for _ in 0..<3 {
            for speed in [-1.6, 1.6, -1.2, 1.2, -2.0, 2.0] {
                scratch.move(speed: speed)
                audio += play(scratch, seconds: 0.16)
            }
        }
        scratch.move(speed: 0)
        audio += play(scratch, seconds: 0.25)
        scratch.move(speed: 5)
        audio += play(scratch, seconds: 0.3)
        scratch.letGo(to: 1)
        audio += play(scratch, seconds: 3)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.count)),
              let file = try? AVAudioFile(forWriting: out, settings: format.settings) else { return }
        buffer.frameLength = buffer.frameCapacity
        audio.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: audio.count) }
        try? file.write(from: buffer)
        print("wrote \(out.path)")
    }
}
