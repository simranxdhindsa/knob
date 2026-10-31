import AVFoundation

/// One of KnobShift's two players with its own effects:
/// player → time-stretch (tempo glide, pitch kept natural) → bass filter → KnobShift's mixer.
///
/// At normal speed the time-stretch unit passes audio through sample for sample, and the bass
/// filter rests at 10 Hz, below anything audible, so both stay connected all the time. Switching
/// effects in and out mid-song would cause a jump.
@MainActor
final class KnobShiftDeck {
    let name: String
    let player = AVAudioPlayerNode()
    private let stretch = AVAudioUnitTimePitch()
    private let filter = AVAudioUnitEQ(numberOfBands: 2)
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
        engine.attach(player)
        engine.attach(stretch)
        engine.attach(filter)
        engine.connect(player, to: stretch, format: nil)
        engine.connect(stretch, to: filter, format: nil)
        engine.connect(filter, to: engine.mainMixerNode, format: nil)
    }

    private static let restingCutoff: Float = 10
    /// Highest cutoff during a bass swap: the bass and kick are gone, vocals and melody stay.
    private static let swapCutoff: Float = 200

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    /// Playback speed with natural pitch: 1 is normal.
    var rate: Double {
        get { Double(stretch.rate) }
        set { stretch.rate = Float(min(max(newValue, 0.5), 2)) }
    }

    /// 0 keeps the full bass, 1 removes it (used to swap basslines during a blend).
    var bassCut: Double = 0 { didSet { updateFilter() } }

    /// Rising filter on a song that is leaving: 0 stops at the bass, 1 thins it out up to
    /// 2 kHz so its beats seem to float upward into the next song.
    var sweep: Double = 0 { didSet { updateFilter() } }

    private static let sweepCutoff: Float = 2_000

    /// 1 holds back the melody and vocal range (12 dB dip around 1.5 kHz) so mostly the beats
    /// come through; 0 is the full song. Used while a new song enters under the old voice.
    var beatsOnly: Double = 0 {
        didSet { filter.bands[1].gain = -12 * Float(min(max(beatsOnly, 0), 1)) }
    }

    private func updateFilter() {
        let bass = Float(min(max(bassCut, 0), 1))
        let lift = Float(min(max(sweep, 0), 1))
        let base = Self.restingCutoff * powf(Self.swapCutoff / Self.restingCutoff, bass)
        filter.bands[0].frequency = base * powf(Self.sweepCutoff / Self.swapCutoff, lift)
    }

    /// Back to plain playback after a blend.
    func resetEffects() {
        rate = 1
        bassCut = 0
        sweep = 0
        beatsOnly = 0
        volume = 1
    }

    /// File position this deck has really reached, read from the audio engine. The player
    /// counts file samples, so this stays right while the time-stretch changes speed.
    var position: TimeInterval? {
        guard let nodeTime = player.lastRenderTime, let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return nil }
        return startOffset + max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }
}
