import AVFoundation

/// A song under a hand, the way a record plays it. The player's decks can only play forward at
/// their own speed, so while a hand is on the iPhone's record the song comes from here instead:
/// held in memory, it plays at any speed in either direction, and slowing it down drops its pitch
/// because that is simply what happens. A stopped record is silent, not a held note, since a
/// stylus only makes a sound while the groove moves under it.
final class KnobShiftScratch {
    /// One song, never changed once made, so the audio thread gets all of it or none of it.
    struct Song {
        let samples: UnsafePointer<Int16>
        let frames: Int
        /// Song frames per output frame at normal speed.
        let step: Double
    }

    /// What the audio thread and the rest of the app share. The audio thread takes no locks and
    /// allocates nothing, so each field has one writer. To move the record the app leaves a
    /// request, which the audio thread picks up at the start of its next block.
    struct Shared {
        // Written by the app.
        var song: UnsafePointer<Song>?
        var targetSpeed = 0.0
        /// How quickly speed follows its target, per output frame.
        var follow = 0.01
        var targetLevel: Float = 0
        var levelFollow: Float = 0.002
        var requestPosition = 0.0
        var requestSpeed = 0.0
        var requests = 0
        // Written by the audio thread.
        var handled = 0
        var position = 0.0
        var speed = 0.0
        var level: Float = 0
        var left: Float = 0
        var right: Float = 0
    }

    /// A hand is quick; the motor takes a moment to bring the record back up to speed.
    static let handSeconds = 0.012, motorSeconds = 0.14, fadeSeconds = 0.03
    /// Below this speed a stylus fades to nothing.
    private static let quietSpeed = 0.12
    /// Longer than this stays off the record: 20 minutes is about 210 MB, and a long mix in
    /// memory is the kind of thing the iPhone closes an app for.
    static let longestSeconds = 1_200.0

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
        shared.pointee.song?.deallocate()
        shared.deinitialize(count: 1)
        shared.deallocate()
    }

    var isLoaded: Bool { shared.pointee.song != nil }
    /// The audio thread has picked up the last request, so `time` and `speed` are current.
    var isCaughtUp: Bool { shared.pointee.handled == shared.pointee.requests }
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
        guard Double(total) / format.sampleRate <= longestSeconds else { throw CocoaError(.fileReadTooLarge) }
        guard total > 0, let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else { throw CocoaError(.fileReadCorruptFile) }
        let samples = UnsafeMutablePointer<Int16>.allocate(capacity: total * 2)
        var written = 0
        let channels = Int(format.channelCount)
        while written < total {
            do {
                try Task.checkCancellation()
                try file.read(into: chunk, frameCount: 65_536)
            } catch {
                samples.deallocate()
                throw error
            }
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

    /// Takes a decoded song, in one step. The old one is only let go a second later, long after
    /// the audio thread can still be reading it.
    func use(_ samples: UnsafeMutablePointer<Int16>, frames: Int, rate: Double) {
        let song = UnsafeMutablePointer<Song>.allocate(capacity: 1)
        song.initialize(to: Song(samples: UnsafePointer(samples), frames: frames, step: rate / outputRate))
        swap(to: UnsafePointer(song), samples: samples)
        fileRate = rate
    }

    /// Lets go of the song, to give its memory back.
    func release() { swap(to: nil, samples: nil) }

    private func swap(to song: UnsafePointer<Song>?, samples: UnsafeMutablePointer<Int16>?) {
        let oldSong = shared.pointee.song, oldSamples = buffer
        // The song must be complete in memory before the audio thread can see it.
        OSMemoryBarrier()
        shared.pointee.song = song
        buffer = samples
        guard oldSong != nil || oldSamples != nil else { return }
        let songAddress = UInt(bitPattern: oldSong), samplesAddress = UInt(bitPattern: oldSamples)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            UnsafeMutablePointer<Song>(bitPattern: songAddress)?.deallocate()
            UnsafeMutablePointer<Int16>(bitPattern: samplesAddress)?.deallocate()
        }
    }

    /// A hand lands on the record at this point in the song.
    func grab(at time: TimeInterval, speed: Double) {
        let last = Double(max((shared.pointee.song?.pointee.frames ?? 1) - 1, 0))
        shared.pointee.requestPosition = max(0, min(time * fileRate, last))
        shared.pointee.requestSpeed = speed
        shared.pointee.targetSpeed = speed
        shared.pointee.follow = Self.coefficient(Self.handSeconds, rate: outputRate)
        shared.pointee.targetLevel = 1
        OSMemoryBarrier()
        shared.pointee.requests += 1
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
        guard let song = s.pointee.song?.pointee, song.frames > 3, s.pointee.level > 0.0005 || s.pointee.targetLevel > 0 else {
            return false
        }
        let requests = s.pointee.requests
        if s.pointee.handled != requests {
            s.pointee.position = s.pointee.requestPosition
            s.pointee.speed = s.pointee.requestSpeed
            s.pointee.level = 1
            s.pointee.handled = requests
        }
        let samples = song.samples, step = song.step
        var position = s.pointee.position, speed = s.pointee.speed, level = s.pointee.level
        var outLeft = s.pointee.left, outRight = s.pointee.right
        let target = s.pointee.targetSpeed, follow = s.pointee.follow
        let targetLevel = s.pointee.targetLevel, levelFollow = s.pointee.levelFollow
        let last = Double(song.frames - 1)
        position = min(position, last)
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
