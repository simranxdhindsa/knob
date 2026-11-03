import Foundation

/// When and how KnobShift moves from one song to the next. Every time here comes from the two
/// songs' own analysis, counted in bars of their own tempo.
///
/// The way a DJ moves between two sung songs: two voices are never heard together.
/// 1. The old song sings its line to the end. At most 2 seconds before that, the new song's
///    beats come in quietly underneath; nothing of it opens up yet.
/// 2. As the old voice ends, the new song opens up and the old one leaves with its exit
///    effects (its slowdown, reverb or echo), about 8 seconds in all and never more than 10,
///    however long its outro is: the rest of the outro is skipped.
/// 3. The new voice lands as the old song is gone, at most 2 seconds before.
/// A song that sings to its end is cut at its last break and is gone within 2 seconds.
/// Songs without vocals mix over their measured fade; with neither, the songs meet cleanly.
struct KnobShiftPlan {
    /// Position in the outgoing song where the incoming song starts.
    let start: TimeInterval
    /// Length of the blend in the outgoing song's music; 0 means a clean handoff at `start`.
    let duration: TimeInterval
    /// Position in the outgoing song where the incoming music opens up fully: where the old
    /// voice ends, never before.
    let handoff: TimeInterval
    /// Position in the outgoing song where its voice ends: its fade and exit effects wait for
    /// this, and so does the incoming voice.
    var voiceEnd: TimeInterval? = nil
    /// Where the incoming song is started from: so its main verse lands as the old song leaves,
    /// or after its leading silence.
    let incomingOffset: TimeInterval
    /// How long only the incoming beats play before its vocals; nil when it has no vocals.
    let beatsBeforeVoice: TimeInterval?
    /// The old voice is cut (it sings to the end, or KnobMix Now) or the beats cannot lock: its
    /// music drops out at once and its separated voice alone slows into a hall (a vocal throw).
    var voiceThrow = false
    let description: String
    let reasoning: [String]

    /// A mix aims at about this long, in whole bars of the old song's beat.
    static let targetMix: TimeInterval = 8
    /// No mix is shorter than this when the song leaves room, so its exit is heard.
    static let shortestMix: TimeInterval = 6
    /// No mix is ever longer than this.
    static let longestMix: TimeInterval = 16
    /// In a sung mix the new voice comes in this long before the old voice's last words end,
    /// so they overlap on the old song's last two or three words.
    /// (3 seconds: a song's first singing is measured up to about a second and a half early.)
    static let handover: TimeInterval = 3
    /// How much of the new song's own intro plays before its voice comes in.
    static let introLead: TimeInterval = 2
    /// How long the old song carries on after its last words (its pressed voice ringing out).
    static let tail: TimeInterval = 4
    /// How long the old pressed voice rings on into the new song after its last words.
    static let voiceRing: TimeInterval = 1.5
    /// The longest the old voice is pressed down before its last words.
    static let longestPress: TimeInterval = 10
    /// The most the new song's beats play under the old voice, and the most the old song may
    /// still be heard once the new voice sings.
    static let overlap: TimeInterval = 2
    /// How long a vocal throw lasts after the cut: the old music fades in time with the new
    /// beats while the old voice slows into a hall.
    static let throwLength: TimeInterval = 7

    /// The longest mix in the old song's music: the old song may slow by up to 8% to meet the
    /// new tempo, which stretches the mix, so this keeps it within 10 seconds of real time.
    static let longestMusic = longestMix * (1 - KnobShiftSync.outgoingStretch)

    /// The mix's length for a song with bars this long: the whole bars nearest to 8 seconds,
    /// kept to 6 seconds and `longestMusic`.
    static func length(bar: TimeInterval) -> TimeInterval {
        let bars = max(1, (targetMix / bar).rounded())
        var length = bars * bar
        while length > longestMusic, length - bar >= shortestMix { length -= bar }
        return min(max(length, shortestMix), longestMusic)
    }

    /// Where to cut a song that sings to its end: within its last minute and at least four
    /// bars before the end, its last music break, else its last sung line ending, else the
    /// start of its fade.
    static func cutPoint(_ analysis: KnobShiftModel.Analysis, audibleEnd: TimeInterval, bar: TimeInterval,
                         after lastLine: TimeInterval) -> (at: TimeInterval, kind: String)? {
        let window = (audibleEnd - 60)...(audibleEnd - 4 * bar)
        guard window.lowerBound <= window.upperBound else { return nil }
        if let found = analysis.musicBreaks.last(where: { window.contains($0) && $0 > lastLine }) { return (found, "last break") }
        if let found = analysis.vocalLineEnds?.last(where: { window.contains($0) }) { return (found, "last line ending") }
        if let fade = analysis.fadeOutCue, window.contains(fade) { return (fade, "fade") }
        return nil
    }

    /// `handoffAt` is a handoff the listener asked for with KnobMix Now: the voices hand over
    /// there instead of where the old song's singing ends.
    static func make(from current: KnobShiftModel.Track, to next: KnobShiftModel.Track,
                     handoffAt: TimeInterval? = nil) -> KnobShiftPlan {
        let outgoing = current.analysis
        let incoming = next.analysis
        var reasoning: [String] = []
        let audibleEnd = outgoing.audibleEnd(duration: current.duration)
        let leadIn = min(incoming.leadingSilence, next.duration)
        // One bar of the outgoing song, or about 2.5 seconds when its tempo is unknown.
        let bar = outgoing.tempo.map { 4 * 60 / $0 } ?? 2.5
        let mainVerse = incoming.mainVocalOnset ?? incoming.vocalOnset
        reasoning.append("\(current.title) is heard until \(clock(audibleEnd)). One bar of it is \(seconds(bar)).")

        // Songs with vocals: the old voice finishes, then the old song leaves.
        if handoffAt != nil || outgoing.vocalEnd != nil {
            var voiceEnd = min(handoffAt ?? outgoing.vocalEnd ?? audibleEnd, audibleEnd)
            let lastLine = min(outgoing.lastLineStart ?? voiceEnd, voiceEnd)
            if let handoffAt {
                reasoning.append("KnobMix Now: \(current.title) starts leaving at \(clock(handoffAt)), the next phrase or break.")
            } else {
                reasoning.append("\(current.title): its last vocal line runs \(clock(lastLine)) to \(clock(voiceEnd)).")
            }
            // Singing that runs right up to the end leaves no room: the voice is taken as ending
            // at its last break (where the bass drops out), else where a sung line ends, else
            // where the song starts fading out under the voice.
            if handoffAt == nil, audibleEnd - voiceEnd < bar,
               let point = Self.cutPoint(outgoing, audibleEnd: audibleEnd, bar: bar, after: lastLine) {
                reasoning.append("Its singing runs to the end, so it is taken as ending at its \(point.kind), \(clock(point.at)).")
                voiceEnd = point.at
            }
            // The mix begins where the song's last hook begins (the second chorus of two), so the
            // old song leaves on its biggest moment. Without a hook it begins over the old voice's
            // last words, so there is still a voice to press down.
            let target = Self.length(bar: bar)
            var start: TimeInterval
            if let handoffAt {
                start = handoffAt
            } else if let hook = outgoing.lastHookStart, hook < voiceEnd, audibleEnd - hook >= Self.shortestMix {
                start = hook
                reasoning.append("\(current.title): its last hook begins at \(clock(hook)), so the mix starts there.")
            } else {
                start = max(0, min(voiceEnd - 0.6 * target, audibleEnd - target))
                reasoning.append("\(current.title): no last hook found, so the mix starts at \(clock(start)), over its last words.")
            }
            // The old voice's last words end at `lastWords`. The new voice comes in on them, 3
            // seconds before, while the old voice is pressed down and fading, so the two voices
            // hand over smoothly instead of leaving a gap. The new song itself starts a little
            // earlier, so a moment of its own intro plays before its voice.
            // A hook far ahead of the last words would press the voice for too long: at most 10
            // seconds before them.
            if voiceEnd - start > Self.longestPress {
                start = voiceEnd - Self.longestPress
                reasoning.append("That is more than \(Int(Self.longestPress)) seconds before its last words, so the mix starts at \(clock(start)) instead.")
            }
            let lastWords = min(max(voiceEnd, start + Self.handover + 1), audibleEnd)
            let newVoiceAt = lastWords - Self.handover
            let firstVoice = [incoming.vocalOnset, incoming.mainVocalOnset].compactMap { $0 }.min()
            let introLead = firstVoice.map { min(Self.introLead, max(0, $0 - leadIn)) } ?? Self.introLead
            let handoff = max(start + 0.5, newVoiceAt - introLead)
            let exit = min(audibleEnd, max(lastWords + Self.tail, start + Self.shortestMix))
            let duration = exit - start
            guard duration > 0.05, handoff < exit else {
                reasoning.append("Nothing is left to blend, so the songs meet cleanly at \(clock(audibleEnd)).")
                return clean(at: audibleEnd, offset: leadIn, reasoning: reasoning)
            }
            let sync = KnobShiftSync.make(outgoing: outgoing, incoming: incoming,
                                          beatsBeforeVoice: firstVoice == nil ? nil : newVoiceAt - handoff)
            let beatsLock = sync.isOn
            // The new song is started in its file so its first singing lands on `newVoiceAt`.
            let incomingOffset = firstVoice.map { max(leadIn, $0 - (newVoiceAt - handoff)) } ?? leadIn
            reasoning.append(beatsLock
                ? "Tempos lock, so \(next.title) comes in at \(clock(handoff)) in time with \(current.title)'s beats, which play on under it."
                : "The tempos are too far apart to lock, so \(current.title)'s beats leave before \(next.title)'s drums come in; \(next.title) comes in at \(clock(handoff)).")
            if let firstVoice {
                reasoning.append("\(next.title): its first singing (\(clock(firstVoice))) is lined up with \(current.title)'s last words, at \(clock(newVoiceAt)). It comes in from \(clock(incomingOffset)).")
            } else {
                reasoning.append("\(next.title): no vocals found, so it comes in from \(clock(incomingOffset)).")
            }
            reasoning.append("\(current.title)'s voice is pressed down and muffled into a hall from \(clock(start)), keeping its speed and pitch, sings its last words over the new voice and rings on into it until \(clock(lastWords + Self.voiceRing)).")
            if exit < audibleEnd - 0.5 {
                reasoning.append("\(current.title) skips its last \(seconds(audibleEnd - exit)).")
            }
            reasoning.append("Blend: \(clock(start)) to \(clock(exit)), \(seconds(duration)), \(next.title) from \(clock(handoff)).")
            return KnobShiftPlan(start: start, duration: duration, handoff: handoff, voiceEnd: lastWords,
                                 incomingOffset: incomingOffset,
                                 beatsBeforeVoice: firstVoice.map { max(0, $0 - incomingOffset) },
                                 voiceThrow: true,
                                 description: "READY • mix at \(clock(start)) for \(Int(duration.rounded()))s, \(next.title) from \(clock(handoff))",
                                 reasoning: reasoning)
        }

        // No vocals in the outgoing song: its measured fade is the cue.
        if let measured = outgoing.fadeOutCue, measured < audibleEnd - Self.shortestMix {
            // The same length as a sung mix, about 8 seconds of the end of its fade.
            let fade = max(0, audibleEnd - Self.length(bar: bar))
            let duration = audibleEnd - fade
            let incomingOffset = mainVerse.map { max(leadIn, $0 - duration) } ?? leadIn
            reasoning.append("\(current.title): no vocals found, its fade starts at \(clock(fade)).")
            reasoning.append("\(next.title) comes in at \(clock(incomingOffset))" + (mainVerse == nil ? "." : ", so its main verse starts as the fade ends."))
            reasoning.append("Blend: \(clock(fade)) to \(clock(audibleEnd)), \(seconds(duration)).")
            return KnobShiftPlan(start: fade, duration: duration, handoff: audibleEnd, incomingOffset: incomingOffset,
                                 beatsBeforeVoice: mainVerse == nil ? nil : duration,
                                 description: "READY • mix at \(clock(fade)) for \(Int(duration.rounded()))s, over the fade",
                                 reasoning: reasoning)
        }
        reasoning.append("No voice and no fade were found, so the songs meet cleanly at \(clock(audibleEnd)).")
        return clean(at: audibleEnd, offset: leadIn, reasoning: reasoning)
    }

    private static func clean(at end: TimeInterval, offset: TimeInterval, reasoning: [String]) -> KnobShiftPlan {
        KnobShiftPlan(start: end, duration: 0, handoff: end, incomingOffset: offset, beatsBeforeVoice: nil,
                      description: "READY • clean handoff at \(clock(end)), the ending is kept whole.",
                      reasoning: reasoning)
    }

    static func clock(_ value: TimeInterval) -> String {
        String(format: "%d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }
}
