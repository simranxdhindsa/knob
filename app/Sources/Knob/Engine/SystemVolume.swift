import AudioToolbox
import CoreAudio
import Foundation

/// Reads and writes the default output device's main volume through Core Audio and follows
/// changes made anywhere else (volume keys, Control Center, switching outputs).
final class SystemVolume: VolumeControl {
    var onChange: ((Double, Bool, Bool) -> Void)?
    private var device = AudioObjectID(kAudioObjectUnknown)
    private let queue = DispatchQueue.main
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebind() }
    private lazy var valueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.publish() }

    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    private static var mainVolume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    func start() {
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, queue, deviceListener)
        rebind()
    }

    func setVolume(_ volume: Double) {
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(device, &Self.mainVolume, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
        if volume > 0, muted { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private var muted: Bool {
        var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectHasProperty(device, &Self.mute)
            && AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &value) == noErr && value != 0
    }

    private func rebind() {
        if device != kAudioObjectUnknown {
            AudioObjectRemovePropertyListenerBlock(device, &Self.mainVolume, queue, valueListener)
            AudioObjectRemovePropertyListenerBlock(device, &Self.mute, queue, valueListener)
        }
        var id = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil, &size, &id)
        device = id
        AudioObjectAddPropertyListenerBlock(device, &Self.mainVolume, queue, valueListener)
        AudioObjectAddPropertyListenerBlock(device, &Self.mute, queue, valueListener)
        publish()
        // A device that has just become the output (Knob's own, as the engine starts) can answer
        // "no volume" for a moment, which left the panel saying Fixed. Look again shortly after.
        let bound = device
        for delay in [0.5, 1.5, 4.0] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.device == bound else { return }
                self.publish()
            }
        }
    }

    private func publish() {
        var settable: DarwinBoolean = false
        let controllable = AudioObjectHasProperty(device, &Self.mainVolume)
            && AudioObjectIsPropertySettable(device, &Self.mainVolume, &settable) == noErr && settable.boolValue
        var value = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        if controllable { AudioObjectGetPropertyData(device, &Self.mainVolume, 0, nil, &size, &value) }
        onChange?(Double(value), muted, controllable)
    }
}

/// A fixed volume for demo and snapshot runs, so screenshots never touch the real Mac volume.
final class DemoVolume: VolumeControl {
    var onChange: ((Double, Bool, Bool) -> Void)?
    private var volume = 0.72
    private var muted = false
    func start() { onChange?(volume, muted, true) }
    func setVolume(_ volume: Double) { self.volume = volume; onChange?(volume, muted, true) }
    func setMuted(_ muted: Bool) { self.muted = muted; onChange?(volume, muted, true) }
}
