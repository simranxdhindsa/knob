import AVFoundation
import Darwin

/// The end of Listen Together's sound path, the same on the host and every listener: frames go
/// into the ring, and a source node plays each one a fixed time after it left the host's mix,
/// easing itself to stay on that moment.
final class KnobShiftTogetherPlayer: @unchecked Sendable {
    let ring = KnobShiftTogetherRing()
    private let plain: UnsafeMutablePointer<KnobShiftTogetherRing.Plain>
    private let lock = NSLock()
    private var timeline = KnobShiftTogetherTimeline()
    /// The speakers' true speed: their stated rate is only roughly right.
    private var speakers = KnobShiftTogetherTimeline()
    private var clockOffset: Int64 = 0
    private var outputRate = 48_000.0
    private var outputDelay: Int64 = 0
    private var lineUp: Int64 = 0
    private var node: AVAudioSourceNode?
    private weak var engine: AVAudioEngine?

    init() {
        plain = .allocate(capacity: 1)
        plain.initialize(to: ring.plain)
    }

    deinit {
        plain.deinitialize(count: 1)
        plain.deallocate()
    }

    /// Adds the source node to `engine`, into its main mixer so this device's volume applies.
    func attach(to engine: AVAudioEngine, outputDelay: TimeInterval) {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate > 0 ? rate : 48_000, channels: 2) else { return }
        let plain = plain, outputRate = format.sampleRate
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let scale = Double(timebase.numer) / Double(timebase.denom)
        let node = AVAudioSourceNode(format: format) { isSilent, stamp, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2, let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                isSilent.pointee = true
                return noErr
            }
            let heardAt = Int64(Double(stamp.pointee.mHostTime) * scale)
            if !KnobShiftTogetherRing.render(plain, left: left, right: right, frames: Int(frames), outputRate: outputRate, heardAt: heardAt) {
                isSilent.pointee = true
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        self.node = node
        self.engine = engine
        lock.lock()
        self.outputRate = outputRate
        self.outputDelay = Int64(outputDelay * 1e9)
        publish()
        lock.unlock()
        ring.start()
    }

    func detach() {
        ring.stop()
        if let node, let engine {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        node = nil
    }

    var speakerRate: Double { outputRate }

    /// The node itself, for checks that listen to what this device plays.
    var sourceNode: AVAudioNode? { node }

    /// Takes a reading of the speakers. Call about once a second.
    func tick() {
        guard let heard = ring.heard else { return }
        lock.lock()
        speakers.add(frame: heard.frames, hostNanoseconds: heard.host, rate: outputRate)
        publish()
        lock.unlock()
    }

    /// Time jumped: the engine paused or restarted.
    func restartSpeakers() {
        lock.lock()
        speakers.restart()
        lock.unlock()
    }

    /// `restart` means time jumped since the last one, from a pause or an engine restart.
    func add(frame: Int64, hostNanoseconds: Int64, rate: Double, restart: Bool = false) {
        lock.lock()
        if restart { timeline.restart() }
        timeline.add(frame: frame, hostNanoseconds: hostNanoseconds, rate: rate)
        publish()
        lock.unlock()
    }

    func setClockOffset(_ offset: Int64) {
        lock.lock()
        clockOffset = offset
        publish()
        lock.unlock()
    }

    /// Plays this device earlier by `seconds`, to line up with the others.
    func setLineUp(_ seconds: TimeInterval) {
        lock.lock()
        lineUp = Int64(seconds * 1e9)
        publish()
        lock.unlock()
    }

    /// Call with the lock held.
    private func publish() {
        guard let line = timeline.line else { return }
        var target = KnobShiftTogetherRing.Target()
        target.line = line
        target.clockOffset = clockOffset
        target.delay = Int64(KnobShiftTogether.delay * 1e9) - outputDelay - lineUp
        let trueRate = speakers.line.map { $0.framesPerNanosecond * 1e9 } ?? outputRate
        target.step = line.framesPerNanosecond * 1e9 / trueRate
        ring.update(target)
    }
}

/// Reads the finished mix off a mixer, off the audio thread: numbers its frames and hands them
/// on as 16 bit stereo, with where they sit on this device's clock.
final class KnobShiftTogetherCapture: @unchecked Sendable {
    struct Block {
        let firstFrame: Int64
        let samples: UnsafeBufferPointer<Int16>
        let hostNanoseconds: Int64
        let rate: Double
        /// Time jumped before this block: the engine paused or restarted.
        let afterBreak: Bool
    }

    /// A gap in time bigger than this between blocks is a break, not a late delivery.
    private static let longestGap: Int64 = 100_000_000

    private var nextFrame: Int64 = 0
    private var lastSampleTime: AVAudioFramePosition?
    private var expectedHost: Int64?
    private var scratch = [Int16](repeating: 0, count: 65_536)
    /// The loudest sample since the last report (1 is full scale), and how many were cut off.
    private let statsLock = NSLock()
    private var peak: Float = 0
    private var clipped = 0
    private weak var node: AVAudioNode?
    private let scale: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        scale = Double(timebase.numer) / Double(timebase.denom)
    }

    func start(on node: AVAudioNode, onBlock: @escaping @Sendable (Block) -> Void) {
        self.node = node
        node.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [self] buffer, time in
            guard time.isHostTimeValid, time.isSampleTimeValid, let data = buffer.floatChannelData else { return }
            let frames = min(Int(buffer.frameLength), scratch.count / 2)
            let rate = buffer.format.sampleRate
            let host = Int64(Double(time.hostTime) * scale)
            let afterBreak = expectedHost.map { abs(host - $0) > Self.longestGap } ?? false
            // A block the tap never delivered still counts, or the frames would fall behind time.
            if !afterBreak, let last = lastSampleTime, time.sampleTime > last { nextFrame += time.sampleTime - last }
            lastSampleTime = time.sampleTime + AVAudioFramePosition(frames)
            expectedHost = host + Int64(Double(frames) / rate * 1e9)
            let left = data[0], right = data[buffer.format.channelCount > 1 ? 1 : 0]
            var loudest: Float = 0, cut = 0
            for frame in 0..<frames {
                let both = max(abs(left[frame]), abs(right[frame]))
                loudest = max(loudest, both)
                if both * KnobShiftTogether.headroom > 1 { cut += 1 }
                scratch[frame * 2] = Int16(max(-1, min(1, left[frame] * KnobShiftTogether.headroom)) * 32_767)
                scratch[frame * 2 + 1] = Int16(max(-1, min(1, right[frame] * KnobShiftTogether.headroom)) * 32_767)
            }
            statsLock.withLock {
                peak = max(peak, loudest)
                clipped += cut
            }
            scratch.withUnsafeBufferPointer { all in
                onBlock(Block(firstFrame: nextFrame, samples: UnsafeBufferPointer(rebasing: all[0..<(frames * 2)]),
                              hostNanoseconds: host, rate: rate, afterBreak: afterBreak))
            }
            nextFrame += Int64(frames)
        }
    }

    /// What the mix did since the last call, for the log.
    func takeStats() -> (peak: Float, clipped: Int) {
        statsLock.withLock {
            defer { peak = 0; clipped = 0 }
            return (peak, clipped)
        }
    }

    func stop() {
        node?.removeTap(onBus: 0)
        node = nil
    }
}
