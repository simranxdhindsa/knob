#if DEBUG
import AVFoundation

/// Development builds only: records what the two decks really play during a check mix (each
/// deck's output after all its effects, added together on their shared clock), so a mix can be
/// listened to from a file. `KNOB_RECORD=FILE.m4a` with `--knobshift-check A B` turns it on.
final class KnobShiftDemoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [(time: AVAudioFramePosition, left: [Float], right: [Float])] = []
    private var rate: Double = 44_100

    /// Called on the tap's own thread (not the audio render thread): copies the samples.
    func add(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let data = buffer.floatChannelData, time.isSampleTimeValid else { return }
        let frames = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: frames))
        let right = buffer.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: frames)) : left
        lock.withLock {
            rate = time.sampleRate
            parts.append((time.sampleTime, left, right))
        }
    }

    /// Adds every deck's recording together and writes it as AAC; returns its length.
    func write(to url: URL) throws -> TimeInterval {
        let (parts, rate) = lock.withLock { (self.parts, self.rate) }
        guard let first = parts.map(\.time).min(), let last = parts.map({ $0.time + AVAudioFramePosition($0.left.count) }).max(),
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
