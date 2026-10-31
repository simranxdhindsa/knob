import Foundation

/// When and how KnobShift moves from one song to the next. There is no fixed crossfade length:
/// every time here comes from the two songs' own analysis.
///
/// - The outgoing song keeps its voice: the blend starts where its last vocal line ends.
/// - The outgoing music then fades under the incoming song's intro until the outgoing audible end.
/// - The incoming voice enters at its own first line, over the outgoing music only.
/// - With no vocal end and no measured fade, the songs meet cleanly at the audible end.
struct KnobShiftPlan {
    /// Position in the outgoing song where the incoming song starts.
    let start: TimeInterval
    /// Length of the blend; 0 means a clean handoff at `start`.
    let duration: TimeInterval
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

        let outroStart: TimeInterval
        let outroSource: String
        if let vocalEnd = outgoing.vocalEnd, vocalEnd < audibleEnd {
            outroStart = vocalEnd
            outroSource = "its last vocal line ends"
        } else if let fade = outgoing.fadeOutCue, fade < audibleEnd {
            outroStart = fade
            outroSource = outgoing.vocalEnd == nil ? "its fade starts (no vocals found)" : "its fade starts"
        } else {
            let why = outgoing.vocalEnd != nil
                ? "The voice runs to the very end and there is no fade"
                : "No voice and no fade were found"
            reasoning.append("\(why), so the songs meet cleanly at \(clock(audibleEnd)).")
            return KnobShiftPlan(start: audibleEnd, duration: 0, incomingOffset: incomingOffset,
                                 description: "READY • clean handoff at \(clock(audibleEnd)), the ending is kept whole.",
                                 reasoning: reasoning)
        }
        let outro = audibleEnd - outroStart
        reasoning.append("\(current.title): \(outroSource) at \(clock(outroStart)), leaving \(seconds(outro)) of music.")

        // The new music rises as soon as the old voice is done; the new voice may arrive during
        // the blend, but only over the old song's music, never over its voice.
        let start = outroStart
        if let onset = incoming.vocalOnset {
            let intro = max(0, onset - incomingOffset)
            if intro < outro {
                reasoning.append("\(next.title): its voice enters \(seconds(intro)) in, at \(Int((intro / outro * 100).rounded()))% of the blend, over the old music only.")
            } else {
                reasoning.append("\(next.title): its voice enters \(seconds(intro)) in, after the old song has gone.")
            }
        } else {
            reasoning.append("\(next.title): no vocals found, so its intro simply rises under the outro.")
        }

        let duration = audibleEnd - start
        if let a = outgoing.tempo, let b = incoming.tempo {
            let apart = abs(a - b) / max(a, b) * 100
            reasoning.append(String(format: "Tempo %.0f to %.0f BPM, %.1f%% apart. Played as is, no stretching yet.", a, b, apart))
        }
        reasoning.append("Blend: \(clock(start)) to \(clock(audibleEnd)), \(seconds(duration)), all from these two songs.")
        return KnobShiftPlan(start: start, duration: duration, incomingOffset: incomingOffset,
                             description: "READY • blend at \(clock(start)) for \(Int(duration.rounded()))s, after \(outroSource.replacingOccurrences(of: "its ", with: "the "))",
                             reasoning: reasoning)
    }

    private static func clock(_ value: TimeInterval) -> String {
        String(format: "%d:%05.2f", Int(value) / 60, value.truncatingRemainder(dividingBy: 60))
    }

    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }
}
