import AVFoundation

/// One of KnobShift's two players with its own effects:
/// player → time-stretch (tempo glide, pitch kept natural) → filters (bass, melody, treble) → KnobShift's mixer.
///
/// At normal speed the time-stretch unit passes audio through sample for sample, and the bass
/// filter rests at 10 Hz, below anything audible, so both stay connected all the time. Switching
/// effects in and out mid-song would cause a jump.
@MainActor
final class KnobShiftDeck {
    let name: String
    let player = AVAudioPlayerNode()
    /// Plays a song's separated voice beside `player` (which then plays its music), so the voice
    /// can be held back on its own while a new song comes in. Silent the rest of the time.
    let voice = AVAudioPlayerNode()
    /// Plays a leaving song's separated music while `voice` plays its separated voice, so its voice
    /// alone can slow down during a mix. Silent the rest of the time.
    let musicStem = AVAudioPlayerNode()
    /// Speed and reverb on the voice alone (the song's music keeps its own speed). At rest the
    /// speed unit passes audio through unchanged and the reverb is bypassed.
    private let voiceStretch = AVAudioUnitTimePitch()
    private let voiceRoom = AVAudioUnitReverb()
    private let submix = AVAudioMixerNode()
    private let stretch = AVAudioUnitTimePitch()
    private let filter = AVAudioUnitEQ(numberOfBands: 3)
    /// Transition effects for a song that is leaving (the lo-fi exit). Bypassed, so not in the
    /// sound at all, during normal playback.
    private let lofi = AVAudioUnitDistortion()
    private let echo = AVAudioUnitDelay()
    private let room = AVAudioUnitReverb()
    /// Where in its file this deck's current segment started.
    var startOffset: TimeInterval = 0

    init(name: String, engine: AVAudioEngine) {
        self.name = name
        let band = filter.bands[0]
        band.filterType = .highPass
        band.bypass = false
        band.frequency = Self.restingCutoff
        // A wide dip where vocals and melody sit, resting at 0 dB (no change).
        let melody = filter.bands[1]
        melody.filterType = .parametric
        melody.frequency = 1_500
        melody.bandwidth = 2
        melody.gain = 0
        melody.bypass = false
        // Treble fade for a leaving song, resting above anything audible.
        let treble = filter.bands[2]
        treble.filterType = .lowPass
        treble.frequency = Self.trebleRest
        treble.bypass = false
        engine.attach(player)
        engine.attach(voice)
        engine.attach(musicStem)
        engine.attach(voiceStretch)
        engine.attach(voiceRoom)
        voiceRoom.loadFactoryPreset(.largeHall)
        voiceRoom.wetDryMix = 0
        voiceRoom.bypass = true
        engine.attach(submix)
        engine.attach(stretch)
        engine.attach(filter)
        lofi.loadFactoryPreset(.drumsLoFi)
        echo.feedback = 45
        echo.lowPassCutoff = 3_500
        room.loadFactoryPreset(.mediumHall)
        for unit in [lofi, echo, room] as [AVAudioUnitEffect] { engine.attach(unit) }
        resetTransitionEffects()
        engine.connect(player, to: submix, format: nil)
        engine.connect(voice, to: voiceStretch, format: nil)
        engine.connect(voiceStretch, to: voiceRoom, format: nil)
        engine.connect(voiceRoom, to: submix, format: nil)
        engine.connect(musicStem, to: submix, format: nil)
        engine.connect(submix, to: stretch, format: nil)
        engine.connect(stretch, to: filter, format: nil)
        engine.connect(filter, to: lofi, format: nil)
        engine.connect(lofi, to: echo, format: nil)
        engine.connect(echo, to: room, format: nil)
        engine.connect(room, to: engine.mainMixerNode, format: nil)
    }

    private static let restingCutoff: Float = 10
    /// Highest cutoff during a bass swap: the bass and kick are gone, vocals and melody stay.
    private static let swapCutoff: Float = 200

    var volume: Float {
        get { submix.outputVolume }
        set { submix.outputVolume = newValue }
    }

    /// Level of the separated voice, 0...1.
    var voiceLevel: Float {
        get { voice.volume }
        set { voice.volume = newValue }
    }

    /// Level of the whole file (`player`); falls to 0 while a leaving song plays as separated
    /// music and voice instead, which add up to the same sound.
    var fileLevel: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    var musicStemLevel: Float {
        get { musicStem.volume }
        set { musicStem.volume = newValue }
    }

    /// Slows the voice alone, 0...1: at 1 it plays 15% slower with its pitch dropping with it.
    var voiceTape: Double = 0 {
        didSet {
            let factor = 1 - 0.15 * min(max(voiceTape, 0), 1)
            voiceStretch.rate = Float(factor)
            voiceStretch.pitch = Float(1_200 * log2(factor))
        }
    }

    /// Hall reverb on the voice alone, 0...1.
    /// The separated voice at `speed` of normal as heard (0.85 is 15% slower, its pitch falling
    /// like tape), whatever speed the whole deck plays at to stay on the beat.
    func throwVoice(speed: Double) {
        let heard = min(max(speed, 0.5), 1)
        voiceStretch.rate = Float(heard / max(stretch.rate == 0 ? 1 : Double(stretch.rate), 0.1))
        voiceStretch.pitch = Float(1_200 * log2(heard))
    }

    var voiceReverb: Double = 0 {
        didSet {
            let wet = min(max(voiceReverb, 0), 1)
            voiceRoom.wetDryMix = Float(wet * 100)
            voiceRoom.bypass = wet <= 0.001
        }
    }

    func stop() {
        player.stop()
        voice.stop()
        musicStem.stop()
    }

    func pause() {
        player.pause()
        voice.pause()
        musicStem.pause()
    }

    func resume() {
        player.play()
        voice.play()
        musicStem.play()
    }

    /// Playback speed with natural pitch: 1 is normal.
    var rate: Double {
        get { baseRate }
        set { baseRate = min(max(newValue, 0.5), 2); applySpeed() }
    }
    private var baseRate = 1.0

    /// The slowdown, 0...1.2: at 1 the song plays 10% slower with its natural pitch, the smooth
    /// glide KnobShift's first tempo meetings had, rather than a tape's falling pitch.
    var tape: Double = 0 { didSet { applySpeed() } }
    private static let slowdownAtFull = 0.10

    private func applySpeed() {
        let factor = 1 - Self.slowdownAtFull * min(max(tape, 0), 1.2)
        stretch.rate = Float(baseRate * factor)
        stretch.pitch = 0
    }

    /// Lo-fi colour, echo and reverb share, each 0...1.
    var lofiMix: Double = 0 { didSet { lofi.wetDryMix = Float(min(max(lofiMix, 0), 1) * 100) } }
    var echoMix: Double = 0 { didSet { echo.wetDryMix = Float(min(max(echoMix, 0), 1) * 100) } }
    var reverbMix: Double = 0 { didSet { room.wetDryMix = Float(min(max(reverbMix, 0), 1) * 100) } }

    /// Turns the transition effects on for a leaving song, with echoes `echoEvery` seconds apart
    /// and the given hall for its reverb.
    func armTransitionEffects(echoEvery: TimeInterval, hall: AVAudioUnitReverbPreset) {
        echo.delayTime = min(max(echoEvery, 0.05), 2)
        room.loadFactoryPreset(hall)
        lofiMix = 0
        echoMix = 0
        reverbMix = 0
        for unit in [lofi, echo, room] as [AVAudioUnitEffect] { unit.bypass = false }
    }

    /// Takes the transition effects back out of the sound. Called only when the deck is silent
    /// (loading its next song), so the echo and reverb tails of a mix always ring out.
    func resetTransitionEffects() {
        tape = 0
        lofiMix = 0
        echoMix = 0
        reverbMix = 0
        for unit in [lofi, echo, room] as [AVAudioUnitEffect] {
            unit.bypass = true
            unit.reset()
        }
    }

    /// 0 keeps the full bass, 1 removes it (used to swap basslines during a blend).
    var bassCut: Double = 0 { didSet { updateFilter() } }

    /// Treble fade on a song that is leaving, as Apple Music's AutoMix does: 0 is the full song,
    /// 1 has closed a low-pass down to 1 kHz, so its top end goes first and its middle lingers.
    var sweep: Double = 0 {
        didSet { filter.bands[2].frequency = Self.trebleRest * powf(Self.trebleClosed / Self.trebleRest, Float(min(max(sweep, 0), 1))) }
    }

    private static let trebleRest: Float = 20_000
    private static let trebleClosed: Float = 1_000

    /// 1 holds back the melody and vocal range (12 dB dip around 1.5 kHz) so mostly the beats
    /// come through; 0 is the full song. Used while a new song enters under the old voice.
    var beatsOnly: Double = 0 {
        didSet { filter.bands[1].gain = -12 * Float(min(max(beatsOnly, 0), 1)) }
    }

    private func updateFilter() {
        let bass = Float(min(max(bassCut, 0), 1))
        filter.bands[0].frequency = Self.restingCutoff * powf(Self.swapCutoff / Self.restingCutoff, bass)
    }

    /// Back to plain playback after a blend.
    func resetEffects() {
        rate = 1
        tape = 0
        bassCut = 0
        sweep = 0
        beatsOnly = 0
        volume = 1
        voiceLevel = 1
        fileLevel = 1
        musicStemLevel = 1
        voiceTape = 0
        voiceReverb = 0
    }

    /// File position this deck has really reached, read from the audio engine. The player
    /// counts file samples, so this stays right while the time-stretch changes speed.
    var position: TimeInterval? {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return startOffset + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    #if DEBUG
    /// Development checks only: hands the deck's finished sound (after every effect) to the
    /// demo recorder.
    func recordOutput(into recorder: KnobShiftDemoRecorder) {
        room.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, time in recorder.add(buffer, at: time) }
    }
    #endif
}
