import Foundation

/// When and how KnobShift moves from one song to the next. There is no fixed crossfade length:
/// every time here comes from the two songs' own analysis, counted in bars of their own tempo.
///
/// The vocal handoff, as in the product intent:
/// 1. The handoff is where the outgoing song's last vocal line ends.
/// 2. Two bars before it, the incoming song comes in, started two bars before its own main
///    verse (not necessarily at its beginning), so only its beats play under the old voice and
///    its main verse lands on the handoff.
/// 3. After the handoff the old song fades out over two bars and stops, rather than playing its
///    whole outro, so its leftover shouts or ad-libs never sing over the new verse.
/// Songs without vocals use their measured fade; with neither, the songs meet cleanly.
struct KnobShiftPlan {
    /// Position in the outgoing song where the incoming song starts.
    let start: TimeInterval
    /// Length of the blend in the outgoing song's music; 0 means a clean handoff at `start`.
    let duration: TimeInterval
    /// Position in the outgoing song where its voice ends and the incoming voice takes over.
    let handoff: TimeInterval
    /// Where the incoming song is started from: shortly before its main verse, or after its
    /// leading silence.
    let incomingOffset: TimeInterval
    /// How long only the incoming beats play before its vocals; nil when it has no vocals.
    let beatsBeforeVoice: TimeInterval?
    let description: String
    let reasoning: [String]

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

        // Songs with vocals: hand the voice over.
        if handoffAt != nil || outgoing.vocalEnd != nil {
            var handoff = min(handoffAt ?? outgoing.vocalEnd ?? audibleEnd, audibleEnd)
            var lastLine = min(outgoing.lastLineStart ?? handoff, handoff)
            if let handoffAt {
                lastLine = 0
                reasoning.append("KnobMix Now: the voices hand over at \(clock(handoffAt)), the next phrase or break in \(current.title).")
            } else {
                reasoning.append("\(current.title): its last vocal line runs \(clock(lastLine)) to \(clock(handoff)).")
            }
            // Singing that runs right up to the end leaves no room to mix, so the handoff moves
            // to the last break in the music (where the bass drops out) at least four bars from
            // the end, as a DJ would leave a song before its final section.
            if handoffAt == nil, audibleEnd - handoff < bar,
               let lastBreak = outgoing.musicBreaks.last(where: { $0 <= audibleEnd - 4 * bar && $0 >= audibleEnd - 60 && $0 > lastLine }) {
                reasoning.append("Its singing runs to the end, so the voices hand over at its last break, \(clock(lastBreak)), instead.")
                handoff = lastBreak
            }
            // Two bars of beats under the old voice; less if the new song has a shorter run-up
            // to its main verse, but at least one bar so the change never feels abrupt.
            let runUp = mainVerse.map { max(0, $0 - leadIn) }
            let underVoice = max(min(2 * bar, runUp ?? 2 * bar), bar)
            let start = max(handoff - underVoice, lastLine)
            let beatsTime = handoff - start
            let incomingOffset = mainVerse.map { max(leadIn, $0 - beatsTime) } ?? leadIn
            if let mainVerse {
                let skipped = incomingOffset - leadIn
                reasoning.append("\(next.title): its main verse starts at \(clock(mainVerse)). It comes in at \(clock(incomingOffset))" +
                                 (skipped > 0.5 ? ", skipping \(seconds(skipped)) of intro," : "") +
                                 " so \(seconds(beatsTime)) of its beats play under \(current.title)'s last line and its verse lands on the handoff.")
            } else {
                reasoning.append("\(next.title): no vocals found, so it comes in from \(clock(incomingOffset)), \(seconds(beatsTime)) before the old voice ends.")
            }
            // The old song fades for two bars after its voice and then stops.
            let end = min(audibleEnd, handoff + 2 * bar)
            if end < audibleEnd - 0.5 {
                reasoning.append("\(current.title) fades out over two bars after its voice and stops at \(clock(end)), skipping its last \(seconds(audibleEnd - end)).")
            }
            let strays = outgoing.vocalStrays.filter { $0 > handoff }
            if !strays.isEmpty {
                let heard = strays.filter { $0 < end }
                reasoning.append(heard.isEmpty
                    ? "Its short vocal sounds after the last line (\(strays.map { clock($0) }.joined(separator: ", "))) come after it stops, so they are not heard."
                    : "Its short vocal sounds at \(heard.map { clock($0) }.joined(separator: ", ")) fall inside the fade.")
            }
            let duration = end - start
            guard duration > 0.05 else {
                reasoning.append("Nothing is left to blend, so the songs meet cleanly at \(clock(audibleEnd)).")
                return clean(at: audibleEnd, offset: incomingOffset, reasoning: reasoning)
            }
            reasoning.append("Blend: \(clock(start)) to \(clock(end)), \(seconds(duration)), voices hand over at \(clock(handoff)).")
            return KnobShiftPlan(start: start, duration: duration, handoff: handoff, incomingOffset: incomingOffset,
                                 beatsBeforeVoice: mainVerse == nil ? nil : beatsTime,
                                 description: "READY • mix at \(clock(start)) for \(Int(duration.rounded()))s, voices hand over at \(clock(handoff))",
                                 reasoning: reasoning)
        }

        // No vocals in the outgoing song: its measured fade is the cue.
        if let fade = outgoing.fadeOutCue, fade < audibleEnd {
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
