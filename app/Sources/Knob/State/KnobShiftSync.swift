import Foundation

/// Tempo sync for one blend: while both songs are heard they play at one shared tempo, so their
/// beats stay together. Pitch is kept natural (time-stretching, not speeding up a tape).
///
/// The incoming song's voice is never sped up or slowed down: it may run off its own speed only
/// while just its beats play under the old song's last line, and it is back at exactly its own
/// speed when its vocals start (the handoff). The outgoing song carries the rest of the change:
/// it eases toward the incoming tempo before and during the blend, the "slow down" that makes
/// the transition.
///
/// - The shared tempo starts at a meeting tempo and reaches the incoming tempo at the handoff.
/// - Close tempos (within 15%) meet at the outgoing tempo, so the old song needs no ease first.
/// - Tempos further apart meet in the middle: over its last two bars before the blend the old
///   song eases to a tempo between the two, then on to the incoming tempo during the blend.
/// - When the incoming song has less than a bar of beats before its vocals, it plays at its own
///   speed throughout and the old song eases all the way to it before the blend.
struct KnobShiftSync {
    /// Largest gap a meeting at the outgoing tempo covers.
    static let glideStretch = 0.08
    /// Largest speed change for the incoming song's beats before its vocals.
    static let incomingStretch = 0.08
    /// Largest speed change for the outgoing song. Apple Music leaves songs further apart at
    /// their own speed (measured: 25% apart, no change at all), and so does KnobShift.
    static let outgoingStretch = 0.08
    /// Tempos further apart than `outgoingStretch` still lock in a vocal throw, meeting in the
    /// middle: the new beats run up to `incomingStretch` off their own speed while only they
    /// play, and the old song covers the rest, up to `throwOutgoing`, as its music drops out.
    static let throwStretch = 0.20
    static let throwOutgoing = 0.12
    /// Both songs need a beat grid at least this trustworthy before beats are lined up.
    static let minimumConfidence = 0.6

    let isOn: Bool
    let outgoingTempo: Double
    /// The incoming tempo as matched: its own, or double or half when that is closer.
    let incomingTempo: Double
    /// The shared tempo when the incoming song comes in.
    let meetingTempo: Double
    let notes: [String]
    /// The tempos are further apart than the old song may ease in a normal mix, so they lock
    /// only as a vocal throw (its music drops out quickly).
    var wide = false

    /// True when the outgoing song first eases to the meeting tempo on its own.
    var easesBeforeBlend: Bool { isOn && abs(meetingTempo / outgoingTempo - 1) > Self.sameTempo }

    /// Tempos closer than this count as the same: no ease, no stretch.
    static let sameTempo = 0.005

    static let off = KnobShiftSync(isOn: false, outgoingTempo: 0, incomingTempo: 0, meetingTempo: 0, notes: [])

    /// `beatsBeforeVoice`: how long the incoming song plays only beats before its vocals start
    /// within the blend; nil when it has no vocals.
    static func make(outgoing: KnobShiftModel.Analysis, incoming: KnobShiftModel.Analysis,
                     beatsBeforeVoice: TimeInterval?) -> KnobShiftSync {
        guard let a = outgoing.tempo, let b = incoming.tempo else {
            return KnobShiftSync(isOn: false, outgoingTempo: 0, incomingTempo: 0, meetingTempo: 0,
                                 notes: ["Tempo sync off: a tempo is missing, so the songs keep their own speed."])
        }
        guard min(outgoing.tempoConfidence, incoming.tempoConfidence) >= minimumConfidence else {
            return KnobShiftSync(isOn: false, outgoingTempo: a, incomingTempo: b, meetingTempo: a, notes: [String(
                format: "Tempo sync off: beat confidence %.0f%% and %.0f%%, both need %.0f%% to line up beats safely.",
                outgoing.tempoConfidence * 100, incoming.tempoConfidence * 100, minimumConfidence * 100)])
        }
        let matched = [b, b * 2, b / 2].min { abs(log($0 / a)) < abs(log($1 / a)) } ?? b
        let octave = matched == b ? "" : (matched > b ? " (counted at double time)" : " (counted at half time)")
        let gap = abs(matched / a - 1)
        // The incoming beats may be stretched only if at least a bar of them plays before its
        // vocals; otherwise the old song makes the whole change before the blend.
        let bar = 4 * 60 / matched
        let incomingBeatsOnly = (beatsBeforeVoice ?? .infinity) >= bar
        let wide = gap > outgoingStretch
        // Wider gaps lock only in a vocal throw: met in the middle when the new beats play alone
        // long enough, else carried by the old song alone up to `throwOutgoing`.
        guard !wide || gap <= throwOutgoing || (incomingBeatsOnly && gap <= throwStretch) else {
            return KnobShiftSync(isOn: false, outgoingTempo: a, incomingTempo: matched, meetingTempo: a, notes: [String(
                format: "Tempo sync off: %.1f to %.1f BPM%@ is %.0f%% apart, more than the %.0f%% two songs can meet without sounding broken.",
                a, matched, octave, gap * 100, (incomingBeatsOnly ? throwStretch : throwOutgoing) * 100)])
        }
        var meeting = matched
        if gap <= sameTempo {
            meeting = a
        } else if incomingBeatsOnly {
            meeting = gap <= glideStretch ? a : (a * matched).squareRoot()
            if abs(meeting / matched - 1) > incomingStretch {
                meeting = matched * (meeting > matched ? 1 + incomingStretch : 1 - incomingStretch)
            }
        }
        let direction = matched < a ? "slows" : "speeds up"
        var note = String(format: "Tempo sync on: %.1f to %.1f BPM%@, %.1f%% apart. ", a, matched, octave, gap * 100)
        if abs(meeting / a - 1) > sameTempo {
            note += String(format: "%@ to %.1f BPM over its last two bars, ", direction == "slows" ? "The old song slows" : "The old song speeds up", meeting)
        } else {
            note += "The old song starts at its own tempo, "
        }
        if abs(meeting / matched - 1) > sameTempo {
            note += String(format: "the new song's beats come in at %.1f BPM (%.0f%% off) and reach their own speed by the time its vocals start. ",
                           meeting, abs(meeting / matched - 1) * 100)
        } else {
            note += "the new song plays at its own speed throughout. "
        }
        note += gap <= sameTempo ? "Same tempo, no speed change needed."
            : String(format: "The old song %@ by %.0f%% in all, pitch stays natural.", direction, gap * 100)
        if wide { note += " Too far apart for a long mix, so it is a vocal throw: the old music drops out quickly." }
        return KnobShiftSync(isOn: true, outgoingTempo: a, incomingTempo: matched, meetingTempo: meeting, notes: [note], wide: wide)
    }

    /// The shared tempo `progress` (0...1) of the way through the blend. It moves from the
    /// meeting tempo to the incoming tempo by `voice`, the point where the incoming vocals start,
    /// and stays there.
    func tempo(progress: Double, voice: Double) -> Double {
        guard isOn else { return outgoingTempo }
        let x = voice > 0.001 ? min(max(progress / voice, 0), 1) : 1
        return meetingTempo + (incomingTempo - meetingTempo) * x * x * (3 - 2 * x)
    }

    /// Playback speeds for each deck so both play at the shared tempo.
    func rates(progress: Double, voice: Double) -> (outgoing: Double, incoming: Double) {
        guard isOn else { return (1, 1) }
        let shared = tempo(progress: progress, voice: voice)
        return (shared / outgoingTempo, shared / incomingTempo)
    }

    /// The outgoing song's speed `amount` of the way (0...1) through its ease before the blend.
    func easeRate(at amount: Double) -> Double {
        let smooth = amount * amount * (3 - 2 * amount)
        return 1 + (meetingTempo / outgoingTempo - 1) * smooth
    }

    /// Real time the blend takes to play `music` seconds of the outgoing song, which runs at
    /// changing speed during the blend.
    func blendLength(forOutgoingMusic music: TimeInterval, voice: Double) -> TimeInterval {
        guard isOn else { return music }
        let samples = 200
        let average = (0...samples).map { rates(progress: Double($0) / Double(samples), voice: voice).outgoing }
            .reduce(0, +) / Double(samples + 1)
        return music / average
    }
}
