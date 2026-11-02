import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's audio devices, read straight from Core Audio (no engine needed).
struct HardwareDevice {
    let id: AudioObjectID
    let uid: String
    let transport: UInt32
    let hasOutput: Bool

    var isPhysicalOutput: Bool {
        hasOutput && uid != HardwareDevices.knobUID
            && transport != kAudioDeviceTransportTypeVirtual
            && transport != kAudioDeviceTransportTypeAggregate
            && transport != kAudioDeviceTransportTypeAutoAggregate
    }
}

enum HardwareDevices {
    /// Knob's own virtual output (driver/).
    static let knobUID = "Knob_Virtual"

    static func all() -> [HardwareDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(device)
    }

    static var defaultOutputID: AudioObjectID {
        var address = defaultOutputAddress
        var id = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    static func setDefaultOutput(_ id: AudioObjectID) {
        var address = defaultOutputAddress
        var value = id
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &value)
    }

    /// Where Knob should play the processed sound: the current output if it is real hardware,
    /// otherwise an external display or headphones, otherwise the built-in speakers.
    static func preferredPhysicalOutput() -> HardwareDevice? {
        let outputs = all().filter(\.isPhysicalOutput)
        if let current = outputs.first(where: { $0.id == defaultOutputID }) { return current }
        let external: Set<UInt32> = [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
                                     kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth]
        return outputs.first { external.contains($0.transport) } ?? outputs.first
    }

    static func device(uid: String) -> HardwareDevice? { all().first { $0.uid == uid } }

    /// A device's main output volume (0...1), or nil if it has none the app can set (HDMI).
    static func volume(of id: AudioObjectID) -> Double? {
        var address = mainVolumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value = Float32(0), size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    static func setVolume(_ volume: Double, of id: AudioObjectID) {
        var address = mainVolumeAddress
        var value = Float32(min(max(volume, 0), 1))
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    /// Whether a device's output is muted; nil when it has no mute the app can set.
    static func isMuted(_ id: AudioObjectID) -> Bool? {
        var address = muteAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value = UInt32(0), size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setMuted(_ muted: Bool, of id: AudioObjectID) {
        var address = muteAddress
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Calls `handler` on the main queue whenever the Mac's default output changes, whoever changed it.
    static func observeDefaultOutput(_ handler: @escaping () -> Void) {
        var address = defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
    }

    private static let muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static let mainVolumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    private static let defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    private static func device(_ id: AudioObjectID) -> HardwareDevice? {
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &size, &uid) == noErr,
              let name = uid?.takeRetainedValue() as String? else { return nil }

        var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                          mScope: kAudioObjectPropertyScopeGlobal,
                                                          mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &size, &transport)

        var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                        mScope: kAudioObjectPropertyScopeOutput,
                                                        mElement: kAudioObjectPropertyElementMain)
        var streamBytes: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamBytes)
        return HardwareDevice(id: id, uid: name, transport: transport, hasOutput: streamBytes > 0)
    }
}
