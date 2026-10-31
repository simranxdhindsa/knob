import Foundation

/// Tempo sync for one blend: both songs play at one shared tempo that glides from the outgoing
/// song's tempo to the incoming song's, so their beats stay together while the volumes cross.
/// Pitch is kept natural (time-stretching, not speeding up a tape).
///
/// The outgoing song ends the blend at the incoming tempo; the incoming song starts at the
/// outgoing tempo and ends at its own normal speed, so nothing is stretched once the blend is
/// over. Pairs too far apart to stretch cleanly blend without tempo sync.
struct KnobShiftSync {
    /// Largest tempo gap to glide across. The big speed change always falls on the quiet deck
    /// (the outgoing song near its end, the incoming song near its start), which hides it; past
    /// this the stretched song starts to sound processed even at low volume.
    static let maxStretch = 0.15
    /// Both songs need a beat grid at least this trustworthy before beats are lined up.
    static let minimumConfidence = 0.6

    let isOn: Bool
    let outgoingTempo: Double
    /// The incoming tempo as matched: its own, or double or half when that is closer.
    let incomingTempo: Double
    let notes: [String]

    static let off = KnobShiftSync(isOn: false, outgoingTempo: 0, incomingTempo: 0, notes: [])

    static func make(outgoing: KnobShiftModel.Analysis, incoming: KnobShiftModel.Analysis) -> KnobShiftSync {
        guard let a = outgoing.tempo, let b = incoming.tempo else {
            return KnobShiftSync(isOn: false, outgoingTempo: 0, incomingTempo: 0,
                                 notes: ["Tempo sync off: a tempo is missing, so the songs keep their own speed."])
        }
        guard min(outgoing.tempoConfidence, incoming.tempoConfidence) >= minimumConfidence else {
            return KnobShiftSync(isOn: false, outgoingTempo: a, incomingTempo: b, notes: [String(
                format: "Tempo sync off: beat confidence %.0f%% and %.0f%%, both need %.0f%% to line up beats safely.",
                outgoing.tempoConfidence * 100, incoming.tempoConfidence * 100, minimumConfidence * 100)])
        }
        let matched = [b, b * 2, b / 2].min { abs(log($0 / a)) < abs(log($1 / a)) } ?? b
        let stretch = abs(matched / a - 1)
        let octave = matched == b ? "" : (matched > b ? " (counted at double time)" : " (counted at half time)")
        guard stretch <= maxStretch else {
            return KnobShiftSync(isOn: false, outgoingTempo: a, incomingTempo: matched, notes: [String(
                format: "Tempo sync off: %.1f to %.1f BPM%@ is %.1f%% apart, beyond the %.0f%% that can glide naturally.",
                a, matched, octave, stretch * 100, maxStretch * 100)])
        }
        return KnobShiftSync(isOn: true, outgoingTempo: a, incomingTempo: matched, notes: [String(
            format: "Tempo sync on: %.1f to %.1f BPM%@, %.1f%% apart. Both glide to a shared tempo, pitch stays natural.",
            a, matched, octave, stretch * 100)])
    }

    /// The shared tempo once the blend is `shaped` of the way through (0...1).
    func tempo(at shaped: Double) -> Double {
        outgoingTempo + (incomingTempo - outgoingTempo) * shaped
    }

    /// Playback speeds for each deck so both play at the shared tempo.
    func rates(at shaped: Double) -> (outgoing: Double, incoming: Double) {
        guard isOn else { return (1, 1) }
        let shared = tempo(at: shaped)
        return (shared / outgoingTempo, shared / incomingTempo)
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
