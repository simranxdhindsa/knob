import Foundation

/// When and how KnobShift moves from one song to the next. There is no fixed crossfade length:
/// every time here comes from the two songs' own analysis.
///
/// The vocal handoff, as in the product intent:
/// 1. The outgoing voice keeps singing its last line at full volume.
/// 2. The incoming music rises underneath, starting early enough that the incoming intro ends
///    exactly where the outgoing voice ends (never before that last line begins).
/// 3. At that handoff the incoming voice starts, the basslines swap and the outgoing music fades
///    out under the new voice until its audible end. Two voices never sing at once.
/// Songs without vocals use their measured fade; with neither, the songs meet cleanly.
struct KnobShiftPlan {
    /// Position in the outgoing song where the incoming song starts.
    let start: TimeInterval
    /// Length of the blend in the outgoing song's music; 0 means a clean handoff at `start`.
    let duration: TimeInterval
    /// Position in the outgoing song where its voice ends and the incoming voice takes over.
    let handoff: TimeInterval
    /// Where the incoming song is started from (its leading silence is skipped).
    let incomingOffset: TimeInterval
    let description: String
    let reasoning: [String]

    static func make(from current: KnobShiftModel.Track, to next: KnobShiftModel.Track) -> KnobShiftPlan {
        let outgoing = current.analysis
        let incoming = next.analysis
        var reasoning: [String] = []
        let audibleEnd = outgoing.audibleEnd(duration: current.duration)
        let incomingOffset = min(incoming.leadingSilence, next.duration)
        reasoning.append("\(current.title) is heard until \(clock(audibleEnd))\(outgoing.trailingSilence > 0.05 ? ", then \(seconds(outgoing.trailingSilence)) of silence is skipped" : "").")
        if incomingOffset > 0.05 {
            reasoning.append("\(next.title) starts at \(seconds(incomingOffset)), skipping its silent lead-in.")
        }
        // Time from the incoming song's start to its main verse (intro ad-libs do not count).
        let intro = (incoming.mainVocalOnset ?? incoming.vocalOnset).map { max(0, $0 - incomingOffset) }

        // Songs with vocals: hand the voice over.
        if let vocalEnd = outgoing.vocalEnd {
            let handoff = min(vocalEnd, audibleEnd)
            let lastLine = min(outgoing.lastLineStart ?? handoff, handoff)
            reasoning.append("\(current.title): its last vocal line runs \(clock(lastLine)) to \(clock(handoff)), then \(seconds(audibleEnd - handoff)) of music.")
            // The new song always comes in a little before the old voice ends: at least two bars
            // (8 beats at the old song's own tempo), or earlier still if the new intro is longer,
            // so the new voice can start as the old one ends. Never before the last line begins.
            let twoBars = outgoing.tempo.map { 8 * 60 / $0 }
            if let twoBars {
                reasoning.append("Two bars of \(current.title) last \(seconds(twoBars)), the least the new song comes in early.")
            }
            if let intro { reasoning.append("\(next.title): its main verse starts \(seconds(intro)) into the song.") }
            else { reasoning.append("\(next.title): no vocals found.") }
            let lead = max(intro ?? 0, twoBars ?? 0)
            let start = max(handoff - lead, lastLine)
            if start < handoff {
                let newVoiceAt = intro.map { start + $0 }
                let detail: String
                if let newVoiceAt, newVoiceAt < handoff - 0.05 {
                    detail = ". Its voice comes in quietly \(seconds(handoff - newVoiceAt)) before the old voice ends and takes over at the handoff."
                } else if let newVoiceAt, newVoiceAt > handoff + 0.05 {
                    detail = ", and its voice enters \(seconds(newVoiceAt - handoff)) after the old voice ends."
                } else if newVoiceAt != nil {
                    detail = ", so its voice starts exactly as the old voice ends."
                } else {
                    detail = "."
                }
                reasoning.append("\(next.title)'s music comes in at \(clock(start)), \(seconds(handoff - start)) before \(current.title)'s voice ends" + detail)
            } else {
                reasoning.append("\(next.title)'s music comes in as the old voice ends.")
            }
            // The old song must be gone before the new main verse, so none of its leftover
            // shouts or ad-libs sing over it. It still gets at least one bar to fade.
            var fadeEnd = audibleEnd
            if let intro, start + intro < audibleEnd {
                let oneBar = outgoing.tempo.map { 4 * 60 / $0 } ?? 0
                fadeEnd = min(audibleEnd, max(start + intro, handoff + oneBar))
                reasoning.append(fadeEnd <= start + intro + 0.01
                    ? "\(current.title) fades out by \(clock(fadeEnd)), before \(next.title)'s main verse at \(clock(start + intro))."
                    : "\(current.title) fades out by \(clock(fadeEnd)), one bar after the handoff, so its music is only a quiet tail under the first words of \(next.title)'s main verse at \(clock(start + intro)).")
            }
            let strays = outgoing.vocalStrays.filter { $0 > handoff }
            let heard = strays.filter { $0 < fadeEnd }
            if !strays.isEmpty {
                let list = strays.map { clock($0) }.joined(separator: ", ")
                reasoning.append(heard.isEmpty
                    ? "Its short vocal sounds after the last line (\(list)) fall after the fade, so they are not heard."
                    : "Its short vocal sounds at \(heard.map { clock($0) }.joined(separator: ", ")) fall inside the fade, under the new song's intro.")
            }
            let duration = fadeEnd - start
            guard duration > 0.05 else {
                reasoning.append("Nothing is left to blend, so the songs meet cleanly at \(clock(audibleEnd)).")
                return clean(at: audibleEnd, offset: incomingOffset, reasoning: reasoning)
            }
            appendTempo(outgoing, incoming, to: &reasoning)
            reasoning.append("Blend: \(clock(start)) to \(clock(fadeEnd)), \(seconds(duration)), voices hand over at \(clock(handoff)).")
            return KnobShiftPlan(start: start, duration: duration, handoff: handoff, incomingOffset: incomingOffset,
                                 description: "READY • blend at \(clock(start)) for \(Int(duration.rounded()))s, voices hand over at \(clock(handoff))",
                                 reasoning: reasoning)
        }

        // No vocals in the outgoing song: its measured fade is the cue.
        if let fade = outgoing.fadeOutCue, fade < audibleEnd {
            reasoning.append("\(current.title): no vocals found, its fade starts at \(clock(fade)).")
            if let intro { reasoning.append("\(next.title): its voice enters \(seconds(intro)) into the song.") }
            appendTempo(outgoing, incoming, to: &reasoning)
            let duration = audibleEnd - fade
            reasoning.append("Blend: \(clock(fade)) to \(clock(audibleEnd)), \(seconds(duration)).")
            return KnobShiftPlan(start: fade, duration: duration, handoff: fade, incomingOffset: incomingOffset,
                                 description: "READY • blend at \(clock(fade)) for \(Int(duration.rounded()))s, over the fade",
                                 reasoning: reasoning)
        }
        reasoning.append("No voice and no fade were found, so the songs meet cleanly at \(clock(audibleEnd)).")
        return clean(at: audibleEnd, offset: incomingOffset, reasoning: reasoning)
    }

    private static func clean(at end: TimeInterval, offset: TimeInterval, reasoning: [String]) -> KnobShiftPlan {
        KnobShiftPlan(start: end, duration: 0, handoff: end, incomingOffset: offset,
                      description: "READY • clean handoff at \(clock(end)), the ending is kept whole.",
                      reasoning: reasoning)
    }

    private static func appendTempo(_ outgoing: KnobShiftModel.Analysis, _ incoming: KnobShiftModel.Analysis,
                                    to reasoning: inout [String]) {
        guard let a = outgoing.tempo, let b = incoming.tempo else { return }
        reasoning.append(String(format: "Tempo %.1f and %.1f BPM.", a, b))
    }

    static func clock(_ value: TimeInterval) -> String {
        String(format: "%d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }
}
