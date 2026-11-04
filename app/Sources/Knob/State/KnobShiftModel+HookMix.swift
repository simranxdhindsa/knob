import Foundation

/// The sung mix, from the old song's last hook into the next song:
/// 1. The old song keeps playing its beats while its voice alone is pressed down: compressed
///    and muffled as if behind a wall, into a hall. Its speed and pitch stay as they are.
/// 2. The new song comes in up to 2 seconds before its voice, from the beginning of the mix when
///    it can, in a hall and muffled, so it never just appears: in time with the old beats when the
///    tempos lock; starting a little slow, reaching its own speed with its voice, when they cannot.
/// 3. The new voice comes in half way to the old voice's last words; the pressed old voice sinks under it,
///    sings its last words and rings away into the new song. The hall and muffling on the new song
///    clear soon after its voice comes in, and the voice itself is never slowed.
/// 4. The old song's beats and hall fade out and the mix completes.
/// Every curve eases in and out, so nothing starts or stops with a jump.
extension KnobShiftModel {
    /// One step of the mix. `progress` runs 0...1 over the mix, `entry` is where the new song
    /// comes in (the plan's handoff) and `wordsEnd` where the old voice's last words end.
    func applyHookMix(_ progress: Double, entry: Double, wordsEnd: Double, beatsIn: Double, length: TimeInterval, sync: KnobShiftSync,
                      rise riseTime: TimeInterval? = nil, voiceAt: Double? = nil) {
        let p = min(max(progress, 0), 1)
        let locked = sync.isOn
        let second = 1 / max(length, 0.1)
        // Where the new voice comes in (on the old voice's last words when not measured).
        let newVoice = voiceAt ?? max(wordsEnd - KnobShiftPlan.handover * second, entry)
        // The press builds until the new voice comes in, then holds.
        let press = Self.shape(min(p / max(newVoice, 0.1), 1))
        // The old voice sings all of its last words over the new voice, then rings away into
        // the new song, gone `voiceRing` seconds after them. Its level comes after its hall, so
        // this is also how long the hall's tail is heard.
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
        // locked it sits a little under the old beats, then comes up to full over the two seconds
        // after its voice arrives.
        let riseShare = (riseTime ?? 1) / max(length, 0.1)
        let rise = p < entry ? 0 : Self.shape(min((p - entry) / max(riseShare, 0.001), 1))
        let voiceUp = Self.shape(min(max((p - newVoice) / max(2 * second, 0.001), 0), 1))
        let incoming = locked ? rise * (0.75 + 0.25 * max(voiceUp, 1 - music)) : rise
        // The new song arrives in a hall and muffled, and comes clear soon after its voice. Drums
        // that land with the voice cannot come in ahead of it, so they rise out of the hall for
        // twice as long instead of arriving all at once.
        let drumsWithVoice = abs(beatsIn - newVoice) <= second
        let clear = min(newVoice + (drumsWithVoice ? 2 : 1) * KnobShiftPlan.washEnds * second, 0.97)
        let wash = 1 - Self.shape(min(max((p - entry) / max(clear - entry, 0.001), 0), 1))
        // Once the new voice sings, the old voice sinks under it, by up to 40%, over at least two
        // seconds, so the two are not fighting for the same place.
        let sink = 0.4 * Self.shape(min(max((p - newVoice) / max(wordsEnd - newVoice, 2 * second, 0.001), 0), 1))

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
            // The new song's music starts slow and reaches its own speed as its voice comes in.
            // With under a second of music there is nothing to slow.
            let reach = Self.shape(min(max((p - entry) / max(newVoice - entry, 0.001), 0), 1))
            let slows = (newVoice - entry) * length >= 1
            secondaryDeck.rate = slows ? KnobShiftPlan.introSpeed + (1 - KnobShiftPlan.introSpeed) * reach : 1
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
            old.voiceLevel = Float(voice * (1 - 0.15 * press) * (1 - sink))
            old.voicePress = press
            // The voice follows its deck's speed like its music, at natural pitch. Held at normal
            // speed, the trace of it left in the music sang the same line seconds apart from it.
            old.voiceTape = 0
            old.voiceReverb = 0.8 * press * hall
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
        // The new song's melody and voice are not held back; only the hall and muffling touch it.
        secondaryDeck.beatsOnly = 0
        // Each effect rises from nothing in half a second as the song arrives, never already full.
        let arrive = p < entry ? 0 : Self.shape(min((p - entry) / max(0.5 * second, 0.001), 1))
        secondaryDeck.sweep = 0.7 * wash * arrive
        secondaryDeck.reverbMix = 0.45 * wash * arrive
        if blendHasStems { secondaryDeck.voiceLevel = 1 }
        secondaryDeck.volume = Float(incoming)

        announce("hook mix stems", when: outgoingOnStems,
                 "Pressed voice: the old voice alone is compressed and muffled from 20 kHz down to 900 Hz into a hall, keeping its speed and pitch, while its beats keep playing.")
        announce("hook mix whole", when: !outgoingOnStems && p > 0.1,
                 "No separated voice ready, so the whole old song is muffled and washed into a hall as it leaves.")
        announce("hook mix new wash", when: p >= entry,
                 "The new song comes in muffled and in a hall, clearing soon after its voice arrives.")
        announce("hook mix new voice", when: p >= newVoice,
                 "The new voice comes in; the pressed old voice sinks under it, sings its last words and rings away into the new song.")
        let tenth = Int(p * 10 + 0.0001)
        if !effectsLogged.contains("hook \(tenth)") {
            effectsLogged.insert("hook \(tenth)")
            log("KNOBMIX", String(format: "+%.1fs %3.0f%% • old beats %3.0f%% • old voice %3.0f%%, pressed %3.0f%% • new song %3.0f%%, its voice %3.0f%% (%@) • speeds %.3f / %.3f",
                                  p * length, p * 100, music * 100, (outgoingOnStems ? voice : min(music, voice)) * 100, press * 100,
                                  incoming * 100, secondaryDeck.voiceLevel * 100, blendHasStems ? (secondaryDeck.voice.isPlaying ? "playing" : "NOT PLAYING") : "in the file",
                                  primaryDeck.rate, secondaryDeck.rate))
        }
    }
}
