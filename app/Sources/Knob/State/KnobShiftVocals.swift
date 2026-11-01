import AVFoundation
import SoundAnalysis

/// Finds where a song's voice starts and really ends, using macOS's built-in on-device sound
/// classifier (singing, rapping, speech, choir, humming). Nothing is downloaded or uploaded.
///
/// "Voice" is judged against the song's own typical vocal level, so a quiet ad-lib outro still
/// counts while a single shout after the last line does not. These are detection settings only:
/// the crossfade start and length are chosen later from what is found here, per song pair.
enum KnobShiftVocals {
    struct Result {
        let onset: TimeInterval?
        let end: TimeInterval?
        /// Where the last steady vocal line begins: the earliest the next song may come in.
        var lastLineStart: TimeInterval? = nil
        /// Where the voice first reaches the song's normal singing level for a steady line, so
        /// intro ad-libs and spoken bits are not mistaken for the main verse.
        var mainOnset: TimeInterval? = nil
        /// Short vocal sounds after the last steady line (shouts, ad-libs).
        var strays: [TimeInterval] = []
        /// The song's typical confidence while someone is singing or rapping, 0...1.
        let level: Double
        let steps: [String]
    }

    private static let labels = ["singing", "rapping", "speech", "choir_singing", "humming"]
    private static let window = 1.5
    /// Clear voice needed before a song counts as having vocals at all.
    private static let clearVoice = 0.4
    /// Voice must hold this long to count as a vocal line rather than a stray sound.
    private static let steadyVoice = 3.0

    /// `beatEntry` is where the song's beat comes in: voice before it (a tag or shout over the
    /// intro) is never taken for the main verse.
    static func detect(in url: URL, beatEntry: TimeInterval? = nil) -> Result {
        let started = Date()
        let observer = Observer()
        do {
            let analyzer = try SNAudioFileAnalyzer(url: url)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: window, preferredTimescale: 1_000)
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: observer)
            analyzer.analyze()
        } catch {
            return Result(onset: nil, end: nil, level: 0,
                          steps: ["Vocals: the built-in sound classifier could not read this file (\(error.localizedDescription))."])
        }
        let frames = observer.frames.sorted { $0.time < $1.time }
        var steps = [String(format: "Vocals: %d voice readings from the built-in classifier in %.0f ms.",
                            frames.count, Date().timeIntervalSince(started) * 1_000)]
        guard frames.count > 4 else {
            steps.append("Vocals: too short to judge.")
            return Result(onset: nil, end: nil, level: 0, steps: steps)
        }

        // Smooth over neighbouring readings so one quiet syllable does not split a line.
        let smoothed = frames.indices.map { index -> Double in
            let range = max(0, index - 1)...min(frames.count - 1, index + 1)
            return range.map { frames[$0].voice }.reduce(0, +) / Double(range.count)
        }
        let clear = smoothed.filter { $0 >= clearVoice }.sorted()
        let hop = window / 2
        let minimumRun = Int((steadyVoice / hop).rounded(.up))
        guard clear.count >= minimumRun else {
            steps.append(String(format: "Vocals: none. Under %.0fs of clear voice, so this is treated as instrumental.", steadyVoice))
            return Result(onset: nil, end: nil, level: 0, steps: steps)
        }
        let level = clear[clear.count / 2]
        let floor = max(0.15, level * 0.3)
        steps.append(String(format: "Vocal level: typical %.0f%%, so voice counts above %.0f%% when it holds for %.0fs.",
                            level * 100, floor * 100, steadyVoice))

        let runs = voicedRuns(smoothed, floor: floor, minimumRun: minimumRun)
        guard let first = runs.first, let last = runs.last else {
            steps.append("Vocals: no steady vocal line found.")
            return Result(onset: nil, end: nil, level: level, steps: steps)
        }
        let onset = max(0, frames[first.lowerBound].time - hop)
        let end = frames[last.upperBound].time + hop
        let lastLineStart = max(0, frames[last.lowerBound].time - hop)
        steps.append(String(format: "Vocal start: %.2fs, the first steady vocal line.", onset))
        let strays = frames.indices
            .filter { $0 > last.upperBound && frames[$0].voice >= floor }
            .map { frames[$0].time }
        let strayNote = strays.isEmpty ? "" : " Short vocal sounds after it at \(strays.prefix(4).map { String(format: "%.1fs", $0) }.joined(separator: ", "))."
        steps.append(String(format: "Vocal end: %.2fs, where the last steady line fades out.", end) + strayNote)
        steps.append(String(format: "Last vocal line: %.2fs to %.2fs.", lastLineStart, end))
        // The main verse: a steady line at the song's normal singing level, not just above the
        // quieter threshold that also catches intro ad-libs.
        let mainRuns = voicedRuns(smoothed, floor: max(floor, level * 0.6), minimumRun: minimumRun)
        let entry = beatEntry ?? 0
        let mainRun = mainRuns.first { frames[$0.upperBound].time + hop >= entry + steadyVoice }
        let mainOnset = mainRun.map { max(entry, frames[$0.lowerBound].time - hop) } ?? onset
        if mainOnset > onset + 0.5 {
            steps.append(String(format: "Main verse: %.2fs. The voice before it (from %.2fs) is intro ad-libs or a tag before the beat.", mainOnset, onset))
        } else {
            steps.append(String(format: "Main verse: %.2fs.", mainOnset))
        }
        return Result(onset: onset, end: end, lastLineStart: lastLineStart, mainOnset: mainOnset, strays: strays,
                      level: level, steps: steps)
    }

    /// Index ranges where smoothed voice stays at or above `floor` for at least `minimumRun`.
    private static func voicedRuns(_ values: [Double], floor: Double, minimumRun: Int) -> [ClosedRange<Int>] {
        var runs: [ClosedRange<Int>] = []
        var start: Int?
        for index in values.indices {
            if values[index] >= floor {
                if start == nil { start = index }
            } else if let open = start {
                if index - open >= minimumRun { runs.append(open...(index - 1)) }
                start = nil
            }
        }
        if let open = start, values.count - open >= minimumRun { runs.append(open...(values.count - 1)) }
        return runs
    }

    private final class Observer: NSObject, SNResultsObserving {
        struct Frame { let time: TimeInterval; let voice: Double }
        private(set) var frames: [Frame] = []

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let voice = KnobShiftVocals.labels.compactMap { result.classification(forIdentifier: $0)?.confidence }.max() ?? 0
            let middle = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
            frames.append(Frame(time: middle, voice: voice))
        }
    }
}
