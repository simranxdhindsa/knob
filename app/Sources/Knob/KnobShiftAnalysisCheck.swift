import AVFoundation
import Foundation

/// Verifies offline local-file analysis without opening an audio output device.
enum KnobShiftAnalysisCheck {
    static func run(file: URL) {
        let completion = DispatchSemaphore(value: 0)
        Task {
            defer { completion.signal() }
            do {
                let result = try await KnobShiftAnalyser().analyse(file, fresh: true)
                for step in result.steps { print("  \(step)") }
                let track = result.track
                guard track.duration > 0 else { fail("analysis returned an empty track") }
                let tempo = track.analysis.tempo.map { String(format: "%.0f BPM", $0) } ?? "no confident tempo"
                let fade = track.analysis.fadeOutCue.map { String(format: "fade at %.1fs", $0) } ?? "no sustained fade"
                let voice = track.analysis.vocalEnd.map { String(format: "voice ends %.1fs", $0) } ?? "no vocals"
                print("KnobShift analysis check passed: \(tempo), \(track.analysis.beatGrid.count) beat cues, \(fade), \(voice)")
            } catch {
                fail("could not analyse local track")
            }
        }
        completion.wait()
    }

    /// Simulates a blend between two real songs with the real plan, beat lock and tempo glide,
    /// following both songs millisecond by millisecond, and reports how far apart their beats
    /// land during the blend. Needs no audio device.
    static func runSync(first: URL, second: URL) {
        let completion = DispatchSemaphore(value: 0)
        Task {
            defer { completion.signal() }
            guard let a = try? await KnobShiftAnalyser().track(for: first),
                  let b = try? await KnobShiftAnalyser().track(for: second) else { fail("could not analyse both songs") }
            let plan = KnobShiftPlan.make(from: a, to: b)
            let sync = KnobShiftSync.make(outgoing: a.analysis, incoming: b.analysis, beatsBeforeVoice: plan.beatsBeforeVoice)
            plan.reasoning.forEach { print("  \($0)") }
            sync.notes.forEach { print("  \($0)") }
            guard plan.duration > 0 else { print("KnobShift sync check: clean handoff, no blend to line up"); return }
            // The same strong beats the deck's beat lock lines up.
            guard let outgoingStart = KnobShiftModel.strongBeat(in: a.analysis, atOrAfter: plan.start),
                  let incomingStart = KnobShiftModel.strongBeat(in: b.analysis, atOrAfter: plan.incomingOffset) else {
                fail("no beats near the blend start")
            }
            let music = plan.start + plan.duration - outgoingStart
            // At half or double time only every second beat of the faster grid should line up.
            let ratio = (b.analysis.tempo ?? 1) / max(sync.incomingTempo, 1)
            // Count every second beat from the one the incoming song really starts on.
            let firstIncoming = b.analysis.beatGrid.firstIndex { $0 >= incomingStart - 0.001 } ?? 0
            let incomingBeats = ratio > 1.5 ? stride(from: firstIncoming, to: b.analysis.beatGrid.count, by: 2).map { b.analysis.beatGrid[$0] }
                : b.analysis.beatGrid
            let firstOutgoing = a.analysis.beatGrid.firstIndex { $0 >= outgoingStart - 0.001 } ?? 0
            let outgoingBeats = ratio < 0.67 ? stride(from: firstOutgoing, to: a.analysis.beatGrid.count, by: 2).map { a.analysis.beatGrid[$0] }
                : a.analysis.beatGrid
            for (label, glide) in [("with tempo sync", sync), ("without tempo sync", KnobShiftSync.off)] {
                let voice = min(max((plan.handoff - outgoingStart) / music, 0), 1)
                let duration = glide.blendLength(forOutgoingMusic: music, voice: voice)
                let offsets = beatOffsets(outgoingBeats, from: outgoingStart, incomingBeats, from: incomingStart,
                                          duration: duration, voice: voice, sync: glide)
                let sorted = offsets.map(abs).sorted()
                guard !sorted.isEmpty else { continue }
                let within = Double(sorted.filter { $0 <= 20 }.count) / Double(sorted.count) * 100
                print(String(format: "KnobShift sync check %@: %d beats over %.2fs, median %.1f ms apart, worst %.1f ms, %.0f%% within 20 ms",
                             label, sorted.count, duration, sorted[sorted.count / 2], sorted.last ?? 0, within))
            }
        }
        completion.wait()
    }

    /// Wall-clock gap from each incoming beat to the nearest outgoing beat during the blend.
    private static func beatOffsets(_ outgoingBeats: [TimeInterval], from outgoingStart: TimeInterval,
                                     _ incomingBeats: [TimeInterval], from incomingStart: TimeInterval,
                                     duration: TimeInterval, voice: Double, sync: KnobShiftSync) -> [Double] {
        let step = 0.0005
        var outgoing = outgoingStart, incoming = incomingStart
        var outgoingTimes: [Double] = [], incomingTimes: [Double] = []
        var nextOutgoing = outgoingBeats.firstIndex { $0 >= outgoingStart } ?? outgoingBeats.count
        var nextIncoming = incomingBeats.firstIndex { $0 >= incomingStart } ?? incomingBeats.count
        var time = 0.0
        while time < duration {
            let rates = sync.rates(progress: time / duration, voice: voice)
            while nextOutgoing < outgoingBeats.count, outgoingBeats[nextOutgoing] <= outgoing {
                outgoingTimes.append(time); nextOutgoing += 1
            }
            while nextIncoming < incomingBeats.count, incomingBeats[nextIncoming] <= incoming {
                incomingTimes.append(time); nextIncoming += 1
            }
            outgoing += rates.outgoing * step
            incoming += rates.incoming * step
            time += step
        }
        return incomingTimes.compactMap { beat in
            outgoingTimes.min { abs($0 - beat) < abs($1 - beat) }.map { (beat - $0) * 1_000 }
        }
    }

    /// Separates `length` seconds from `start` into voice and music and writes both as WAV files
    /// in `folder`, so the separation can be heard.
    static func runStems(file: URL, start: TimeInterval, length: TimeInterval, folder: URL) {
        do {
            let error = try KnobShiftStems.roundTripError(file, from: start, length: length)
            print(String(format: "  Transform alone, nothing removed: largest difference %.6f%% of the peak.", error * 100))
            guard error < 0.001 else { fail("the transform does not rebuild the original sound") }
            let stems = try KnobShiftStems.separate(file, from: start, length: length)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, buffer) in [("vocals", stems.vocals), ("music", stems.music)] {
                let url = folder.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) \(name).wav")
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: buffer.format.sampleRate,
                                               AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16]
                let output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                try output.write(from: buffer)
                let peak = (0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max() ?? 0
                print(String(format: "  %@: %@, peak %.2f", name, url.path, peak))
            }
            print(String(format: "KnobShift stems check passed: %.1fs separated in %.2fs.", length, stems.seconds))
            exit(0)
        } catch {
            fail("separation failed: \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("KnobShift analysis check failed: \(message)\n", stderr)
        exit(1)
    }
}
