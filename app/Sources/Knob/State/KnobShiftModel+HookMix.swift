import Foundation

/// The sung mix, from the old song's last hook into the next song:
/// 1. The old song keeps playing its beats while its voice alone is pressed down: compressed
///    and muffled as if behind a wall, into a hall. Its speed and pitch stay as they are.
/// 2. The new song comes in a moment before its voice: in time with the old beats when the tempos
///    lock; after the old beats have left when they cannot, so two beats never clash.
/// 3. The new voice comes in 3 seconds before the old voice's last words end; the pressed old
///    voice sings them over it and rings away into the new song. Nothing is done to the new voice.
/// 4. The old song's beats and hall fade out and the mix completes.
/// Every curve eases in and out, so nothing starts or stops with a jump.
extension KnobShiftModel {
    /// One step of the mix. `progress` runs 0...1 over the mix, `entry` is where the new song
    /// comes in (the plan's handoff) and `wordsEnd` where the old voice's last words end.
    func applyHookMix(_ progress: Double, entry: Double, wordsEnd: Double, beatsIn: Double, length: TimeInterval, sync: KnobShiftSync,
                      rise riseTime: TimeInterval? = nil) {
        let p = min(max(progress, 0), 1)
        let locked = sync.isOn
        let second = 1 / max(length, 0.1)
        // Where the new voice comes in: on the old voice's last words.
        let newVoice = max(wordsEnd - KnobShiftPlan.handover * second, entry)
        // The press builds until the new voice comes in, then holds.
        let press = Self.shape(min(p / max(newVoice, 0.1), 1))
        // The old voice sings all of its last words over the new voice, then rings away into
        // the new song, gone `voiceRing` seconds after them.
        let voiceGone = min(wordsEnd + KnobShiftPlan.voiceRing * second, 1)
        let voice = p <= wordsEnd ? 1 : cos(Self.shape(min((p - wordsEnd) / max(voiceGone - wordsEnd, 0.01), 1)) * .pi / 2)
        // The old beats play on and fade out after the old voice's last words. Locked, the new
        // song's beats run with them; apart, they leave in the second before the new song's own
        // drums come in (`beatsIn`), so two beats never clash.
        let clash = !locked && beatsIn < 1
        let musicFrom = clash ? max(min(beatsIn - second, wordsEnd), 0) : wordsEnd
        let musicTo = clash ? max(beatsIn, musicFrom + 0.01) : 1
        let music = p <= musicFrom ? 1 : cos(Self.shape(min((p - musicFrom) / max(musicTo - musicFrom, 0.01), 1)) * .pi / 2)
        // The new song rises over the moment before its voice (a second when not measured);
        // locked it sits a little under the old beats until they leave.
        let riseShare = (riseTime ?? 1) / max(length, 0.1)
        let rise = p < entry ? 0 : Self.shape(min((p - entry) / max(riseShare, 0.001), 1))
        let incoming = locked ? min(1, 0.75 * rise + 0.25 * rise * (1 - music)) : rise

        // Tempo: while the old beats play, both songs hold the meeting tempo so they stay
        // locked; at the very end the new song glides to its own speed.
        if locked {
            let glide = Self.shape(min(max((p - 0.9) / 0.1, 0), 1))
            let shared = sync.meetingTempo + (sync.incomingTempo - sync.meetingTempo) * glide
            primaryDeck.rate = sync.meetingTempo / sync.outgoingTempo
            secondaryDeck.rate = shared / sync.incomingTempo
        } else {
            // Back to its own speed, gently if it had been eased toward a tempo it now won't meet.
            let rate = primaryDeck.rate
            primaryDeck.rate = rate + max(min(1 - rate, 0.004), -0.004)
            secondaryDeck.rate = 1
        }

        let old = primaryDeck
        old.tape = 0
        old.echoMix = 0
        old.lofiMix = 0
        throwingVoice = outgoingOnStems
        // The hall eases away over the last tenth, so its tail is not cut when the mix ends.
        let hall = 1 - Self.shape(min(max((p - 0.9) / 0.1, 0), 1))
        if outgoingOnStems {
            // The voice is separate: press it alone and leave the beats as they are.
            old.volume = 1
            old.musicStemLevel = Float(music)
            old.voiceLevel = Float(voice * (1 - 0.15 * press))
            old.voicePress = press
            old.throwVoice(speed: 1)
            old.voiceReverb = 0.6 * press * hall
            // The leaving beats lose some treble and wash into a hall as they go.
            old.sweep = 0.6 * (1 - music)
            old.reverbMix = 0.25 * (1 - music) * hall
        } else {
            // No separated voice: the whole old song is muffled and washed instead, and leaves
            // as its voice does.
            old.volume = Float(min(music, voice))
            old.sweep = max(0.55 * press, 1 - music)
            old.reverbMix = 0.35 * press * hall
        }
        // Two basslines never stack: when locked the new bass comes in as the old beats leave.
        old.bassCut = locked ? 1 - music : 0
        secondaryDeck.bassCut = locked ? music : 0
        // The new song is left as it is, its voice included.
        secondaryDeck.beatsOnly = 0
        if blendHasStems { secondaryDeck.voiceLevel = 1 }
        secondaryDeck.volume = Float(incoming)

        announce("hook mix stems", when: outgoingOnStems,
                 "Pressed voice: the old voice alone is compressed and muffled from 20 kHz down to 900 Hz into a hall, keeping its speed and pitch, while its beats keep playing.")
        announce("hook mix whole", when: !outgoingOnStems && p > 0.1,
                 "No separated voice ready, so the whole old song is muffled and washed into a hall as it leaves.")
        announce("hook mix new voice", when: p >= newVoice,
                 "The new voice comes in; the pressed old voice sings its last words over it and rings away into the new song.")
        let tenth = Int(p * 10 + 0.0001)
        if !effectsLogged.contains("hook \(tenth)") {
            effectsLogged.insert("hook \(tenth)")
            log("KNOBMIX", String(format: "+%.1fs %3.0f%% • old beats %3.0f%% • old voice %3.0f%%, pressed %3.0f%% • new song %3.0f%% • speeds %.3f / %.3f",
                                  p * length, p * 100, music * 100, (outgoingOnStems ? voice : min(music, voice)) * 100, press * 100,
                                  incoming * 100, primaryDeck.rate, secondaryDeck.rate))
        }
    }
}
