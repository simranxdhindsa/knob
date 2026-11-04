import Foundation

/// `--knobshift-mix-check`: KnobMix's rules for a sung transition, checked against the real
/// planner and the real mix curves with made up songs, no audio and no files:
/// - the mix starts where the old song's last hook starts (KnobMix Now: where the listener asked;
///   no usable hook: over the old voice's last words), never more than 12 seconds before those
///   last words, and never runs past the end of what is heard;
/// - the old voice's last words end at `voiceEnd` (at least 4 seconds into the mix), the new voice
///   lands half a second before that, on the old voice's last words (measured and kept between a
///   quarter of a second and a second when the mix starts), and the new song comes in
///   about 2 seconds ahead of its voice (less when its own intro is shorter);
/// - the mix ends 4 seconds after the old voice's last words, but lasts at least 6 seconds
///   when the song leaves room;
/// - only the old voice is pressed (compressed and muffled into a hall, speed and pitch kept) while
///   its beats keep playing; it holds through its last words, over the new voice, and is gone
///   1.5 seconds after them; the new voice is never touched and never muted; the old beats fade after the last
///   words (locked, under the new song) or before the new drums (apart); nothing jumps;
/// - songs without vocals mix over their fade, and songs with neither meet cleanly.
@MainActor
enum KnobShiftMixTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ what: String) {
        print("  \(condition ? "ok  " : "FAIL") \(what)")
        if !condition { failures += 1 }
    }

    static func run() {
        constants()
        hookStart()
        noUsableHook()
        singsToTheEnd()
        singsThroughItsFade()
        mixNow()
        mixLength()
        entryPoint()
        tempoClash()
        wideGap()
        glide()
        newSongsFirstVoice()
        middleEntry()
        shortIntro()
        instrumental()
        cleanHandoff()
        hookMixCurves()
        hookMixWithoutStems()
        voices()
        print(failures == 0 ? "KnobMix check passed" : "KnobMix check: \(failures) failure(s)")
    }

    // MARK: Songs

    private static func song(_ title: String, tempo: Double? = 96, duration: TimeInterval = 200, trailing: TimeInterval = 0,
                             voice: ClosedRange<TimeInterval>? = 12...150, lastLine: TimeInterval? = nil, main: TimeInterval? = nil,
                             fade: TimeInterval? = nil, breaks: [TimeInterval] = [], hook: TimeInterval? = nil,
                             lead: TimeInterval = 0) -> KnobShiftModel.Track {
        let beat = tempo.map { 60 / $0 } ?? 0.5
        let grid = stride(from: 0.0, to: duration, by: beat).map { $0 }
        var analysis = KnobShiftModel.Analysis(tempo: tempo, tempoConfidence: tempo == nil ? 0 : 0.9, beatGrid: tempo == nil ? [] : grid,
                                               leadingSilence: lead, trailingSilence: trailing, fadeOutCue: fade, safeOutroCue: nil,
                                               vocalOnset: voice?.lowerBound, vocalEnd: voice?.upperBound)
        analysis.lastLineStart = voice.map { lastLine ?? $0.upperBound - 8 }
        analysis.mainVocalOnset = main ?? voice?.lowerBound
        analysis.beatEntry = 0
        analysis.musicBreaks = breaks
        analysis.lastHookStart = hook
        return KnobShiftModel.Track(url: URL(fileURLWithPath: "/tmp/\(title).m4a"), title: title, duration: duration,
                                    tailSilence: trailing, analysis: analysis)
    }

    private static let next = song("Next", duration: 220, voice: 16...200, main: 17)

    private static func bar(_ track: KnobShiftModel.Track) -> TimeInterval {
        track.analysis.tempo.map { 4 * 60 / $0 } ?? 2.5
    }

    private static func target(_ track: KnobShiftModel.Track) -> TimeInterval {
        KnobShiftPlan.length(bar: bar(track))
    }

    private static func audibleEnd(_ track: KnobShiftModel.Track) -> TimeInterval {
        track.analysis.audibleEnd(duration: track.duration)
    }

    /// Where a sung mix starts, by the rules: the hook when it is usable (before the voice ends,
    /// at least 6 seconds from the end), else (or at KnobMix Now) where asked, else over the old
    /// voice's last words; and never more than 12 seconds before those last words.
    private static func expectedStart(_ track: KnobShiftModel.Track, voiceEnd: TimeInterval, handoffAt: TimeInterval? = nil) -> TimeInterval {
        let length = target(track)
        let end = audibleEnd(track)
        var start: TimeInterval
        if let handoffAt {
            start = handoffAt
        } else if let hook = track.analysis.lastHookStart, hook < voiceEnd, end - hook >= KnobShiftPlan.shortestMix {
            start = hook
        } else {
            start = max(0, min(voiceEnd - 0.6 * length, end - length))
        }
        return max(start, voiceEnd - KnobShiftPlan.longestPress)
    }

    private static func near(_ a: TimeInterval, _ b: TimeInterval, _ tolerance: Double = 0.01) -> Bool {
        abs(a - b) <= tolerance
    }

    private static func f(_ value: Double) -> String { String(format: "%.1f", value) }

    /// The rules every plan with an old voice must keep, whatever the songs are. `voiceEnd` is
    /// where the old voice ends (as the planner sees it), when the case knows it.
    private static func checkSung(_ plan: KnobShiftPlan, from current: KnobShiftModel.Track, to next: KnobShiftModel.Track,
                                  _ name: String, voiceEnd: TimeInterval? = nil) {
        let end = audibleEnd(current)
        let exit = plan.start + plan.duration
        let lastWords = plan.voiceEnd ?? -1
        let handover = KnobShiftPlan.handover
        expect(plan.voiceThrow, "\(name): the old voice is pressed down")
        expect(plan.start >= 0 && exit <= end + 0.01, "\(name): the mix (\(KnobShiftPlan.clock(plan.start)) to \(KnobShiftPlan.clock(exit))) never runs past the end heard (\(KnobShiftPlan.clock(end)))")
        let room = end - plan.start
        expect(plan.duration >= min(room, KnobShiftPlan.shortestMix) - 0.01
               && plan.duration <= min(room, KnobShiftPlan.longestPress + KnobShiftPlan.longestTail) + 0.01,
               "\(name): \(f(plan.duration))s, at least 6 (or what is left) and at most 38")
        if let voiceEnd {
            expect(near(lastWords, min(max(voiceEnd, plan.start + KnobShiftPlan.shortestWords), end)),
                   "\(name): the old voice's last words end at \(KnobShiftPlan.clock(lastWords)), at least \(Int(KnobShiftPlan.shortestWords))s into the mix")
            expect(plan.start >= voiceEnd - KnobShiftPlan.longestPress - 0.01, "\(name): the voice is pressed at most 30s before its last words")
        }
        let tail = KnobShiftPlan.tail(bar: bar(current))
        expect(near(exit, min(end, max(lastWords + tail, plan.start + KnobShiftPlan.shortestMix))),
               "\(name): the mix ends \(f(tail))s after the last words (or after 6s, or at the end of the song)")

        // The new song comes in ahead of its voice, which lands half way to the old voice's last
        // words, never more than four bars (5 to 8 seconds) ahead of them and never after them.
        let together = min(max(4 * bar(current), 5), 8)
        let newVoiceAt = min(max((plan.start + lastWords) / 2, lastWords - together), lastWords - handover)
        let firstVoice = KnobShiftPlan.firstSinging(next.analysis)?.at
        let leadIn = min(next.analysis.leadingSilence, next.duration)
        let introLead = firstVoice.map { min(KnobShiftPlan.introLead, max(0, $0 - leadIn)) } ?? KnobShiftPlan.introLead
        expect(near(plan.handoff, max(plan.start + 0.5, newVoiceAt - introLead)),
               "\(name): the new song comes in \(f(plan.handoff - plan.start))s into the mix, \(f(introLead))s ahead of its voice")
        expect(plan.handoff > plan.start && plan.handoff < exit, "\(name): the new song comes in during the mix")

        let sync = KnobShiftSync.make(outgoing: current.analysis, incoming: next.analysis,
                                      beatsBeforeVoice: firstVoice == nil ? nil : newVoiceAt - plan.handoff)
        if sync.isOn, !sync.wide {
            let heard = plan.duration / max(sync.meetingTempo / sync.outgoingTempo, 0.1)
            let most = (KnobShiftPlan.longestPress + KnobShiftPlan.longestTail) / (1 - KnobShiftSync.outgoingStretch)
            expect(heard <= most + 0.01, "\(name): \(f(heard))s heard at the meeting tempo, never more than \(f(most))")
        }

        expect(plan.incomingOffset >= leadIn - 0.001, "\(name): the new song never starts inside its leading silence")
        guard let firstVoice else {
            expect(near(plan.incomingOffset, leadIn) && plan.beatsBeforeVoice == nil, "\(name): no vocals in the new song, it comes in after its leading silence")
            return
        }
        expect(near(plan.incomingOffset, max(leadIn, firstVoice - (newVoiceAt - plan.handoff))), "\(name): the new song starts at \(KnobShiftPlan.clock(plan.incomingOffset)) in its file")
        let heard = firstVoice - plan.incomingOffset
        expect(plan.beatsBeforeVoice.map { near($0, max(0, heard)) } ?? false, "\(name): \(f(heard))s of the new song before its voice")
        if firstVoice >= leadIn {
            let lands = plan.handoff + heard
            expect(near(lands, newVoiceAt), "\(name): the new voice lands at \(KnobShiftPlan.clock(lands)), \(f(lastWords - lands))s before the old voice's last words end")
            expect(lastWords - lands >= handover - 0.01 && lastWords - lands <= together + 0.01, "\(name): the voices sing together for 0.5 to \(f(together))s, never a gap")
            expect(lands > plan.start && lands < exit, "\(name): and inside the mix, over the old voice's last words")
        }
    }

    // MARK: Cases

    private static func constants() {
        print("The numbers the rules are built on")
        expect(KnobShiftPlan.targetMix == 8 && KnobShiftPlan.shortestMix == 6 && KnobShiftPlan.longestMix == 16, "a mix aims at 8s, between 6 and 16")
        expect(KnobShiftPlan.handover == 0.5 && KnobShiftPlan.leastOverlap == 0.25 && KnobShiftPlan.mostTogether(bar: 1) == 5 && KnobShiftPlan.mostTogether(bar: 1.8) == 7.2 && KnobShiftPlan.mostTogether(bar: 3) == 8 && KnobShiftPlan.shortestWords == 4 && KnobShiftPlan.introLead == 3 && KnobShiftPlan.introSpeed == 0.92 && KnobShiftPlan.washEnds == 2.5 && KnobShiftPlan.voiceRing == 3
               && KnobShiftPlan.longestPress == 30,
               "the voices overlap by at least 0.25s and at most four bars (5 to 8s), the old voice gets at least 4s, up to 3s of intro, the old voice rings 3s, at most 30s of pressing")
        expect(KnobShiftPlan.tail(bar: 2.5) == 7.5 && KnobShiftPlan.tail(bar: 1.4) == 6 && KnobShiftPlan.tail(bar: 4) == 8,
               "three bars of the old song after its last words, 6 to 8s")
    }

    private static func hookStart() {
        print("The mix starts at the old song's last hook")
        let current = song("Hook", duration: 200, voice: 12...170, hook: 160)
        let plan = KnobShiftPlan.make(from: current, to: next)
        expect(near(plan.start, 160), "it starts at the hook, 2:40 (\(KnobShiftPlan.clock(plan.start)))")
        expect(near(plan.voiceEnd ?? 0, 170) && near(plan.handoff, 162) && near(plan.duration, 17.5),
               "last words 2:50, the new song at 2:42, its voice half way to them, 17.5s in all (\(f(plan.duration))s)")
        expect(near(plan.incomingOffset, 13) && plan.beatsBeforeVoice.map { near($0, 3) } == true, "the new song starts at 0:13, 3s before its voice")
        checkSung(plan, from: current, to: next, "hook at 2:40", voiceEnd: 170)
        // A hook 30s ahead of the last words is still the start.
        let early = song("Early", duration: 200, voice: 12...170, hook: 140)
        let earlyPlan = KnobShiftPlan.make(from: early, to: next)
        expect(near(earlyPlan.start, 140) && near(earlyPlan.duration, 37.5), "a hook at 2:20, 30s before the last words, is the start (\(KnobShiftPlan.clock(earlyPlan.start)))")
        checkSung(earlyPlan, from: early, to: next, "hook 30s before the voice ends", voiceEnd: 170)
        // A hook found further back than that is pulled up: the voice is pressed for at most 30s.
        let far = song("Far", duration: 200, voice: 12...170, hook: 120)
        let farPlan = KnobShiftPlan.make(from: far, to: next)
        expect(near(farPlan.start, 140), "a hook at 2:00 is 50s early, so the mix starts 30s before the last words, 2:20 (\(KnobShiftPlan.clock(farPlan.start)))")
        checkSung(farPlan, from: far, to: next, "hook 50s before the voice ends", voiceEnd: 170)
        // The hook wins over a long outro, which is skipped.
        let outro = song("Outro", duration: 200, voice: 12...120, fade: 185, hook: 110)
        let outroPlan = KnobShiftPlan.make(from: outro, to: next)
        expect(near(outroPlan.start, 110), "a long outro changes nothing, it starts at the hook (\(KnobShiftPlan.clock(outroPlan.start)))")
        expect(outroPlan.start + outroPlan.duration <= 120 + KnobShiftPlan.longestTail + 0.01, "the long outro is skipped")
        checkSung(outroPlan, from: outro, to: next, "30s of outro", voiceEnd: 120)
        // A hook with 8 seconds left still has room for the whole tail.
        let late = song("Late", duration: 200, voice: 12...197, hook: 192)
        let latePlan = KnobShiftPlan.make(from: late, to: next)
        expect(near(latePlan.start, 192) && near(latePlan.duration, 8), "8s left after the hook: it runs to the end, 8s (\(f(latePlan.duration))s)")
        checkSung(latePlan, from: late, to: next, "hook 8s from the end", voiceEnd: 197)
        // Exactly 6 seconds left is still enough, and the mix takes all of it.
        let last = song("Last", duration: 200, voice: 12...197, hook: 194)
        let lastPlan = KnobShiftPlan.make(from: last, to: next)
        expect(near(lastPlan.start, 194) && near(lastPlan.duration, 6), "6s left after the hook: it starts there for exactly 6s (\(f(lastPlan.duration))s)")
        checkSung(lastPlan, from: last, to: next, "hook 6s from the end", voiceEnd: 197)
        // Silence at the end counts: the hook is judged against what is heard.
        let quiet = song("Quiet", duration: 200, trailing: 10, voice: 12...185, hook: 175)
        let quietPlan = KnobShiftPlan.make(from: quiet, to: next)
        expect(near(quietPlan.start, 175) && quietPlan.start + quietPlan.duration <= 190.01, "trailing silence is never mixed (\(KnobShiftPlan.clock(quietPlan.start + quietPlan.duration)))")
        checkSung(quietPlan, from: quiet, to: next, "10s of trailing silence", voiceEnd: 185)
    }

    private static func noUsableHook() {
        print("No usable hook: the mix starts over the old voice's last words")
        let voiceEnd = 150.0
        let none = song("NoHook", duration: 200, voice: 12...voiceEnd)
        let plan = KnobShiftPlan.make(from: none, to: next)
        expect(near(plan.start, expectedStart(none, voiceEnd: voiceEnd)) && near(plan.start, 145.5), "no hook found: 0.6 of a mix before the voice ends (\(KnobShiftPlan.clock(plan.start)))")
        expect(plan.start < voiceEnd && plan.start + plan.duration > voiceEnd - 0.01, "the voice's last words are inside the mix")
        checkSung(plan, from: none, to: next, "no hook", voiceEnd: voiceEnd)
        // A hook that begins after the voice has ended is not a hook to press the voice on.
        let after = song("After", duration: 200, voice: 12...voiceEnd, hook: 160)
        expect(near(KnobShiftPlan.make(from: after, to: next).start, expectedStart(none, voiceEnd: voiceEnd)), "a hook after the voice ends is ignored")
        expect(near(KnobShiftPlan.make(from: song("Same", duration: 200, voice: 12...voiceEnd, hook: voiceEnd), to: next).start,
                    expectedStart(none, voiceEnd: voiceEnd)), "a hook exactly where the voice ends is ignored")
        // A hook with under 6 seconds of song left would give a short, rushed mix.
        let tight = song("Tight", duration: 200, voice: 12...197, hook: 195)
        let tightPlan = KnobShiftPlan.make(from: tight, to: next)
        expect(near(tightPlan.start, expectedStart(tight, voiceEnd: 197)) && tightPlan.start < 195, "a hook 5s from the end is ignored, the mix starts earlier (\(KnobShiftPlan.clock(tightPlan.start)))")
        checkSung(tightPlan, from: tight, to: next, "hook too close to the end", voiceEnd: 197)
        // A voice right at the end of the song: the mix is pulled back to fit.
        let close = song("Close", duration: 200, voice: 12...197)
        let closePlan = KnobShiftPlan.make(from: close, to: next)
        expect(near(closePlan.start, expectedStart(close, voiceEnd: 197)) && closePlan.start + closePlan.duration <= 200.01, "a voice 3s from the end: the mix still fits (\(KnobShiftPlan.clock(closePlan.start)))")
        checkSung(closePlan, from: close, to: next, "voice 3s from the end", voiceEnd: 197)
        // Unknown tempo: bars are taken as 2.5s.
        let unsure = song("Unsure", tempo: nil, duration: 200, voice: 12...150)
        let unsurePlan = KnobShiftPlan.make(from: unsure, to: next)
        expect(near(unsurePlan.start, expectedStart(unsure, voiceEnd: 150)), "tempo unknown: the same rule")
        checkSung(unsurePlan, from: unsure, to: next, "tempo unknown", voiceEnd: 150)
    }

    private static func singsToTheEnd() {
        print("A song that sings to the end (Putt Jam Te Lau)")
        let current = song("Sings", tempo: 86, duration: 222, voice: 12...221.5, lastLine: 177.75, breaks: [180, 210.64])
        let plan = KnobShiftPlan.make(from: current, to: next)
        // Its voice is taken as ending at its last break, and the mix starts over its last words.
        expect(near(plan.start, expectedStart(current, voiceEnd: 210.64)), "no hook: the mix starts before the last break, 3:25 (\(KnobShiftPlan.clock(plan.start)))")
        expect(plan.start < 210.64 && plan.start + plan.duration > 210.64, "the last break is inside the mix")
        checkSung(plan, from: current, to: next, "sings to the end", voiceEnd: 210.64)
        // With a hook, the hook is the start, as for any song (but at most 30s before the last words).
        let hooked = song("Hooked", tempo: 86, duration: 222, voice: 12...221.5, lastLine: 177.75, breaks: [180, 210.64], hook: 190)
        let hookedPlan = KnobShiftPlan.make(from: hooked, to: next)
        expect(near(hookedPlan.start, 190), "its last hook, 3:10, is the start (\(KnobShiftPlan.clock(hookedPlan.start)))")
        checkSung(hookedPlan, from: hooked, to: next, "sings to the end, hook", voiceEnd: 210.64)
        let nearHook = song("NearHook", tempo: 86, duration: 222, voice: 12...221.5, lastLine: 177.75, breaks: [180, 210.64], hook: 202)
        expect(near(KnobShiftPlan.make(from: nearHook, to: next).start, 202), "a hook 8s before the break is the start")
        // A hook after the cut point is after the voice has ended: it is not used.
        let late = song("LateHook", tempo: 86, duration: 222, voice: 12...221.5, lastLine: 177.75, breaks: [180, 210.64], hook: 215)
        expect(near(KnobShiftPlan.make(from: late, to: next).start, expectedStart(late, voiceEnd: 210.64)), "a hook after the cut point is ignored")
        // With locked beats the rules are the same.
        let partner = song("Partner", tempo: 86, duration: 220, voice: 16...200, main: 17)
        let locked = KnobShiftPlan.make(from: current, to: partner)
        expect(KnobShiftSync.make(outgoing: current.analysis, incoming: partner.analysis, beatsBeforeVoice: 7).isOn, "the beats lock")
        checkSung(locked, from: current, to: partner, "sings to the end, beats locked", voiceEnd: 210.64)
    }

    private static func singsThroughItsFade() {
        print("A song that sings through its fade, with no late break (Why So)")
        let fades = song("Fades", tempo: 90, duration: 233.27, voice: 4.5...232.5, lastLine: 126.75, fade: 220.78, breaks: [23.1, 137.7, 231.7])
        let plan = KnobShiftPlan.make(from: fades, to: next)
        expect(near(plan.start, expectedStart(fades, voiceEnd: 220.78)), "its voice ends where it starts fading, so the mix starts before that (\(KnobShiftPlan.clock(plan.start)))")
        expect(plan.start < 220.78 && plan.start + plan.duration > 220.78, "the fade start is inside the mix")
        checkSung(plan, from: fades, to: next, "sings through its fade", voiceEnd: 220.78)
        var analysis = fades.analysis
        analysis.vocalLineEnds = [180.2, 214.4, 232.5]
        analysis.musicBreaks = [137.7]
        let lines = KnobShiftModel.Track(url: fades.url, title: "Lines", duration: fades.duration, tailSilence: 0, analysis: analysis)
        let linesPlan = KnobShiftPlan.make(from: lines, to: next)
        expect(near(linesPlan.start, expectedStart(lines, voiceEnd: 214.4)), "a sung line ending is used before the fade (\(KnobShiftPlan.clock(linesPlan.start)))")
        checkSung(linesPlan, from: lines, to: next, "sings through its fade, line ending", voiceEnd: 214.4)
    }

    private static func mixNow() {
        print("KnobMix Now")
        let hooked = song("Now", duration: 200, voice: 12...150, breaks: [80], hook: 140)
        let plan = KnobShiftPlan.make(from: hooked, to: next, handoffAt: 80)
        expect(near(plan.start, 80), "it starts where asked, 1:20, not at the hook (\(KnobShiftPlan.clock(plan.start)))")
        expect(near(plan.voiceEnd ?? 0, 84) && near(plan.handoff, 80.5) && near(plan.duration, 11.5),
               "the old voice is given 4s to finish, the new song comes in half a second in, 11.5s in all (\(f(plan.duration))s)")
        checkSung(plan, from: hooked, to: next, "KnobMix Now", voiceEnd: 80)
        let plain = song("NowPlain", duration: 200, voice: 12...150)
        expect(near(KnobShiftPlan.make(from: plain, to: next, handoffAt: 33.5).start, 33.5), "a song with no hook starts there too")
        // Near the end the mix is cut to what is left.
        let late = KnobShiftPlan.make(from: plain, to: next, handoffAt: 195)
        expect(near(late.start, 195) && near(late.duration, 5), "5s from the end: a 5s mix, never past the end (\(f(late.duration))s)")
        checkSung(late, from: plain, to: next, "KnobMix Now near the end", voiceEnd: 195)
        // Nothing left to blend: the songs meet cleanly.
        let over = KnobShiftPlan.make(from: plain, to: next, handoffAt: 205)
        expect(over.duration == 0 && near(over.start, 200) && !over.voiceThrow, "asked past the end: a clean handoff at the end")
        // An instrumental can still be mixed on request.
        let instrumental = song("Beat", duration: 200, voice: nil)
        let asked = KnobShiftPlan.make(from: instrumental, to: next, handoffAt: 60)
        expect(near(asked.start, 60) && asked.voiceThrow, "an instrumental starts there as well")
    }

    private static func mixLength() {
        print("How long the voice is pressed and how long the mix lasts")
        for tempo in [70.0, 86, 96, 128, 174] {
            let current = song("T\(Int(tempo))", tempo: tempo, duration: 200, voice: 12...150, hook: 120)
            // A partner at the same tempo, so the beats lock.
            let partner = song("N\(Int(tempo))", tempo: tempo, duration: 220, voice: 16...200, main: 17)
            let plan = KnobShiftPlan.make(from: current, to: partner)
            let tail = KnobShiftPlan.tail(bar: 240 / tempo)
            expect(near(plan.start, 120) && near(plan.duration, 30 + tail), "\(Int(tempo)) BPM: the hook is 30s before the last words, so 30s of pressing and a \(f(tail))s tail make \(f(plan.duration))s")
            checkSung(plan, from: current, to: partner, "\(Int(tempo)) BPM", voiceEnd: 150)
        }
        // A hook 5s before the last words: the whole stretch, then the tail.
        let five = song("Five", duration: 200, voice: 12...150, hook: 145)
        let fivePlan = KnobShiftPlan.make(from: five, to: next)
        expect(near(fivePlan.start, 145) && near(fivePlan.duration, 12.5), "a hook 5s before the last words: a 12.5s mix (\(f(fivePlan.duration))s)")
        checkSung(fivePlan, from: five, to: next, "hook 5s before the last words", voiceEnd: 150)
        // A hook 2s before the last words: the old voice is still given 4s, the mix lasts 8s.
        let two = song("Two", duration: 200, voice: 12...150, hook: 148)
        let twoPlan = KnobShiftPlan.make(from: two, to: next)
        expect(near(twoPlan.start, 148) && near(twoPlan.voiceEnd ?? 0, 152) && near(twoPlan.duration, 11.5),
               "a hook 2s before the last words: the voice is given until 2:32, an 11.5s mix (\(f(twoPlan.duration))s)")
        checkSung(twoPlan, from: two, to: next, "hook 2s before the last words", voiceEnd: 150)
        // The bar based length is still what a fade mix and a missing hook are measured in.
        for bar in [1.5, 2.0, 2.5, 3.0, 4.0, 6.0, 20.0] {
            let length = KnobShiftPlan.length(bar: bar)
            expect(length >= 6 && length <= KnobShiftPlan.longestMusic + 0.001, "bars of \(bar)s: a \(f(length))s length")
        }
    }

    private static func entryPoint() {
        print("Where the new song comes in")
        let current = song("Old", tempo: 96, duration: 200, voice: 12...170, hook: 150)
        let same = song("Same", tempo: 96, duration: 220, voice: 16...200, main: 17)
        let plan = KnobShiftPlan.make(from: current, to: same)
        expect(near(plan.start, 150) && near(plan.handoff, 159), "beats lock: it comes in 3s before its voice, which lands 8s before the last words (\(KnobShiftPlan.clock(plan.handoff)) of a mix from \(KnobShiftPlan.clock(plan.start)))")
        let unsure = song("Unsure", tempo: nil, duration: 220, voice: 16...200, main: 17)
        let apart = KnobShiftPlan.make(from: current, to: unsure)
        expect(near(apart.handoff, plan.handoff) && near(apart.start, plan.start) && near(apart.duration, plan.duration), "the new tempo is unknown, so no lock: the same plan")
        let shaky = KnobShiftModel.Track(url: same.url, title: "Shaky", duration: 220, tailSilence: 0, analysis: {
            var analysis = same.analysis
            analysis = KnobShiftModel.Analysis(tempo: 96, tempoConfidence: 0.3, beatGrid: analysis.beatGrid, leadingSilence: 0, trailingSilence: 0,
                                               fadeOutCue: nil, safeOutroCue: nil, vocalOnset: 16, vocalEnd: 200, mainVocalOnset: 17)
            return analysis
        }())
        let unlocked = KnobShiftPlan.make(from: current, to: shaky)
        expect(near(unlocked.handoff, plan.handoff), "beats not trusted, so no lock: the same plan")
        checkSung(plan, from: current, to: same, "same tempo", voiceEnd: 170)
        checkSung(apart, from: current, to: unsure, "new tempo unknown", voiceEnd: 170)
        checkSung(unlocked, from: current, to: shaky, "beats not trusted", voiceEnd: 170)
    }

    private static func middleEntry() {
        print("The new voice comes in half way to the old voice's last words (Khuda into Muse On, No Luck into Jee Karuga)")
        // Reported: Khuda ended with all its effects and only then Muse On started.
        let khuda = song("Khuda", tempo: 133, duration: 203.7, trailing: 0.66, voice: 13.5...201, hook: 183.88)
        let museOn = song("Muse On", tempo: 92, duration: 155, voice: 5.25...144.75, main: 8.37)
        let plan = KnobShiftPlan.make(from: khuda, to: museOn)
        let lands = plan.handoff + (plan.beatsBeforeVoice ?? 0) - plan.start
        expect(near(plan.start, 183.88), "it starts at the hook, 3:03.88")
        expect(lands / plan.duration >= 0.4 && lands / plan.duration <= 0.6, "Muse On's voice arrives \(Int(lands / plan.duration * 100))% of the way through, not at the end")
        expect((plan.voiceEnd ?? 0) - plan.start - lands <= 240 / 133 * 4 + 0.01, "the voices sing together for at most four bars of Khuda")
        checkSung(plan, from: khuda, to: museOn, "Khuda into Muse On", voiceEnd: 201)
        // Reported: No Luck's hook is 3.2s before its last words, and Jee Karuga's voice came in
        // 0.5s before they ended, so nothing overlapped. Half way is 1.6s into the mix.
        expect(near(KnobShiftPlan.newVoiceEntry(wordsEnd: 3.17, bar: 1.66), 1.585), "No Luck: the new voice comes in 1.6s into the mix, half way to the last words")
        // Very little room: the voice still lands at least half a second before the last words.
        expect(near(KnobShiftPlan.newVoiceEntry(wordsEnd: 0.8, bar: 2), 0.3), "under a second to the last words: it lands half a second before them, so no gap")
        // A long mix keeps the voices from singing together for too long.
        let long = song("Long", duration: 200, voice: 12...170, hook: 140)
        let longPlan = KnobShiftPlan.make(from: long, to: next)
        let longLands = longPlan.handoff + (longPlan.beatsBeforeVoice ?? 0)
        expect(near(longLands, 162), "a 37.5s mix: the voice lands 8s before the last words, not at the middle (\(KnobShiftPlan.clock(longLands)))")
    }

    private static func tempoClash() {
        print("Tempos too far apart to lock")
        let current = song("Slow", tempo: 90, duration: 200, voice: 12...150, hook: 140)
        let fast = song("Fast", tempo: 128, duration: 220, voice: 16...200, main: 17)
        let plan = KnobShiftPlan.make(from: current, to: fast)
        expect(!KnobShiftSync.make(outgoing: current.analysis, incoming: fast.analysis, beatsBeforeVoice: 6).isOn, "90 into 128 BPM does not lock")
        expect(near(plan.start, 140) && near(plan.handoff, 142), "it still starts at the hook and the new song comes in at 2:22")
        checkSung(plan, from: current, to: fast, "90 into 128 BPM", voiceEnd: 150)
    }

    private static func wideGap() {
        print("Tempos 16% apart still lock, meeting in the middle (Kaali Hoodie into Ghostface Killah)")
        let current = song("Kaali", tempo: 172, duration: 164.86, voice: 3...163.5, lastLine: 120, breaks: [139.93], hook: 118)
        let partner = song("Ghost", tempo: 100, duration: 137, voice: 9...118, main: 9.25)
        let plan = KnobShiftPlan.make(from: current, to: partner)
        let sync = KnobShiftSync.make(outgoing: current.analysis, incoming: partner.analysis, beatsBeforeVoice: plan.beatsBeforeVoice)
        expect(sync.isOn && sync.wide, "the beats lock, meeting in the middle")
        expect(near(plan.start, 118), "the hook (1:58) is the start, 22s before the last break (\(KnobShiftPlan.clock(plan.start)))")
        checkSung(plan, from: current, to: partner, "16% apart", voiceEnd: 139.93)
    }

    private static func glide() {
        print("Close tempos: the old song plays at the meeting tempo throughout the mix")
        for (old, new) in [(70.0, 75.0), (96, 101), (128, 120), (100, 92.5)] {
            let current = song("G\(Int(old))", tempo: old, duration: 200, voice: 12...150, hook: 130)
            let partner = song("H\(Int(new))", tempo: new, duration: 220, voice: 16...200, main: 17)
            let plan = KnobShiftPlan.make(from: current, to: partner)
            expect(KnobShiftSync.make(outgoing: current.analysis, incoming: partner.analysis, beatsBeforeVoice: 6).isOn, "\(Int(old)) into \(new) BPM locks")
            checkSung(plan, from: current, to: partner, "\(Int(old)) into \(Int(new)) BPM", voiceEnd: 150)
        }
    }

    private static func newSongsFirstVoice() {
        print("The new song's first singing lands on the old voice's last words")
        let current = song("Old", tempo: 96, duration: 200, voice: 12...170, hook: 140)
        let partner = { (name: String, voice: ClosedRange<TimeInterval>, main: TimeInterval?) in
            song(name, tempo: 96, duration: 240, voice: voice, main: main)
        }
        // A long intro: the song comes in well back, never earlier than its start.
        let long = partner("Long", 100...230, 100)
        let longPlan = KnobShiftPlan.make(from: current, to: long)
        expect(near(longPlan.incomingOffset, 97), "a voice at 1:40: the song comes in from \(KnobShiftPlan.clock(longPlan.incomingOffset)), 3s ahead of it")
        checkSung(longPlan, from: current, to: long, "voice at 1:40", voiceEnd: 170)
        // A voice at 6s, well before the main verse at 40s, is a sung intro: the song starts at
        // its main verse (Naggnee, Putt Jam Te Lau).
        let adlib = partner("Adlib", 6...230, 40)
        let adlibPlan = KnobShiftPlan.make(from: current, to: adlib)
        expect(adlibPlan.beatsBeforeVoice.map { near($0, 3) } ?? false && near(adlibPlan.incomingOffset, 37), "a voice at 0:06 is an intro, the song starts 3s before its main verse at 0:40")
        // A voice less than 8s before the main verse is where it starts singing (Jee Karuga).
        let close = partner("Close", 34...230, 40)
        expect(near(KnobShiftPlan.make(from: current, to: close).incomingOffset, 31), "a voice at 0:34, 6s before the verse, is the first singing")
        let firstSinging = KnobShiftPlan.firstSinging(adlib.analysis), closeSinging = KnobShiftPlan.firstSinging(close.analysis)
        expect(firstSinging.map { near($0.at, 40) && $0.onGrid } == true && closeSinging.map { near($0.at, 34) && !$0.onGrid } == true,
               "the main verse is marked as on the phrase grid, an earlier voice is not")
        // Without a beat entry (or a tempo) the main verse is not placed on the grid, so it is
        // as early as any heard onset and still gets the correction.
        var loose = adlib.analysis
        loose.beatEntry = nil
        var late = adlib.analysis
        late.beatEntry = 45
        let noTempo = song("NoTempo", tempo: nil, duration: 240, voice: 6...230, main: 40)
        expect([loose, late, noTempo.analysis].allSatisfy { analysis in KnobShiftPlan.firstSinging(analysis).map { near($0.at, 40) && !$0.onGrid } == true },
               "no beat entry, a beat entry after 40s or no tempo: the main verse is not taken as on the grid")
        checkSung(adlibPlan, from: current, to: adlib, "ad lib before the verse", voiceEnd: 170)
        // The main verse before the first steady vocal onset counts too.
        let early = partner("Early", 60...230, 25)
        let earlyPlan = KnobShiftPlan.make(from: current, to: early)
        expect(earlyPlan.beatsBeforeVoice.map { near($0, 25 - earlyPlan.incomingOffset) } ?? false, "the earlier of the two onsets is used (0:25)")
        checkSung(earlyPlan, from: current, to: early, "verse before the vocal onset", voiceEnd: 170)
        // A song with an intro that is just long enough.
        let enough = partner("Enough", 20...230, 20)
        checkSung(KnobShiftPlan.make(from: current, to: enough), from: current, to: enough, "voice at 0:20", voiceEnd: 170)
        // No vocals at all: it comes in after its leading silence.
        let beats = song("Beats", tempo: 96, duration: 240, voice: nil, lead: 1.5)
        let beatsPlan = KnobShiftPlan.make(from: current, to: beats)
        expect(near(beatsPlan.incomingOffset, 1.5) && beatsPlan.beatsBeforeVoice == nil, "an instrumental comes in at 0:01.50")
        checkSung(beatsPlan, from: current, to: beats, "instrumental next song", voiceEnd: 170)
    }

    private static func shortIntro() {
        print("A new song that sings almost at once")
        let current = song("Old", tempo: 96, duration: 200, voice: 12...170, hook: 140)
        let quick = song("Quick", tempo: 96, duration: 240, voice: 3...230, main: 3.5)
        let plan = KnobShiftPlan.make(from: current, to: quick)
        expect(near(plan.incomingOffset, 0) && plan.beatsBeforeVoice.map { near($0, 3) } == true, "a voice at 0:03: it comes in from its very start, 3s ahead of its voice")
        checkSung(plan, from: current, to: quick, "voice at 0:03", voiceEnd: 170)
        let instant = song("Instant", tempo: 96, duration: 240, voice: 1...230, main: 1)
        let instantPlan = KnobShiftPlan.make(from: current, to: instant)
        expect(near(instantPlan.incomingOffset, 0) && instantPlan.beatsBeforeVoice.map { near($0, 1) } == true, "a voice at 0:01: it comes in from its very start, only 1s ahead")
        checkSung(instantPlan, from: current, to: instant, "voice at 0:01", voiceEnd: 170)
        let silent = song("Silent", tempo: 96, duration: 240, voice: 4...230, main: 4, lead: 1.5)
        let silentPlan = KnobShiftPlan.make(from: current, to: silent)
        expect(near(silentPlan.incomingOffset, 1.5), "after 1.5s of silence: it comes in as the silence ends, 2.5s ahead of its voice")
        checkSung(silentPlan, from: current, to: silent, "voice at 0:04 after silence", voiceEnd: 170)
        let tight = song("TightLead", tempo: 96, duration: 240, voice: 4...230, main: 4, lead: 3.5)
        let tightPlan = KnobShiftPlan.make(from: current, to: tight)
        expect(near(tightPlan.incomingOffset, 3.5) && tightPlan.beatsBeforeVoice.map { near($0, 0.5) } == true, "silence until 0:03.50 and a voice at 0:04: only half a second of intro")
        checkSung(tightPlan, from: current, to: tight, "voice half a second after the silence", voiceEnd: 170)
    }

    private static func instrumental() {
        print("An instrumental with a long fade")
        let current = song("Fade", duration: 200, voice: nil, fade: 160)
        let plan = KnobShiftPlan.make(from: current, to: next)
        expect(!plan.voiceThrow, "no voice to press down")
        expect(near(plan.duration, target(current)), "its fade is mixed for the usual length, not all 40s (\(f(plan.duration))s)")
        expect(plan.duration >= KnobShiftPlan.shortestMix - 0.01 && plan.duration <= KnobShiftPlan.longestMusic + 0.01, "between 6 and 14.7s")
        expect(near(plan.start + plan.duration, 200) && near(plan.handoff, 200), "it ends where the song ends")
        // A hook means nothing without a voice.
        let hooked = song("FadeHook", duration: 200, voice: nil, fade: 160, hook: 100)
        expect(near(KnobShiftPlan.make(from: hooked, to: next).start, plan.start), "a hook does not move a fade mix")
        // A fade too close to the end is not worth mixing.
        let short = song("ShortFade", duration: 200, voice: nil, fade: 195)
        expect(KnobShiftPlan.make(from: short, to: next).duration == 0, "a fade under 6s long: a clean handoff")
    }

    private static func cleanHandoff() {
        print("No voice and no fade")
        let current = song("Plain", duration: 200, trailing: 3, voice: nil)
        let plan = KnobShiftPlan.make(from: current, to: song("Lead", duration: 220, voice: 16...200, lead: 1.2))
        expect(plan.duration == 0 && !plan.voiceThrow, "the songs meet cleanly, nothing is pressed")
        expect(near(plan.start, 197) && near(plan.handoff, 197), "at the end of what is heard, 3:17")
        expect(near(plan.incomingOffset, 1.2) && plan.beatsBeforeVoice == nil, "the next song starts after its leading silence")
    }

    // MARK: Mix curves

    /// One reading of the decks at a point of the mix.
    private struct Reading {
        var p: Double
        var oldBeats: Double, oldVoice: Double, oldWhole: Double, press: Double, hall: Double, sweep: Double, wash: Double, oldTape: Double
        var newBeats: Double, newVoice: Double, newPress: Double, newHall: Double, newTape: Double, newBeatsOnly: Double
        var newSweep = 0.0, newRoom = 0.0
        var oldRate: Double, newRate: Double
    }

    /// Where things happen in a mix, as shares of it (what `beginBlend` hands to the curves).
    private struct MixTimes {
        var entry: Double, wordsEnd: Double, beatsIn: Double, length: Double, voiceAt: Double
        var second: Double { 1 / length }
        /// The new voice arrives half way to the old voice's last words, as the plan has it.
        var newVoice: Double { max(voiceAt, entry) }
        /// The old voice is gone 3 seconds after its last words.
        var voiceGone: Double { min(wordsEnd + KnobShiftPlan.voiceRing * second, 1) }
        /// Where the old beats start to leave, and how long they take.
        func musicFrom(locked: Bool) -> Double { !locked && beatsIn < 1 ? max(min(beatsIn - second, wordsEnd), 0) : wordsEnd }
        func musicSpan(locked: Bool) -> Double {
            let from = musicFrom(locked: locked)
            return (!locked && beatsIn < 1 ? max(beatsIn, from + 0.01) : 1) - from
        }
    }

    /// The shares of a real plan, worked out as `beginBlend` does. `drums` is where the new song's
    /// own drums come in (the entry when nil).
    private static func mixTimes(_ plan: KnobShiftPlan, sync: KnobShiftSync, drums: Double? = nil) -> MixTimes {
        let entry = min(max((plan.handoff - plan.start) / plan.duration, 0), 1)
        let wordsEnd = min(max(((plan.voiceEnd ?? plan.start) - plan.start) / plan.duration, entry), 1)
        let length = plan.duration / (sync.isOn ? max(sync.meetingTempo / sync.outgoingTempo, 0.1) : 1)
        let voiceAt = min(entry + (plan.beatsBeforeVoice ?? 0) / plan.duration, wordsEnd)
        return MixTimes(entry: entry, wordsEnd: wordsEnd, beatsIn: min(max(drums ?? entry, entry), 1), length: length, voiceAt: voiceAt)
    }

    private static func readings(sync: KnobShiftSync, mix: MixTimes, stems: Bool) -> [Reading] {
        let model = KnobShiftModel(restoresQueue: false)
        model.outgoingOnStems = stems
        model.blendHasStems = true
        // The curves are the subject, not the log: mark every line as already written.
        model.effectsLogged = ["hook mix stems", "hook mix whole", "hook mix new wash", "hook mix new voice"].reduce(into: Set((0...10).map { "hook \($0)" })) { $0.insert($1) }
        // The new song starts with its voice muted and its melody held back, to prove the mix
        // gives it back whole.
        model.secondaryDeck.voiceLevel = 0
        model.secondaryDeck.beatsOnly = 0.5
        let steps = 400
        return (0...steps).map { step in
            let p = Double(step) / Double(steps)
            model.applyHookMix(p, entry: mix.entry, wordsEnd: mix.wordsEnd, beatsIn: mix.beatsIn, length: mix.length, sync: sync, voiceAt: mix.newVoice)
            let old = model.primaryDeck, new = model.secondaryDeck
            return Reading(p: p, oldBeats: Double(old.musicStemLevel), oldVoice: Double(old.voiceLevel), oldWhole: Double(old.volume),
                           press: old.voicePress, hall: old.voiceReverb, sweep: old.sweep, wash: old.reverbMix, oldTape: old.voiceTape,
                           newBeats: Double(new.volume), newVoice: Double(new.voiceLevel), newPress: new.voicePress, newHall: new.voiceReverb,
                           newTape: new.voiceTape, newBeatsOnly: new.beatsOnly, newSweep: new.sweep, newRoom: new.reverbMix, oldRate: old.rate, newRate: new.rate)
        }
    }

    /// The most a value moves between two neighbouring readings (1/400 of the mix).
    private static func jump(_ readings: [Reading], _ value: (Reading) -> Double) -> Double {
        zip(readings, readings.dropFirst()).map { abs(value($1) - value($0)) }.max() ?? 0
    }

    private static func at(_ readings: [Reading], _ p: Double) -> Reading {
        readings[min(max(Int((p * 400).rounded()), 0), 400)]
    }

    /// The first reading at or after `p`.
    private static func after(_ readings: [Reading], _ p: Double) -> Reading {
        readings.first { $0.p >= p - 1e-9 } ?? readings[400]
    }

    private static func hookMixCurves() {
        print("The mix curves: only the old voice is pressed")
        let oldSong = song("Old", tempo: 90, duration: 200, voice: 12...150, hook: 140)
        let old = oldSong.analysis
        let near96 = song("New", tempo: 96, duration: 220, voice: 16...200, main: 17)
        let far = song("Far", tempo: 128, duration: 220, voice: 16...200, main: 17)
        let locked = KnobShiftSync.make(outgoing: old, incoming: near96.analysis, beatsBeforeVoice: 6)
        let unlocked = KnobShiftSync.make(outgoing: old, incoming: far.analysis, beatsBeforeVoice: 6)
        expect(locked.isOn && !unlocked.isOn, "90 into 96 BPM locks, 90 into 128 BPM does not")
        // A long mix from the hook, and a short one from KnobMix Now.
        let long = KnobShiftPlan.make(from: oldSong, to: near96)
        let short = KnobShiftPlan.make(from: oldSong, to: near96, handoffAt: 80)
        for (planName, plan) in [("hook mix", long), ("KnobMix Now", short)] {
            for (name, sync) in [("beats locked", locked), ("beats apart", unlocked)] {
                // The new drums come in with the song, a little later (a drumless intro), or not before the end.
                let base = mixTimes(plan, sync: sync)
                let variants: [(String, Double?)] = sync.isOn ? [("", nil)] : [("drums with the song", nil), ("drumless intro", base.entry + 0.15), ("drums only at the end", 1)]
                for (variant, drums) in variants {
                    let mix = mixTimes(plan, sync: sync, drums: drums)
                    curves(sync: sync, mix: mix, "\(planName), \(name)\(variant.isEmpty ? "" : ", \(variant)")")
                }
            }
        }
    }

    private static func curves(sync: KnobShiftSync, mix: MixTimes, _ name: String) {
        let r = readings(sync: sync, mix: mix, stems: true)
        let nv = mix.newVoice
        // The new voice is not touched: it plays whole from the first step.
        expect(r.allSatisfy { $0.newVoice == 1 }, "\(name): the new voice is never muted")
        expect(r.allSatisfy { $0.newPress == 0 && $0.newHall == 0 && $0.newTape == 0 && $0.newBeatsOnly == 0 },
               "\(name): the new voice is never pressed, slowed or put in a hall, and its melody is not held back")
        // The old voice is pressed in until the new voice arrives, then held.
        expect(r.first!.press == 0 && r.first!.hall == 0, "\(name): the press starts from nothing")
        expect(after(r, nv).press > 0.999 && at(r, 1).press > 0.999, "\(name): fully pressed by the time the new voice arrives (\(Int((nv * 100).rounded()))%)")
        expect(zip(r, r.dropFirst()).allSatisfy { $1.press >= $0.press - 1e-9 }, "\(name): the press never lets go")
        expect(r.allSatisfy { $0.oldTape == 0 }, "\(name): the old voice keeps its speed and pitch, no slowdown")
        expect(after(r, nv).hall >= 0.79 && r.map(\.hall).max()! <= 0.8001, "\(name): the old voice sinks into a hall (\(f(r.map(\.hall).max()! * 100))%)")
        expect(at(r, 1).hall <= 0.001 && zip(r.filter { $0.p >= 0.9 }, r.filter { $0.p >= 0.9 }.dropFirst()).allSatisfy { $1.hall <= $0.hall + 1e-9 },
               "\(name): the hall eases out in the last 10%")
        // The old voice sings its last words over the new voice, then rings away, gone 3 seconds after them.
        expect(r.filter { $0.p <= nv }.allSatisfy { $0.oldVoice >= 0.85 - 1e-6 }, "\(name): the old voice holds (at least 85%) until the new voice arrives")
        expect(r.filter { $0.p <= mix.wordsEnd }.allSatisfy { $0.oldVoice >= 0.51 - 1e-6 }, "\(name): then sinks under it, to no less than 51%, through its last words")
        expect(abs(after(r, nv).oldVoice - 0.85) < 0.01, "\(name): and is still there when the new voice arrives (\(f(after(r, nv).oldVoice * 100))%)")
        let faded = r.filter { $0.p >= nv }
        expect(zip(faded, faded.dropFirst()).allSatisfy { $1.oldVoice <= $0.oldVoice + 1e-9 }, "\(name): then it only gets quieter")
        expect(after(r, mix.voiceGone).oldVoice <= 0.001 && at(r, 1).oldVoice <= 0.001, "\(name): the old voice is gone 3 seconds after its last words (\(Int((mix.voiceGone * 100).rounded()))%)")
        // The old beats.
        let from = mix.musicFrom(locked: sync.isOn)
        let clash = !sync.isOn && mix.beatsIn < 1
        expect(r.filter { $0.p <= from }.allSatisfy { $0.oldBeats > 0.999 }, "\(name): the old beats play at full until \(Int((from * 100).rounded()))%")
        let beats = r.filter { $0.p >= from }
        expect(zip(beats, beats.dropFirst()).allSatisfy { $1.oldBeats <= $0.oldBeats + 1e-9 }, "\(name): then they only fade")
        if clash {
            expect(after(r, mix.beatsIn).oldBeats <= 0.001, "\(name): the old beats are gone when the new drums come in (\(Int((mix.beatsIn * 100).rounded()))%)")
            if mix.beatsIn <= mix.entry + 1e-9 {
                expect(r.allSatisfy { $0.oldBeats * $0.newBeats <= 1e-6 }, "\(name): old and new beats are never both up")
            }
            expect(r.allSatisfy { $0.oldRate == 1 } && r.allSatisfy { $0.newRate >= KnobShiftPlan.introSpeed - 1e-9 && $0.newRate <= 1 + 1e-9 } && r.filter { $0.p >= nv }.allSatisfy { abs($0.newRate - 1) < 1e-9 },
                   "\(name): the old song keeps its speed, the new music starts at most 8% slow and its voice plays at its own speed")
        } else {
            expect(at(r, mix.wordsEnd - 0.0025).oldBeats > 0.99, "\(name): the old beats play on until the old voice's last words end (\(Int((mix.wordsEnd * 100).rounded()))%)")
            expect(at(r, 1).oldBeats <= 0.001, "\(name): and fade out by the end")
            if sync.isOn {
                expect(r.filter { $0.p <= nv }.allSatisfy { $0.newBeats <= 0.75 + 1e-6 }, "\(name): the new song sits under the old beats until its voice arrives")
                expect(after(r, min(nv + 2 * mix.second + 0.005, 1)).newBeats > 0.999, "\(name): and is at full level two seconds after its voice")
                expect(r.allSatisfy { $0.oldRate == r[0].oldRate }, "\(name): the old song holds the meeting tempo (\(String(format: "%.3f", r[0].oldRate)))")
                expect(abs(r[0].oldRate - sync.meetingTempo / sync.outgoingTempo) < 1e-9, "\(name): which is the sync's meeting tempo")
                expect(abs(at(r, 0.9).newRate - sync.meetingTempo / sync.incomingTempo) < 1e-9 && abs(r.last!.newRate - 1) < 1e-9,
                       "\(name): the new song holds the meeting tempo, then glides to its own speed in the last 10% (\(String(format: "%.3f", r.last!.newRate)))")
            } else {
                expect(r.allSatisfy { $0.oldRate == 1 } && r.allSatisfy { $0.newRate >= KnobShiftPlan.introSpeed - 1e-9 && $0.newRate <= 1 + 1e-9 } && r.filter { $0.p >= nv }.allSatisfy { abs($0.newRate - 1) < 1e-9 },
                   "\(name): the old song keeps its speed, the new music starts at most 8% slow and its voice plays at its own speed")
            }
        }
        // The new song arrives in a hall and muffled and comes clear after its voice, so it never
        // just appears, and nothing of that is left when the mix ends.
        let arriving = r.filter { $0.p >= mix.entry }
        if mix.entry < 0.9 {
            expect(after(r, mix.entry).newSweep > 0.5 && after(r, mix.entry).newRoom > 0.3, "\(name): the new song arrives muffled and in a hall")
        }
        expect(zip(arriving, arriving.dropFirst()).allSatisfy { $1.newSweep <= $0.newSweep + 1e-9 && $1.newRoom <= $0.newRoom + 1e-9 }, "\(name): which only ever clear")
        expect(at(r, 1).newSweep <= 1e-6 && at(r, 1).newRoom <= 1e-6, "\(name): and are gone by the end of the mix")
        // The new song: nothing before it comes in, fully up by the end.
        expect(r.filter { $0.p < mix.entry - 0.001 }.allSatisfy { $0.newBeats == 0 }, "\(name): the new song is silent until \(Int((mix.entry * 100).rounded()))%")
        expect(at(r, 1).newBeats > 0.999 && after(r, min(mix.entry + mix.second + 0.005, 1)).newBeats > (sync.isOn ? 0.74 : 0.999),
               "\(name): it rises over about a second and is fully up by the end")
        // Everything eases. Slow curves move at most 5% per 1/400 of the mix; the deliberate
        // one second moves (the new song rising, the old beats leaving) may move faster, as much as
        // their length allows.
        let quick = 2.4 / (400 * min(mix.second, mix.musicSpan(locked: sync.isOn)))
        let slow: [(String, (Reading) -> Double)] = [("press", \.press), ("hall", \.hall), ("old voice", \.oldVoice), ("new speed", \.newRate)]
        for (curve, value) in slow {
            let step = jump(r, value)
            expect(step <= 0.05, "\(name): \(curve) never jumps (largest step \(String(format: "%.4f", step)))")
        }
        let fast: [(String, (Reading) -> Double)] = [("old beats", \.oldBeats), ("treble loss", \.sweep), ("wash", \.wash), ("new song", \.newBeats)]
        for (curve, value) in fast {
            let step = jump(r, value)
            expect(step <= max(0.05, quick), "\(name): \(curve) never jumps (largest step \(String(format: "%.4f", step)), room \(String(format: "%.4f", max(0.05, quick))))")
        }
        expect(abs(r[1].press - r[0].press) < 0.002 && abs(r[400].oldBeats - r[399].oldBeats) < 0.002 && abs(r[400].oldVoice - r[399].oldVoice) < 0.002,
               "\(name): the press starts gently and the old song's voice and beats end gently")
        let rising = r.filter { $0.p >= mix.entry }
        // Within the first tenth of a second of its one second rise it is still almost silent.
        expect(rising.count > 2 && rising[0].newBeats < 0.01 && rising[1].newBeats < 0.03,
               "\(name): the new song rises from nothing, with no step as it comes in")
    }

    private static func hookMixWithoutStems() {
        print("The mix curves with no separated voice")
        let oldSong = song("Old", tempo: 90, duration: 200, voice: 12...150, hook: 140)
        let new = song("New", tempo: 96, duration: 220, voice: 16...200, main: 17)
        let sync = KnobShiftSync.make(outgoing: oldSong.analysis, incoming: new.analysis, beatsBeforeVoice: 6)
        let mix = mixTimes(KnobShiftPlan.make(from: oldSong, to: new), sync: sync)
        let r = readings(sync: sync, mix: mix, stems: false)
        expect(at(r, 0.1).oldWhole > 0.99, "the whole old song plays at the start")
        expect(r.last!.oldWhole <= 0.001, "and is gone at the end")
        expect(zip(r, r.dropFirst()).allSatisfy { $1.oldWhole <= $0.oldWhole + 1e-9 }, "it only ever gets quieter")
        let quick = max(0.05, 2.4 / (400 * min(mix.second, mix.musicSpan(locked: true))))
        expect(jump(r, \.oldWhole) <= quick && jump(r, \.sweep) <= quick && jump(r, \.wash) <= 0.05, "its volume, muffling and wash never jump")
        expect(after(r, mix.newVoice).sweep >= 0.54, "it is muffled by the time the new voice arrives (\(String(format: "%.2f", after(r, mix.newVoice).sweep)))")
        expect(r.filter { $0.p < mix.entry - 0.001 }.allSatisfy { $0.newBeats == 0 }, "the new song still waits for its entry")
        expect(r.allSatisfy { $0.newVoice == 1 && $0.newPress == 0 && $0.newHall == 0 }, "the new voice is left alone here too")
    }

    private static func voices() {
        print("The voices in a plain crossfade (not a sung mix)")
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
