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
    let description: String
    let reasoning: [String]

    /// A mix aims at about this long, in whole bars of the old song's beat.
    static let targetMix: TimeInterval = 8
    /// No mix is shorter than this when the song leaves room, so its exit is heard.
    static let shortestMix: TimeInterval = 6
    /// No mix is ever longer than this.
    static let longestMix: TimeInterval = 10
    /// The most the new song's beats play under the old voice, and the most the old song may
    /// still be heard once the new voice sings.
    static let overlap: TimeInterval = 2

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
            var handoff = min(handoffAt ?? outgoing.vocalEnd ?? audibleEnd, audibleEnd)
            let lastLine = min(outgoing.lastLineStart ?? handoff, handoff)
            // The voice is cut rather than finished: KnobMix Now, or singing that runs to the end.
            var cut = handoffAt != nil
            if let handoffAt {
                reasoning.append("KnobMix Now: \(current.title) is cut at \(clock(handoffAt)), the next phrase or break.")
            } else {
                reasoning.append("\(current.title): its last vocal line runs \(clock(lastLine)) to \(clock(handoff)).")
            }
            // Singing that runs right up to the end leaves no room to mix, so the voice is cut
            // in the last minute, at least four bars from the end, as a DJ leaves a song before
            // its final section: at its last break (where the bass drops out), else where a sung
            // line ends, else where the song starts fading out under the voice.
            if handoffAt == nil, audibleEnd - handoff < bar,
               let point = Self.cutPoint(outgoing, audibleEnd: audibleEnd, bar: bar, after: lastLine) {
                reasoning.append("Its singing runs to the end, so it is cut at its \(point.kind), \(clock(point.at)), instead.")
                handoff = point.at
                cut = true
            }
            let length = Self.length(bar: bar)
            // Tempos too far apart to lock would clash, so then no new beats play under the old
            // song: the new one starts on the downbeat as the old voice ends, and the old one
            // leaves within 2 seconds under its echo or reverb, as a DJ echoes out.
            let beatsLock = KnobShiftSync.make(outgoing: outgoing, incoming: incoming, beatsBeforeVoice: nil).isOn
            // The new beats come in under the old voice's last words, at most 2 seconds before
            // it ends; the new song opens up as it ends.
            let underVoice = beatsLock ? min(Self.overlap, bar, handoff) : 0
            let start = handoff - underVoice
            // After the voice the old song leaves with its exit effects: the rest of the mix,
            // or within 2 seconds (in whole beats) when its voice was cut, since it would keep
            // singing, or when the beats cannot lock.
            let beat = bar / 4
            let quickExit = max(beat, (Self.overlap / beat + 0.001).rounded(.down) * beat)
            let afterVoice = cut || !beatsLock ? quickExit : length - underVoice
            if !beatsLock {
                reasoning.append("The tempos are too far apart to lock, so no new beats play under \(current.title); it echoes out as \(next.title) starts.")
            }
            let exit = min(audibleEnd, handoff + afterVoice)
            let open = handoff
            reasoning.append(cut
                ? "It leaves within \(seconds(exit - handoff)) of the cut, so its voice is never heard over the new song."
                : "After its voice it plays out for \(seconds(exit - handoff)) with its exit effects and is gone at \(clock(exit)).")
            let underneath = exit - start
            let incomingOffset = mainVerse.map { max(leadIn, $0 - underneath) } ?? leadIn
            if let mainVerse {
                let skipped = incomingOffset - leadIn
                reasoning.append("\(next.title): its main verse starts at \(clock(mainVerse)). It comes in at \(clock(incomingOffset))" +
                                 (skipped > 0.5 ? ", skipping \(seconds(skipped)) of intro," : " with its whole intro,") +
                                 " \(seconds(underVoice)) before \(current.title)'s voice ends, so its verse lands as \(current.title) is gone.")
            } else {
                reasoning.append("\(next.title): no vocals found, so it comes in from \(clock(incomingOffset)), \(seconds(underneath)) before \(current.title) leaves.")
            }
            if exit < audibleEnd - 0.5 {
                reasoning.append("\(current.title) skips its last \(seconds(audibleEnd - exit)): a mix never runs longer than \(Int(Self.longestMix)) seconds.")
            }
            let strays = outgoing.vocalStrays.filter { $0 > handoff && $0 < exit }
            if !strays.isEmpty {
                reasoning.append("Its short vocal sounds at \(strays.map { clock($0) }.joined(separator: ", ")) fall inside its exit.")
            }
            let duration = exit - start
            guard duration > 0.05 else {
                reasoning.append("Nothing is left to blend, so the songs meet cleanly at \(clock(audibleEnd)).")
                return clean(at: audibleEnd, offset: incomingOffset, reasoning: reasoning)
            }
            reasoning.append("Blend: \(clock(start)) to \(clock(exit)), \(seconds(duration)), the new song opens up at \(clock(open)).")
            return KnobShiftPlan(start: start, duration: duration, handoff: open, voiceEnd: handoff,
                                 incomingOffset: incomingOffset,
                                 beatsBeforeVoice: mainVerse == nil ? nil : open - start,
                                 description: "READY • mix at \(clock(start)) for \(Int(duration.rounded()))s, opens up at \(clock(open))",
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
