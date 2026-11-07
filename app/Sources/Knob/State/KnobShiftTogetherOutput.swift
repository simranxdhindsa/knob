import AVFoundation
#if os(macOS)
import CoreAudio
#endif

/// How long this device's output takes to reach the air. Measured with a microphone, a MacBook
/// speaker is 8 ms later than it reports, and going through Knob's own sound adds 30 ms more.
/// Other outputs start from what they report, and the line up slider covers the rest.
enum KnobShiftTogetherOutput {
    private static let speakerExtra = 0.008
    private static let throughKnob = 0.072

    static var name: String {
        #if os(macOS)
        deviceName(defaultDevice) ?? "Output"
        #else
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "Output"
        #endif
    }

    /// Where the sound goes, for the log: the device, its rate and how it connects. On the iPhone
    /// it also says when a microphone is open, which turns Bluetooth headphones to call quality.
    static var report: String {
        #if os(macOS)
        let device = defaultDevice
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        var kind: UInt32 = 0
        _ = read(device, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &kind)
        let transport = switch kind {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
        case kAudioDeviceTransportTypeBuiltIn: "built in"
        case kAudioDeviceTransportTypeVirtual: "virtual"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        default: "other"
        }
        return "\(name), \(Int(rate)) Hz, \(transport), \(Int((delay * 1000).rounded())) ms to the air"
        #else
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        let inputs = session.currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", ")
        return "\(outputs.isEmpty ? "no output" : outputs), \(Int(session.sampleRate)) Hz, \(session.category.rawValue), \(session.mode.rawValue), "
            + "microphone \(inputs.isEmpty ? "closed" : "open: \(inputs)"), \(Int((delay * 1000).rounded())) ms to the air"
        #endif
    }

    /// AirPlay holds sound back for about two seconds, far more than a session can make up for.
    static var isAirPlay: Bool {
        #if os(macOS)
        var kind: UInt32 = 0
        return read(defaultDevice, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, &kind) && kind == kAudioDeviceTransportTypeAirPlay
        #else
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        #endif
    }

    static var delay: TimeInterval {
        #if os(macOS)
        let device = defaultDevice
        if deviceName(device)?.hasPrefix("Knob") == true { return throughKnob }
        var rate = 48_000.0
        var size = UInt32(MemoryLayout<Double>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        var total: UInt32 = 0
        for selector in [kAudioDevicePropertyLatency, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyBufferFrameSize] {
            var value: UInt32 = 0
            if read(device, selector, kAudioObjectPropertyScopeOutput, &value) { total += value }
        }
        var streamSize: UInt32 = 0
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)
        if AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize >= 4 {
            var list = [AudioStreamID](repeating: 0, count: Int(streamSize) / 4)
            if AudioObjectGetPropertyData(device, &streams, 0, nil, &streamSize, &list) == noErr, let first = list.first {
                var value: UInt32 = 0
                if read(first, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal, &value) { total += value }
            }
        }
        return Double(total) / max(rate, 1) + speakerExtra
        #else
        let session = AVAudioSession.sharedInstance()
        return session.outputLatency + session.ioBufferDuration
        #endif
    }

    #if os(macOS)
    private static var defaultDevice: AudioObjectID {
        var device = AudioObjectID()
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ value: inout UInt32) -> Bool {
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: 0)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }
    #endif
}
