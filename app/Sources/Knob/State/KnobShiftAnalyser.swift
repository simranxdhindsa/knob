import AVFoundation
import Foundation

/// Offline analysis of one local file, entirely off the playback and driver callbacks. Every
/// decision is also written as a plain step, so the KnobShift log shows why a cue was or was not
/// found instead of only the final numbers.
actor KnobShiftAnalyser {
    struct Result {
        let track: KnobShiftModel.Track
        let steps: [String]
    }

    func track(for url: URL) throws -> KnobShiftModel.Track {
        try analyse(url).track
    }

    /// Uses the saved analysis when the file has not changed since it was analysed, so opening
    /// Knob does not re-analyse every queued song. `fresh` always measures again.
    /// `progress` hears 0...1 as the analysis moves through its steps (for the queue's ring).
    func analyse(_ url: URL, fresh: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) throws -> Result {
        let started = Date()
        if !fresh, let saved = KnobShiftAnalysisCache.load(for: url) {
            let track = KnobShiftModel.Track(url: url, title: url.deletingPathExtension().lastPathComponent,
                                             duration: saved.duration, tailSilence: saved.tailSilence, analysis: saved.analysis)
            let note = String(format: "Saved analysis reused (file unchanged since it was analysed), loaded in %.0f ms.",
                              Date().timeIntervalSince(started) * 1_000)
            return Result(track: track, steps: [note] + saved.steps)
        }
        let result = try measure(url, progress: progress ?? { _ in })
        KnobShiftAnalysisCache.save(result.track, steps: result.steps)
        return result
    }

    private func measure(_ url: URL, progress: @Sendable (Double) -> Void) throws -> Result {
        progress(0.05)
        let started = Date()
        var steps: [String] = []
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let duration = Double(file.length) / sampleRate
        steps.append(String(format: "File: %.0f Hz, %d channel(s), %lld frames, %.2fs.",
                            sampleRate, Int(format.channelCount), file.length, duration))
        guard duration.isFinite, duration > 0 else { throw AnalysisError.invalidFile }

        let windows = try energyWindows(in: file, sampleRate: sampleRate)
        progress(0.3)
        let peak = windows.map(\.rms).max() ?? 0
        let windowLength = windows.first?.duration ?? 0
        steps.append(String(format: "Energy: %d RMS windows of %.0f ms, peak RMS %.4f.",
                            windows.count, windowLength * 1_000, peak))

        let trailing = silenceDuration(in: windows.reversed())
        let leading = silenceDuration(in: windows)
        steps.append(String(format: "Silence (RMS < %.3f): leading %.2fs, trailing %.2fs.",
                            Self.silenceRMS, leading, trailing))

        let rhythm = KnobShiftBeats.analyse(url)
        progress(0.6)
        steps.append(contentsOf: rhythm.steps)

        // A quiet tail is the only safe cue available without supplied timed lyrics. The cue
        // begins at the measured quiet boundary, not at an arbitrary number of seconds.
        let quietStart = duration - trailing
        let fade = fadeOutStart(in: windows, quietStart: quietStart)
        steps.append(fade.note)
        let vocals = KnobShiftVocals.detect(in: url)
        progress(0.95)
        steps.append(contentsOf: vocals.steps)
        if let end = vocals.end {
            steps.append(String(format: "Outro after the voice: %.2fs of music before the audible end.", max(0, quietStart - end)))
        }
        let safeOutroCue = fade.cue ?? (trailing >= 1 ? quietStart : nil)
        if let safeOutroCue {
            let source = fade.cue != nil ? "fade start" : "start of the trailing silence"
            steps.append(String(format: "Safe outro cue: %.2fs (%@), %.2fs before the end.",
                                safeOutroCue, source, duration - safeOutroCue))
        } else {
            steps.append("Safe outro cue: none. No sustained fade and under 1s of trailing silence.")
        }

        let analysis = KnobShiftModel.Analysis(tempo: rhythm.tempo, tempoConfidence: rhythm.confidence,
                                               beatGrid: rhythm.beats, leadingSilence: leading,
                                               trailingSilence: trailing, fadeOutCue: fade.cue,
                                               safeOutroCue: safeOutroCue,
                                               vocalOnset: vocals.onset, vocalEnd: vocals.end,
                                               lastLineStart: vocals.lastLineStart,
                                               mainVocalOnset: vocals.mainOnset, vocalStrays: vocals.strays)
        steps.append(String(format: "Finished in %.0f ms.", Date().timeIntervalSince(started) * 1_000))
        let track = KnobShiftModel.Track(url: url, title: url.deletingPathExtension().lastPathComponent,
                                         duration: duration, tailSilence: trailing, analysis: analysis)
        return Result(track: track, steps: steps)
    }

    private static let silenceRMS: Float = 0.006

    private struct EnergyWindow {
        let time: TimeInterval
        let duration: TimeInterval
        let rms: Float
    }

    /// Uses short RMS windows. This supplies conservative silence and rhythmic-onset candidates,
    /// not a claim of lyric recognition.
    private func energyWindows(in file: AVAudioFile, sampleRate: Double) throws -> [EnergyWindow] {
        let frames = AVAudioFrameCount(max(512, min(2_048, Int(sampleRate / 20))))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw AnalysisError.invalidFile
        }
        var windows: [EnergyWindow] = []
        while file.framePosition < file.length {
            buffer.frameLength = 0
            let start = Double(file.framePosition) / sampleRate
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { continue }
            var power: Float = 0
            for index in 0..<Int(buffer.frameLength) { power += samples[index] * samples[index] }
            let length = Double(buffer.frameLength) / sampleRate
            windows.append(EnergyWindow(time: start, duration: length,
                                        rms: sqrt(power / Float(buffer.frameLength))))
        }
        return windows
    }

    private func silenceDuration<S: Sequence>(in windows: S) -> TimeInterval where S.Element == EnergyWindow {
        var total: TimeInterval = 0
        for window in windows {
            guard window.rms < Self.silenceRMS else { break }
            total += window.duration
        }
        return total
    }

    /// Finds a sustained end-of-track energy descent before silence. This is deliberately more
    /// conservative than choosing a random final window: it only returns a cue when the envelope
    /// stays substantially below the immediately preceding musical section through the ending.
    private func fadeOutStart(in windows: [EnergyWindow], quietStart: TimeInterval) -> (cue: TimeInterval?, note: String) {
        let active = windows.filter { $0.time < quietStart && $0.rms >= Self.silenceRMS }
        guard active.count > 20, let first = active.first, let last = active.last else {
            return (nil, "Fade: skipped, only \(active.count) non-silent windows.")
        }
        let span = last.time - first.time
        guard span > 2 else { return (nil, String(format: "Fade: skipped, music lasts only %.2fs.", span)) }
        let referenceStart = first.time + span * 0.45
        let reference = active.filter { $0.time >= referenceStart }.map { Double($0.rms) }
        guard reference.count > 10 else { return (nil, "Fade: skipped, too little music after the midpoint.") }
        let baseline = reference.sorted()[Int(Double(reference.count - 1) * 0.8)]
        guard baseline > 0 else { return (nil, "Fade: skipped, reference loudness is zero.") }
        let windowLength = active.map(\.duration).reduce(0, +) / Double(active.count)
        let confirmation = max(1, Int((0.6 / max(windowLength, 0.001)).rounded()))
        for index in 0..<(active.count - confirmation) {
            let local = active[index..<(index + confirmation)].map { Double($0.rms) }
            let localAverage = local.reduce(0, +) / Double(local.count)
            guard localAverage < baseline * 0.55 else { continue }
            let remaining = active[index...].map { Double($0.rms) }
            let lowerFrames = remaining.filter { $0 < baseline * 0.82 }.count
            let lowerShare = Double(lowerFrames) / Double(remaining.count)
            if lowerShare >= 0.82 {
                let cue = active[index].time
                return (cue, String(format: "Fade: starts at %.2fs. Loudness %.4f vs baseline %.4f (under 55%%), %.0f%% of the rest stays quieter.",
                                    cue, localAverage, baseline, lowerShare * 100))
            }
        }
        return (nil, String(format: "Fade: none. No 0.6s stretch held under 55%% of the baseline %.4f through to the end.", baseline))
    }

    private enum AnalysisError: Error { case invalidFile }
}
