import Foundation

/// Tempo sync for one blend: while both songs are heard they play at one shared tempo, so their
/// beats stay together. Pitch is kept natural (time-stretching, not speeding up a tape).
///
/// - Close tempos glide: the shared tempo moves from the outgoing tempo to the incoming one
///   across the blend. The big speed change falls on whichever song is quiet at the time.
/// - Tempos further apart meet in the middle: in its last bars before the blend the outgoing
///   song eases to a tempo between the two, the incoming song comes in at that tempo with its
///   beats locked, both stay there while they overlap, and once the outgoing song has gone the
///   incoming song eases back to its own speed over two bars. Each song moves about half the
///   gap: the audible "slow down, beats mix, the next song speeds back up" of a DJ transition.
/// - Pairs too far apart for that blend at their own speeds.
/// The incoming song always ends the blend at its own normal speed.
struct KnobShiftSync {
    /// Largest gap the plain glide covers.
    static let glideStretch = 0.15
    /// Largest speed change either song makes when they meet in the middle.
    static let meetStretch = 0.20
    /// Both songs need a beat grid at least this trustworthy before beats are lined up.
    static let minimumConfidence = 0.6

    let isOn: Bool
    let outgoingTempo: Double
    /// The incoming tempo as matched: its own, or double or half when that is closer.
    let incomingTempo: Double
    /// The shared tempo when the incoming song comes in.
    let meetingTempo: Double
    let notes: [String]

    /// True when the outgoing song first eases to the meeting tempo on its own.
    var easesBeforeBlend: Bool { isOn && abs(meetingTempo / outgoingTempo - 1) > 0.001 }

    static let off = KnobShiftSync(isOn: false, outgoingTempo: 0, incomingTempo: 0, meetingTempo: 0, notes: [])

    static func make(outgoing: KnobShiftModel.Analysis, incoming: KnobShiftModel.Analysis) -> KnobShiftSync {
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
        if gap <= glideStretch {
            return KnobShiftSync(isOn: true, outgoingTempo: a, incomingTempo: matched, meetingTempo: a, notes: [String(
                format: "Tempo sync on: %.1f to %.1f BPM%@, %.1f%% apart. Both glide to a shared tempo, pitch stays natural.",
                a, matched, octave, gap * 100)])
        }
        let meeting = (a * matched).squareRoot()
        let outgoingMove = abs(meeting / a - 1), incomingMove = abs(meeting / matched - 1)
        guard max(outgoingMove, incomingMove) <= meetStretch else {
            return KnobShiftSync(isOn: false, outgoingTempo: a, incomingTempo: matched, meetingTempo: a, notes: [String(
                format: "Tempo sync off: %.1f to %.1f BPM%@ is %.0f%% apart. Even meeting in the middle would stretch a song by %.0f%%, beyond the %.0f%% that sounds natural.",
                a, matched, octave, gap * 100, max(outgoingMove, incomingMove) * 100, meetStretch * 100)])
        }
        let direction = meeting < a ? "slows" : "speeds up"
        return KnobShiftSync(isOn: true, outgoingTempo: a, incomingTempo: matched, meetingTempo: meeting, notes: [String(
            format: "Tempo sync on, meeting in the middle: %.1f to %.1f BPM%@ is %.0f%% apart. The outgoing song %@ to %.1f BPM (%.0f%%) before the blend, both stay locked there while they overlap, then the incoming song eases back from %.0f%% off its own speed.",
            a, matched, octave, gap * 100, direction, meeting, outgoingMove * 100, incomingMove * 100)])
    }

    /// The shared tempo once the blend is `shaped` of the way through (0...1). When the songs
    /// meet in the middle they stay at the meeting tempo for the whole overlap; the incoming
    /// song eases back to its own speed on its own afterwards (`incomingEase`).
    func tempo(at shaped: Double) -> Double {
        easesBeforeBlend ? meetingTempo : outgoingTempo + (incomingTempo - outgoingTempo) * shaped
    }

    /// The incoming song's speed `amount` of the way (0...1) through its ease back to normal
    /// after the outgoing song has gone.
    func incomingEase(at amount: Double) -> Double {
        let smooth = amount * amount * (3 - 2 * amount)
        let start = meetingTempo / incomingTempo
        return start + (1 - start) * smooth
    }

    /// Playback speeds for each deck so both play at the shared tempo.
    func rates(at shaped: Double) -> (outgoing: Double, incoming: Double) {
        guard isOn else { return (1, 1) }
        let shared = tempo(at: shaped)
        return (shared / outgoingTempo, shared / incomingTempo)
    }

    /// The outgoing song's speed `amount` of the way (0...1) through its ease before the blend.
    func easeRate(at amount: Double) -> Double {
        let smooth = amount * amount * (3 - 2 * amount)
        return 1 + (meetingTempo / outgoingTempo - 1) * smooth
    }

    /// Real time the blend takes to play `music` seconds of the outgoing song, which runs at
    /// changing speed during the glide. Averaged over the same curve the blend uses.
    func blendLength(forOutgoingMusic music: TimeInterval, curve: (Double) -> Double) -> TimeInterval {
        guard isOn else { return music }
        let samples = 200
        let average = (0...samples).map { rates(at: curve(Double($0) / Double(samples))).outgoing }
            .reduce(0, +) / Double(samples + 1)
        return music / average
    }
}
