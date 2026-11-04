#if DEBUG
import AVFoundation

/// Development builds only: records what the two decks really play during a check mix (each
/// deck's output after all its effects, added together on their shared clock), so a mix can be
/// listened to from a file. `KNOB_RECORD=FILE.m4a` with `--knobshift-check A B` turns it on, and
/// `KNOB_RECORD_PARTS=1` also writes each part ("old", "new", "new voice") beside it on the same
/// timeline, so the mix can be measured.
final class KnobShiftDemoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [(part: String, time: AVAudioFramePosition, left: [Float], right: [Float])] = []
    private var rate: Double = 44_100

    /// Called on the tap's own thread (not the audio render thread): copies the samples.
    func add(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime, part: String, gain: Float = 1) {
        guard let data = buffer.floatChannelData, time.isSampleTimeValid else { return }
        let frames = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: frames)).map { $0 * gain }
        let right = buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: frames)).map { $0 * gain } : left
        lock.withLock {
            rate = time.sampleRate
            parts.append((part, time.sampleTime, left, right))
        }
    }

    /// Adds the chosen parts together (by default the two decks) and writes them as AAC; returns
    /// the length. Every part is written on the same timeline, from the first sample of any.
    func write(to url: URL, parts chosen: Set<String> = ["old", "new"]) throws -> TimeInterval {
        let (all, rate) = lock.withLock { (self.parts, self.rate) }
        let parts = all.filter { chosen.contains($0.part) }
        guard let first = all.map(\.time).min(), let last = all.map({ $0.time + AVAudioFramePosition($0.left.count) }).max(),
              !parts.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let mix = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first)) else { return 0 }
        mix.frameLength = mix.frameCapacity
        let left = mix.floatChannelData![0], right = mix.floatChannelData![1]
        for index in 0..<Int(mix.frameLength) { left[index] = 0; right[index] = 0 }
        for part in parts {
            let offset = Int(part.time - first)
            for index in 0..<part.left.count {
                left[offset + index] += part.left[index]
                right[offset + index] += part.right[index]
            }
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                                                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000],
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: mix)
        return Double(mix.frameLength) / rate
    }
}
#endif
