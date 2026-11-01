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
    }

    /// Moves the leaving song's effects with its exit, 0 at the handoff to 1 when it is gone.
    func applyExitEffects(_ exit: Double) {
        guard let style = exitStyle else { return }
        let deck = primaryDeck
        func ramp(_ from: Double, _ to: Double) -> Double { min(max((exit - from) / (to - from), 0), 1) }
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
