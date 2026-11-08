#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
        /// Where the kick and bass first come in and stay.
        var beatEntry: TimeInterval? = nil
        /// Where the bass drops out for a moment: the breaks between sections.
        var musicBreaks: [TimeInterval] = []
        /// Where each sung line ends, for KnobMix Now to leave a song between lines.
        var vocalLineEnds: [TimeInterval]? = nil
        /// Where the song's last hook (its final repeat of the main section) begins.
        var lastHookStart: TimeInterval? = nil

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
        var analysis: Analysis
        /// Its voice could not be read, so KnobMix knows less about it. It is read once more
        /// quietly (`voiceRetried`); only after that does the queue offer Retry.
        var voiceUnread = false
        var voiceRetried = false
        /// The file's own title and artists, when it has tags (KnobShiftTags).
        var tags: KnobShiftTags.Tags? = nil
        /// Set for songs that came from a Spotify playlist (KnobShiftModel+Spotify.swift).
        var spotifyId: String? = nil
        var playlistId: String? = nil

        /// The file's tags first; otherwise "Title - Artist" file names show as a title with the
        /// artist underneath.
        var name: String { tags?.title ?? Self.split(title).name }
        var artist: String? { tags?.artist ?? Self.split(title).artist }
        static func split(_ title: String) -> (name: String, artist: String?) {
            let title = KnobShiftPlaylists.plainTitle(title)
            guard let range = title.range(of: " - ", options: .backwards) else { return (title, nil) }
            let name = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let artist = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return name.isEmpty || artist.isEmpty ? (title, nil) : (name, artist)
        }
    }

    /// A song added to the queue that is still being prepared (or failed to be).
    struct PendingSong: Identifiable, Equatable {
        let id = UUID()
        /// The song's file; for a Spotify song still downloading, where its file will be.
        var url: URL
        /// Spotify songs show their Spotify name and artists while they download.
        var spotifyId: String? = nil
        var playlistId: String? = nil
        var spotifyName: String? = nil
        var spotifyArtist: String? = nil
        /// True until the Spotify download has written the file; analysis waits for it.
        var waitingForDownload = false
        /// "Finding", "Downloading" while a Spotify song is on its way.
        var stage: String? = nil
        /// 0...1 through the analysis; 0 while waiting its turn.
        var progress: Double = 0
        var isActive = false
        /// Set when preparing failed; the queue offers Retry.
        var failure: String?
        /// Where it joins the queue once prepared (a song synced from the Mac); nil adds it at the end.
        var placement: KnobShiftSyncPlan.Placement? = nil
        /// False for a song on its way into a playlist only (an import or a sync): it stays out
        /// of the queue, and once downloaded and prepared it waits in its playlist, ready to add.
        var joinsQueue = true
        var title: String { url.deletingPathExtension().lastPathComponent }
        /// "Title - Artist" file names split the same way as ready songs.
        var name: String { spotifyName ?? Track.split(title).name }
        var artist: String? { spotifyArtist ?? Track.split(title).artist }
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

    /// The queue in play order: the user's order, or the shuffled one (KnobShiftModel+Queue.swift).
    @Published internal(set) var tracks: [Track] = []
    @Published internal(set) var isShuffled = false
    /// Mix Order is on: the songs after the playing one are arranged by tempo. Like shuffle it
    /// keeps the user's own order in `unshuffled`, and the two are never on together.
    @Published internal(set) var isMixOrdered = false
    var mixOrderToRestore = false
    /// The user's own order from before the first sort, so a sort can be taken back. A drag makes
    /// a new order of their own, and this goes.
    @Published internal(set) var orderBeforeSort: [Track]?
    /// KnobMix Now was pressed and the mix is waiting for its phrase or break.
    @Published internal(set) var mixNowWaiting = false
    /// The user's own order while shuffle is on, so turning it off brings that order back.
    var unshuffled: [Track] = []
    /// The shuffled order waiting to be put back while a saved queue is restored.
    var shuffleToRestore: [String]?
    @Published internal(set) var nowPlaying: Track?
    /// For the log and checks only; nothing on screen shows it, so it never redraws the player.
    internal(set) var transitionDescription = "Add local music to begin."
    @Published internal(set) var isPreparing = false
    /// Songs that have just finished preparing, whose covers fade in.
    @Published internal(set) var justPrepared: Set<UUID> = []
    /// Covers being read while their songs are measured, so they are ready when the song is.
    var coverLoads: [UUID: Task<Void, Never>] = [:]
    /// Songs whose voice is being read again.
    @Published internal(set) var rereading: Set<UUID> = []
    @Published internal(set) var isPlaying = false
    @Published internal(set) var notice: String?
    /// Where the song is, ten times a second. It lives in its own object so only the timelines
    /// redraw, not the queue with its hundreds or thousands of rows.
    let clock = KnobShiftClock()
    var playbackTime: TimeInterval { get { clock.time } set { clock.time = newValue } }
    var playbackDuration: TimeInterval { get { clock.duration } set { clock.duration = newValue } }
    @Published internal(set) var mixState: MixState = .idle
    /// The recent log, for the command line checks; the terminal shows the full log.
    private(set) var diagnostics: [Diagnostic] = []
    /// The next transition as planned, for the player's Up Next card and mix marker.
    @Published internal(set) var nextMix: NextMix?
    /// The song coming in while a blend runs, and how far the blend is (0...1).
    @Published internal(set) var mixingInto: Track?
    var blendProgress: Double { get { clock.blend } set { clock.blend = newValue } }
    /// Songs added but not ready yet, prepared one at a time in the order they were added.
    @Published internal(set) var pending: [PendingSong] = []
    /// Spotify playlists in the queue and ones removed in the last 30 days
    /// (KnobShiftModel+Spotify.swift).
    @Published internal(set) var playlists: [KnobShiftPlaylist] = []
    @Published internal(set) var removedPlaylists: [KnobShiftRemovedPlaylist] = []
    var persistScheduled = false
    /// When the song in the player and its position were last saved (rememberNowPlaying).
    var rememberedAt = Date.distantPast
    #if os(macOS)
    @Published internal(set) var spotifyLoggedIn = false
    /// Signed in to YouTube with Google, and signing in now; the dashboard's rows are in youtubeHub.
    @Published internal(set) var youtubeSignedIn = false
    @Published internal(set) var youtubeSigningIn = false
    let youtubeHub = KnobShiftYouTubeHub()
    /// One plain sentence about the latest Spotify step, shown in the Spotify sheet.
    @Published internal(set) var spotifyStatus: String?
    @Published internal(set) var spotifyBusy = false
    /// Running downloads by playlist id.
    var spotifyJobs: [String: UUID] = [:]
    /// YouTube blocked a download this session and a browser is chosen, so downloads now use it.
    var youtubeBrowserInUse = false
    /// The browser login waiting for Spotify, so LOG IN can turn into CANCEL.
    @Published internal(set) var spotifyLoginJob: UUID?
    /// Reading a list from Spotify, so the sheet can offer Cancel.
    @Published internal(set) var spotifyReadJob: UUID?
    /// A list just read, waiting for the user to tick the songs to add.
    @Published internal(set) var spotifyReview: SpotifyReview?
    /// Download progress by playlist id, as the views see it (updated at most twice a second).
    @Published internal(set) var spotifyProgress: [String: KnobShiftImport.Progress] = [:]
    /// The live progress behind it, updated on every line spotDL prints.
    var downloadProgress: [String: KnobShiftImport.Progress] = [:]
    var progressPublishScheduled = false
    var collectScheduled: Set<String> = []
    /// spotDL downloads one playlist at a time; single song retries have their own lane.
    let spotifyLane = KnobShiftLane()
    let spotifyRetryLane = KnobShiftLane()
    /// Each playlist's songs exactly as spotDL describes them, to download without asking
    /// Spotify again.
    var spotifyRaw: [String: [String: Data]] = [:]
    /// Songs waiting for their playlist's next spotDL run, by playlist id.
    var queuedDownloads: [String: [KnobShiftSpotDL.Song]] = [:]
    /// The logged in Spotify account's name and playlists, for the Spotify sheet.
    @Published internal(set) var spotifyAccount: KnobShiftSpotifyAccount.Account?
    @Published internal(set) var spotifyAccountLoading = false
    #endif

    /// One per song being prepared at once: an analyser works on one song at a time.
    let analysers = [KnobShiftAnalyser(), KnobShiftAnalyser()]
    let audioEngine = AVAudioEngine()
    private let deckOne: KnobShiftDeck
    private let deckTwo: KnobShiftDeck
    /// The deck the listener hears now; the other one brings in the next song. They swap roles
    /// after every blend. Set only here and in KnobShiftModel+Blend.swift.
    var primaryDeck: KnobShiftDeck
    var secondaryDeck: KnobShiftDeck
    var currentIndex = 0
    /// The next song's separated voice and music for the coming mix (KnobShiftModel+Stems.swift).
    var preparedStems: KnobShiftStems.Prepared?
    var stemTask: Task<Void, Never>?
    /// True while the incoming song plays as separated music and voice.
    var blendHasStems = false
    /// The leaving song's separated voice and music for the coming mix, and whether the leaving
    /// deck has switched over to them (KnobShiftModel+Stems.swift).
    var preparedOutgoingStems: KnobShiftStems.Prepared?
    var outgoingOnStems = false
    /// Transition effects already announced in the log for the current blend.
    var effectsLogged: Set<String> = []
    /// How the leaving song exits in the current blend (KnobShiftExitEffects.swift).
    var exitStyle: KnobShiftExitStyle?
    /// How far the slowdown goes for this song: 0.8...1.2, so 8% to 12% slower at its peak.
    var tapeDepth = 1.0
    /// The leaving song's separated voice is slowing alone (a vocal throw), so the whole deck
    /// is not slowed too.
    var throwingVoice = false
    /// The exit effects' strength at their peak for the current mix, at most half.
    var exitStrength = 0.5
    var transitionTask: Task<Void, Never>?
    var mixPause = MixPause()
    var progressTask: Task<Void, Never>?
    /// Set while the iPhone's record holds the song. Anything that moves the song, from any
    /// button or the lock screen, ends the hold first, so the song never plays twice.
    var releaseHold: (() -> Void)?
    var playbackStartedAt = Date()
    private var configurationObserver: NSObjectProtocol?
    /// Everything KnobShift plays meets here, before any device's volume: what Listen Together
    /// sends. The gate is open unless a session plays this device through its delay instead.
    let deckBus = AVAudioMixerNode()
    let deckGate = AVAudioMixerNode()
    /// The running Listen Together session, if any.
    var together: KnobShiftTogetherPlayer?
    var togetherCapture: KnobShiftTogetherCapture?
    /// The song the current plan or blend leads into, for the log when it is called off.
    var plannedNext: Track?
    /// Another device's music shown in the player while listening to it (KnobShiftModel+Mirror.swift).
    var mirror: KnobShiftMirror?
    var isProcessing = false

    private var outputFormatDescription: String {
        let format = audioEngine.outputNode.outputFormat(forBus: 0)
        return String(format: "output %.0f Hz, %d channel(s)", format.sampleRate, Int(format.channelCount))
    }

    init(restoresQueue: Bool = true) {
        let engine = audioEngine
        engine.attach(deckBus)
        engine.attach(deckGate)
        engine.connect(deckBus, to: deckGate, format: nil)
        engine.connect(deckGate, to: engine.mainMixerNode, format: nil)
        deckOne = KnobShiftDeck(name: "Deck 1", engine: engine, output: deckBus)
        deckTwo = KnobShiftDeck(name: "Deck 2", engine: engine, output: deckBus)
        primaryDeck = deckOne
        secondaryDeck = deckTwo
        log("SESSION", "Local mixer initialized with Deck 1 and Deck 2.")
        loadPlaylists()
        // The engine stops itself when the Mac's output device changes; log it so a silent or
        // stalled mix can be matched to the device change that caused it.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.log("DEVICE", "Output configuration changed. Engine running: \(self.audioEngine.isRunning), \(self.outputFormatDescription).")
                KnobShiftTogetherSession.shared.outputChanged()
            }
        }
        if restoresQueue {
            Task { [weak self] in await self?.restoreQueue() }
        }
        #if os(macOS)
        let leaving = NSApplication.willTerminateNotification
        #else
        // An iPhone app is usually stopped in the background, never told it is quitting.
        let leaving = UIApplication.didEnterBackgroundNotification
        #endif
        NotificationCenter.default.addObserver(forName: leaving, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistQueueNow() }
        }
    }

    /// Adds songs to the queue at once; they are prepared one by one in the background. Returns
    /// once every waiting song has been prepared (or has failed).
    func addTracks(_ urls: [URL]) async {
        guard enqueueFiles(urls) else { return }
        await processPending()
    }

    /// Adds files to the waiting rows in one change, skipping any already queued (checked
    /// against a set, so thousands of songs add instantly). Returns whether any were new.
    @discardableResult
    func enqueueFiles(_ urls: [URL]) -> Bool {
        var known = Set(tracks.map { $0.url.standardizedFileURL.path })
        known.formUnion(pending.map { $0.url.standardizedFileURL.path })
        // A song still on its way into its playlist joins the queue where it is, instead of twice.
        let wanted = Set(urls.map { $0.standardizedFileURL.path })
        var promoted = false
        for index in pending.indices where !pending[index].joinsQueue && wanted.contains(pending[index].url.standardizedFileURL.path) {
            pending[index].joinsQueue = true
            promoted = true
        }
        let new = urls.filter { known.insert($0.standardizedFileURL.path).inserted }
        guard !new.isEmpty else {
            if promoted { persistQueue() }
            return promoted
        }
        log("IMPORT", "Added \(new.count) song(s) to the queue. Preparing them one by one.")
        pending.append(contentsOf: new.map { url in
            var row = PendingSong(url: url)
            // Songs back from a relaunch are bare paths; the file says which playlist owns them.
            if let origin = KnobShiftPlaylists.origin(of: url, in: playlists), let playlistId = origin.playlistId {
                row.spotifyId = origin.spotifyId
                row.playlistId = playlistId
            }
            return row
        })
        persistQueue()
        return true
    }

    func retry(_ song: PendingSong) {
        guard let index = pending.firstIndex(where: { $0.id == song.id }) else { return }
        #if os(macOS)
        if song.waitingForDownload {
            retryDownload(song)
            return
        }
        #else
        // The Mac does the downloading: the next sync brings the song or says what is wrong.
        if song.waitingForDownload {
            pending[index].failure = nil
            pending[index].stage = "Coming on the next sync"
            return
        }
        #endif
        pending[index].failure = nil
        pending[index].progress = 0
        log("IMPORT", "Retrying \(song.title).")
        Task { await processPending() }
    }

    func removePending(_ song: PendingSong) {
        pending.removeAll { $0.id == song.id }
        // A Spotify song taken out before it downloaded is not downloaded again after a relaunch.
        if song.waitingForDownload, let id = song.spotifyId, let index = playlists.firstIndex(where: { $0.id == song.playlistId }) {
            playlists[index].skipped = (playlists[index].skipped ?? []) + [id]
            savePlaylists()
        }
        persistQueue()
    }

    func isQueued(_ url: URL) -> Bool {
        let path = url.standardizedFileURL
        return tracks.contains { $0.url.standardizedFileURL == path } || pending.contains { $0.joinsQueue && $0.url.standardizedFileURL == path }
    }

    /// The waiting rows the queue shows: not songs on their way into a playlist only.
    var queuePending: [PendingSong] { pending.filter(\.joinsQueue) }

    /// When a newly ready song becomes the next one while music plays, plan the mix into it.
    func refreshPlanIfNeeded() {
        guard !isMirroring, isPlaying, mixState != .mixing, nowPlaying != nil, tracks.count > 1,
              abs(primaryDeck.rate - 1) < 0.001 else { return }
        let expected = tracks[(currentIndex + 1) % tracks.count]
        guard plannedNext != expected else { return }
        cancelPlan("The queue changed")
        scheduleNext()
    }

    func play() {
        guard !isMirroring, !tracks.isEmpty else { return }
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
            deck.stop()
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

    /// The level of everything KnobShift plays, 0...1: what the iPhone app's volume knob turns.
    var outputVolume: Float {
        get { audioEngine.mainMixerNode.outputVolume }
        set { audioEngine.mainMixerNode.outputVolume = min(max(newValue, 0), 1) }
    }

    /// Puts an effect between KnobShift's mix and the speakers: Knob's own sound in the iPhone
    /// app, which has no system wide engine to play through.
    func insertOutputEffect(_ effect: AVAudioNode) {
        let output = audioEngine.outputNode
        let format = output.inputFormat(forBus: 0)
        audioEngine.attach(effect)
        audioEngine.disconnectNodeOutput(audioEngine.mainMixerNode)
        audioEngine.connect(audioEngine.mainMixerNode, to: effect, format: format)
        audioEngine.connect(effect, to: output, format: format)
        log("SESSION", "Knob's sound added after the mix, at \(Int(format.sampleRate)) Hz.")
    }

    /// Used only by Knob's command-line smoke check. The audio graph still runs, but its output
    /// is muted so automated checks never make sound or change the system output.
    func playForCheck(volume: Float = 0, bySelecting track: Track? = nil) {
        audioEngine.mainMixerNode.outputVolume = min(max(volume, 0), 1)
        log("CHECK", String(format: "Check playback at %.0f%% volume.", min(max(volume, 0), 1) * 100))
        if let track { select(track) } else { play() }
    }

    func remove(_ track: Track) {
        guard !isMirroring, let index = tracks.firstIndex(of: track) else { return }
        if nowPlaying == track { stop() }
        tracks.remove(at: index)
        unshuffled.removeAll { $0 == track }
        log("QUEUE", "Removed \(track.title).")
        currentIndex = min(currentIndex, max(0, tracks.count - 1))
        persistQueue()
        if tracks.isEmpty {
            mixState = .idle
            transitionDescription = "Add local music to begin."
        }
    }

    func pauseOrResume() {
        if sendToMirror(.playPause) { return }
        releaseHold?()
        guard nowPlaying != nil else { play(); return }
        if isPlaying, mixState == .mixing, transitionTask != nil {
            pauseMix()
        } else if isMixPaused {
            do { try resumeMix() }
            catch {
                log("ERROR", "Resume failed: \(error.localizedDescription)")
                notice = "KnobShift could not play this file."
            }
        } else if isPlaying {
            updatePlaybackTime()
            log("PLAY", "Paused at \(Self.seconds(playbackTime)).")
            cancelPlan("Paused")
            secondaryDeck.stop()
            primaryDeck.pause()
            progressTask?.cancel()
            isPlaying = false
            rememberNowPlaying()
        } else {
            log("PLAY", "Resumed at \(Self.seconds(playbackTime)).")
            do { try startEngineIfNeeded() }
            catch {
                log("ERROR", "Resume failed: \(error.localizedDescription)")
                notice = "KnobShift could not play this file."
                return
            }
            primaryDeck.resume()
            isPlaying = true
            playbackStartedAt = Date().addingTimeInterval(-playbackTime)
            startProgressUpdates()
            scheduleNext()
        }
    }

    func previous() {
        if sendToMirror(.previous) { return }
        releaseHold?()
        guard !tracks.isEmpty else { return }
        if playbackTime > 3 { seek(to: 0); return }
        currentIndex = (currentIndex - 1 + tracks.count) % tracks.count
        log("TRANSPORT", "Previous track: \(tracks[currentIndex].title).")
        restartCurrent()
    }

    func next() {
        if sendToMirror(.next) { return }
        releaseHold?()
        guard !tracks.isEmpty else { return }
        currentIndex = (currentIndex + 1) % tracks.count
        log("TRANSPORT", "Next track: \(tracks[currentIndex].title).")
        restartCurrent()
    }

    func select(_ track: Track) {
        if sendToMirror(.pick, track: track) { return }
        guard let index = tracks.firstIndex(of: track) else { return }
        currentIndex = index
        log("TRANSPORT", "Selected \(track.title).")
        restartCurrent()
    }

    /// Moves within the song. `start` holds the deck back until that exact moment, for the record
    /// to hand the song over with no gap.
    func seek(to time: TimeInterval, at start: AVAudioTime? = nil) {
        if sendToMirror(.seek, time: time) { return }
        releaseHold?()
        guard let track = nowPlaying else { return }
        let wasPlaying = isPlaying
        cancelPlan("You moved to \(Analysis.clock(time))")
        secondaryDeck.stop()
        do {
            log("SEEK", "Moving \(track.title) to \(String(format: "%.2f", time))s.")
            try schedulePrimary(track, from: min(max(time, 0), track.duration), play: wasPlaying, at: start)
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

    func schedulePrimary(_ track: Track, from time: TimeInterval, play: Bool, at startTime: AVAudioTime? = nil) throws {
        let file = try AVAudioFile(forReading: track.url)
        let start = AVAudioFramePosition((time * file.processingFormat.sampleRate).rounded())
        let remaining = max(0, file.length - start)
        guard remaining > 0, remaining <= AVAudioFramePosition(UInt32.max) else { throw PlayerError.invalidSegment }
        primaryDeck.stop()
        primaryDeck.resetEffects()
        primaryDeck.resetTransitionEffects()
        primaryDeck.startOffset = time
        primaryDeck.player.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(remaining), at: nil)
        nowPlaying = track
        playbackDuration = track.duration
        playbackTime = time
        let wait = startTime.map { AVAudioTime.seconds(forHostTime: $0.hostTime - min($0.hostTime, mach_absolute_time())) } ?? 0
        playbackStartedAt = Date().addingTimeInterval(wait - time)
        isPlaying = play
        if play {
            try startEngineIfNeeded()
            primaryDeck.player.play(at: startTime)
            startProgressUpdates()
        }
        log("DECK", "\(primaryDeck.name) is primary: \(track.title) from \(Self.seconds(time)) of \(Self.seconds(track.duration)), \(remaining) frames, \(play ? "playing" : "paused").")
        rememberNowPlaying()
    }

    /// Every way of making sound goes through here: Play, clicking a song, Next, Previous,
    /// Resume and the incoming deck of a blend. The engine only starts when something plays.
    func startEngineIfNeeded() throws {
        guard !audioEngine.isRunning else { return }
        try audioEngine.start()
        log("ENGINE", "Local audio engine started, \(outputFormatDescription).")
    }

    /// Calls off the planned or running transition and says why, at the moment it happens.
    func cancelPlan(_ reason: String) {
        mixNowWaiting = false
        mixPause = MixPause()
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
        secondaryDeck.stop()
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
                // Where the song is, saved every 5 seconds, so even a crash loses little.
                if let self, Date().timeIntervalSince(self.rememberedAt) >= 5 { self.rememberNowPlaying() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Reads where the song really is from its deck, which stays right while KnobShift slows or
    /// speeds it up; the wall clock is only a fallback before the deck has rendered.
    func updatePlaybackTime() {
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
        #if os(macOS)
        // Spotify playlists: one downloading, one finished, one removed, with their songs.
        let road = KnobShiftPlaylist(id: "demoroad", name: "Punjabi Road Trip", link: "", kind: .playlist,
                                     folderName: "Punjabi Road Trip", spotifyOrder: [], addedAt: Date())
        let liked = KnobShiftPlaylist(id: "liked", name: "Liked Songs", link: "saved", kind: .liked,
                                      folderName: "Liked Songs", spotifyOrder: [], addedAt: Date())
        playlists = [road, liked]
        removedPlaylists = [KnobShiftRemovedPlaylist(playlist: KnobShiftPlaylist(id: "demogym", name: "Gym Mix", link: "", kind: .album,
                                                                                    folderName: "Gym Mix", spotifyOrder: [], addedAt: Date()),
                                                     removedAt: Date().addingTimeInterval(-3 * 86_400), folderName: "Gym Mix 1")]
        tracks[3].playlistId = road.id
        tracks[4].playlistId = liked.id
        var progress = KnobShiftImport.Progress(songs: Self.previewSongs(["Sardaari", "Kya Baat Aa", "Bodyguard", "Lalkaara", "Ghaint"]))
        progress.started = true
        _ = progress.consume(#"Downloaded "Artist - Sardaari": u"#)
        _ = progress.consume(#"Downloaded "Artist - Kya Baat Aa": u"#)
        spotifyProgress[road.id] = progress
        var downloading = PendingSong(url: URL(fileURLWithPath: "/nonexistent/x.pending"))
        downloading.spotifyName = "Sardaari"
        downloading.spotifyArtist = "Himmat Sandhu"
        downloading.playlistId = road.id
        downloading.waitingForDownload = true
        downloading.stage = "Downloading"
        var missing = downloading
        missing.spotifyName = "Bodyguard"
        missing.spotifyArtist = "Navaan Sandhu"
        missing.stage = nil
        missing.failure = "Not found"
        missing.playlistId = liked.id
        pending.insert(contentsOf: [downloading, missing], at: 0)
        #endif
    }

    #if os(macOS)
    /// Songs for screenshots, as spotDL would describe them.
    static func previewSongs(_ names: [String]) -> [KnobShiftSpotDL.Song] {
        names.enumerated().compactMap { index, name in
            let json = #"{"name":"\#(name)","artists":["Artist"],"artist":"Artist","album_name":null,"duration":\#(190 + index * 13),"song_id":"preview\#(index)","url":"u","list_name":"Punjabi Road Trip","list_position":\#(index + 1)}"#
            return try? JSONDecoder().decode(KnobShiftSpotDL.Song.self, from: Data(json.utf8))
        }
    }
    #endif

    func logSection(_ title: String) {
        log("SECTION", title)
    }

    func logAnalysis(_ result: KnobShiftAnalyser.Result) {
        logSection("Analysis • \(result.track.title)")
        for step in result.steps { log("ANALYSIS", step) }
        log("ANALYSIS", "Result: \(result.track.analysis.summary).")
    }

    static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.2fs", value)
    }

    enum PlayerError: Error { case invalidSegment }
}
