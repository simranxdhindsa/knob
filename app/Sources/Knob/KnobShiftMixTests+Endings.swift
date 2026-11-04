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

    /// Why So's real repeat scores, every 2 seconds from 2:40: its chorus comes back at 3:20 with
    /// no music break, so only comparing every moment finds it.
    static func hookWithoutBreak() {
        print("A chorus that comes back with no music break (Why So, 35 seconds from the end)")
        let earlier = [0.73, 0.65, 0.57, 0.53, 0.52, 0.52, 0.56, 0.62, 0.67, 0.66, 0.66, 0.60, 0.54, 0.54, 0.48]
        let late = [0.69, 0.69, 0.61, 0.59, 0.61, 0.84, 0.74, 0.71, 0.90, 0.91, 0.90, 0.91, 0.81, 0.72, 0.63, 0.54, 0.55, 0.56]
        let found = KnobShiftHooks.lastRepeat(in: earlier + late, step: 2)
        expect(found == earlier.count + 5, "the last strong repeat starts at 3:20, the jump to 84%, 20 steps of 2s after 2:40")
        let everyHalf = (earlier + late).flatMap { [$0, $0, $0, $0] }
        let start = KnobShiftHooks.lastRepeat(in: everyHalf, step: 0.5).map { Double($0) * 0.5 }
        expect(start.map { near($0, Double(earlier.count + 5) * 2) } == true, "read every half second, the short dip at 3:22 does not split it (\(start ?? -1)s)")
        expect(KnobShiftHooks.lastRepeat(in: [0.5, 0.55, 0.58, 0.52], step: 0.5) == nil, "nothing repeats well enough: no hook")
        expect(KnobShiftHooks.lastRepeat(in: [0.2, 0.9, 0.2, 0.2, 0.2], step: 0.5) == nil, "one lucky match is not a hook")
        expect(KnobShiftHooks.lastRepeat(in: [0.2, 0.9, 0.9, 0.9, 0.9, 0.9, 0.2], step: 0.5) == 1, "a repeat that holds for 2s is one")
    }

    /// Reported: No Good read as an instrumental on the iPhone and played from 0:00, though its
    /// beat and main verse come in at 0:22.
    static func noVoiceRead() {
        print("A new song whose voice could not be read starts at its beat, not its top")
        var analysis = song("No Good", tempo: 172, duration: 199.54, voice: nil).analysis
        analysis.beatEntry = 22.02
        let noGood = KnobShiftModel.Track(url: URL(fileURLWithPath: "/tmp/No Good.m4a"), title: "No Good", duration: 199.54, tailSilence: 0, analysis: analysis)
        expect(KnobShiftPlan.firstSinging(analysis).map { near($0.at, 22.02) && $0.onGrid } == true, "its beat entry stands in for its first singing")
        let plan = KnobShiftPlan.make(from: song("Old", duration: 200, voice: 12...170, hook: 150), to: noGood)
        expect(near(plan.incomingOffset, 20.02), "it comes in 2s before its beat at 0:22, not from 0:00 (\(KnobShiftPlan.clock(plan.incomingOffset)))")
        var soon = analysis
        soon.beatEntry = 4
        expect(KnobShiftPlan.firstSinging(soon) == nil, "a beat 4s in is no long intro: it plays from its top")
        var late = analysis
        late.beatEntry = 45
        expect(KnobShiftPlan.firstSinging(late) == nil, "a beat after 40s is not trusted")
    }

    /// Real numbers from the songs' analyses: Why So has no hook, and Kaali Hoodie's drums and
    /// main verse land together at 0:33.53. The new song and its voice used to arrive within 1.4
    /// seconds of the start, with the old voice pressed down in about the same time.
    static func runUp() {
        print("A song with no usable hook still gets a gradual mix of about 10 to 14 seconds (Why So into Kaali Hoodie)")
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
        expect(near(plan.voiceEnd ?? 0, 221.25) && near(plan.start, 221.25 - 4 * 240 / 90), "four bars before its last line ending, 10.7s (\(KnobShiftPlan.clock(plan.start)))")
        expect(newVoiceIn >= 5, "the old voice is pressed down over \(f(newVoiceIn))s before the new voice")
        expect(plan.beatsBeforeVoice.map { near($0, KnobShiftPlan.introLead) } == true, "the new song plays 2s ahead of its voice")
        expect(plan.duration >= 13, "\(f(plan.duration))s in all")
        checkSung(plan, from: current, to: kaali, "Why So into Kaali Hoodie", voiceEnd: 221.25)
        // A hook with room is still the start, whatever the run up would have been.
        let sardaari = song("Sardaari", tempo: 165, duration: 235.65, voice: 1.5...234, main: 17.58)
        expect(near(KnobShiftPlan.make(from: kaali, to: sardaari).start, 129.12), "Kaali Hoodie's hook, 10.8s before its last break, stays the start")
        // The run up follows the old song's bars and its own music breaks.
        expect(near(KnobShiftPlan.runUp(bar: 1.4), 9.8) && near(KnobShiftPlan.runUp(bar: 2.5), 10) && near(KnobShiftPlan.runUp(bar: 6), 12) && near(KnobShiftPlan.runUp(bar: 20), 12),
               "whole bars nearest to 10s, kept to 8 to 12s")
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
        hookWithoutBreak()
        noVoiceRead()
    }
}
