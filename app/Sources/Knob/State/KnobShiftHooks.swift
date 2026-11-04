import Accelerate
import AVFoundation
import Foundation

/// Finds where a song's last hook begins: the last section that plays again something heard
/// earlier (a chorus). Songs with two hooks give the start of the second, which is where the
/// mix should begin. It listens to the sound itself, as 24 bands of loudness every half second,
/// and compares each music break (the places where sections change) with everything heard at
/// least 20 seconds before it. A break whose next 10 seconds repeat an earlier stretch is a
/// hook; the last one with enough song left to mix is returned. Some choruses come back with no
/// break at all (Why So, at 3:20): when no break is a hook, every half second is compared the
/// same way, and the last strongly repeating stretch gives the hook. Only then, because over a
/// whole song this also catches verses that sound alike (it would put No Luck's hook at 2:33).
enum KnobShiftHooks {
    private static let step = 0.5
    private static let windowLength = 10.0
    private static let minimumGap = 20.0
    private static let minimumRemaining = 10.0
    private static let bands = 24
    private static let frameSize = 4_096
    /// A dip this short inside a repeating stretch does not end it.
    private static let repeatGap = 6.0
    /// A repeat must hold this long to count, so one lucky match is not a hook.
    private static let shortestRepeat = 2.0

    static func lastHook(in url: URL, breaks: [TimeInterval], beats: [TimeInterval], audibleEnd: TimeInterval) -> (start: TimeInterval?, steps: [String]) {
        let candidates = breaks.filter { $0 >= audibleEnd * 0.4 && audibleEnd - $0 >= minimumRemaining }
        guard let features = readFeatures(url) else { return (nil, ["Hook: skipped, the sound could not be read."]) }
        let span = Int(windowLength / step)
        guard features.count > span * 2 else { return (nil, ["Hook: skipped, the song is too short."]) }

        // One normalised vector per 10 second stretch, starting at every half second.
        let vectors: [[Float]] = (0...(features.count - span)).map { start in
            var vector = features[start..<(start + span)].flatMap { $0 }
            let length = sqrt(vector.reduce(0) { $0 + $1 * $1 })
            if length > 0 { vector = vector.map { $0 / length } }
            return vector
        }
        var scored: [(at: TimeInterval, score: Double, match: TimeInterval)] = []
        for candidate in candidates {
            let frame = Int((candidate / step).rounded())
            let limit = frame - span - Int(minimumGap / step)
            guard frame < vectors.count, limit > 0 else { continue }
            var best = 0.0, bestAt = 0
            for earlier in 0..<limit {
                var dot: Float = 0
                vDSP_dotpr(vectors[earlier], 1, vectors[frame], 1, &dot, vDSP_Length(vectors[frame].count))
                if Double(dot) > best { best = Double(dot); bestAt = earlier }
            }
            scored.append((candidate, best, Double(bestAt) * step))
        }
        // A hook repeats about as well as the song's best repeat does; a floor keeps a song
        // with no real repeats from picking one.
        let top = scored.map(\.score).max() ?? 0
        let threshold = max(0.6, 0.9 * top)
        var steps = scored.map { String(format: "Hook check at %@: repeats %@ with %.2f similarity.", Self.clock($0.at), Self.clock($0.match), $0.score) }
        if let hook = scored.last(where: { $0.score >= threshold }) {
            steps.append(String(format: "Hook: the last hook begins at %@ (%.2f similarity, needs %.2f), %.0fs before the end.",
                                Self.clock(hook.at), hook.score, threshold, audibleEnd - hook.at))
            return (hook.at, steps)
        }
        // No break is a hook: compare every half second of the later part of the song.
        let first = Int(audibleEnd * 0.4 / step), last = min(Int((audibleEnd - minimumRemaining) / step), vectors.count - 1)
        guard first < last else {
            steps.append("Hook: none, the song is too short to look for repeats.")
            return (nil, steps)
        }
        let scores = (first...last).map { frame in
            (0..<max(frame - span - Int(minimumGap / step), 0)).reduce(0.0) { best, earlier in
                var dot: Float = 0
                vDSP_dotpr(vectors[earlier], 1, vectors[frame], 1, &dot, vDSP_Length(vectors[frame].count))
                return max(best, Double(dot))
            }
        }
        guard let found = lastRepeat(in: scores, step: step) else {
            steps.append(String(format: "Hook: none, nothing repeats well enough (best %.2f, needs 0.60).", max(top, scores.max() ?? 0)))
            return (nil, steps)
        }
        let heard = Double(first + found) * step
        let start = beats.min { abs($0 - heard) < abs($1 - heard) } ?? heard
        steps.append(String(format: "Hook: no music break is a hook, but the sound repeats strongly from %@ (%.2f similarity), %.0fs before the end.",
                            Self.clock(start), scores[found], audibleEnd - start))
        return (start, steps)
    }

    /// The index where the last strongly repeating stretch begins, in `scores` taken `step`
    /// seconds apart. Strong means about as good as the song's best repeat.
    static func lastRepeat(in scores: [Double], step: TimeInterval) -> Int? {
        guard let top = scores.max() else { return nil }
        let threshold = max(0.6, 0.9 * top)
        var runs: [(from: Int, to: Int)] = []
        for (index, score) in scores.enumerated() where score >= threshold {
            if let open = runs.last, Double(index - open.to) * step <= repeatGap {
                runs[runs.count - 1].to = index
            } else {
                runs.append((index, index))
            }
        }
        return runs.last { Double($0.to - $0.from) * step >= shortestRepeat }?.from
    }

    private static func clock(_ time: TimeInterval) -> String {
        String(format: "%d:%02d", Int(time) / 60, Int(time) % 60)
    }

    /// The loudness of 24 bands between 100 Hz and 6 kHz, in dB with each frame's average
    /// taken off, so the shape of the sound is compared and not how loud it is.
    private static func readFeatures(_ url: URL) -> [[Float]]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameSize)) else { return nil }
        let log2n = vDSP_Length(log2(Double(frameSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        // Band edges, spaced evenly in pitch, as bin numbers.
        let edges = (0...bands).map { 100 * pow(60.0, Double($0) / Double(bands)) }
        let bins = edges.map { max(1, min(frameSize / 2 - 1, Int($0 * Double(frameSize) / rate))) }
        let hop = Int(rate * step)
        var features: [[Float]] = []
        var real = [Float](repeating: 0, count: frameSize / 2)
        var imaginary = [Float](repeating: 0, count: frameSize / 2)
        var position = 0
        while position + frameSize <= Int(file.length) {
            file.framePosition = AVAudioFramePosition(position)
            buffer.frameLength = 0
            guard (try? file.read(into: buffer, frameCount: AVAudioFrameCount(frameSize))) != nil,
                  Int(buffer.frameLength) == frameSize, let samples = buffer.floatChannelData?[0] else { break }
            var windowed = [Float](repeating: 0, count: frameSize)
            vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(frameSize))
            var power = [Float](repeating: 0, count: frameSize / 2)
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    windowed.withUnsafeBufferPointer { pointer in
                        pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: frameSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(frameSize / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(frameSize / 2))
                }
            }
            var frame = (0..<bands).map { band -> Float in
                let low = bins[band], high = max(bins[band + 1], bins[band] + 1)
                let sum = power[low..<min(high, frameSize / 2)].reduce(0, +)
                return Float(log(Double(sum) + 1e-9))
            }
            let mean = frame.reduce(0, +) / Float(bands)
            frame = frame.map { $0 - mean }
            features.append(frame)
            position += hop
        }
        return features
    }
}
