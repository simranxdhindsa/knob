import Foundation

/// `--knobshift-mix-check`: a voice ending just before its song does, and the old tails clearing
/// for the new voice in a mix without a hook.
@MainActor
extension KnobShiftMixTests {
    static func shortEnding() {
        print("A voice ending 2 seconds before the song does (Khuda)")
        var current = song("Khuda", tempo: 133, duration: 203.7, trailing: 0.66, voice: 4...201, lastLine: 183)
        var analysis = current.analysis
        analysis.vocalLineEnds = [150.2, 190.5, 201]
        current = KnobShiftModel.Track(url: current.url, title: current.title, duration: current.duration, tailSilence: 0.66, analysis: analysis)
        let partner = song("Muse", tempo: 92, duration: 158, voice: 8...145, main: 8.37)
        let plan = KnobShiftPlan.make(from: current, to: partner)
        let lastWords = plan.voiceEnd ?? 0
        expect(near(lastWords, 190.5), "it leaves at its last line ending, not 2s from the end (\(KnobShiftPlan.clock(lastWords)))")
        expect(plan.start + plan.duration - lastWords >= 4, "the mix has room: \(f(plan.start + plan.duration - lastWords))s after the last words")
    }

    static func clearForTheNewVoice() {
        print("The new voice comes in clear")
        for (length, voiceDone) in [(8.0, 0.25), (5.0, 0.2), (1.7, 0.0), (3.0, 0.5)] {
            let arrives = KnobShiftModel.newVoiceArrives(voiceDone: voiceDone, length: length)
            var tailUnder = 0.0
            for step in 0...800 {
                let progress = Double(step) / 800
                let voice = KnobShiftModel.voiceLevels(progress: progress, voiceDone: voiceDone, length: length).new
                let tail = KnobShiftModel.tailLevel(progress: progress, newVoiceAt: arrives, length: length)
                if voice >= 0.5 { tailUnder = max(tailUnder, tail) }
                if progress < arrives - 0.6 / length { expect(tail >= 0.999, "\(length)s mix: the old tails ring until just before the new voice"); break }
            }
            expect(tailUnder <= 0.01, "\(length)s mix: no old echo, reverb or hall under the new voice (\(String(format: "%.2f", tailUnder)))")
        }
    }
}
