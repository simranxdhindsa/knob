import Foundation

/// `--knobshift-mix-check`: KnobMix's rules for a transition, checked against the real planner
/// and blend curves with made up songs, no audio and no files:
/// - a mix lasts about 8 seconds and never more than 10, however long the old song's outro is;
/// - the old voice finishes first: the new song's beats come in at most 2 seconds before it
///   ends, and the new song opens up only once it has ended;
/// - the new voice starts at most 2 seconds before the old song is gone;
/// - a song that sings to the end leaves within 2 seconds of its voice being cut.
@MainActor
enum KnobShiftMixTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func run() {
        longOutro()
        singsToTheEnd()
        voiceNearTheEnd()
        fastAndSlow()
        instrumental()
        mixNow()
        tempoClash()
        cutWithLockedBeats()
        glide()
        singsThroughItsFade()
        wideGap()
        throwVoices()
        voices()
        print(failures == 0 ? "KnobMix check passed" : "KnobMix check: \(failures) failure(s)")
    }

    // MARK: Songs

    private static func song(_ title: String, tempo: Double? = 96, duration: TimeInterval = 200, trailing: TimeInterval = 0,
                             voice: ClosedRange<TimeInterval>? = 12...150, lastLine: TimeInterval? = nil, main: TimeInterval? = nil,
                             fade: TimeInterval? = nil, breaks: [TimeInterval] = []) -> KnobShiftModel.Track {
        let beat = tempo.map { 60 / $0 } ?? 0.5
        let grid = stride(from: 0.0, to: duration, by: beat).map { $0 }
        var analysis = KnobShiftModel.Analysis(tempo: tempo, tempoConfidence: tempo == nil ? 0 : 0.9, beatGrid: tempo == nil ? [] : grid,
                                               leadingSilence: 0, trailingSilence: trailing, fadeOutCue: fade, safeOutroCue: nil,
                                               vocalOnset: voice?.lowerBound, vocalEnd: voice?.upperBound)
        analysis.lastLineStart = voice.map { lastLine ?? $0.upperBound - 8 }
        analysis.mainVocalOnset = main ?? voice?.lowerBound
        analysis.beatEntry = 0
        analysis.musicBreaks = breaks
        return KnobShiftModel.Track(url: URL(fileURLWithPath: "/tmp/\(title).m4a"), title: title, duration: duration,
                                    tailSilence: trailing, analysis: analysis)
    }

    private static let next = song("Next", duration: 220, voice: 16...200, main: 17)

    /// The rules every plan with an old voice must keep.
    private static func checkVoices(_ plan: KnobShiftPlan, voiceEnd: TimeInterval, next: KnobShiftModel.Track, _ name: String,
                                    from current: KnobShiftModel.Track? = nil) {
        let exit = plan.start + plan.duration
        expect(plan.duration <= KnobShiftPlan.longestMix + 0.01, "\(name): \(String(format: "%.1f", plan.duration))s, never more than 10")
        if let current {
            // The real length once the old song eases to the new tempo.
            let sync = KnobShiftSync.make(outgoing: current.analysis, incoming: next.analysis, beatsBeforeVoice: plan.beatsBeforeVoice)
            let pivot = plan.duration > 0 ? min(max((plan.handoff - plan.start) / plan.duration, 0), 1) : 0
            let heard = sync.blendLength(forOutgoingMusic: plan.duration, voice: pivot)
            expect(heard <= KnobShiftPlan.longestMix + 0.01, "\(name): \(String(format: "%.1f", heard))s heard with the tempo glide, never more than 10")
        }
        expect(plan.start >= voiceEnd - 2.01, "\(name): the new beats come in at most 2s before the old voice ends")
        expect(plan.handoff >= voiceEnd - 0.01, "\(name): the new song opens up only once the old voice has ended")
        if let verse = next.analysis.mainVocalOnset {
            let lands = plan.start + (verse - plan.incomingOffset)
            expect(lands >= exit - 2.01, "\(name): the new voice starts at most 2s before the old song is gone")
        }
    }

    /// A vocal throw: about 5s after the cut, the old music fading slowly when the beats lock
    /// and within about half a second when they cannot, the new voice only after the old one.
    private static func throwChecks(_ plan: KnobShiftPlan, cut: TimeInterval, _ name: String) {
        let tail = plan.start + plan.duration - cut
        expect(plan.voiceThrow, "\(name): a vocal throw")
        expect(tail <= KnobShiftPlan.throwLength + 0.01 && tail >= 4, "\(name): the old song slows and fades for \(String(format: "%.1f", tail))s")
        let gone = { (locked: Bool) in
            (stride(from: 0.0, through: 1, by: 0.005).first { KnobShiftModel.throwLevels(share: $0, locked: locked).music <= 0.001 } ?? 1) * tail
        }
        expect(gone(true) >= 3.5, "\(name): beats locked, the old music fades slowly (\(String(format: "%.1f", gone(true)))s)")
        expect(gone(false) <= 0.8, "\(name): beats apart, the old music is gone in \(String(format: "%.1f", gone(false)))s")
    }

    // MARK: Cases

    private static func longOutro() {
        print("A song with a long outro")
        let current = song("Outro", duration: 200, voice: 12...120, fade: 185)
        let plan = KnobShiftPlan.make(from: current, to: next)
        checkVoices(plan, voiceEnd: 120, next: next, "30s of outro")
        expect(plan.duration >= KnobShiftPlan.shortestMix - 0.01, "at least 6s, so the exit is heard")
        expect(plan.start + plan.duration <= 120 + 10, "the old song leaves soon after its voice, its long outro skipped")
    }

    private static func singsToTheEnd() {
        print("A song that sings to the end (Putt Jam Te Lau)")
        let current = song("Sings", tempo: 86, duration: 222, voice: 12...221.5, lastLine: 177.75, breaks: [180, 210.64])
        let plan = KnobShiftPlan.make(from: current, to: next)
        expect(abs(plan.handoff - 210.64) < 0.01, "the voice is cut at the last break")
        checkVoices(plan, voiceEnd: 210.64, next: next, "sings to the end")
        throwChecks(plan, cut: 210.64, "sings to the end")
    }

    private static func voiceNearTheEnd() {
        print("A voice ending close to the end")
        let current = song("Near", duration: 200, voice: 12...197)
        let plan = KnobShiftPlan.make(from: current, to: next)
        checkVoices(plan, voiceEnd: 197, next: next, "3s left after the voice")
        expect(plan.start + plan.duration <= 200.01, "it never runs past the end")
    }

    private static func fastAndSlow() {
        print("Fast and slow songs")
        for tempo in [70.0, 96, 128, 174] {
            let current = song("T\(Int(tempo))", tempo: tempo, duration: 200, voice: 12...150)
            // A partner at the same tempo, so the beats lock and the full mix is used.
            let next = song("N\(Int(tempo))", tempo: tempo, duration: 220, voice: 16...200, main: 17)
            let plan = KnobShiftPlan.make(from: current, to: next)
            checkVoices(plan, voiceEnd: 150, next: next, "\(Int(tempo)) BPM", from: current)
            expect(plan.duration >= KnobShiftPlan.shortestMix - 0.01, "\(Int(tempo)) BPM: at least 6s")
        }
        let unsure = song("Unsure", tempo: nil, duration: 200, voice: 12...150)
        checkVoices(KnobShiftPlan.make(from: unsure, to: next), voiceEnd: 150, next: next, "tempo unknown")
    }

    private static func instrumental() {
        print("An instrumental with a long fade")
        let current = song("Fade", duration: 200, voice: nil, fade: 160)
        let plan = KnobShiftPlan.make(from: current, to: next)
        expect(plan.duration <= KnobShiftPlan.longestMix + 0.01 && plan.duration >= KnobShiftPlan.shortestMix - 0.01,
               "its fade is mixed for 6 to 10s, not all 40s (\(String(format: "%.1f", plan.duration))s)")
    }

    private static func mixNow() {
        print("KnobMix Now")
        let current = song("Now", duration: 200, voice: 12...150, breaks: [80])
        let plan = KnobShiftPlan.make(from: current, to: next, handoffAt: 80)
        checkVoices(plan, voiceEnd: 80, next: next, "KnobMix Now")
        throwChecks(plan, cut: 80, "KnobMix Now")
    }

    private static func tempoClash() {
        print("Tempos too far apart to lock")
        let current = song("Slow", tempo: 90, duration: 200, voice: 12...150)
        let fast = song("Fast", tempo: 128, duration: 220, voice: 16...200, main: 17)
        let plan = KnobShiftPlan.make(from: current, to: fast)
        checkVoices(plan, voiceEnd: 150, next: fast, "90 into 128 BPM")
        expect(plan.start >= 150 - 0.01, "no new beats under the old song when they would clash")
        throwChecks(plan, cut: 150, "tempos apart")
    }

    private static func cutWithLockedBeats() {
        print("A song that sings to the end, beats locked")
        let current = song("Locked", tempo: 86, duration: 222, voice: 12...221.5, lastLine: 177.75, breaks: [180, 210.64])
        let partner = song("Partner", tempo: 86, duration: 220, voice: 16...200, main: 17)
        let plan = KnobShiftPlan.make(from: current, to: partner)
        checkVoices(plan, voiceEnd: 210.64, next: partner, "cut, beats locked", from: current)
        expect(plan.start < 210.64 - 0.5, "the new beats come in under the old voice's last words")
        throwChecks(plan, cut: 210.64, "cut, beats locked")
    }

    private static func glide() {
        print("The tempo glide never takes a mix past 10s")
        for (old, new) in [(70.0, 75.0), (96, 101), (128, 120), (100, 92.5)] {
            let current = song("G\(Int(old))", tempo: old, duration: 200, voice: 12...150)
            let partner = song("H\(Int(new))", tempo: new, duration: 220, voice: 16...200, main: 17)
            checkVoices(KnobShiftPlan.make(from: current, to: partner), voiceEnd: 150, next: partner, "\(Int(old)) into \(Int(new)) BPM", from: current)
        }
    }

    private static func singsThroughItsFade() {
        print("A song that sings through its fade, with no late break (Why So)")
        var current = song("Fades", tempo: 90, duration: 233.27, voice: 4.5...232.5, lastLine: 126.75, fade: 220.78, breaks: [23.1, 137.7, 231.7])
        let plan = KnobShiftPlan.make(from: current, to: next)
        expect(abs(plan.handoff - 220.78) < 0.01, "it is cut where it starts fading (\(KnobShiftPlan.clock(plan.handoff)))")
        expect(plan.start < 233.27 - 8, "the mix starts well before its last seconds (\(KnobShiftPlan.clock(plan.start)))")
        current = song("Lines", tempo: 90, duration: 233.27, voice: 4.5...232.5, lastLine: 126.75, fade: 220.78, breaks: [137.7])
        var analysis = current.analysis
        analysis.vocalLineEnds = [180.2, 214.4, 232.5]
        current = KnobShiftModel.Track(url: current.url, title: current.title, duration: current.duration, tailSilence: 0, analysis: analysis)
        expect(abs(KnobShiftPlan.make(from: current, to: next).handoff - 214.4) < 0.01, "a sung line ending is used before the fade")
    }

    private static func wideGap() {
        print("Tempos 16% apart still lock, as a vocal throw (Kaali Hoodie into Ghostface Killah)")
        let current = song("Kaali", tempo: 172, duration: 164.86, voice: 3...163.5, lastLine: 120, breaks: [139.93])
        let partner = song("Ghost", tempo: 100, duration: 137, voice: 9...118, main: 9.25)
        let plan = KnobShiftPlan.make(from: current, to: partner)
        let sync = KnobShiftSync.make(outgoing: current.analysis, incoming: partner.analysis, beatsBeforeVoice: plan.beatsBeforeVoice)
        expect(sync.isOn && sync.wide, "the beats lock, meeting in the middle")
        expect(plan.start < plan.handoff, "the new beats come in under the old voice's last words")
        throwChecks(plan, cut: 139.93, "16% apart")
    }

    private static func throwVoices() {
        print("The voices in a vocal throw")
        var together = false, tapeEnd = 0.0, reverbEnd = 0.0
        for step in 0...400 {
            let levels = KnobShiftModel.throwLevels(share: Double(step) / 400)
            if levels.voice > 0.01, levels.newVoice > 0.01 { together = true }
            tapeEnd = levels.tape
            reverbEnd = levels.reverb
        }
        expect(!together, "the old voice is gone before the new voice comes in")
        expect(tapeEnd >= 0.99 && reverbEnd >= 0.59, "the old voice slows fully into a hall")
    }

    private static func voices() {
        print("The voices in the blend")
        let length = 8.0, voiceDone = 0.25
        var newVoiceStart: Double?, oldVoiceGone: Double?
        for step in 0...800 {
            let progress = Double(step) / 800
            let levels = KnobShiftModel.voiceLevels(progress: progress, voiceDone: voiceDone, length: length)
            if newVoiceStart == nil, levels.new > 0.01 { newVoiceStart = progress }
            if oldVoiceGone == nil, progress >= voiceDone, levels.old <= 0.01 { oldVoiceGone = progress }
            if levels.new > 0.01, levels.old > 0.35 { expect(false, "two full voices at \(progress)"); break }
        }
        expect((oldVoiceGone ?? 1) * length - voiceDone * length <= 1.6, "the old voice fades into its hall within 1.5s of its end")
        expect((newVoiceStart ?? 0) >= 1 - 2 / length - 0.01, "the new voice comes in only in the last 2s")
        // A short echo out, and a crossfade that starts after the old voice (a seek or late start).
        for (length, voiceDone) in [(1.7, 0.0), (8.0, 0.0), (3.0, 0.5)] {
            var together = false, newRose = false
            for step in 0...400 {
                let levels = KnobShiftModel.voiceLevels(progress: Double(step) / 400, voiceDone: voiceDone, length: length)
                if levels.new > 0.01, levels.old > 0.35 { together = true }
                if levels.new > 0.99 { newRose = true }
            }
            expect(!together && newRose, "\(length)s mix, old voice done at \(Int(voiceDone * 100))%: only a quiet tail meets the new voice, and it arrives")
        }
    }
}
