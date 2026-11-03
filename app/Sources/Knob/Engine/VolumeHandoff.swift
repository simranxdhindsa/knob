import Foundation

/// Keeps the volume the same when Knob takes over the sound output and when it hands it back.
///
/// Taking over: Knob's device gets the physical output's volume, and the physical output goes
/// to 100% underneath so loudness doesn't change. An output with no volume of its own (HDMI)
/// gets Knob's last remembered level instead. Handing back: the physical output gets Knob's
/// current level. What was raised to 100% is saved to disk, so a later run (after a crash or a
/// relaunch) can always put it back and never leaves speakers stuck at full volume. Mute moves
/// the same way: a muted output is unmuted underneath and Knob's device takes the mute, so a
/// mute set before Knob took over never silences Knob's sound with no way to see it.
@MainActor
enum VolumeHandoff {
    private static let fallbackLevel = 0.5

    /// Remembers Knob's level while it is the output, for outputs without their own volume.
    static func remember(_ level: Double) {
        UserDefaults.standard.set(level, forKey: PersistKey.lastVolume.rawValue)
    }

    static func takeOver(from physical: HardwareDevice?) {
        guard let knob = HardwareDevices.device(uid: HardwareDevices.knobUID) else { return }
        if let physical, HardwareDevices.isMuted(physical.id) == true {
            HardwareDevices.setMuted(true, of: knob.id)
            HardwareDevices.setMuted(false, of: physical.id)
        }
        if let physical, let level = HardwareDevices.volume(of: physical.id) {
            if pending == nil { UserDefaults.standard.set(physical.uid, forKey: PersistKey.raisedOutputUID.rawValue) }
            HardwareDevices.setVolume(level, of: knob.id)
            HardwareDevices.setVolume(1, of: physical.id)
            remember(level)
        } else {
            let saved = UserDefaults.standard.object(forKey: PersistKey.lastVolume.rawValue) as? Double
            HardwareDevices.setVolume(saved ?? fallbackLevel, of: knob.id)
        }
    }

    /// Puts the raised physical output back to Knob's current (or last remembered) level.
    static func giveBack() {
        guard let uid = pending else { return }
        UserDefaults.standard.removeObject(forKey: PersistKey.raisedOutputUID.rawValue)
        guard let physical = HardwareDevices.device(uid: uid) else { return }
        let knobLevel = HardwareDevices.device(uid: HardwareDevices.knobUID).flatMap { HardwareDevices.volume(of: $0.id) }
        let saved = UserDefaults.standard.object(forKey: PersistKey.lastVolume.rawValue) as? Double
        HardwareDevices.setVolume(knobLevel ?? saved ?? fallbackLevel, of: physical.id)
        if let knob = HardwareDevices.device(uid: HardwareDevices.knobUID), let muted = HardwareDevices.isMuted(knob.id) {
            HardwareDevices.setMuted(muted, of: physical.id)
        }
    }

    private static var pending: String? { UserDefaults.standard.string(forKey: PersistKey.raisedOutputUID.rawValue) }
}
