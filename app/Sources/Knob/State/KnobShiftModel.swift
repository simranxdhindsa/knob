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

        /// "Title - Artist" file names show as a title with the artist underneath.
        var name: String { Self.split(title).name }
        var artist: String? { Self.split(title).artist }
        static func split(_ title: String) -> (name: String, artist: String?) {
            guard let range = title.range(of: " - ", options: .backwards) else { return (title, nil) }
            let name = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let artist = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || artist.isEmpty ? (title, nil) : (name, artist)
        }
    }

    /// A song added to the queue that is still being prepared (or failed to be).
    struct PendingSong: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        /// 0...1 through the analysis; 0 while waiting its turn.
        var progress: Double = 0
        var isActive = false
        /// Set when preparing failed; the queue offers Retry.
        var failure: String?
        var title: String { url.deletingPathExtension().lastPathComponent }
        /// "Title - Artist" file names split the same way as ready songs.
        var name: String { Track.split(title).name }
        var artist: String? { Track.split(title).artist }
    }

    /// The planned transition, as the player shows it.
    struct NextMix: Equatable {
        let next: Track
        /// Position in the current song where the next one comes in, and where the blend ends.
        let startsAt: TimeInterval
        let endsAt: TimeInterval
        /// Clock time the mix starts.
        let at: Date
        let blends: Bool
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
    /// The next transition as planned, for the player's Up Next card and mix marker.
    @Published internal(set) var nextMix: NextMix?
    /// The song coming in while a blend runs, and how far the blend is (0...1).
    @Published internal(set) var mixingInto: Track?
    @Published internal(set) var blendProgress: Double = 0
    /// Songs added but not ready yet, prepared one at a time in the order they were added.
    @Published private(set) var pending: [PendingSong] = []

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
    private var isProcessing = false

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

    /// Adds songs to the queue at once; they are prepared one by one in the background. Returns
    /// once every waiting song has been prepared (or has failed).
    func addTracks(_ urls: [URL]) async {
        let new = urls.filter { url in !isQueued(url) }
        guard !new.isEmpty else { return }
        log("IMPORT", "Added \(new.count) song(s) to the queue. Preparing them one by one.")
        pending.append(contentsOf: new.map { PendingSong(url: $0) })
        persistQueue()
        await processPending()
    }

    func retry(_ song: PendingSong) {
        guard let index = pending.firstIndex(where: { $0.id == song.id }) else { return }
        pending[index].failure = nil
        pending[index].progress = 0
        log("IMPORT", "Retrying \(song.title).")
        Task { await processPending() }
    }

    func removePending(_ song: PendingSong) {
        pending.removeAll { $0.id == song.id }
        persistQueue()
    }

    private func isQueued(_ url: URL) -> Bool {
        let path = url.standardizedFileURL
        return tracks.contains { $0.url.standardizedFileURL == path } || pending.contains { $0.url.standardizedFileURL == path }
    }

    /// Prepares waiting songs in order. A second call while this runs returns at once; the
    /// running loop picks up anything added meanwhile.
    private func processPending() async {
        guard !isProcessing else { return }
        isProcessing = true
        isPreparing = true
        if !isPlaying { mixState = .analyzing }
        defer {
            isProcessing = false
            isPreparing = false
        }
        while let index = pending.firstIndex(where: { $0.failure == nil }) {
            let song = pending[index]
            pending[index].isActive = true
            pending[index].progress = 0.02
            log("ANALYSIS", "Analysing \(song.url.lastPathComponent).")
            do {
                let id = song.id
                let result = try await analyser.analyse(song.url) { [weak self] value in
                    Task { @MainActor [weak self] in self?.setProgress(value, for: id) }
                }
                pending.removeAll { $0.id == song.id }
                tracks.append(result.track)
                logAnalysis(result)
                refreshPlanIfNeeded()
            } catch {
                if let failed = pending.firstIndex(where: { $0.id == song.id }) {
                    pending[failed].isActive = false
                    pending[failed].failure = "Could not read this file"
                }
                log("ERROR", "Analysis failed for \(song.url.lastPathComponent): \(error.localizedDescription)")
            }
            persistQueue()
        }
        if !tracks.isEmpty, !isPlaying {
            mixState = .ready
            transitionDescription = "Ready. Choose a song to begin."
            log("READY", "Prepared \(tracks.count) song(s).")
        }
    }

    private func setProgress(_ value: Double, for id: UUID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].progress = max(pending[index].progress, value)
    }

    /// When a newly ready song becomes the next one while music plays, plan the mix into it.
    private func refreshPlanIfNeeded() {
        guard isPlaying, mixState != .mixing, nowPlaying != nil, tracks.count > 1,
              abs(primaryDeck.rate - 1) < 0.001 else { return }
        let expected = tracks[(currentIndex + 1) % tracks.count]
        guard plannedNext != expected else { return }
        cancelPlan("The queue changed")
        scheduleNext()
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
        nextMix = nil
        mixingInto = nil
        blendProgress = 0
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
        nextMix = nil
        mixingInto = nil
        blendProgress = 0
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

    func log(_ stage: String, _ message: String, blend: Diagnostic.Blend? = nil) {
        let entry = Diagnostic(timestamp: Date(), stage: stage, message: message, blend: blend)
        diagnostics.append(entry)
        if diagnostics.count > 400 { diagnostics.removeFirst(diagnostics.count - 400) }
        KnobShiftLog.append(stage: stage, message: message, at: entry.timestamp)
    }

    /// Screenshot only: a queue with one song playing and its next mix planned, or mid-mix.
    func showPreviewForSnapshot(mixing: Bool) {
        let titles = ["Ghostface Killah - Sidhu Moose Wala", "No Luck - Prem Dhillon", "Shaukeen - Karan Aujla",
                      "Why So - Shubh", "Daaru Sasti - Arjan Dhillon"]
        tracks = titles.enumerated().map { index, title in
            Track(url: URL(fileURLWithPath: "/nonexistent/\(title).mp3"), title: title, duration: 160 + Double(index * 17),
                  tailSilence: 1, analysis: Analysis(tempo: [100, 145, 102.7, 90, 88][index], tempoConfidence: 0.9, beatGrid: [],
                                                     leadingSilence: 0, trailingSilence: 1, fadeOutCue: nil, safeOutroCue: nil,
                                                     vocalOnset: 5, vocalEnd: 140))
        }
        currentIndex = 0
        nowPlaying = tracks[0]
        playbackDuration = tracks[0].duration
        playbackTime = mixing ? 117 : 64
        isPlaying = true
        nextMix = NextMix(next: tracks[1], startsAt: 114.4, endsAt: 124.1, at: Date().addingTimeInterval(mixing ? 0 : 83), blends: true)
        mixState = mixing ? .mixing : .ready
        mixingInto = mixing ? tracks[1] : nil
        blendProgress = mixing ? 0.45 : 0
        pending = [PendingSong(url: URL(fileURLWithPath: "/nonexistent/Nagni - TEJAY.mp3"), progress: 0.6, isActive: true),
                   PendingSong(url: URL(fileURLWithPath: "/nonexistent/18 Lakh - Rehal.mp3")),
                   PendingSong(url: URL(fileURLWithPath: "/nonexistent/Broken File.mp3"), failure: "Could not read this file")]
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
        log("RESTORE", "Restoring \(paths.count) song(s).")
        var urls: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) { urls.append(url) }
            else { log("RESTORE", "Skipped \(url.lastPathComponent): the file is no longer there.") }
        }
        await addTracks(urls)
    }

    private func persistQueue() {
        let paths = tracks.map { $0.url.path } + pending.map { $0.url.path }
        UserDefaults.standard.set(paths, forKey: PersistKey.knobShiftQueue.rawValue)
    }

    enum PlayerError: Error { case invalidSegment }
}
