import AVFoundation

/// A song under a hand, the way a record plays it. The player's decks can only play forward at
/// their own speed, so while a hand is on the iPhone's record the song comes from here instead:
/// held in memory, it plays at any speed in either direction, and slowing it down drops its pitch
/// because that is simply what happens. A stopped record is silent, not a held note, since a
/// stylus only makes a sound while the groove moves under it.
final class KnobShiftScratch {
    /// What the audio thread and the rest of the app share. Plain numbers only: the audio thread
    /// takes no locks and allocates nothing, and each side writes its own fields.
    struct Shared {
        var samples: UnsafePointer<Int16>?
        var frames = 0
        /// Song frames per output frame at normal speed.
        var step = 1.0
        var position = 0.0
        var speed = 0.0
        var targetSpeed = 0.0
        /// How quickly speed follows its target, per output frame.
        var follow = 0.01
        var level: Float = 0
        var targetLevel: Float = 0
        var levelFollow: Float = 0.002
        var left: Float = 0
        var right: Float = 0
    }

    /// A hand is quick; the motor takes a moment to bring the record back up to speed.
    static let handSeconds = 0.012, motorSeconds = 0.14, fadeSeconds = 0.03
    /// Below this speed a stylus fades to nothing.
    private static let quietSpeed = 0.12

    let shared: UnsafeMutablePointer<Shared>
    let outputRate: Double
    private(set) var fileRate = 44_100.0
    private var buffer: UnsafeMutablePointer<Int16>?

    init(outputRate: Double) {
        self.outputRate = outputRate
        shared = .allocate(capacity: 1)
        shared.initialize(to: Shared())
        shared.pointee.levelFollow = Self.coefficient(Self.fadeSeconds, rate: outputRate).float
    }

    deinit {
        buffer?.deallocate()
        shared.deinitialize(count: 1)
        shared.deallocate()
    }

    var isLoaded: Bool { shared.pointee.samples != nil }
    var isSounding: Bool { shared.pointee.level > 0.0005 || shared.pointee.targetLevel > 0 }
    var time: TimeInterval { shared.pointee.position / fileRate }
    var speed: Double { shared.pointee.speed }

    /// The player node for this record: it sits silent until a hand lands.
    func makeNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let shared = shared
        return AVAudioSourceNode(format: format) { isSilent, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self),
                  Self.render(shared, left: left, right: right, frames: Int(frames)) else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                isSilent.pointee = true
                return noErr
            }
            return noErr
        }
    }

    /// Reads the whole song into memory as 16 bit stereo, about 42 MB for four minutes. Slow, so
    /// it runs off the main thread, and the old song is only let go once nothing can be reading it.
    static func decode(_ url: URL) throws -> (UnsafeMutablePointer<Int16>, Int, Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let total = Int(file.length)
        guard total > 0, let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw CocoaError(.fileReadCorruptFile) }
        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: total * 2)
        var written = 0
        let channels = Int(format.channelCount)
        while written < total {
            do { try file.read(into: chunk, frameCount: 65_536) } catch { samples.deallocate(); throw error }
            let count = Int(chunk.frameLength)
            guard count > 0, let data = chunk.floatChannelData else { break }
            let left = data[0], right = data[channels > 1 ? 1 : 0]
            for frame in 0..<min(count, total - written) {
                let at = (written + frame) * 2
                samples[at] = Int16(max(-1, min(1, left[frame])) * 32_767)
                samples[at + 1] = Int16(max(-1, min(1, right[frame])) * 32_767)
            }
            written += count
        }
        return (samples, min(written, total), format.sampleRate)
    }

    /// Takes a decoded song. Only when silent, so the audio thread is not reading the old one.
    func use(_ samples: UnsafeMutablePointer<Int16>, frames: Int, rate: Double) {
        let old = buffer
        shared.pointee.samples = nil
        shared.pointee.frames = frames
        shared.pointee.step = rate / outputRate
        fileRate = rate
        buffer = samples
        shared.pointee.samples = UnsafePointer(samples)
        if let old {
            let address = UInt(bitPattern: old)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                UnsafeMutablePointer<Int16>(bitPattern: address)?.deallocate()
            }
        }
    }

    /// A hand lands on the record at this point in the song.
    func grab(at time: TimeInterval, speed: Double) {
        shared.pointee.position = max(0, min(time * fileRate, Double(max(shared.pointee.frames - 1, 0))))
        shared.pointee.speed = speed
        shared.pointee.targetSpeed = speed
        shared.pointee.follow = Self.coefficient(Self.handSeconds, rate: outputRate)
        shared.pointee.level = 1
        shared.pointee.targetLevel = 1
    }

    /// The record's speed under the hand: 1 is normal, negative is backward.
    func move(speed: Double) { shared.pointee.targetSpeed = speed }

    /// The hand lets go, and the motor takes the record to this speed.
    func letGo(to speed: Double) {
        shared.pointee.follow = Self.coefficient(Self.motorSeconds, rate: outputRate)
        shared.pointee.targetSpeed = speed
    }

    /// Fades out, for the deck to take over.
    func fadeOut() { shared.pointee.targetLevel = 0 }

    private static func coefficient(_ seconds: Double, rate: Double) -> Double { 1 - exp(-1 / (seconds * rate)) }

    /// Fills the output. Runs on the audio thread: no allocation, locks or logging. Returns
    /// false when it wrote nothing because it is silent.
    @inline(__always)
    static func render(_ s: UnsafeMutablePointer<Shared>, left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        guard let samples = s.pointee.samples, s.pointee.frames > 3, s.pointee.level > 0.0005 || s.pointee.targetLevel > 0 else {
            return false
        }
        var position = s.pointee.position, speed = s.pointee.speed, level = s.pointee.level
        var outLeft = s.pointee.left, outRight = s.pointee.right
        let target = s.pointee.targetSpeed, follow = s.pointee.follow, step = s.pointee.step
        let targetLevel = s.pointee.targetLevel, levelFollow = s.pointee.levelFollow
        let last = Double(s.pointee.frames - 1)
        for frame in 0..<frames {
            speed += (target - speed) * follow
            level += (targetLevel - level) * levelFollow
            position += speed * step
            if position <= 0 { position = 0; if speed < 0 { speed = 0 } }
            if position >= last { position = last; if speed > 0 { speed = 0 } }
            let index = Int(position)
            let t = Float(position - Double(index))
            let before = max(index - 1, 0), next = min(index + 1, Int(last)), after = min(index + 2, Int(last))
            let sampleLeft = hermite(samples[before * 2], samples[index * 2], samples[next * 2], samples[after * 2], t)
            let sampleRight = hermite(samples[before * 2 + 1], samples[index * 2 + 1], samples[next * 2 + 1], samples[after * 2 + 1], t)
            let moving = abs(speed)
            // Softer the faster it goes, as a stylus in a fast groove is, which also keeps a
            // quick spin from turning harsh. At normal speed this does nothing.
            let smooth = Float(min(1, 1.25 / max(moving, 0.0001)))
            outLeft += (sampleLeft - outLeft) * smooth
            outRight += (sampleRight - outRight) * smooth
            let gain = level * Float(min(1, moving / quietSpeed))
            left[frame] = outLeft * gain
            right[frame] = outRight * gain
        }
        s.pointee.position = position
        s.pointee.speed = speed
        s.pointee.level = level
        s.pointee.left = outLeft
        s.pointee.right = outRight
        return true
    }

    @inline(__always)
    private static func hermite(_ a: Int16, _ b: Int16, _ c: Int16, _ d: Int16, _ t: Float) -> Float {
        let y0 = Float(a), y1 = Float(b), y2 = Float(c), y3 = Float(d)
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return (((c3 * t + c2) * t + c1) * t + y1) / 32_768
    }
}

private extension Double {
    var float: Float { Float(self) }
}
