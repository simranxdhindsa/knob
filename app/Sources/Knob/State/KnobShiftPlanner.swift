import Foundation

/// When and how KnobShift moves from one song to the next. There is no fixed crossfade length:
/// every time here comes from the two songs' own analysis, counted in bars of their own tempo.
///
/// Modelled on a measured Apple Music AutoMix (Naggnee into Sardaari):
/// 1. The old song plays its voice to the end, then its outro, and leaves at its own fade.
/// 2. The new song's main verse lands as the old song leaves, so two singers never overlap.
/// 3. Before that the new song's intro plays quietly underneath, often from its very start.
/// 4. Three bars before the old song is gone, the new song opens up fully and the old one
///    loses its treble first, then fades.
/// Songs without vocals use their measured fade; with neither, the songs meet cleanly.
struct KnobShiftPlan {
    /// Position in the outgoing song where the incoming song starts.
    let start: TimeInterval
    /// Length of the blend in the outgoing song's music; 0 means a clean handoff at `start`.
    let duration: TimeInterval
    /// Position in the outgoing song where the incoming music opens up fully.
    let handoff: TimeInterval
    /// Position in the outgoing song where its voice ends: its fade and exit effects wait for
    /// this, and so does the incoming voice.
    var voiceEnd: TimeInterval? = nil
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
            // Where the old song leaves, as Apple Music's AutoMix does it: at its own fade when
            // that comes after the voice (its outro plays out first), at most eight bars after
            // the voice. A song that sings to the end, or KnobMix Now, leaves two bars after.
            var exit = min(audibleEnd, handoff + 2 * bar)
            if handoffAt == nil, audibleEnd - (outgoing.vocalEnd ?? audibleEnd) >= bar {
                let natural = outgoing.fadeOutCue.map { $0 > handoff + bar ? $0 : audibleEnd } ?? audibleEnd
                exit = min(natural, handoff + 8 * bar, audibleEnd)
            }
            // The new song opens up fully three bars before the old one is gone, never before
            // the old voice ends, and its main verse lands as the old song leaves, so the two
            // singers never overlap. Its intro plays quietly underneath first, up to 24 seconds
            // of it, and at least one bar before it opens up.
            var open = max(handoff, exit - 3 * bar)
            // At least two bars for the old song's exit, so its fade and exit effects are heard:
            // when its voice ends close to where it would leave, it plays on a little longer.
            if exit - open < 2 * bar {
                exit = min(audibleEnd, open + 2 * bar)
                open = max(handoff, min(open, exit - 2 * bar))
            }
            let introRoom = mainVerse.map { max(0, $0 - leadIn) } ?? 4 * bar
            // The new music opens up two bars before the old voice ends, on a bar line, so the new
            // song arrives during the old song's last line. Its voice still waits for the old one.
            if handoffAt == nil, outgoing.vocalEnd != nil {
                let anchor = outgoing.beatEntry ?? outgoing.beatGrid.first ?? 0
                let target = handoff - 2 * bar
                let barLine = anchor + max(0, ((target - anchor) / bar).rounded(.down)) * bar
                let snapped = outgoing.beatGrid.min { abs($0 - barLine) < abs($1 - barLine) } ?? barLine
                if snapped > lastLine + bar, snapped < open {
                    open = snapped
                    reasoning.append("The new music opens up at \(clock(open)), two bars before \(current.title)'s voice ends, on a bar line; the new voice waits until \(clock(handoff)).")
                }
            }
            let start = max(lastLine, exit - min(max(introRoom, exit - open + bar), 24))
            let underneath = exit - start
            let incomingOffset = mainVerse.map { max(leadIn, $0 - underneath) } ?? leadIn
            if let mainVerse {
                let skipped = incomingOffset - leadIn
                reasoning.append("\(next.title): its main verse starts at \(clock(mainVerse)). It comes in at \(clock(incomingOffset))" +
                                 (skipped > 0.5 ? ", skipping \(seconds(skipped)) of intro," : " with its whole intro,") +
                                 " playing quietly under \(current.title) for \(seconds(underneath)), so its verse lands as \(current.title) leaves.")
            } else {
                reasoning.append("\(next.title): no vocals found, so it comes in from \(clock(incomingOffset)), \(seconds(underneath)) before \(current.title) leaves.")
            }
            if exit < audibleEnd - 0.5 {
                reasoning.append("\(current.title) plays out after its voice, loses its treble first, and is gone at \(clock(exit)), skipping its last \(seconds(audibleEnd - exit)).")
            }
            let strays = outgoing.vocalStrays.filter { $0 > handoff }
            if !strays.isEmpty {
                let heard = strays.filter { $0 < exit }
                reasoning.append(heard.isEmpty
                    ? "Its short vocal sounds after the last line (\(strays.map { clock($0) }.joined(separator: ", "))) come after it leaves, so they are not heard."
                    : "Its short vocal sounds at \(heard.map { clock($0) }.joined(separator: ", ")) fall inside the mix.")
            }
            let duration = exit - start
            guard duration > 0.05 else {
                reasoning.append("Nothing is left to blend, so the songs meet cleanly at \(clock(audibleEnd)).")
                return clean(at: audibleEnd, offset: incomingOffset, reasoning: reasoning)
            }
            reasoning.append("Blend: \(clock(start)) to \(clock(exit)), \(seconds(duration)), the new song opens up at \(clock(open)).")
            return KnobShiftPlan(start: start, duration: duration, handoff: open, voiceEnd: max(open, handoff),
                                 incomingOffset: incomingOffset,
                                 beatsBeforeVoice: mainVerse == nil ? nil : open - start,
                                 description: "READY • mix at \(clock(start)) for \(Int(duration.rounded()))s, opens up at \(clock(open))",
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
