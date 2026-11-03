import AVFoundation
import AudioToolbox

/// Knob's sound as an audio unit in the iPhone app's audio graph, after KnobShift's mix and
/// before the speakers. Each block goes through the same effects code the Mac engine runs.
final class PhoneEffectUnit: AUAudioUnit {
    static let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                       componentSubType: 0x6b6e_6f62,        // "knob"
                                                       componentManufacturer: 0x4b6e_6f62,   // "Knob"
                                                       componentFlags: 0, componentFlagsMask: 0)
    /// The engine whose sound this unit plays; set before the unit is made (an audio unit is
    /// created by the system, so it can't be handed over in init).
    nonisolated(unsafe) static var engine: PhoneEngine?
    #if DEBUG
    /// Development checks: Knob's sound is measured (meters and spectrum) and then silenced, so
    /// a test in the simulator never plays through the Mac's speakers. KNOB_PHONE_SILENT=1.
    nonisolated(unsafe) static var silent = false
    #endif

    /// Registers the unit, makes one for `engine` and returns it, ready to connect.
    static func make(for engine: PhoneEngine) async throws -> AVAudioUnit {
        self.engine = engine
        AUAudioUnit.registerSubclass(PhoneEffectUnit.self, as: description, name: "Knob: Knob Sound", version: 1)
        return try await AVAudioUnit.instantiate(with: description, options: [])
    }

    private let dsp: OpaquePointer?
    private let input: AUAudioUnitBus
    private let output: AUAudioUnitBus
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    /// Interleaved stereo for the effects code, made with the unit: the audio engine may take
    /// the render block before it allocates render resources, so the block must never see a
    /// buffer that is not there yet. Blocks longer than this pass through untouched.
    private static let capacity = 4_096
    private let scratch = UnsafeMutablePointer<Float>.allocate(capacity: PhoneEffectUnit.capacity * 2)

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        dsp = Self.engine?.dsp
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        input = try AUAudioUnitBus(format: format)
        output = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [input])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [output])
        maximumFramesToRender = AUAudioFrameCount(Self.capacity)
    }

    deinit { scratch.deallocate() }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard let dsp else { return }
        var error = [CChar](repeating: 0, count: 256)
        if knob_phone_dsp_prepare(dsp, Int32(output.format.sampleRate), &error, error.count) != 0 {
            throw EngineError(message: String(cString: error))
        }
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        // Only plain values reach the audio thread: no self, nothing allocated while it plays.
        let dsp = dsp, scratch = scratch, capacity = Self.capacity
        #if DEBUG
        let silent = Self.silent
        #else
        let silent = false
        #endif
        return { _, timestamp, frames, _, outputData, _, pullInput in
            guard let pullInput else { return kAudioUnitErr_NoConnection }
            var flags = AudioUnitRenderActionFlags()
            let status = pullInput(&flags, timestamp, frames, 0, outputData)
            guard status == noErr else { return status }
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            let count = Int(frames)
            guard let dsp, count <= capacity, buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for frame in 0..<count {
                scratch[frame * 2] = left[frame]
                scratch[frame * 2 + 1] = right[frame]
            }
            knob_phone_dsp_render(dsp, scratch, count)
            for frame in 0..<count {
                left[frame] = silent ? 0 : scratch[frame * 2]
                right[frame] = silent ? 0 : scratch[frame * 2 + 1]
            }
            return noErr
        }
    }
}
