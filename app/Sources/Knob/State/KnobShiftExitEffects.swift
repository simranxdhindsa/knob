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
        let pair = seed(current, next)
        if !sync.isOn {
            if current.analysis.fadeOutCue != nil, pair % 2 == 0 {
                return (.reverbWash, "the tempos are far apart and the old song fades out, so it dissolves into a hall")
            }
            return (.echoOut, "the tempos are far apart, so its last beats echo away instead of clashing")
        }
        let styles: [KnobShiftExitStyle] = [.underwater, .lofiDip, .tapeSlowdown]
        let style = styles[pair % styles.count]
        return (style, "the tempos match, so a filter style keeps the beat going")
    }

    /// A number fixed for a pair of songs, so the same two songs always mix the same way.
    static func seed(_ current: KnobShiftModel.Track, _ next: KnobShiftModel.Track) -> Int {
        var pair = 0
        for scalar in (current.title + "→" + next.title).unicodeScalars {
            pair = (pair &* 31 &+ Int(scalar.value)) & 0xFFFF
        }
        return pair
    }

    /// The effects' strength at their peak for a pair: 40%, 45% or 50%, never more.
    static func strength(_ current: KnobShiftModel.Track, _ next: KnobShiftModel.Track) -> Double {
        0.4 + 0.05 * Double((seed(current, next) / 3) % 3)
    }

    /// One beat of a song, its tempo folded into 70...140 BPM; half a second when unknown.
    static func beat(of track: KnobShiftModel.Track) -> TimeInterval {
        var beatsPerMinute = track.analysis.tempo ?? 120
        while beatsPerMinute > 140 { beatsPerMinute /= 2 }
        while beatsPerMinute < 70 { beatsPerMinute *= 2 }
        return 60 / beatsPerMinute
    }
}

extension KnobShiftModel {
    /// Readies the leaving song's effects at the start of a blend and announces the style.
    func armExitEffects(from current: Track, to next: Track, sync: KnobShiftSync) {
        let choice = KnobShiftExitStyle.choose(from: current, to: next, sync: sync)
        let beat = KnobShiftExitStyle.beat(of: current)
        let beatsPerMinute = 60 / beat
        exitStyle = choice.style
        exitStrength = KnobShiftExitStyle.strength(current, next)
        effectsLogged = []
        // Slow, laid back songs take a deeper tape slowdown; fast, energetic ones only a touch.
        tapeDepth = min(max((130 - beatsPerMinute) / 60, 0.1), 0.6)
        primaryDeck.armTransitionEffects(echoEvery: beat / 2, hall: choice.style == .reverbWash ? .largeHall : .mediumHall)
        log("EFFECT", "\(choice.style.name) on \(current.title): \(choice.reason). Peak strength \(Int((exitStrength * 100).rounded()))%.")
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
    /// `exit` runs 0...1 through the leaving song's fade; `envelope` is the effects' keyframe
    /// curve over the whole mix: 0 at its start, full at its middle, 0 again when it completes.
    func applyExitEffects(_ exit: Double, envelope: Double) {
        guard let style = exitStyle else { return }
        let deck = primaryDeck
        let pulse = envelope > 0.01 ? beatPulse() : nil
        let level = pulse?.level ?? 1
        if let pulse, pulse.beatInBar == 0, !effectsLogged.contains("bar \(pulse.bar)") {
            effectsLogged.insert("bar \(pulse.bar)")
            log("EFFECT", String(format: "Bar %d, beat 1: effects drop to 0%% on the kick, exit %.0f%% done.", pulse.bar + 1, exit * 100))
        }
        // The effect levels below follow the keyframe curve; each is then scaled by the beat pulse.
        defer {
            deck.reverbMix *= level
            deck.lofiMix *= level
            deck.echoMix *= level
            // The underwater filter half reopens on each kick, so the punch comes through.
            deck.sweep *= 0.5 + 0.5 * level
        }
        switch style {
        case .underwater:
            deck.reverbMix = 0.12 * envelope
        case .lofiDip:
            deck.lofiMix = 0.18 * envelope
            deck.reverbMix = 0.08 * envelope
        case .tapeSlowdown:
            deck.tape = tapeDepth * envelope
            deck.reverbMix = 0.1 * envelope
        case .echoOut:
            deck.echoMix = 0.4 * envelope
        case .reverbWash:
            deck.reverbMix = 0.5 * envelope
        }
        // The singers: the old voice alone slows down and gains a hall while its music keeps the
        // new song's beat; the new voice arrives through a reverb that clears as it takes over.
        if outgoingOnStems {
            deck.voiceTape = tapeDepth * envelope
            deck.voiceReverb = 0.25 * envelope
        }
        if blendHasStems { secondaryDeck.voiceReverb = 0.35 * envelope }
        announce("old voice", when: outgoingOnStems && envelope > 0.01, String(format: "Old voice alone slows down, to %.0f%% speed at the peak where it ends, with a hall on it; its music keeps the beat.", (1 - 0.15 * tapeDepth * exitStrength) * 100))
        announce("new voice", when: blendHasStems && envelope > 0.01, "New voice comes in through a reverb that clears as it takes over.")
        announce("treble", when: exit > 0.01, "Treble fade on the leaving song: a low pass closing from 20 kHz to 1 kHz, the underwater sound.")
        announce("reverb", when: deck.reverbMix > 0.01, style == .reverbWash
                 ? "Reverb wash: large hall rising to 50%." : "Reverb tail: hall rising to \(Int((style == .underwater ? 0.12 : style == .lofiDip ? 0.08 : 0.1) * 100))%.")
        announce("lofi", when: deck.lofiMix > 0.01, "Lo-fi colour: vintage crunch rising to 18%.")
        announce("tape", when: deck.tape > 0.01, String(format: "Tape slowdown at %.0f%% depth for this song: it slows to %.0f%% speed, its pitch dropping with it.",
                                                        tapeDepth * 100, (1 - 0.15 * tapeDepth * exitStrength) * 100))
        announce("echo", when: deck.echoMix > 0.01, "Echo out: repeats every half beat, 45% feedback, rising to 40%.")
    }

    private func announce(_ key: String, when active: Bool, _ message: String) {
        guard active, !effectsLogged.contains(key) else { return }
        effectsLogged.insert(key)
        log("EFFECT", message)
    }
}
