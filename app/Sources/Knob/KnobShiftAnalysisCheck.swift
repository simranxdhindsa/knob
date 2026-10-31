import Foundation

/// Verifies offline local-file analysis without opening an audio output device.
enum KnobShiftAnalysisCheck {
    static func run(file: URL) {
        let completion = DispatchSemaphore(value: 0)
        Task {
            defer { completion.signal() }
            do {
                let result = try await KnobShiftAnalyser().analyse(file)
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
            let sync = KnobShiftSync.make(outgoing: a.analysis, incoming: b.analysis)
            plan.reasoning.forEach { print("  \($0)") }
            sync.notes.forEach { print("  \($0)") }
            guard plan.duration > 0 else { print("KnobShift sync check: clean handoff, no blend to line up"); return }
            guard let outgoingStart = a.analysis.beatGrid.first(where: { $0 >= plan.start }),
                  let incomingStart = b.analysis.beatGrid.first(where: { $0 >= plan.incomingOffset }) else {
                fail("no beats near the blend start")
            }
            let music = plan.start + plan.duration - outgoingStart
            for (label, glide) in [("with tempo sync", sync), ("without tempo sync", KnobShiftSync.off)] {
                let duration = glide.blendLength(forOutgoingMusic: music) { KnobShiftModel.shape($0, .gentle) }
                let offsets = beatOffsets(a.analysis.beatGrid, from: outgoingStart, b.analysis.beatGrid, from: incomingStart,
                                          duration: duration, sync: glide)
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
                                     duration: TimeInterval, sync: KnobShiftSync) -> [Double] {
        let step = 0.0005
        var outgoing = outgoingStart, incoming = incomingStart
        var outgoingTimes: [Double] = [], incomingTimes: [Double] = []
        var nextOutgoing = outgoingBeats.firstIndex { $0 >= outgoingStart } ?? outgoingBeats.count
        var nextIncoming = incomingBeats.firstIndex { $0 >= incomingStart } ?? incomingBeats.count
        var time = 0.0
        while time < duration {
            let rates = sync.rates(at: KnobShiftModel.shape(time / duration, .gentle))
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

    private static func fail(_ message: String) -> Never {
        fputs("KnobShift analysis check failed: \(message)\n", stderr)
        exit(1)
    }
}
