import Darwin
import Foundation

/// The sound on its way to the speakers, shared by whoever fills it and the audio thread. Written
/// by one side and read by the other with no locks: the audio thread never waits, allocates or
/// logs. Everything it touches is allocated here, up front.
final class KnobShiftTogetherRing: @unchecked Sendable {
    /// When the audio thread should be, as of the last update.
    struct Target {
        var line = KnobShiftTogetherTimeline.Line(frame: 0, host: 0, framesPerNanosecond: 0)
        /// Host clock minus this device's clock.
        var clockOffset: Int64 = 0
        /// How long after leaving the mix a frame is heard, less this device's own output delay
        /// and line up.
        var delay: Int64 = 0
        /// The mix's frames per output frame at the stated rates.
        var step = 1.0
    }

    struct Shared {
        var written: Int64 = 0
        var version = 0
        var target = Target()
        var wanted = false
        // Written by the audio thread.
        var position = 0.0
        var correction = 0.0
        var level: Float = 0
        var error = 0.0
        var underruns = 0
        var jumps = 0
        /// Every frame the speakers have asked for, and when the latest block is heard. These
        /// times are real. A tap's are not: on a real song they drifted about 700 parts per
        /// million from the speakers, which measured within 12 of their stated rate.
        var heardVersion = 0
        var heardFrames: Int64 = 0
        var heardHost: Int64 = 0
    }

    /// Further than this from where it should be, it jumps instead of easing back.
    static let jumpSeconds = 0.05
    /// The most the speed may change: 500 parts per million cannot be heard.
    static let mostCorrection = 0.0005
    /// Seconds to ease out an error, and to learn a steady drift.
    private static let easeSeconds = 2.0, learnSeconds = 30.0
    private static let fadeSeconds = 0.02
    private static let learnWithin = 0.005

    let capacity: Int
    private let mask: Int
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    let shared: UnsafeMutablePointer<Shared>

    /// `capacity` is rounded up to a power of two.
    init(capacity: Int = 1 << 19) {
        var size = 1
        while size < capacity { size <<= 1 }
        self.capacity = size
        mask = size - 1
        left = .allocate(capacity: size)
        right = .allocate(capacity: size)
        left.initialize(repeating: 0, count: size)
        right.initialize(repeating: 0, count: size)
        shared = .allocate(capacity: 1)
        shared.initialize(to: Shared())
    }

    deinit {
        left.deallocate()
        right.deallocate()
        shared.deinitialize(count: 1)
        shared.deallocate()
    }

    // MARK: The side that fills it

    /// Adds 16 bit stereo frames at their place in the mix. Frames lost on the way are silence.
    func write(firstFrame: Int64, samples: UnsafeBufferPointer<Int16>) {
        let frames = samples.count / 2
        let written = shared.pointee.written
        guard firstFrame + Int64(frames) > written else { return }
        var from = max(written, firstFrame - Int64(capacity))
        while from < firstFrame {
            let at = Int(from) & mask
            left[at] = 0
            right[at] = 0
            from += 1
        }
        let skip = max(0, Int(written - firstFrame))
        for frame in skip..<frames {
            let at = Int(firstFrame + Int64(frame)) & mask
            left[at] = Float(samples[frame * 2]) / 32_768
            right[at] = Float(samples[frame * 2 + 1]) / 32_768
        }
        OSMemoryBarrier()
        shared.pointee.written = firstFrame + Int64(frames)
    }

    /// Hands the audio thread a new target. The version is odd while it changes, so a half
    /// written target is never used.
    func update(_ target: Target) {
        shared.pointee.version &+= 1
        OSMemoryBarrier()
        shared.pointee.target = target
        OSMemoryBarrier()
        shared.pointee.version &+= 1
    }

    /// How many frames the speakers have played and when, read safely from any thread.
    var heard: (frames: Int64, host: Int64)? {
        for _ in 0..<8 {
            let before = shared.pointee.heardVersion
            OSMemoryBarrier()
            let frames = shared.pointee.heardFrames, host = shared.pointee.heardHost
            OSMemoryBarrier()
            if before % 2 == 0, before == shared.pointee.heardVersion { return frames > 0 ? (frames, host) : nil }
        }
        return nil
    }

    func start() { shared.pointee.wanted = true }
    func stop() { shared.pointee.wanted = false }

    // MARK: The audio thread

    /// Fills the speakers for `frames`, the first of them heard at `heardAt` on this device's
    /// clock, in nanoseconds. Returns false for silence. Called on the audio thread.
    @inline(__always)
    static func render(_ ring: UnsafePointer<Plain>, left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>,
                       frames: Int, outputRate: Double, heardAt: Int64) -> Bool {
        let plain = ring.pointee
        let shared = plain.shared
        shared.pointee.heardVersion &+= 1
        OSMemoryBarrier()
        shared.pointee.heardHost = heardAt
        shared.pointee.heardFrames &+= Int64(frames)
        OSMemoryBarrier()
        shared.pointee.heardVersion &+= 1
        // A target caught mid change is skipped: the last one is good for this short moment.
        var target = shared.pointee.target
        let before = shared.pointee.version
        OSMemoryBarrier()
        target = shared.pointee.target
        OSMemoryBarrier()
        let settled = before % 2 == 0 && shared.pointee.version == before
        guard settled, target.line.framesPerNanosecond > 0 else { return silence(shared, outLeft, outRight, frames) }

        let written = shared.pointee.written
        OSMemoryBarrier()
        let hostMoment = heardAt + target.clockOffset - target.delay
        let wantedFrame = Double(target.line.frame) + Double(hostMoment - target.line.host) * target.line.framesPerNanosecond
        let oldest = Double(written - Int64(plain.capacity) + 8)
        let newest = Double(written - 8)
        let sourceRate = target.line.framesPerNanosecond * 1e9
        let room = wantedFrame > max(oldest, 2) && wantedFrame < newest
        guard shared.pointee.wanted, room else {
            if shared.pointee.wanted, shared.pointee.level > 0 { shared.pointee.underruns += 1 }
            return silence(shared, outLeft, outRight, frames)
        }

        var position = shared.pointee.position
        var error = wantedFrame - position
        if shared.pointee.level == 0 || abs(error) > jumpSeconds * sourceRate {
            if shared.pointee.level != 0 { shared.pointee.jumps += 1 }
            position = wantedFrame
            error = 0
            shared.pointee.correction = 0
        }
        // Easing out what's left, plus a slow memory of any steady drift.
        let seconds = Double(frames) / outputRate
        // Only near the target: a big error is a moment's event, not a drift worth remembering.
        let near = abs(error) < learnWithin * sourceRate
        var learned = shared.pointee.correction + (near ? error / sourceRate * seconds / (learnSeconds * easeSeconds) : 0)
        learned = max(-mostCorrection, min(mostCorrection, learned))
        shared.pointee.correction = learned
        let correction = max(-mostCorrection, min(mostCorrection, learned + error / sourceRate / easeSeconds))
        shared.pointee.error = error / sourceRate
        let step = target.step * (1 + correction)

        let left = plain.left, right = plain.right, mask = plain.mask
        var level = shared.pointee.level
        let fade = Float(1 / (fadeSeconds * outputRate))
        for frame in 0..<frames {
            let whole = Int(position.rounded(.down))
            let part = Float(position - Double(whole))
            let a = (whole - 1) & mask, b = whole & mask, c = (whole + 1) & mask, d = (whole + 2) & mask
            level = min(1, level + fade)
            outLeft[frame] = cubic(left[a], left[b], left[c], left[d], part) * level
            outRight[frame] = cubic(right[a], right[b], right[c], right[d], part) * level
            position += step
        }
        shared.pointee.level = level
        shared.pointee.position = position
        return true
    }

    /// What the audio thread needs, copied out so it never touches this object's reference count.
    struct Plain {
        let shared: UnsafeMutablePointer<Shared>
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        let mask: Int
        let capacity: Int
    }

    var plain: Plain { Plain(shared: shared, left: left, right: right, mask: mask, capacity: capacity) }

    @inline(__always)
    private static func cubic(_ a: Float, _ b: Float, _ c: Float, _ d: Float, _ t: Float) -> Float {
        b + 0.5 * t * (c - a + t * (2 * a - 5 * b + 4 * c - d + t * (3 * (b - c) + d - a)))
    }

    @inline(__always)
    private static func silence(_ shared: UnsafeMutablePointer<Shared>, _ left: UnsafeMutablePointer<Float>,
                                _ right: UnsafeMutablePointer<Float>, _ frames: Int) -> Bool {
        memset(left, 0, frames * MemoryLayout<Float>.size)
        memset(right, 0, frames * MemoryLayout<Float>.size)
        shared.pointee.level = 0
        return false
    }
}
