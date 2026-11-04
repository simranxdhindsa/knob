import Foundation

/// The volume knob on the iPhone: the level of everything KnobShift plays, under the iPhone's
/// own volume buttons (which no app may set). Remembered between launches.
@MainActor
final class PhoneVolume: VolumeControl {
    var onChange: ((Double, Bool, Bool) -> Void)?
    /// Set once the panel model (which makes KnobShift) exists.
    var shift: KnobShiftModel? { didSet { apply() } }
    private var volume: Double
    private var muted = false

    init() {
        volume = UserDefaults.standard.object(forKey: PersistKey.lastVolume.rawValue) as? Double ?? 0.8
    }

    func start() { apply() }

    func setVolume(_ volume: Double) {
        self.volume = min(max(volume, 0), 1)
        muted = false
        UserDefaults.standard.set(self.volume, forKey: PersistKey.lastVolume.rawValue)
        apply()
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        apply()
    }

    private func apply() {
        shift?.outputVolume = Float(muted ? 0 : volume)
        onChange?(volume, muted, true)
    }
}
