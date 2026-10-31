import AVFoundation
import Foundation

/// KnobShift owns local, non-DRM music that the user explicitly chooses in Knob. Its two audio
/// players are kept entirely outside Knob's system-audio engine, driver and DSP callbacks.
@MainActor
final class KnobShiftModel: ObservableObject {
    enum Style: String, CaseIterable, Identifiable {
        case gentle, balanced, party

        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
    }

    enum MixState: String {
        case idle, analyzing, ready, mixing, preservingEnding

        var title: String {
            switch self {
            case .idle: "IDLE"
            case .analyzing: "ANALYZING"
            case .ready: "READY"
            case .mixing: "MIXING"
            case .preservingEnding: "PRESERVING ENDING"
            }
        }
    }

    /// Offline local-file features. The confidence values prevent the mixer from presenting a
    /// guess as a musical or lyric-aware decision.
    struct Analysis: Equatable {
        let tempo: Double?
        let tempoConfidence: Double
        let beatGrid: [TimeInterval]
        let leadingSilence: TimeInterval
        let trailingSilence: TimeInterval
        let fadeOutCue: TimeInterval?
        let phraseOutroCue: TimeInterval?
        let safeOutroCue: TimeInterval?

        var summary: String {
            guard let tempo else { return "ANALYSED • NO CONFIDENT TEMPO" }
            return String(format: "ANALYSED • %.0f BPM • %.0f%%", tempo, tempoConfidence * 100)
        }
    }

    struct Track: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let duration: TimeInterval
        let tailSilence: TimeInterval
        let analysis: Analysis
    }

    struct Transition {
        let duration: TimeInterval
        let description: String
    }

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var nowPlaying: Track?
    @Published private(set) var transitionDescription = "Add local music to begin."
    @Published private(set) var isPreparing = false
    @Published private(set) var isPlaying = false
    @Published private(set) var notice: String?
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var playbackDuration: TimeInterval = 0
    @Published private(set) var mixState: MixState = .idle
    /// Real-time energy bars sampled from KnobShift's own audio mixer for the player visualizer.
    @Published private(set) var visualizerLevels = Array(repeating: Float(0.08), count: 42)

    private let analyser = KnobShiftAnalyser()
    private let audioEngine = AVAudioEngine()
    private let deckOne = AVAudioPlayerNode()
    private let deckTwo = AVAudioPlayerNode()
    private var primaryDeck: AVAudioPlayerNode
    private var secondaryDeck: AVAudioPlayerNode
    private var currentIndex = 0
    private var transitionTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var playbackStartedAt = Date()
    private var activeStyle: Style = .gentle

    init(restoresQueue: Bool = true) {
        primaryDeck = deckOne
        secondaryDeck = deckTwo
        audioEngine.attach(deckOne)
        audioEngine.attach(deckTwo)
        audioEngine.connect(deckOne, to: audioEngine.mainMixerNode, format: nil)
        audioEngine.connect(deckTwo, to: audioEngine.mainMixerNode, format: nil)
        installVisualizerTap()
        if restoresQueue {
            Task { [weak self] in await self?.restoreQueue() }
        }
    }

    func addTracks(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isPreparing = true
        mixState = .analyzing
        defer { isPreparing = false }
        for url in urls where !tracks.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            do { tracks.append(try await analyser.track(for: url)) }
            catch { notice = "One or more files could not be prepared for KnobShift." }
        }
        persistQueue()
        if !tracks.isEmpty, !isPlaying {
            mixState = .ready
            transitionDescription = "Local analysis is ready. Choose a track to begin."
        }
    }

    func play(style: Style) {
        guard !tracks.isEmpty else { return }
        stop()
        currentIndex = min(currentIndex, tracks.count - 1)
        activeStyle = style
        do {
            if !audioEngine.isRunning { try audioEngine.start() }
            try playCurrent(style: style)
        } catch {
            notice = "KnobShift could not play this file."
        }
    }

    func stop() {
        transitionTask?.cancel()
        transitionTask = nil
        deckOne.stop()
        deckTwo.stop()
        progressTask?.cancel()
        progressTask = nil
        isPlaying = false
        nowPlaying = nil
        playbackTime = 0
        playbackDuration = 0
        visualizerLevels = Array(repeating: 0.08, count: visualizerLevels.count)
        mixState = tracks.isEmpty ? .idle : .ready
    }

    /// Used only by Knob's command-line smoke check. The audio graph still runs, but its output
    /// is muted so automated checks never make sound or change the system output.
    func playSilentlyForCheck(style: Style) {
        audioEngine.mainMixerNode.outputVolume = 0
        play(style: style)
    }

    func remove(_ track: Track) {
        guard let index = tracks.firstIndex(of: track) else { return }
        if nowPlaying == track { stop() }
        tracks.remove(at: index)
        currentIndex = min(currentIndex, max(0, tracks.count - 1))
        persistQueue()
        if tracks.isEmpty {
            mixState = .idle
            transitionDescription = "Add local music to begin."
        }
    }

    func pauseOrResume(style: Style) {
        guard nowPlaying != nil else { play(style: style); return }
        activeStyle = style
        if isPlaying {
            updatePlaybackTime()
            transitionTask?.cancel()
            secondaryDeck.stop()
            primaryDeck.pause()
            progressTask?.cancel()
            isPlaying = false
        } else {
            primaryDeck.play()
            isPlaying = true
            playbackStartedAt = Date().addingTimeInterval(-playbackTime)
            startProgressUpdates()
            scheduleNext(style: style)
        }
    }

    func previous() {
        guard !tracks.isEmpty else { return }
        if playbackTime > 3 { seek(to: 0); return }
        currentIndex = (currentIndex - 1 + tracks.count) % tracks.count
        restartCurrent()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        currentIndex = (currentIndex + 1) % tracks.count
        restartCurrent()
    }

    func select(_ track: Track) {
        guard let index = tracks.firstIndex(of: track) else { return }
        currentIndex = index
        restartCurrent()
    }

    func seek(to time: TimeInterval) {
        guard let track = nowPlaying else { return }
        let wasPlaying = isPlaying
        transitionTask?.cancel()
        secondaryDeck.stop()
        do {
            try schedulePrimary(track, from: min(max(time, 0), track.duration), play: wasPlaying)
            if wasPlaying { scheduleNext(style: activeStyle) }
        } catch {
            notice = "KnobShift could not move within this song."
        }
    }

    private func playCurrent(style: Style) throws {
        let track = tracks[currentIndex]
        try schedulePrimary(track, from: 0, play: true)
        scheduleNext(style: style)
    }

    private func schedulePrimary(_ track: Track, from time: TimeInterval, play: Bool) throws {
        let file = try AVAudioFile(forReading: track.url)
        let start = AVAudioFramePosition((time * file.processingFormat.sampleRate).rounded())
        let remaining = max(0, file.length - start)
        guard remaining > 0, remaining <= AVAudioFramePosition(UInt32.max) else { throw PlayerError.invalidSegment }
        primaryDeck.stop()
        primaryDeck.volume = 1
        primaryDeck.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(remaining), at: nil)
        nowPlaying = track
        playbackDuration = track.duration
        playbackTime = time
        playbackStartedAt = Date().addingTimeInterval(-time)
        isPlaying = play
        if play {
            primaryDeck.play()
            startProgressUpdates()
        }
    }

    private func restartCurrent() {
        transitionTask?.cancel()
        secondaryDeck.stop()
        guard !tracks.isEmpty else { return }
        do { try playCurrent(style: activeStyle) }
        catch { notice = "KnobShift could not play this file." }
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updatePlaybackTime()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func updatePlaybackTime() {
        guard isPlaying else { return }
        playbackTime = min(playbackDuration, max(0, Date().timeIntervalSince(playbackStartedAt)))
    }

    /// Mirrors the source-driven 21st.dev visualizer using only KnobShift's local playback graph.
    /// The tap never reads or changes Knob's system audio engine, audio driver or DSP callback.
    private func installVisualizerTap() {
        // The mixer can invoke its tap far faster than SwiftUI can render. One frame in flight
        // prevents queued UI tasks from building up while preserving a live response.
        let frameGate = DispatchSemaphore(value: 1)
        audioEngine.mainMixerNode.installTap(onBus: 0, bufferSize: 2_048, format: nil) { [weak self, frameGate] buffer, _ in
            guard frameGate.wait(timeout: .now()) == .success else { return }
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else {
                frameGate.signal()
                return
            }
            let bars = 42
            let framesPerBar = max(1, Int(buffer.frameLength) / bars)
            var levels = [Float]()
            levels.reserveCapacity(bars)
            for bar in 0..<bars {
                let start = min(Int(buffer.frameLength) - 1, bar * framesPerBar)
                let end = min(Int(buffer.frameLength), start + framesPerBar)
                var power: Float = 0
                for index in start..<end { power += samples[index] * samples[index] }
                let rms = sqrt(power / Float(max(1, end - start)))
                levels.append(min(1, sqrt(rms) * 2.4))
            }
            Task { @MainActor [weak self] in
                self?.receiveVisualizerLevels(levels)
                frameGate.signal()
            }
        }
    }

    private func receiveVisualizerLevels(_ levels: [Float]) {
        guard isPlaying else { return }
        visualizerLevels = levels
    }

    /// Knob is not sandboxed, so a user-selected local path remains readable after relaunch.
    /// Missing or moved files are quietly removed from the saved queue on restore.
    private func restoreQueue() async {
        let paths = UserDefaults.standard.stringArray(forKey: PersistKey.knobShiftQueue.rawValue) ?? []
        guard !paths.isEmpty else { return }
        isPreparing = true
        defer { isPreparing = false }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let track = try await analyser.track(for: url)
                if !tracks.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    tracks.append(track)
                }
            }
            catch { continue }
        }
        persistQueue()
        if !tracks.isEmpty {
            mixState = .ready
            transitionDescription = "Local analysis is ready. Choose a track to begin."
        }
    }

    private func persistQueue() {
        UserDefaults.standard.set(tracks.map { $0.url.path }, forKey: PersistKey.knobShiftQueue.rawValue)
    }

    private func scheduleNext(style: Style) {
        guard let current = nowPlaying, tracks.count > 1 else {
            mixState = .ready
            transitionDescription = "Playing normally."
            return
        }
        let next = tracks[(currentIndex + 1) % tracks.count]
        let transition = plan(from: current, to: next, style: style)
        transitionDescription = transition.description
        mixState = transition.duration > 0 ? .ready : .preservingEnding
        let wait = max(0, current.duration - playbackTime - transition.duration)
        transitionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            if transition.duration == 0 { self.advance(to: next, style: style) }
            else { self.beginBlend(to: next, transition: transition, style: style) }
        }
    }

    private func plan(from current: Track, to next: Track, style: Style) -> Transition {
        guard let cue = current.analysis.phraseOutroCue ?? current.analysis.safeOutroCue else {
            return Transition(duration: 0, description: "No confident outro cue. KnobShift will preserve the ending.")
        }
        let dynamicWindow = current.duration - cue
        let duration = min(dynamicWindow, next.duration / 4)
        guard duration >= 1 else {
            return Transition(duration: 0, description: "Analysed outro is too short. KnobShift will preserve the ending.")
        }
        let tempoNote: String
        if let outgoing = current.analysis.tempo, let incoming = next.analysis.tempo,
           min(current.analysis.tempoConfidence, next.analysis.tempoConfidence) >= 0.45 {
            let difference = abs(outgoing - incoming) / max(outgoing, incoming)
            tempoNote = difference <= 0.06 ? "Tempo compatible" : "Tempo differs, no stretch"
        } else {
            tempoNote = "Tempo uncertain"
        }
        let cueName = current.analysis.phraseOutroCue == cue ? "phrase cue" : "fade cue"
        return Transition(duration: duration, description: "READY • analysed \(cueName) \(Int(duration.rounded()))s • \(tempoNote).")
    }

    private func beginBlend(to next: Track, transition: Transition, style: Style) {
        do {
            mixState = .mixing
            transitionDescription = "MIXING • \(Int(transition.duration.rounded())) second local transition."
            let file = try AVAudioFile(forReading: next.url)
            secondaryDeck.stop()
            secondaryDeck.volume = 0
            secondaryDeck.scheduleFile(file, at: nil)
            secondaryDeck.play()
            transitionTask = Task { [weak self] in
                let steps = 30
                for step in 0...steps {
                    guard !Task.isCancelled else { return }
                    self?.setBlend(Double(step) / Double(steps), style: style)
                    try? await Task.sleep(for: .seconds(transition.duration / Double(steps)))
                }
                guard !Task.isCancelled else { return }
                self?.finishBlend(to: next, style: style)
            }
        } catch {
            mixState = .preservingEnding
            notice = "KnobShift could not prepare the next song."
            advance(to: next, style: style)
        }
    }

    private func setBlend(_ progress: Double, style: Style) {
        let shaped: Double
        switch style {
        case .gentle: shaped = progress * progress * (3 - 2 * progress)
        case .balanced: shaped = progress
        case .party: shaped = sqrt(progress)
        }
        primaryDeck.volume = Float(cos(shaped * .pi / 2))
        secondaryDeck.volume = Float(sin(shaped * .pi / 2))
    }

    private func finishBlend(to next: Track, style: Style) {
        primaryDeck.stop()
        let outgoing = primaryDeck
        primaryDeck = secondaryDeck
        secondaryDeck = outgoing
        primaryDeck.volume = 1
        currentIndex = tracks.firstIndex(of: next) ?? 0
        nowPlaying = next
        playbackTime = 0
        playbackDuration = next.duration
        playbackStartedAt = Date()
        startProgressUpdates()
        scheduleNext(style: style)
    }

    private func advance(to next: Track, style: Style) {
        primaryDeck.stop()
        secondaryDeck.stop()
        currentIndex = tracks.firstIndex(of: next) ?? 0
        do { try playCurrent(style: style) }
        catch { notice = "KnobShift could not continue playback." }
    }

    private enum PlayerError: Error { case invalidSegment }
}

actor KnobShiftAnalyser {
    func track(for url: URL) throws -> KnobShiftModel.Track {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let duration = Double(file.length) / sampleRate
        guard duration.isFinite, duration > 0 else { throw AnalysisError.invalidFile }
        let windows = try energyWindows(in: file, sampleRate: sampleRate)
        let trailing = silenceDuration(in: windows.reversed())
        let leading = silenceDuration(in: windows)
        let tempo = estimateTempo(from: windows)
        let beats = beatGrid(tempo: tempo.value, windows: windows, duration: duration)
        // A quiet tail is the only safe cue available without supplied timed lyrics. The cue
        // begins at the measured quiet boundary, not at an arbitrary number of seconds.
        let quietStart = duration - trailing
        let fadeOutCue = fadeOutStart(in: windows, quietStart: quietStart)
        let phraseOutroCue = estimatedPhraseCue(duration: duration, tempo: tempo.value,
                                                 confidence: tempo.confidence, beats: beats,
                                                 hasEndingFade: fadeOutCue != nil)
        let safeOutroCue = fadeOutCue ?? (trailing >= 1 ? quietStart : nil)
        let analysis = KnobShiftModel.Analysis(tempo: tempo.value, tempoConfidence: tempo.confidence,
                                                beatGrid: beats, leadingSilence: leading,
                                                trailingSilence: trailing, fadeOutCue: fadeOutCue,
                                                phraseOutroCue: phraseOutroCue, safeOutroCue: safeOutroCue)
        return KnobShiftModel.Track(url: url, title: url.deletingPathExtension().lastPathComponent,
                                    duration: duration, tailSilence: trailing, analysis: analysis)
    }

    private struct EnergyWindow {
        let time: TimeInterval
        let duration: TimeInterval
        let rms: Float
    }

    /// Uses short RMS windows, entirely off the playback and driver callbacks. This supplies
    /// conservative silence and rhythmic-onset candidates, not a claim of lyric recognition.
    private func energyWindows(in file: AVAudioFile, sampleRate: Double) throws -> [EnergyWindow] {
        let frames = AVAudioFrameCount(max(512, min(2_048, Int(sampleRate / 20))))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw AnalysisError.invalidFile
        }
        var windows: [EnergyWindow] = []
        while file.framePosition < file.length {
            buffer.frameLength = 0
            let start = Double(file.framePosition) / sampleRate
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { continue }
            var power: Float = 0
            for index in 0..<Int(buffer.frameLength) { power += samples[index] * samples[index] }
            let length = Double(buffer.frameLength) / sampleRate
            windows.append(EnergyWindow(time: start, duration: length,
                                        rms: sqrt(power / Float(buffer.frameLength))))
        }
        return windows
    }

    private func silenceDuration<S: Sequence>(in windows: S) -> TimeInterval where S.Element == EnergyWindow {
        var total: TimeInterval = 0
        for window in windows {
            guard window.rms < 0.006 else { break }
            total += window.duration
        }
        return total
    }

    private func estimateTempo(from windows: [EnergyWindow]) -> (value: Double?, confidence: Double) {
        guard windows.count > 80 else { return (nil, 0) }
        let step = windows.map(\.duration).reduce(0, +) / Double(windows.count)
        guard step > 0 else { return (nil, 0) }
        let energy = windows.map { Double($0.rms) }
        var onsets = [Double](repeating: 0, count: energy.count)
        for index in 1..<energy.count { onsets[index] = max(0, energy[index] - energy[index - 1]) }
        let mean = onsets.reduce(0, +) / Double(onsets.count)
        let variance = onsets.reduce(0) { $0 + pow($1 - mean, 2) } / Double(onsets.count)
        let deviation = sqrt(variance)
        guard deviation > 0 else { return (nil, 0) }
        onsets = onsets.map { max(0, ($0 - mean) / deviation) }

        var bestBPM: Double?
        var bestScore = 0.0
        for bpm in stride(from: 70.0, through: 180.0, by: 1.0) {
            let lag = Int((60 / (bpm * step)).rounded())
            guard lag > 0, lag < onsets.count / 3 else { continue }
            var score = 0.0
            for index in lag..<onsets.count { score += onsets[index] * onsets[index - lag] }
            if score > bestScore { bestScore = score; bestBPM = bpm }
        }
        guard let bestBPM else { return (nil, 0) }
        let onsetPower = onsets.reduce(0) { $0 + $1 * $1 }
        let confidence = min(1, bestScore / max(0.0001, onsetPower))
        return confidence >= 0.12 ? (bestBPM, confidence) : (nil, confidence)
    }

    /// Finds a sustained end-of-track energy descent before silence. This is deliberately more
    /// conservative than choosing a random final window: it only returns a cue when the envelope
    /// stays substantially below the immediately preceding musical section through the ending.
    private func fadeOutStart(in windows: [EnergyWindow], quietStart: TimeInterval) -> TimeInterval? {
        let active = windows.filter { $0.time < quietStart && $0.rms >= 0.006 }
        guard active.count > 20, let first = active.first, let last = active.last else { return nil }
        let span = last.time - first.time
        guard span > 2 else { return nil }
        let referenceStart = first.time + span * 0.45
        let reference = active.filter { $0.time >= referenceStart }.map { Double($0.rms) }
        guard reference.count > 10 else { return nil }
        let baseline = reference.sorted()[Int(Double(reference.count - 1) * 0.8)]
        guard baseline > 0 else { return nil }
        let windowLength = active.map(\.duration).reduce(0, +) / Double(active.count)
        let confirmation = max(1, Int((0.6 / max(windowLength, 0.001)).rounded()))
        for index in 0..<(active.count - confirmation) {
            let local = active[index..<(index + confirmation)].map { Double($0.rms) }
            let localAverage = local.reduce(0, +) / Double(local.count)
            guard localAverage < baseline * 0.55 else { continue }
            let remaining = active[index...].map { Double($0.rms) }
            let lowerFrames = remaining.filter { $0 < baseline * 0.82 }.count
            if Double(lowerFrames) / Double(remaining.count) >= 0.82 {
                return active[index].time
            }
        }
        return nil
    }

    /// An estimated 16-beat final phrase is useful only when a rhythmic grid and a genuine end
    /// fade are both present. It is a musical cue, not a claim that the last lyric has been read.
    private func estimatedPhraseCue(duration: TimeInterval, tempo: Double?, confidence: Double,
                                    beats: [TimeInterval], hasEndingFade: Bool) -> TimeInterval? {
        guard hasEndingFade, let tempo, confidence >= 0.45 else { return nil }
        let phraseLength = 16 * (60 / tempo)
        guard phraseLength >= 4, phraseLength < duration / 2 else { return nil }
        let estimated = duration - phraseLength
        return beats.min(by: { abs($0 - estimated) < abs($1 - estimated) }) ?? estimated
    }

    private func beatGrid(tempo: Double?, windows: [EnergyWindow], duration: TimeInterval) -> [TimeInterval] {
        guard let tempo, !windows.isEmpty else { return [] }
        let interval = 60 / tempo
        let energies = windows.map { Double($0.rms) }
        guard let strongest = energies.indices.max(by: { energies[$0] < energies[$1] }) else { return [] }
        let anchor = windows[strongest].time
        var beats: [TimeInterval] = []
        var backward = anchor
        while backward > 0 { beats.append(backward); backward -= interval }
        var forward = anchor + interval
        while forward < duration { beats.append(forward); forward += interval }
        return beats.sorted()
    }

    private enum AnalysisError: Error { case invalidFile }
}
