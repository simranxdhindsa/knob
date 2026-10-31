import Foundation

/// Verifies offline local-file analysis without opening an audio output device.
enum KnobShiftAnalysisCheck {
    static func run(file: URL) {
        let completion = DispatchSemaphore(value: 0)
        Task {
            defer { completion.signal() }
            do {
                let track = try await KnobShiftAnalyser().track(for: file)
                guard track.duration > 0 else { fail("analysis returned an empty track") }
                let tempo = track.analysis.tempo.map { String(format: "%.0f BPM", $0) } ?? "no confident tempo"
                let fade = track.analysis.fadeOutCue.map { String(format: "fade at %.1fs", $0) } ?? "no sustained fade"
                let phrase = track.analysis.phraseOutroCue.map { String(format: "phrase cue %.1fs", $0) } ?? "no phrase cue"
                print("KnobShift analysis check passed: \(tempo), \(track.analysis.beatGrid.count) beat cues, \(fade), \(phrase)")
            } catch {
                fail("could not analyse local track")
            }
        }
        completion.wait()
    }

    private static func fail(_ message: String) -> Never {
        fputs("KnobShift analysis check failed: \(message)\n", stderr)
        exit(1)
    }
}
