import Foundation

/// Listen Together in the player itself: while this device listens to another, the player shows
/// that device's song, cover, time and queue, with the record deck and every effect as usual, and
/// its buttons control the device playing. This device's own queue waits aside and comes back,
/// with any songs added meanwhile, when it leaves.
@MainActor
final class KnobShiftMirror {
    struct Own {
        let tracks: [KnobShiftModel.Track]
        let unshuffled: [KnobShiftModel.Track]
        let nowPlaying: KnobShiftModel.Track?
        let currentIndex: Int
        let isShuffled: Bool
        let isMixOrdered: Bool
        let time: TimeInterval
        let duration: TimeInterval
        let mixState: KnobShiftModel.MixState
    }

    /// Where the other device's songs seem to live. Nothing is written there: the path only gives
    /// each song a cover of its own (KnobShiftArtwork).
    static let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Knob Together", isDirectory: true)
    static let fileExtension = "knobtogether"

    let own: Own
    let send: (KnobShiftTogether.Action, TimeInterval?, String?) -> Void
    /// One track per song, so rows and the deck keep their identity as updates arrive.
    var known: [String: KnobShiftModel.Track] = [:]
    var songIds: [UUID: String] = [:]
    /// Songs added here while listening, kept for this device's own queue.
    var added: [KnobShiftModel.Track] = []
    var state: KnobShiftTogether.State?
    var receivedAt = Date()
    var ticker: Task<Void, Never>?

    init(own: Own, send: @escaping (KnobShiftTogether.Action, TimeInterval?, String?) -> Void) {
        self.own = own
        self.send = send
    }

    func track(for song: KnobShiftTogether.Song) -> KnobShiftModel.Track {
        if let track = known[song.id] { return track }
        let url = Self.folder.appendingPathComponent(song.id).appendingPathExtension(Self.fileExtension)
        let track = KnobShiftModel.Track(
            url: url, title: song.title, duration: max(song.duration ?? 0, 0), tailSilence: 0,
            analysis: KnobShiftModel.Analysis(tempo: nil, tempoConfidence: 0, beatGrid: [], leadingSilence: 0, trailingSilence: 0,
                                              fadeOutCue: nil, safeOutroCue: nil, vocalOnset: nil, vocalEnd: nil),
            tags: KnobShiftTags.Tags(title: song.title, artist: song.artist, album: nil))
        known[song.id] = track
        songIds[track.id] = song.id
        return track
    }

    static func isMirrored(_ url: URL) -> Bool { url.pathExtension == fileExtension }
}

extension KnobShiftModel {
    var isMirroring: Bool { mirror != nil }

    /// Puts this device's own queue aside and shows the other device's music instead.
    func startMirror(send: @escaping (KnobShiftTogether.Action, TimeInterval?, String?) -> Void) {
        guard mirror == nil else { return }
        persistQueueNow()
        mirror = KnobShiftMirror(own: .init(tracks: tracks, unshuffled: unshuffled, nowPlaying: nowPlaying, currentIndex: currentIndex,
                                            isShuffled: isShuffled, isMixOrdered: isMixOrdered, time: playbackTime,
                                            duration: playbackDuration, mixState: mixState), send: send)
        tracks = []
        unshuffled = []
        nowPlaying = nil
        isShuffled = false
        isMixOrdered = false
        isPlaying = false
        nextMix = nil
        mixingInto = nil
        blendProgress = 0
        playbackTime = 0
        playbackDuration = 0
        mixState = .idle
        mirror?.ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.mirrorTick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        log("TOGETHER", "The player shows the other device's music.")
    }

    /// What the other device says is happening.
    func mirrorUpdate(state: KnobShiftTogether.State?, queue: [KnobShiftTogether.Song], cover: PlatformImage?) {
        guard let mirror else { return }
        mirror.added += tracks.filter { mirror.songIds[$0.id] == nil && !mirror.added.contains($0) }
        let shown = queue.map { mirror.track(for: $0) }
        if tracks != shown { tracks = shown }
        guard let state else { return }
        mirror.state = state
        mirror.receivedAt = Date()
        var current: Track?
        if let id = state.song {
            current = mirror.known[id] ?? state.title.map {
                mirror.track(for: .init(id: id, title: $0, artist: state.artist, duration: state.duration))
            }
        }
        if nowPlaying != current { nowPlaying = current }
        if let current, let index = tracks.firstIndex(of: current) { currentIndex = index }
        if isPlaying != state.isPlaying { isPlaying = state.isPlaying }
        if isShuffled != (state.isShuffled ?? false) { isShuffled = state.isShuffled ?? false }
        let mix: MixState = current == nil ? .idle : .ready
        if mixState != mix { mixState = mix }
        playbackDuration = state.duration
        playbackTime = min(state.time, state.duration)
        if let cover, let current { KnobShiftArtwork.remember(cover, for: current.url) }
    }

    /// Gives this device its own queue back, with any songs added while listening.
    func endMirror() {
        guard let mirror else { return }
        mirror.ticker?.cancel()
        let added = mirror.added + tracks.filter { mirror.songIds[$0.id] == nil && !mirror.added.contains($0) }
        self.mirror = nil
        let own = mirror.own
        tracks = own.tracks + added
        unshuffled = own.unshuffled.isEmpty ? [] : own.unshuffled + added
        isShuffled = own.isShuffled
        isMixOrdered = own.isMixOrdered
        currentIndex = min(own.currentIndex, max(0, tracks.count - 1))
        nowPlaying = own.nowPlaying
        isPlaying = false
        playbackDuration = own.duration
        playbackTime = own.time
        mixState = own.mixState == .mixing ? .ready : (tracks.isEmpty ? .idle : own.mixState)
        if !added.isEmpty { persistQueue() }
        log("TOGETHER", "The player shows this device's own music again.")
    }

    /// The time runs on between updates, so the timeline and the record move smoothly.
    private func mirrorTick() {
        guard let mirror, let state = mirror.state, state.isPlaying, isPlaying else { return }
        playbackTime = min(state.time + Date().timeIntervalSince(mirror.receivedAt), state.duration)
    }

    /// A button pressed in the player while listening goes to the device playing. Returns true
    /// when it was sent, so the button does nothing more here.
    func sendToMirror(_ action: KnobShiftTogether.Action, time: TimeInterval? = nil, track: Track? = nil) -> Bool {
        guard let mirror else { return false }
        let song = track.flatMap { mirror.songIds[$0.id] }
        if track != nil, song == nil { return true }
        mirror.send(action, time, song)
        // Shown at once, before the other device answers.
        switch action {
        case .playPause:
            if let state = mirror.state {
                mirror.state?.time = min(state.time + (state.isPlaying ? Date().timeIntervalSince(mirror.receivedAt) : 0), state.duration)
            }
            isPlaying.toggle()
            mirror.state?.isPlaying = isPlaying
            mirror.receivedAt = Date()
        case .seek:
            if let time {
                playbackTime = time
                mirror.state?.time = time
                mirror.receivedAt = Date()
            }
        default: break
        }
        return true
    }
}
