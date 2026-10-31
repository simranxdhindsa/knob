import AVFoundation
import Foundation

/// KnobShift owns local, non-DRM music that the user explicitly chooses in Knob. Its two audio
/// players are kept entirely outside Knob's system-audio engine, driver and DSP callbacks.
@MainActor
final class KnobShiftModel: ObservableObject {
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
    struct Analysis: Equatable, Codable {
        let tempo: Double?
        let tempoConfidence: Double
        let beatGrid: [TimeInterval]
        let leadingSilence: TimeInterval
        let trailingSilence: TimeInterval
        let fadeOutCue: TimeInterval?
        let safeOutroCue: TimeInterval?
        /// Where the first steady vocal line starts and the last one really ends.
        let vocalOnset: TimeInterval?
        let vocalEnd: TimeInterval?
        /// Where the last steady vocal line begins.
        var lastLineStart: TimeInterval? = nil
        /// Where the main verse starts (after any intro ad-libs).
        var mainVocalOnset: TimeInterval? = nil
        /// Short vocal sounds after the last steady line.
        var vocalStrays: [TimeInterval] = []

        /// Where the song is actually heard, without leading or trailing silence.
        func audibleEnd(duration: TimeInterval) -> TimeInterval { max(0, duration - trailingSilence) }

        var summary: String {
            let tempoText = tempo.map { String(format: "%.0f BPM", $0) } ?? "TEMPO UNSURE"
            guard let vocalOnset, let vocalEnd else { return "ANALYSED • \(tempoText) • INSTRUMENTAL" }
            return "ANALYSED • \(tempoText) • VOICE \(Self.clock(vocalOnset)) TO \(Self.clock(vocalEnd))"
        }

        static func clock(_ value: TimeInterval) -> String {
            String(format: "%d:%02d", Int(value) / 60, Int(value) % 60)
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

    /// Recent entries are available to the player UI; the complete history is written to disk.
    struct Diagnostic: Identifiable {
        /// Deck levels during a blend, so the log can draw them instead of only printing numbers.
        struct Blend {
            let progress: Double
            let outgoing: Double
            let incoming: Double
            var tempo: Double?
        }

        let id = UUID()
        let timestamp: Date
        let stage: String
        let message: String
        var blend: Blend?
        /// A heading that starts a new group, such as one song's analysis or one transition.
        var isSection: Bool { stage == "SECTION" }
    }

    @Published private(set) var tracks: [Track] = []
    @Published internal(set) var nowPlaying: Track?
    @Published internal(set) var transitionDescription = "Add local music to begin."
    @Published private(set) var isPreparing = false
    @Published private(set) var isPlaying = false
    @Published internal(set) var notice: String?
    @Published internal(set) var playbackTime: TimeInterval = 0
    @Published internal(set) var playbackDuration: TimeInterval = 0
    @Published internal(set) var mixState: MixState = .idle
    @Published private(set) var diagnostics: [Diagnostic] = []
    /// Real-time energy bars sampled from KnobShift's own audio mixer for the player visualizer.
    @Published private(set) var visualizerLevels = Array(repeating: Float(0.08), count: 42)

    private let analyser = KnobShiftAnalyser()
    private let audioEngine = AVAudioEngine()
    private let deckOne: KnobShiftDeck
    private let deckTwo: KnobShiftDeck
    /// The deck the listener hears now; the other one brings in the next song. They swap roles
    /// after every blend. Set only here and in KnobShiftModel+Blend.swift.
    var primaryDeck: KnobShiftDeck
    var secondaryDeck: KnobShiftDeck
    var currentIndex = 0
    var transitionTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    var playbackStartedAt = Date()
    private var configurationObserver: NSObjectProtocol?
    /// The song the current plan or blend leads into, for the log when it is called off.
    var plannedNext: Track?

    private var outputFormatDescription: String {
        let format = audioEngine.outputNode.outputFormat(forBus: 0)
        return String(format: "output %.0f Hz, %d channel(s)", format.sampleRate, Int(format.channelCount))
    }

    init(restoresQueue: Bool = true) {
        let engine = audioEngine
        deckOne = KnobShiftDeck(name: "Deck 1", engine: engine)
        deckTwo = KnobShiftDeck(name: "Deck 2", engine: engine)
        primaryDeck = deckOne
        secondaryDeck = deckTwo
        installVisualizerTap()
        log("SESSION", "Local mixer initialized with Deck 1 and Deck 2.")
        // The engine stops itself when the Mac's output device changes; log it so a silent or
        // stalled mix can be matched to the device change that caused it.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log("DEVICE", "Output configuration changed. Engine running: \(self.audioEngine.isRunning), \(self.outputFormatDescription).")
            }
        }
        if restoresQueue {
            Task { [weak self] in await self?.restoreQueue() }
        }
    }

    func addTracks(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        log("IMPORT", "Preparing \(urls.count) local file(s).")
        isPreparing = true
        mixState = .analyzing
        defer { isPreparing = false }
        for url in urls where !tracks.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            do {
                log("ANALYSIS", "Analysing \(url.lastPathComponent).")
                let result = try await analyser.analyse(url)
                tracks.append(result.track)
                logAnalysis(result)
            } catch {
                log("ERROR", "Analysis failed for \(url.lastPathComponent): \(error.localizedDescription)")
                notice = "One or more files could not be prepared for KnobShift."
            }
        }
        persistQueue()
        if !tracks.isEmpty, !isPlaying {
            mixState = .ready
            transitionDescription = "Local analysis is ready. Choose a track to begin."
            log("READY", "Analysis completed for \(tracks.count) queued track(s).")
        }
    }

    func play() {
        guard !tracks.isEmpty else { return }
        stop()
        currentIndex = min(currentIndex, tracks.count - 1)
        log("PLAY", "Starting \(tracks[currentIndex].title).")
        do {
            try playCurrent()
        } catch {
            log("ERROR", "Playback startup failed: \(error.localizedDescription)")
            notice = "KnobShift could not play this file."
        }
    }

    func stop() {
        if isPlaying { log("STOP", "Stopped local playback.") }
        cancelPlan("Playback stopped")
        for deck in [deckOne, deckTwo] {
            deck.player.stop()
            deck.resetEffects()
        }
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
    func playForCheck(volume: Float = 0, bySelecting track: Track? = nil) {
        audioEngine.mainMixerNode.outputVolume = min(max(volume, 0), 1)
        log("CHECK", String(format: "Check playback at %.0f%% volume.", min(max(volume, 0), 1) * 100))
        if let track { select(track) } else { play() }
    }

    func remove(_ track: Track) {
        guard let index = tracks.firstIndex(of: track) else { return }
        if nowPlaying == track { stop() }
        tracks.remove(at: index)
        log("QUEUE", "Removed \(track.title).")
        currentIndex = min(currentIndex, max(0, tracks.count - 1))
        persistQueue()
        if tracks.isEmpty {
            mixState = .idle
            transitionDescription = "Add local music to begin."
        }
    }

    func pauseOrResume() {
        guard nowPlaying != nil else { play(); return }
        if isPlaying {
            updatePlaybackTime()
            log("PLAY", "Paused at \(Self.seconds(playbackTime)).")
            cancelPlan("Paused")
            secondaryDeck.player.stop()
            primaryDeck.player.pause()
            progressTask?.cancel()
            isPlaying = false
        } else {
            log("PLAY", "Resumed at \(Self.seconds(playbackTime)).")
            do { try startEngineIfNeeded() }
            catch {
                log("ERROR", "Resume failed: \(error.localizedDescription)")
                notice = "KnobShift could not play this file."
                return
            }
            primaryDeck.player.play()
            isPlaying = true
            playbackStartedAt = Date().addingTimeInterval(-playbackTime)
            startProgressUpdates()
            scheduleNext()
        }
    }

    func previous() {
        guard !tracks.isEmpty else { return }
        if playbackTime > 3 { seek(to: 0); return }
        currentIndex = (currentIndex - 1 + tracks.count) % tracks.count
        log("TRANSPORT", "Previous track: \(tracks[currentIndex].title).")
        restartCurrent()
    }

    func next() {
        guard !tracks.isEmpty else { return }
        currentIndex = (currentIndex + 1) % tracks.count
        log("TRANSPORT", "Next track: \(tracks[currentIndex].title).")
        restartCurrent()
    }

    func select(_ track: Track) {
        guard let index = tracks.firstIndex(of: track) else { return }
        currentIndex = index
        log("TRANSPORT", "Selected \(track.title).")
        restartCurrent()
    }

    func seek(to time: TimeInterval) {
        guard let track = nowPlaying else { return }
        let wasPlaying = isPlaying
        cancelPlan("You moved to \(Analysis.clock(time))")
        secondaryDeck.player.stop()
        do {
            log("SEEK", "Moving \(track.title) to \(String(format: "%.2f", time))s.")
            try schedulePrimary(track, from: min(max(time, 0), track.duration), play: wasPlaying)
            if wasPlaying { scheduleNext() }
        } catch {
            log("ERROR", "Seek failed: \(error.localizedDescription)")
            notice = "KnobShift could not move within this song."
        }
    }

    private func playCurrent() throws {
        let track = tracks[currentIndex]
        try schedulePrimary(track, from: 0, play: true)
        scheduleNext()
    }

    func schedulePrimary(_ track: Track, from time: TimeInterval, play: Bool) throws {
        let file = try AVAudioFile(forReading: track.url)
        let start = AVAudioFramePosition((time * file.processingFormat.sampleRate).rounded())
        let remaining = max(0, file.length - start)
        guard remaining > 0, remaining <= AVAudioFramePosition(UInt32.max) else { throw PlayerError.invalidSegment }
        primaryDeck.player.stop()
        primaryDeck.resetEffects()
        primaryDeck.startOffset = time
        primaryDeck.player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(remaining), at: nil)
        nowPlaying = track
        playbackDuration = track.duration
        playbackTime = time
        playbackStartedAt = Date().addingTimeInterval(-time)
        isPlaying = play
        if play {
            try startEngineIfNeeded()
            primaryDeck.player.play()
            startProgressUpdates()
        }
        log("DECK", "\(primaryDeck.name) is primary: \(track.title) from \(Self.seconds(time)) of \(Self.seconds(track.duration)), \(remaining) frames, \(play ? "playing" : "paused").")
    }

    /// Every way of making sound goes through here: Play, clicking a song, Next, Previous,
    /// Resume and the incoming deck of a blend. The engine only starts when something plays.
    func startEngineIfNeeded() throws {
        guard !audioEngine.isRunning else { return }
        try audioEngine.start()
        log("ENGINE", "Local audio engine started, \(outputFormatDescription).")
    }

    /// Calls off the planned or running transition and says why, at the moment it happens.
    private func cancelPlan(_ reason: String) {
        guard let task = transitionTask else { return }
        task.cancel()
        transitionTask = nil
        guard let next = plannedNext else { return }
        if mixState == .mixing {
            log("KNOBMIX", "\(reason), so the blend into \(next.title) stops here.")
        } else {
            log("PLAN", "\(reason), so the plan into \(next.title) is replaced.")
        }
        plannedNext = nil
    }

    private func restartCurrent() {
        cancelPlan("You switched to \(tracks.indices.contains(currentIndex) ? tracks[currentIndex].title : "another song")")
        secondaryDeck.player.stop()
        guard !tracks.isEmpty else { return }
        do { try playCurrent() }
        catch {
            log("ERROR", "Restart failed: \(error.localizedDescription)")
            notice = "KnobShift could not play this file."
        }
    }

    func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updatePlaybackTime()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Reads where the song really is from its deck, which stays right while KnobShift slows or
    /// speeds it up; the wall clock is only a fallback before the deck has rendered.
    private func updatePlaybackTime() {
        guard isPlaying else { return }
        let position = primaryDeck.position ?? Date().timeIntervalSince(playbackStartedAt)
        playbackTime = min(playbackDuration, max(0, position))
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

    func openDiagnosticLog() {
        log("LOG", "Opening KnobShift diagnostics.")
        KnobShiftLog.open()
    }

    func log(_ stage: String, _ message: String, blend: Diagnostic.Blend? = nil) {
        let entry = Diagnostic(timestamp: Date(), stage: stage, message: message, blend: blend)
        diagnostics.append(entry)
        if diagnostics.count > 400 { diagnostics.removeFirst(diagnostics.count - 400) }
        KnobShiftLog.append(stage: stage, message: message, at: entry.timestamp)
    }

    /// Screenshot only: one of each kind of log row, so the log's look can be checked in PNGs.
    func showSampleLogForSnapshot() {
        logSection("Analysis • Ghostface Killah")
        log("ANALYSIS", "Tempo: 96 BPM, confidence 63% (accepted, minimum 12%).")
        log("ANALYSIS", "Vocal end: 119.25s, where the last steady line fades out. Ignored short sounds after it at 125.2s, 128.2s.")
        logSection("Ghostface Killah → Shaukeen")
        log("PLAN", "Ghostface Killah: its last vocal line ends at 1:59.25, leaving 15.43s of music.")
        log("PLAN", "Shaukeen: its voice enters 10.45s in, at 68% of the blend, over the old music only.")
        log("KNOBMIX", "Starting 15.43s blend. Outgoing Deck 1, incoming Deck 2 with Shaukeen.")
        log("SYNC", "Tempo sync on: 100.0 to 102.7 BPM, 2.7% apart. Both glide to a shared tempo, pitch stays natural.")
        log("KNOBMIX", "+7.46s 50% done", blend: Diagnostic.Blend(progress: 0.5, outgoing: 0.70, incoming: 0.71, tempo: 101.3))
    }

    func logSection(_ title: String) {
        log("SECTION", title)
    }

    private func logAnalysis(_ result: KnobShiftAnalyser.Result) {
        logSection("Analysis • \(result.track.title)")
        for step in result.steps { log("ANALYSIS", step) }
        log("ANALYSIS", "Result: \(result.track.analysis.summary).")
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }

    /// Knob is not sandboxed, so a user-selected local path remains readable after relaunch.
    /// Missing or moved files are quietly removed from the saved queue on restore.
    private func restoreQueue() async {
        let paths = UserDefaults.standard.stringArray(forKey: PersistKey.knobShiftQueue.rawValue) ?? []
        guard !paths.isEmpty else { return }
        log("RESTORE", "Restoring \(paths.count) local file reference(s).")
        isPreparing = true
        defer { isPreparing = false }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                log("RESTORE", "Skipped \(url.lastPathComponent): the file is no longer there.")
                continue
            }
            do {
                let result = try await analyser.analyse(url)
                if !tracks.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    tracks.append(result.track)
                    logAnalysis(result)
                }
            }
            catch {
                log("ERROR", "Restore analysis failed for \(url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
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

    enum PlayerError: Error { case invalidSegment }
}
