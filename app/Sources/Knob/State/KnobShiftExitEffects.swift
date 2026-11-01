import AVFoundation

/// How the leaving song sounds as it goes. Apple Music's AutoMix gave its iOS 26 transitions an
/// "underwater" feel (a closing low-pass) and since iOS 27 varies its transition types between
/// songs, so KnobShift chooses one of these per song pair, all subtle. The choice is fixed for a
/// pair, so the same two songs always mix the same way. Effects apply to the leaving song only.
enum KnobShiftExitStyle: CaseIterable {
    case underwater, lofiDip, tapeSlowdown, echoOut, reverbWash

    var name: String {
        switch self {
        case .underwater: return "Underwater fade"
        case .lofiDip: return "Lo-fi dip"
        case .tapeSlowdown: return "Tape slowdown"
        case .echoOut: return "Echo out"
        case .reverbWash: return "Reverb wash"
        }
    }

    /// Tempos close enough to glide get a filter style; far apart, the beats would clash, so an
    /// echo or a reverb wash covers the change.
    static func choose(from current: KnobShiftModel.Track, to next: KnobShiftModel.Track,
                       sync: KnobShiftSync) -> (style: KnobShiftExitStyle, reason: String) {
        var pair = 0
        for scalar in (current.title + "→" + next.title).unicodeScalars {
            pair = (pair &* 31 &+ Int(scalar.value)) & 0xFFFF
        }
        if !sync.isOn {
            if current.analysis.fadeOutCue != nil, pair % 2 == 0 {
                return (.reverbWash, "the tempos are far apart and the old song fades out, so it dissolves into a hall")
            }
            return (.echoOut, "the tempos are far apart, so its last beats echo away instead of clashing")
        }
        let styles: [KnobShiftExitStyle] = [.underwater, .underwater, .lofiDip, .tapeSlowdown]
        let style = styles[pair % styles.count]
        return (style, "the tempos match, so a filter style keeps the beat going")
    }
}

extension KnobShiftModel {
    /// Readies the leaving song's effects at the start of a blend and announces the style.
    func armExitEffects(from current: Track, to next: Track, sync: KnobShiftSync) {
        let choice = KnobShiftExitStyle.choose(from: current, to: next, sync: sync)
        var beatsPerMinute = current.analysis.tempo ?? 120
        while beatsPerMinute > 140 { beatsPerMinute /= 2 }
        while beatsPerMinute < 70 { beatsPerMinute *= 2 }
        let beat = 60 / beatsPerMinute
        exitStyle = choice.style
        effectsLogged = []
        primaryDeck.armTransitionEffects(echoEvery: beat / 2, hall: choice.style == .reverbWash ? .largeHall : .mediumHall)
        log("EFFECT", "\(choice.style.name) on \(current.title): \(choice.reason).")
        log("EFFECT", String(format: "Beat pulse at %.1f BPM: the effects build between kicks and drop on every beat, to 0%% on the first beat of each bar, 50%% on the second and fourth, 10%% on the third.", 60 / beat))
    }

    /// How much of the exit effects to let through right now, following the leaving song's own
    /// beat: low on each kick (a deeper drop on the strong beats), rising back to full just
    /// before the next one. 1 when the beat is unknown.
    private static let beatDrops: [Double] = [0, 0.5, 0.1, 0.5]

    private func beatPulse() -> (level: Double, beatInBar: Int, bar: Int)? {
        guard let track = nowPlaying, let position = primaryDeck.position else { return nil }
        let grid = track.analysis.beatGrid
        guard grid.count > 8, let nextIndex = grid.firstIndex(where: { $0 > position }), nextIndex > 0 else { return nil }
        let previous = grid[nextIndex - 1], next = grid[nextIndex]
        let phase = min(max((position - previous) / max(next - previous, 0.05), 0), 1)
        // Bars counted from where the drums come in, four beats each.
        let entry = track.analysis.beatEntry ?? grid[0]
        let entryIndex = grid.firstIndex(where: { $0 >= entry - 0.05 }) ?? 0
        let count = nextIndex - 1 - entryIndex
        let beatInBar = ((count % 4) + 4) % 4
        let drop = Self.beatDrops[beatInBar]
        let rise = phase * phase * (3 - 2 * phase)
        return (drop + (1 - drop) * rise, beatInBar, count / 4)
    }

    /// Moves the leaving song's effects with its exit, 0 at the handoff to 1 when it is gone.
    func applyExitEffects(_ exit: Double) {
        guard let style = exitStyle else { return }
        let deck = primaryDeck
        let pulse = exit > 0 ? beatPulse() : nil
        let level = pulse?.level ?? 1
        if let pulse, pulse.beatInBar == 0, !effectsLogged.contains("bar \(pulse.bar)") {
            effectsLogged.insert("bar \(pulse.bar)")
            log("EFFECT", String(format: "Bar %d, beat 1: effects drop to 0%% on the kick, exit %.0f%% done.", pulse.bar + 1, exit * 100))
        }
        func ramp(_ from: Double, _ to: Double) -> Double { min(max((exit - from) / (to - from), 0), 1) }
        // The effect levels below follow the exit; each is then scaled by the beat pulse.
        defer {
            deck.reverbMix *= level
            deck.lofiMix *= level
            deck.echoMix *= level
            // The underwater filter half reopens on each kick, so the punch comes through.
            deck.sweep *= 0.5 + 0.5 * level
        }
        switch style {
        case .underwater:
            deck.reverbMix = 0.12 * ramp(0.5, 1)
        case .lofiDip:
            deck.lofiMix = 0.18 * ramp(0, 0.6)
            deck.reverbMix = 0.08 * ramp(0.5, 1)
        case .tapeSlowdown:
            deck.tape = ramp(0.15, 0.85)
            deck.reverbMix = 0.1 * ramp(0.5, 1)
        case .echoOut:
            deck.echoMix = 0.4 * ramp(0.3, 0.6)
        case .reverbWash:
            deck.reverbMix = 0.5 * ramp(0.2, 0.6)
        }
        announce("treble", when: exit > 0.01, "Treble fade on the leaving song: a low pass closing from 20 kHz to 1 kHz, the underwater sound.")
        announce("reverb", when: deck.reverbMix > 0.01, style == .reverbWash
                 ? "Reverb wash: large hall rising to 50%." : "Reverb tail: hall rising to \(Int((style == .underwater ? 0.12 : style == .lofiDip ? 0.08 : 0.1) * 100))%.")
        announce("lofi", when: deck.lofiMix > 0.01, "Lo-fi colour: vintage crunch rising to 18%.")
        announce("tape", when: deck.tape > 0.01, "Tape slowdown: the leaving song slows to 85% speed, its pitch dropping with it.")
        announce("echo", when: deck.echoMix > 0.01, "Echo out: repeats every half beat, 45% feedback, rising to 40%.")
    }

    private func announce(_ key: String, when active: Bool, _ message: String) {
        guard active, !effectsLogged.contains(key) else { return }
        effectsLogged.insert(key)
        log("EFFECT", message)
    }
}
