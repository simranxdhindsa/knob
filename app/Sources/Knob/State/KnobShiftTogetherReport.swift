import Foundation

/// Listen Together's sound check in the log, every few seconds while a session runs, so how it
/// sounded can be matched with what each device was doing: how loud the mix was and whether any
/// of it was cut off, how closely this device followed the shared time, where its sound went,
/// and the effects it used.
@MainActor
final class KnobShiftTogetherReport {
    static let seconds = 5.0

    private var underruns = 0
    private var jumps = 0

    func reset() {
        underruns = 0
        jumps = 0
    }

    /// One line for the log. `capture` is the host's mix on its way out, `guest` what a listener
    /// receives, `player` what this device plays.
    func line(capture: KnobShiftTogetherCapture?, guest: KnobShiftTogetherGuest?, player: KnobShiftTogetherPlayer?,
              listening: Int?, lineUp: Double, soundOn: Bool?) -> String {
        var parts: [String] = []
        if let capture {
            let stats = capture.takeStats()
            parts.append("mix peak \(Self.decibels(stats.peak)), \(stats.clipped) frames cut off")
        }
        if let listening { parts.append("\(listening) listening") }
        if let guest {
            let stats = guest.takeStats()
            parts.append("\(stats.blocks) blocks in, peak \(Self.decibels(stats.peak))")
            if let trip = stats.trip { parts.append(String(format: "clock round trip %.1f ms", Double(trip) / 1e6)) }
        }
        if let ring = player?.ring.shared.pointee {
            parts.append(String(format: "%.1f ms from the shared time, speed %+.0f ppm", ring.error * 1000, ring.correction * 1e6))
            parts.append("\(ring.underruns - underruns) gaps and \(ring.jumps - jumps) jumps")
            underruns = ring.underruns
            jumps = ring.jumps
            if ring.level < 1 { parts.append("faded to \(Int(ring.level * 100))%") }
        }
        parts.append("line up \(Int((lineUp * 1000).rounded())) ms")
        if let soundOn { parts.append("Knob's sound \(soundOn ? "on" : "off")") }
        return "Sound check: " + parts.joined(separator: ", ") + "."
    }

    /// The effects by name, as the knobs show them, and the equalizer.
    static func describe(_ settings: KnobShiftTogether.Effects) -> String {
        let knobs = EffectSlot.allCases.compactMap { slot in
            settings.effects.indices.contains(slot.rawValue) ? "\(slot.title) \(String(format: "%.1f", settings.effects[slot.rawValue]))" : nil
        }
        let eq = settings.eq.allSatisfy { abs($0) < 0.001 } ? "EQ flat"
            : "EQ " + settings.eq.map { String(format: "%+.2f", $0) }.joined(separator: " ")
        return "\(settings.preset ?? "no preset"): " + (knobs + [eq]).joined(separator: ", ")
    }

    private static func decibels(_ peak: Float) -> String {
        peak > 0 ? String(format: "%.1f dB", 20 * log10(peak)) : "silent"
    }
}
