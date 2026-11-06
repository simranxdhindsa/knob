import Accelerate
import AVFoundation
import CoreML

/// Splits part of a song into its voice and its music, on this Mac, with the Open-Unmix UMX-HQ
/// vocal model (Inria, MIT licence, `Resources/KnobShift/OpenUnmix-LICENSE.txt`). Only the
/// stretch around a mix is separated, so it takes a few seconds rather than a whole song's worth.
///
/// How: a short-time Fourier transform (4096 point, hop 1024, as the model was trained), the
/// model estimates the voice's share of every frequency in every moment, that share is applied
/// to the mix, and the result is turned back into sound. The music is the mix minus the voice.
enum KnobShiftStems {
    struct Stems {
        let vocals: AVAudioPCMBuffer
        let music: AVAudioPCMBuffer
        let start: TimeInterval
        /// How long the separation took.
        let seconds: TimeInterval
    }

    enum StemError: Error { case noModel, unsupportedFile, modelFailed }

    static let sampleRate = 44_100.0
    fileprivate static let fftSize = 4_096
    fileprivate static let log2Size: vDSP_Length = 12
    fileprivate static let hop = 1_024
    fileprivate static let bins = 2_049
    private static let chunk = 256

    static func separate(_ url: URL, from start: TimeInterval, length: TimeInterval) throws -> Stems {
        let began = Date()
        let model = try loadModel()
        // The model only knows 44.1 kHz. A song at another rate is separated from a converted
        // copy, then its voice goes back to the song's rate and the music is what remains, so
        // the two parts still add up to the file exactly.
        let (original, first, rate) = try read(url, from: start, length: length)
        let channels = rate == sampleRate ? original : try original.map { try resample($0, from: rate, to: sampleRate) }
        let samples = channels[0].count
        let transform = Transform()
        let spectra = channels.map { transform.forward($0) }
        let frames = spectra[0].count
        var masks = [[[Float]]](repeating: [], count: 2)
        for chunkStart in stride(from: 0, to: frames, by: chunk) {
            let part = try voiceShare(model: model, spectra: spectra, from: chunkStart, frames: min(chunk, frames - chunkStart))
            for channel in 0..<2 { masks[channel].append(contentsOf: part[channel]) }
        }
        let outSamples = original[0].count
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        guard let vocals = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outSamples)),
              let music = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(outSamples)) else {
            throw StemError.modelFailed
        }
        vocals.frameLength = AVAudioFrameCount(outSamples)
        music.frameLength = AVAudioFrameCount(outSamples)
        for channel in 0..<2 {
            var voice = transform.inverse(spectra[channel], masks: masks[channel], length: samples)
            if rate != sampleRate { voice = try resample(voice, from: sampleRate, to: rate, count: outSamples) }
            for index in 0..<outSamples {
                vocals.floatChannelData![channel][index] = voice[index]
                music.floatChannelData![channel][index] = original[channel][index] - voice[index]
            }
        }
        return Stems(vocals: vocals, music: music, start: first, seconds: Date().timeIntervalSince(began))
    }

    /// Separated voice and music written to files, ready to play from `start` of `song`.
    struct Prepared: Sendable {
        let song: URL
        let start: TimeInterval
        let length: TimeInterval
        let music: URL
        let vocals: URL
        let seconds: TimeInterval
    }

    /// Separates `length` seconds from `start` and writes both parts as files the decks can play
    /// like any song, in a temporary folder that only ever holds the latest mix.
    static func prepare(_ url: URL, from start: TimeInterval, length: TimeInterval) throws -> Prepared {
        let stems = try separate(url, from: start, length: length)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KnobShift Stems", isDirectory: true)
        // Keep the files of the mix being prepared alongside; clear anything over an hour old.
        let old = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in old where ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) < Date().addingTimeInterval(-3_600) {
            try? FileManager.default.removeItem(at: file)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let urls = [folder.appendingPathComponent("\(id) music.caf"), folder.appendingPathComponent("\(id) vocals.caf")]
        for (target, buffer) in zip(urls, [stems.music, stems.vocals]) {
            let file = try AVAudioFile(forWriting: target, settings: buffer.format.settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        return Prepared(song: url, start: stems.start, length: Double(stems.music.frameLength) / stems.music.format.sampleRate,
                        music: urls[0], vocals: urls[1], seconds: stems.seconds)
    }

    /// For checks: how far the transform alone (every share at 1) is from the original sound,
    /// as the largest difference relative to the loudest sample. Near 0 means nothing is lost.
    static func roundTripError(_ url: URL, from start: TimeInterval, length: TimeInterval) throws -> Float {
        let part = try read(url, from: start, length: length)
        let signal = part.rate == sampleRate ? part.channels[0] : try resample(part.channels[0], from: part.rate, to: sampleRate)
        let transform = Transform()
        let spectrum = transform.forward(signal)
        let back = transform.inverse(spectrum, masks: spectrum.map { _ in [Float](repeating: 1, count: bins) }, length: signal.count)
        let peak = signal.map(abs).max() ?? 1
        return zip(signal, back).map { abs($0 - $1) }.max().map { $0 / max(peak, 1e-9) } ?? 0
    }

    private static func read(_ url: URL, from start: TimeInterval, length: TimeInterval) throws -> (channels: [[Float]], start: TimeInterval, rate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard rate > 0, format.channelCount >= 1 else { throw StemError.unsupportedFile }
        let first = AVAudioFramePosition(max(0, start) * rate)
        let count = AVAudioFrameCount(max(0, min(Double(file.length - first), length * rate)))
        guard count > AVAudioFrameCount(fftSize), let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw StemError.unsupportedFile
        }
        file.framePosition = first
        try file.read(into: input, frameCount: count)
        guard let data = input.floatChannelData else { throw StemError.unsupportedFile }
        let samples = Int(input.frameLength)
        let channels = (0..<2).map { Array(UnsafeBufferPointer(start: data[min($0, Int(format.channelCount) - 1)], count: samples)) }
        return (channels, Double(first) / rate, rate)
    }

    /// One channel at another sample rate, lined up with the original from its first sample.
    /// `count` trims or pads the result to an exact length.
    private static func resample(_ samples: [Float], from source: Double, to target: Double, count: Int? = nil) throws -> [Float] {
        guard let input = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
              let output = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
              let converter = AVAudioConverter(from: input, to: output),
              let whole = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw StemError.unsupportedFile
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        whole.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { whole.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let length = count ?? Int((Double(samples.count) * target / source).rounded())
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(length + 4_096)) else {
            throw StemError.unsupportedFile
        }
        var given = false
        var problem: NSError?
        let status = converter.convert(to: converted, error: &problem) { _, state in
            state.pointee = given ? .endOfStream : .haveData
            defer { given = true }
            return given ? nil : whole
        }
        guard status != .error, problem == nil else { throw StemError.unsupportedFile }
        var result = Array(UnsafeBufferPointer(start: converted.floatChannelData![0], count: Int(converted.frameLength)))
        if result.count > length { result.removeLast(result.count - length) }
        if result.count < length { result.append(contentsOf: repeatElement(0, count: length - result.count)) }
        return result
    }

    /// Runs the model on up to `chunk` frames and returns, per channel and frame, the voice's
    /// share (0...1) of each frequency bin.
    private static func voiceShare(model: MLModel, spectra: [[Frame]], from start: Int, frames: Int) throws -> [[[Float]]] {
        let shape = [1, 2, bins, chunk].map { NSNumber(value: $0) }
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        let inStrides = input.strides.map(\.intValue)
        let inPointer = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        for index in 0..<input.count { inPointer[index] = 0 }
        for channel in 0..<2 {
            for frame in 0..<frames {
                let magnitudes = spectra[channel][start + frame].magnitudes
                for bin in 0..<bins {
                    inPointer[channel * inStrides[1] + bin * inStrides[2] + frame * inStrides[3]] = magnitudes[bin]
                }
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["mix": MLFeatureValue(multiArray: input)])
        guard let output = try model.prediction(from: provider).featureValue(for: "vocals")?.multiArrayValue else {
            throw StemError.modelFailed
        }
        let outStrides = output.strides.map(\.intValue)
        let read: (Int) -> Float
        switch output.dataType {
        case .float16:
            // Half precision converted with vImage, which works on Intel Macs too.
            let span = output.strides[0].intValue * output.shape[0].intValue
            var floats = [Float](repeating: 0, count: span)
            var source = vImage_Buffer(data: output.dataPointer, height: 1, width: vImagePixelCount(span), rowBytes: span * 2)
            floats.withUnsafeMutableBytes {
                var target = vImage_Buffer(data: $0.baseAddress, height: 1, width: vImagePixelCount(span), rowBytes: span * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&source, &target, vImage_Flags(kvImageNoFlags))
            }
            let converted = floats
            read = { converted[$0] }
        default:
            let pointer = output.dataPointer.bindMemory(to: Float.self, capacity: output.count)
            read = { pointer[$0] }
        }
        return (0..<2).map { channel in
            (0..<frames).map { frame in
                let magnitudes = spectra[channel][start + frame].magnitudes
                return (0..<bins).map { bin in
                    let voice = read(channel * outStrides[1] + bin * outStrides[2] + frame * outStrides[3])
                    return min(max(voice / (magnitudes[bin] + 1e-8), 0), 1)
                }
            }
        }
    }

    /// The bundled model, compiled for this Mac once and kept in Application Support.
    private static func loadModel() throws -> MLModel {
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("KnobShift/KnobVocals.mlpackage"),
              FileManager.default.fileExists(atPath: source.path) else { throw StemError.noModel }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.simranxdhindsa.knob")
            .appendingPathComponent("KnobShift Model", isDirectory: true)
        let compiled = support.appendingPathComponent("KnobVocals-1.mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let temporary = try MLModel.compileModel(at: source)
            try? FileManager.default.removeItem(at: compiled)
            try FileManager.default.moveItem(at: temporary, to: compiled)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// One moment of the spectrum, kept in vDSP's packed form (bin 0 and the top bin share the
    /// first slot) so it can be turned back into sound exactly.
    fileprivate struct Frame {
        let real: [Float]
        let imaginary: [Float]
        let magnitudes: [Float]
    }

    /// Short-time Fourier transform matching the model's training (periodic Hann window,
    /// centred frames with reflected edges).
    private final class Transform {
        private let setup: FFTSetup
        private let window: [Float]
        /// vDSP's forward then inverse transform scales the signal by 2 × size.
        private let roundTrip = 1 / Float(2 * KnobShiftStems.fftSize)

        init() {
            setup = vDSP_create_fftsetup(KnobShiftStems.log2Size, FFTRadix(kFFTRadix2))!
            window = (0..<KnobShiftStems.fftSize).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(KnobShiftStems.fftSize)) }
        }

        deinit { vDSP_destroy_fftsetup(setup) }

        func forward(_ signal: [Float]) -> [Frame] {
            let size = KnobShiftStems.fftSize, half = size / 2
            var padded = [Float](repeating: 0, count: signal.count + size)
            for index in 0..<padded.count {
                var source = index - half
                if source < 0 { source = -source }
                if source >= signal.count { source = 2 * (signal.count - 1) - source }
                padded[index] = signal[min(max(source, 0), signal.count - 1)]
            }
            let frames = signal.count / KnobShiftStems.hop + 1
            return (0..<frames).map { frame in
                let offset = frame * KnobShiftStems.hop
                var block = [Float](repeating: 0, count: size)
                vDSP_vmul(Array(padded[offset..<(offset + size)]), 1, window, 1, &block, 1, vDSP_Length(size))
                var real = [Float](repeating: 0, count: half)
                var imaginary = [Float](repeating: 0, count: half)
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        block.withUnsafeBufferPointer {
                            $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, KnobShiftStems.log2Size, FFTDirection(FFT_FORWARD))
                    }
                }
                // vDSP's forward transform is twice the true spectrum.
                var magnitudes = [Float](repeating: 0, count: KnobShiftStems.bins)
                magnitudes[0] = abs(real[0]) / 2
                magnitudes[half] = abs(imaginary[0]) / 2
                for bin in 1..<half { magnitudes[bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot() / 2 }
                return Frame(real: real, imaginary: imaginary, magnitudes: magnitudes)
            }
        }

        /// Applies the voice share to each frame and overlap-adds the frames back into sound.
        func inverse(_ frames: [Frame], masks: [[Float]], length: Int) -> [Float] {
            let size = KnobShiftStems.fftSize, half = size / 2
            var output = [Float](repeating: 0, count: length + size)
            var weight = [Float](repeating: 0, count: length + size)
            for (index, frame) in frames.enumerated() {
                let mask = masks[index]
                var real = frame.real
                var imaginary = frame.imaginary
                real[0] *= mask[0]
                imaginary[0] *= mask[half]
                for bin in 1..<half {
                    real[bin] *= mask[bin]
                    imaginary[bin] *= mask[bin]
                }
                var block = [Float](repeating: 0, count: size)
                real.withUnsafeMutableBufferPointer { realPointer in
                    imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                        var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                        vDSP_fft_zrip(setup, &split, 1, KnobShiftStems.log2Size, FFTDirection(FFT_INVERSE))
                        block.withUnsafeMutableBufferPointer {
                            $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                                vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                            }
                        }
                    }
                }
                let offset = index * KnobShiftStems.hop
                for sample in 0..<size {
                    output[offset + sample] += block[sample] * roundTrip * window[sample]
                    weight[offset + sample] += window[sample] * window[sample]
                }
            }
            return (0..<length).map { index in
                let position = index + half
                return weight[position] > 1e-6 ? output[position] / weight[position] : 0
            }
        }
    }
}
