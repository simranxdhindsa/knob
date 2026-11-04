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

    /// Real numbers from the songs' analyses: Why So has no hook, and Kaali Hoodie's drums and
    /// main verse land together at 0:33.53. The new song and its voice used to arrive within 1.4
    /// seconds of the start, with the old voice pressed down in about the same time.
    static func runUp() {
        print("A song with no usable hook still gets a long, gradual mix (Why So into Kaali Hoodie)")
        var whySo = song("Why So", tempo: 90, duration: 234.73, trailing: 1.46, voice: 4.5...232.5, lastLine: 126.75, main: 10.38,
                         fade: 220.78, breaks: [23, 73.7, 137.7, 231.7]).analysis
        whySo.vocalLineEnds = [200, 221.25]
        let current = KnobShiftModel.Track(url: URL(fileURLWithPath: "/tmp/Why So.m4a"), title: "Why So", duration: 234.73, tailSilence: 1.46, analysis: whySo)
        var kaali = song("Kaali Hoodie", tempo: 172, duration: 167.45, trailing: 2.59, voice: 3...163.5, lastLine: 129, main: 33.53,
                         breaks: [129.1, 139.93, 163.7], hook: 129.12)
        var hoodie = kaali.analysis
        hoodie.beatEntry = 33.53
        kaali = KnobShiftModel.Track(url: kaali.url, title: kaali.title, duration: kaali.duration, tailSilence: 2.59, analysis: hoodie)
        let plan = KnobShiftPlan.make(from: current, to: kaali)
        let newVoiceIn = plan.handoff + (plan.beatsBeforeVoice ?? 0) - plan.start
        expect(near(plan.voiceEnd ?? 0, 221.25) && near(plan.start, 221.25 - 5 * 240 / 90), "five bars before its last line ending, 13.3s (\(KnobShiftPlan.clock(plan.start)))")
        expect(newVoiceIn >= 5, "the old voice is pressed down over \(f(newVoiceIn))s before the new voice")
        expect(plan.beatsBeforeVoice.map { near($0, KnobShiftPlan.introLead) } == true, "the new song plays 3s ahead of its voice")
        expect(plan.duration >= 18, "\(f(plan.duration))s in all")
        checkSung(plan, from: current, to: kaali, "Why So into Kaali Hoodie", voiceEnd: 221.25)
        // A hook with room is still the start, whatever the run up would have been.
        let sardaari = song("Sardaari", tempo: 165, duration: 235.65, voice: 1.5...234, main: 17.58)
        expect(near(KnobShiftPlan.make(from: kaali, to: sardaari).start, 129.12), "Kaali Hoodie's hook, 10.8s before its last break, stays the start")
        // The run up follows the old song's bars and its own music breaks.
        expect(near(KnobShiftPlan.runUp(bar: 1.4), 14) && near(KnobShiftPlan.runUp(bar: 2.5), 15) && near(KnobShiftPlan.runUp(bar: 6), 12) && near(KnobShiftPlan.runUp(bar: 20), 18),
               "whole bars nearest to 14s, kept to 10 to 18s")
        let broken = song("Broken", duration: 200, voice: 12...150, breaks: [138])
        expect(near(KnobShiftPlan.make(from: broken, to: next).start, 138), "a music break 12s before the last words is the start")
        // Drums that land with the new voice rise out of the hall for twice as long.
        let model = KnobShiftModel(restoresQueue: false)
        model.blendHasStems = true
        let sync = KnobShiftSync.make(outgoing: current.analysis, incoming: kaali.analysis, beatsBeforeVoice: 3)
        let muffled = { (drums: Double) -> Float in
            model.applyHookMix(0.4, entry: 0.1, wordsEnd: 0.6, beatsIn: drums, length: 20, sync: sync, voiceAt: 0.25)
            return Float(model.secondaryDeck.sweep)
        }
        expect(muffled(0.25) > 0.05 && muffled(0.1) == 0, "3s after the voice the drums are still clearing, earlier drums have cleared")
    }
}
