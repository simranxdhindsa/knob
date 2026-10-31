import AVFoundation
import Accelerate

/// Tempo and beat positions for one local file, so KnobShift can line up and glide two songs'
/// beats during a blend. Runs offline during analysis, never on an audio callback.
///
/// 1. Onset strength: how much the spectrum grows from one 11.6 ms step to the next.
/// 2. Tempo: the strongest repeat in that onset curve between 60 and 200 BPM, with a gentle
///    preference for common dance and pop tempos so half or double speed is not picked.
/// 3. Beats: a best-path search that follows the actual hits while staying close to that
///    tempo, so beats stay on the music even when a drummer drifts slightly.
enum KnobShiftBeats {
    struct Result {
        let tempo: Double?
        let confidence: Double
        let beats: [TimeInterval]
        let steps: [String]
    }

    private static let frameSize = 1_024
    private static let hop = 512

    static func analyse(_ url: URL) -> Result {
        let started = Date()
        guard let file = try? AVAudioFile(forReading: url) else {
            return Result(tempo: nil, confidence: 0, beats: [], steps: ["Beats: could not read the file."])
        }
        let sampleRate = file.processingFormat.sampleRate
        let curves = onsetCurve(file)
        let onsets = curves.full
        let framesPerSecond = sampleRate / Double(hop)
        guard onsets.count > Int(framesPerSecond * 8) else {
            return Result(tempo: nil, confidence: 0, beats: [], steps: ["Beats: too short to find a tempo."])
        }
        guard let period = bestPeriod(onsets, framesPerSecond: framesPerSecond) else {
            return Result(tempo: nil, confidence: 0, beats: [], steps: ["Beats: no steady pulse found."])
        }
        let beatFrames = trackBeats(onsets, period: period.frames)
        // A frame's flux belongs to the moment its window reaches the new sound: its middle.
        let centre = Double(frameSize / 2) / sampleRate
        let beats = beatFrames.map { Double($0) / framesPerSecond + centre }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let median = gaps.isEmpty ? 60 / period.bpm : gaps[gaps.count / 2]
        let tempo = 60 / fittedInterval(beats, near: median)
        let steadiness = gaps.isEmpty ? 0 : Double(gaps.filter { abs($0 - median) / median < 0.06 }.count) / Double(gaps.count)
        let confidence = min(1, period.strength * 0.5 + steadiness * 0.5)
        var steps = [
            String(format: "Beats: tempo %.1f BPM, %d beats, first at %.2fs (%.0f ms).",
                   tempo, beats.count, beats.first ?? 0, Date().timeIntervalSince(started) * 1_000),
            String(format: "Beat steadiness: %.0f%% of beats within 6%% of the tempo, pulse strength %.0f%%, confidence %.0f%%.",
                   steadiness * 100, period.strength * 100, confidence * 100)
        ]
        let duration = Double(file.length) / sampleRate
        let kick = KickPosition(bass: curves.bass, framesPerSecond: framesPerSecond, centre: centre)
        guard let grid = sectionGrid(beats, near: median, duration: duration, kick: kick) else {
            steps.append("Beat grid: no steady drum section, so the detected beats are used as they are.")
            return Result(tempo: tempo, confidence: confidence, beats: beats, steps: steps)
        }
        if let period = grid.period {
            steps.append(String(format: "Beat grid: one continuous grid at %.2f BPM, placed on the kick drum across the whole song (drum hits %.1f ms from it, median).",
                                60 / period, grid.residual * 1_000))
            return Result(tempo: 60 / period, confidence: confidence, beats: grid.beats, steps: steps)
        }
        steps.append(String(format: "Beat grid: the tempo changes, so %d drum sections each get their own grid on the kick (median %.1f ms from the hits). Quiet parts follow the nearest section.",
                            grid.sections, grid.residual * 1_000))
        return Result(tempo: tempo, confidence: confidence, beats: grid.beats, steps: steps)
    }

    /// One exact grid (first beat and spacing) per steady drum section. The tracker can follow
    /// the kick in one section and the snare in the next, so a single grid for the whole song
    /// would be off by part of a beat somewhere; each section is right where it matters.
    /// Quiet parts take the grid of the section they lead into, or the one before an outro.
    private static func sectionGrid(_ beats: [TimeInterval], near median: Double,
                                    duration: TimeInterval, kick: KickPosition) -> (beats: [TimeInterval], sections: Int, residual: Double, period: Double?)? {
        var runs: [[TimeInterval]] = []
        var current: [TimeInterval] = []
        for (index, time) in beats.enumerated() {
            if index > 0, abs(time - beats[index - 1] - median) / median > 0.04 {
                runs.append(current)
                current = []
            }
            current.append(time)
        }
        runs.append(current)
        let sections = runs.filter { $0.count >= 12 }.compactMap { fit($0) }.map { section in
            var moved = section
            moved.phase = kick.bestPhase(phase: section.phase, period: section.period, from: section.first, to: section.last)
            return moved
        }
        guard !sections.isEmpty else { return nil }

        // Produced tracks keep one tempo, so their sections must share one continuous grid. The
        // tracker can still land on a different subdivision per section; one whole-song search
        // on the kick removes those jumps.
        let periods = sections.map(\.period)
        if let lowest = periods.min(), let highest = periods.max(), highest / lowest < 1.005,
           let first = sections.first?.first, let last = sections.last?.last {
            let counts = sections.map { Double($0.residuals.count) }
            let estimate = zip(periods, counts).map { $0 * $1 }.reduce(0, +) / counts.reduce(0, +)
            let whole = kick.bestGrid(near: estimate, phase: sections[0].phase, from: first, to: last)
            var start = whole.phase.truncatingRemainder(dividingBy: whole.period)
            if start < 0 { start += whole.period }
            let grid = stride(from: start, to: duration, by: whole.period).map { $0 }
            let residuals = sections.flatMap(\.residuals).sorted()
            return (grid, 1, residuals[residuals.count / 2], whole.period)
        }

        var grid: [TimeInterval] = []
        var residuals: [Double] = []
        for (index, section) in sections.enumerated() {
            // Each section owns time up to halfway into the gap on either side; the first and
            // last sections also own the song's start and end.
            let from = index == 0 ? 0 : (sections[index - 1].last + section.first) / 2
            let to = index == sections.count - 1 ? duration : (section.last + sections[index + 1].first) / 2
            let firstNumber = ((from - section.phase) / section.period).rounded(.up)
            var time = section.phase + firstNumber * section.period
            while time < to {
                if time >= 0 { grid.append(time) }
                time += section.period
            }
            residuals.append(contentsOf: section.residuals)
        }
        residuals.sort()
        return (grid, sections.count, residuals[residuals.count / 2], nil)
    }

    /// Least-squares grid through one run of steady beats.
    private static func fit(_ run: [TimeInterval]) -> Section? {
        let count = Double(run.count)
        let meanNumber = (count - 1) / 2
        let meanTime = run.reduce(0, +) / count
        var numerator = 0.0, denominator = 0.0
        for (number, time) in run.enumerated() {
            numerator += (Double(number) - meanNumber) * (time - meanTime)
            denominator += (Double(number) - meanNumber) * (Double(number) - meanNumber)
        }
        guard denominator > 0, let first = run.first, let last = run.last else { return nil }
        let period = numerator / denominator
        let phase = meanTime - period * meanNumber
        let residuals = run.enumerated().map { abs($1 - (phase + Double($0) * period)) }
        return Section(phase: phase, period: period, first: first, last: last, residuals: residuals)
    }

    private struct Section {
        var phase: Double
        let period: Double
        let first: Double
        let last: Double
        let residuals: [Double]
    }

    /// Picks where in the beat the kick drum lands. The tracker can lock onto a hi-hat triplet
    /// or the off-beat in some sections; trying twelve positions within one beat and keeping the
    /// one with the strongest bass hits puts every section back on the kick.
    private struct KickPosition {
        let bass: [Float]
        let framesPerSecond: Double
        let centre: Double

        /// One grid for the whole song: tempos within ±0.3% of the estimate in 0.01% steps, at 96
        /// positions within the beat, keeping the one with the most kick energy on its beats.
        func bestGrid(near estimate: Double, phase: Double, from: Double, to: Double) -> (phase: Double, period: Double) {
            var best = (phase: phase, period: estimate)
            var bestScore = -Float.infinity
            // Closest tempos first, so a tie keeps the measured tempo rather than a range edge.
            for step in (-30...30).sorted(by: { abs($0) < abs($1) }) {
                let period = estimate * (1 + Double(step) * 0.0001)
                for slot in 0..<96 {
                    let candidate = phase + period * Double(slot) / 96
                    let score = strength(candidate, period, from, to)
                    if score > bestScore { bestScore = score; best = (candidate, period) }
                }
            }
            return best
        }

        func bestPhase(phase: Double, period: Double, from: Double, to: Double) -> Double {
            let candidates = (0..<12).map { phase + period * Double($0) / 12 }
            return candidates.max { strength($0, period, from, to) < strength($1, period, from, to) } ?? phase
        }

        private func strength(_ phase: Double, _ period: Double, _ from: Double, _ to: Double) -> Float {
            var total: Float = 0
            var time = phase + ((from - phase) / period).rounded(.up) * period
            while time <= to {
                // Read the bass curve at the beat's exact moment, between analysis steps.
                let position = (time - centre) * framesPerSecond
                let frame = Int(position.rounded(.down))
                if frame >= 0, frame + 1 < bass.count {
                    let blend = Float(position - Double(frame))
                    total += bass[frame] * (1 - blend) + bass[frame + 1] * blend
                }
                time += period
            }
            return total
        }
    }

    /// Least-squares slope of beat time against beat number over steady runs, which is far finer
    /// than any single gap (each gap is rounded to the 11.6 ms analysis step).
    private static func fittedInterval(_ beats: [TimeInterval], near median: Double) -> Double {
        var runs: [[TimeInterval]] = [[]]
        for (index, time) in beats.enumerated() {
            if index > 0, abs(time - beats[index - 1] - median) / median > 0.15 { runs.append([]) }
            runs[runs.count - 1].append(time)
        }
        var weighted = 0.0, total = 0.0
        for run in runs where run.count >= 8 {
            let count = Double(run.count)
            let meanIndex = (count - 1) / 2
            let meanTime = run.reduce(0, +) / count
            var numerator = 0.0, denominator = 0.0
            for (index, time) in run.enumerated() {
                numerator += (Double(index) - meanIndex) * (time - meanTime)
                denominator += (Double(index) - meanIndex) * (Double(index) - meanIndex)
            }
            guard denominator > 0 else { continue }
            weighted += numerator / denominator * count
            total += count
        }
        return total > 0 ? weighted / total : median
    }

    /// Spectral flux on a mono mix: summed growth of log-magnitude per frequency bin.
    private static func onsetCurve(_ file: AVAudioFile) -> (full: [Float], bass: [Float]) {
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let bins = frameSize / 2
        guard let setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(frameSize), .FORWARD),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { return ([], []) }
        defer { vDSP_DFT_DestroySetup(setup) }
        var window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_NORM))

        var pending: [Float] = []
        var start = 0
        var previous = [Float](repeating: 0, count: bins)
        var onsets: [Float] = []
        var bassOnsets: [Float] = []
        // Bins up to about 170 Hz: kick drum and bass, where the beat really sits.
        let bassBins = max(2, Int(170 / (format.sampleRate / Double(frameSize))))
        var evenIn = [Float](repeating: 0, count: bins), oddIn = [Float](repeating: 0, count: bins)
        var real = [Float](repeating: 0, count: bins), imag = [Float](repeating: 0, count: bins)
        var magnitudes = [Float](repeating: 0, count: bins)
        var framed = [Float](repeating: 0, count: frameSize)
        file.framePosition = 0
        while file.framePosition < file.length {
            buffer.frameLength = 0
            guard (try? file.read(into: buffer)) != nil, buffer.frameLength > 0,
                  let data = buffer.floatChannelData else { break }
            let count = Int(buffer.frameLength)
            var mono = [Float](repeating: 0, count: count)
            for channel in 0..<channels {
                vDSP_vadd(mono, 1, data[channel], 1, &mono, 1, vDSP_Length(count))
            }
            var scale = 1 / Float(channels)
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(count))
            pending.append(contentsOf: mono)

            while pending.count - start >= frameSize {
                pending.withUnsafeBufferPointer { source in
                    vDSP_vmul(source.baseAddress! + start, 1, window, 1, &framed, 1, vDSP_Length(frameSize))
                }
                for index in 0..<bins {
                    evenIn[index] = framed[2 * index]
                    oddIn[index] = framed[2 * index + 1]
                }
                vDSP_DFT_Execute(setup, evenIn, oddIn, &real, &imag)
                var flux: Float = 0
                var bassFlux: Float = 0
                for index in 0..<bins {
                    let magnitude = log1pf(100 * sqrtf(real[index] * real[index] + imag[index] * imag[index]))
                    magnitudes[index] = magnitude
                    let rise = max(0, magnitude - previous[index])
                    flux += rise
                    if index > 0, index <= bassBins { bassFlux += rise }
                }
                swap(&previous, &magnitudes)
                onsets.append(flux)
                bassOnsets.append(bassFlux)
                start += hop
            }
            if start > 1 << 16 {
                pending.removeFirst(start)
                start = 0
            }
        }
        return (hitsOnly(onsets), hitsOnly(bassOnsets))
    }

    /// Removes the slowly changing loudness so only the hits remain, then normalises.
    private static func hitsOnly(_ onsets: [Float]) -> [Float] {
        let smooth = 16
        var detrended = [Float](repeating: 0, count: onsets.count)
        var running: Float = 0
        for index in onsets.indices {
            running += onsets[index]
            if index >= smooth { running -= onsets[index - smooth] }
            let mean = running / Float(min(index + 1, smooth))
            detrended[index] = max(0, onsets[index] - mean)
        }
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(detrended, 1, nil, 1, &mean, &deviation, vDSP_Length(detrended.count))
        if deviation > 0 { detrended = detrended.map { $0 / deviation } }
        return detrended
    }

    /// Autocorrelation peak between 60 and 200 BPM, weighted toward about 120 BPM by one octave,
    /// refined between lags so the tempo is not limited to whole frames.
    private static func bestPeriod(_ onsets: [Float], framesPerSecond: Double) -> (frames: Double, bpm: Double, strength: Double)? {
        let shortest = Int(framesPerSecond * 60 / 200)
        let longest = Int(framesPerSecond * 60 / 60)
        guard longest + 2 < onsets.count / 2 else { return nil }
        var energy: Float = 0
        vDSP_dotpr(onsets, 1, onsets, 1, &energy, vDSP_Length(onsets.count))
        guard energy > 0 else { return nil }
        var correlation = [Double](repeating: 0, count: longest + 2)
        onsets.withUnsafeBufferPointer { values in
            for lag in max(1, shortest - 1)...(longest + 1) {
                var dot: Float = 0
                vDSP_dotpr(values.baseAddress!, 1, values.baseAddress! + lag, 1, &dot, vDSP_Length(values.count - lag))
                correlation[lag] = Double(dot / energy)
            }
        }
        var best = shortest
        var bestScore = -Double.infinity
        for lag in shortest...longest {
            let bpm = 60 * framesPerSecond / Double(lag)
            let octaves = log2(bpm / 120)
            let score = correlation[lag] * exp(-0.5 * octaves * octaves)
            if score > bestScore { bestScore = score; best = lag }
        }
        let left = correlation[best - 1], middle = correlation[best], right = correlation[best + 1]
        let curve = left - 2 * middle + right
        let shift = curve < 0 ? 0.5 * (left - right) / curve : 0
        let frames = Double(best) + max(-0.5, min(0.5, shift))
        return (frames, 60 * framesPerSecond / frames, max(0, min(1, middle * 2)))
    }

    /// Dynamic-programming beat tracker: each beat is worth its onset strength, minus a penalty
    /// for straying from the tempo, and the best chain through the whole song is kept.
    private static func trackBeats(_ onsets: [Float], period: Double) -> [Int] {
        let count = onsets.count
        let tightness = 100.0
        var score = onsets.map(Double.init)
        var previous = [Int](repeating: -1, count: count)
        let earliest = Int((period * 2).rounded()), latest = max(1, Int((period / 2).rounded()))
        for index in 0..<count {
            let low = max(0, index - earliest), high = index - latest
            guard high >= low else { continue }
            var bestValue = -Double.infinity, bestIndex = -1
            for candidate in low...high {
                let ratio = log(Double(index - candidate) / period)
                let value = score[candidate] - tightness * ratio * ratio
                if value > bestValue { bestValue = value; bestIndex = candidate }
            }
            if bestIndex >= 0, bestValue > 0 {
                score[index] += bestValue
                previous[index] = bestIndex
            }
        }
        let tail = max(0, count - Int(period.rounded()))
        guard var current = (tail..<count).max(by: { score[$0] < score[$1] }) else { return [] }
        var beats: [Int] = []
        while current >= 0 {
            beats.append(current)
            current = previous[current]
        }
        return beats.reversed()
    }
}
