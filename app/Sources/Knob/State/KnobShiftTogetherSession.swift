import AVFoundation
import Combine
import Network
import SwiftUI

/// One Listen Together session on this device, hosting or listening, for the screens to show.
@MainActor
final class KnobShiftTogetherSession: ObservableObject {
    static let shared = KnobShiftTogetherSession()

    /// Play On adds two with no shared sound: `playing` is the device the music moved to, sending
    /// its state out, and `remote` is the one it came from, controlling it.
    enum Role: Equatable { case off, hosting, listening(String), playing(String), remote(String) }
    struct Nearby: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    /// How long a lost listener keeps trying before giving up.
    private static let retrySeconds = 20.0

    @Published var showing = false
    @Published private(set) var role = Role.off
    @Published private(set) var nearby: [Nearby] = []
    @Published private(set) var people: [String] = []
    @Published private(set) var status: String?
    @Published private(set) var state: KnobShiftTogether.State?
    @Published private(set) var cover: PlatformImage?
    @Published private(set) var queue: [KnobShiftTogether.Song] = []
    @Published private(set) var presetName: String?
    @Published var lineUp = 0.0 { didSet { lineUpChanged() } }

    /// Knob's own sound on this device, which every device in a session shares.
    weak var sound: KnobModel?
    /// This device's own sound from before it joined, given back when it leaves.
    private var ownEffects: KnobShiftTogether.Effects?
    private var sharedEffects: KnobShiftTogether.Effects?
    private weak var model: KnobShiftModel?
    private var browser: NWBrowser?
    private var host: KnobShiftTogetherHost?
    private var guest: KnobShiftTogetherGuest?
    private var player: KnobShiftTogetherPlayer?
    private var joined: Nearby?
    private var lostAt: Date?
    private var ticker: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []
    /// Play On's connection, in place of a Listen Together host or guest.
    private var outbound: (@Sendable (KnobShiftTogether.Message) -> Void)?

    private var deviceName: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        UIDevice.current.name
        #endif
    }

    private var lineUpKey: String { "\(PersistKey.togetherLineUp.rawValue).\(KnobShiftTogetherOutput.name)" }

    /// How the sound is holding, for checks.
    var debugRing: KnobShiftTogetherRing.Shared? { player?.ring.shared.pointee }

    func show(_ model: KnobShiftModel) {
        self.model = model
        showing = true
    }

    // MARK: Finding sessions

    func startLooking() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: KnobShiftTogether.service, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Nearby? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Nearby(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor [weak self] in self?.nearby = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopLooking() {
        browser?.cancel()
        browser = nil
    }

    // MARK: Hosting

    func startHosting(_ model: KnobShiftModel) {
        guard role == .off else { return }
        self.model = model
        guard !KnobShiftTogetherOutput.isAirPlay else {
            status = "AirPlay adds too much delay to stay together. Choose another output first."
            return
        }
        let host = KnobShiftTogetherHost(name: deviceName)
        host.onPeople = { names in Task { @MainActor [weak self] in self?.people = names } }
        host.onCommand = { command in Task { @MainActor [weak self] in self?.run(command) } }
        host.onEffects = { effects in Task { @MainActor [weak self] in self?.received(effects) } }
        host.onFailure = { Task { @MainActor [weak self] in self?.stop(saying: "Listen Together stopped because the network went away.") } }
        do {
            try host.start()
            try model.startTogetherSound(outputDelay: KnobShiftTogetherOutput.delay, onBlock: { [weak host] block in
                host?.send(block: block)
            }, onAnchor: { [weak host] frame, time, rate in
                host?.send(KnobShiftTogether.anchor(frame: frame, hostNanoseconds: time, rate: rate))
            })
        } catch {
            host.stop(state: nil)
            status = "Listen Together could not start. Check that this device is on Wi-Fi."
            model.log("TOGETHER", "Could not host: \(error.localizedDescription)")
            return
        }
        self.host = host
        role = .hosting
        status = nil
        loadLineUp()
        model.together?.setLineUp(lineUp)
        watchModel(model)
        watchSound()
        model.log("TOGETHER", "Hosting as \(deviceName).")
    }

    private func watchModel(_ model: KnobShiftModel) {
        model.$nowPlaying.sink { [weak self] _ in Task { @MainActor [weak self] in self?.sendCover(); self?.sendState() } }.store(in: &watching)
        model.$isPlaying.sink { [weak self] _ in Task { @MainActor [weak self] in self?.sendState() } }.store(in: &watching)
        model.$isShuffled.sink { [weak self] _ in Task { @MainActor [weak self] in self?.sendState() } }.store(in: &watching)
        model.$mixState.sink { [weak self] _ in Task { @MainActor [weak self] in self?.sendState() } }.store(in: &watching)
        model.$tracks.sink { [weak self] _ in Task { @MainActor [weak self] in self?.sendQueue() } }.store(in: &watching)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.sendState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func currentState(ended: Bool? = nil) -> KnobShiftTogether.State? {
        guard let model else { return nil }
        return KnobShiftTogether.State(title: model.nowPlaying?.name, artist: model.nowPlaying?.artist,
                                       time: max(0, model.playbackTime - KnobShiftTogether.delay), duration: model.playbackDuration,
                                       isPlaying: model.isPlaying, ended: ended, song: model.nowPlaying?.id.uuidString,
                                       isShuffled: model.isShuffled,
                                       canMix: model.isPlaying && model.tracks.count >= 2 && model.mixState != .mixing)
    }

    private func sendState() {
        guard let state = currentState(), let message = KnobShiftTogether.json(.state, state) else { return }
        self.state = state
        broadcast(message)
    }

    private func broadcast(_ message: KnobShiftTogether.Message) {
        if let host { host.send(message) } else { outbound?(message) }
    }

    private func sendQueue() {
        guard let model else { return }
        queue = model.tracks.prefix(KnobShiftTogether.longestQueue).map {
            KnobShiftTogether.Song(id: $0.id.uuidString, title: $0.name, artist: $0.artist)
        }
        if let message = KnobShiftTogether.json(.queue, queue) { broadcast(message) }
    }

    private func sendCover() {
        guard let url = model?.nowPlaying?.url else { return }
        Task { [weak self] in
            guard let image = await KnobShiftArtwork.load(url), let data = Self.jpeg(image), data.count < KnobShiftTogether.longestMessage - 8 else { return }
            self?.cover = image
            self?.broadcast(KnobShiftTogether.Message(kind: .cover, body: data))
        }
    }

    private static func jpeg(_ image: PlatformImage) -> Data? {
        #if os(macOS)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        #else
        image.jpegData(compressionQuality: 0.6)
        #endif
    }

    /// Runs a listener's button press, or this device's while listening, on the host.
    func run(_ command: KnobShiftTogether.Command) {
        guard let model else { return }
        switch command.action {
        case .playPause: model.pauseOrResume()
        case .next: model.next()
        case .previous: model.previous()
        case .seek:
            guard let time = command.time, time.isFinite, time >= 0, time <= model.playbackDuration else { return }
            model.seek(to: time)
        case .shuffle:
            if model.tracks.count >= 2 { model.toggleShuffle() }
        case .mixNow:
            if model.isPlaying, model.tracks.count >= 2, model.mixState != .mixing { model.mixNow() }
        case .pick:
            guard let song = command.song, let track = model.tracks.first(where: { $0.id.uuidString == song }) else { return }
            model.select(track)
        }
        sendState()
    }

    func remove(_ name: String) { host?.removeListener(named: name) }

    // MARK: Listening

    func join(_ session: Nearby, model: KnobShiftModel) {
        guard role == .off else { return }
        self.model = model
        guard !KnobShiftTogetherOutput.isAirPlay else {
            status = "AirPlay adds too much delay to stay together. Choose another output first."
            return
        }
        if model.isPlaying { model.pauseOrResume() }
        joined = session
        lostAt = nil
        role = .listening(session.name)
        status = "Joining \(session.name)."
        loadLineUp()
        ownEffects = currentEffects
        watchSound()
        connect(session)
        // Playing a song here means leaving: two sounds at once is never what anyone wants.
        model.$isPlaying.dropFirst().sink { [weak self] playing in
            if playing { Task { @MainActor [weak self] in self?.leave() } }
        }.store(in: &watching)
    }

    private func connect(_ session: Nearby) {
        guard let model else { return }
        do {
            try model.startEngineIfNeeded()
        } catch {
            stop(saying: "Listen Together could not start the sound on this device.")
            return
        }
        let player = KnobShiftTogetherPlayer()
        player.attach(to: model.audioEngine, outputDelay: KnobShiftTogetherOutput.delay)
        player.setLineUp(lineUp)
        let guest = KnobShiftTogetherGuest(endpoint: session.endpoint, name: deviceName, player: player)
        guest.onHello = { _ in Task { @MainActor [weak self] in self?.status = nil; self?.lostAt = nil } }
        guest.onState = { state in Task { @MainActor [weak self] in self?.state = state } }
        guest.onCover = { data in Task { @MainActor [weak self] in self?.cover = PlatformImage(data: data) } }
        guest.onEffects = { effects in Task { @MainActor [weak self] in self?.received(effects) } }
        guest.onQueue = { songs in Task { @MainActor [weak self] in self?.queue = songs } }
        guest.onEnd = { ending in Task { @MainActor [weak self] in self?.ended(ending) } }
        self.player = player
        self.guest = guest
        guest.start()
    }

    private func ended(_ ending: KnobShiftTogetherGuest.Ending) {
        guard case .listening(let name) = role else { return }
        switch ending {
        case .ended: stop(saying: "Listen Together ended.")
        case .full: stop(saying: "\(name) already has as many listeners as it can take.")
        case .version: stop(saying: "Update Knob on both devices to listen together.")
        case .lost:
            let lost = lostAt ?? Date()
            lostAt = lost
            player?.detach()
            guard Date().timeIntervalSince(lost) < Self.retrySeconds, let joined else {
                stop(saying: "Lost \(name). Listen Together ended.")
                return
            }
            status = "Reconnecting to \(name)."
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, case .listening = self.role else { return }
                self.connect(joined)
            }
        }
    }

    func send(_ action: KnobShiftTogether.Action, time: Double? = nil, song: String? = nil) {
        let command = KnobShiftTogether.Command(action: action, time: time, song: song)
        switch role {
        case .hosting, .playing: run(command)
        case .remote: if let message = KnobShiftTogether.json(.command, command) { outbound?(message) }
        default: guest?.send(command)
        }
    }

    func leave() { stop(saying: nil) }

    // MARK: Knob's own sound

    var currentSound: KnobShiftTogether.Effects? { currentEffects }

    private var currentEffects: KnobShiftTogether.Effects? {
        sound.map { KnobShiftTogether.Effects(effects: $0.effects, eq: $0.eq, preset: $0.currentPreset?.name) }
    }

    /// Any change on this device, by knob, fader or preset, goes to everyone.
    private func watchSound() {
        guard let sound else { return }
        if role == .hosting || isPlayingHere { soundChanged() }
        sound.$effects.combineLatest(sound.$eq, sound.$currentPreset).dropFirst().debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _, _, _ in Task { @MainActor [weak self] in self?.soundChanged() } }
            .store(in: &watching)
    }

    private func soundChanged() {
        guard let current = currentEffects, sharedEffects.map({ !$0.isClose(to: current) }) ?? true else { return }
        sharedEffects = current
        presetName = current.preset
        guard let message = KnobShiftTogether.json(.effects, current) else { return }
        switch role {
        case .hosting, .playing: broadcast(message)
        case .remote: outbound?(message)
        default: guest?.send(current)
        }
    }

    /// Another device changed the sound. The host passes it on to everyone else.
    func received(_ effects: KnobShiftTogether.Effects) {
        guard role != .off else { return }
        sharedEffects = effects
        presetName = effects.preset
        apply(effects)
        if role == .hosting || isPlayingHere, let message = KnobShiftTogether.json(.effects, effects) { broadcast(message) }
    }

    private func apply(_ settings: KnobShiftTogether.Effects) {
        guard let sound else { return }
        for slot in EffectSlot.allCases where settings.effects.indices.contains(slot.rawValue) {
            sound.setEffect(slot, settings.effects[slot.rawValue])
        }
        for band in settings.eq.indices { sound.setEQ(band: band, settings.eq[band]) }
        sound.showSharedPreset(named: settings.preset)
    }

    /// Effects only reach the speakers on a Mac while Knob is on.
    var soundIsOff: Bool { role != .off && sound?.powerOn == false }

    // MARK: Play On

    private var isPlayingHere: Bool {
        if case .playing = role { return true }
        return false
    }

    var isListening: Bool {
        if case .listening = role { return true }
        return false
    }

    var isRemote: Bool {
        if case .remote = role { return true }
        return false
    }

    /// The music moved here from `name`: tells it what's playing and takes its button presses.
    func beginPlaying(from name: String, model: KnobShiftModel, send: @escaping @Sendable (KnobShiftTogether.Message) -> Void) {
        stop(saying: nil)
        self.model = model
        outbound = send
        role = .playing(name)
        watchModel(model)
        watchSound()
    }

    /// The music moved to `name`: this device is now its remote, with the same controls.
    func beginRemote(of name: String, model: KnobShiftModel, send: @escaping @Sendable (KnobShiftTogether.Message) -> Void) {
        stop(saying: nil)
        self.model = model
        outbound = send
        role = .remote(name)
        watchSound()
    }

    /// What the device the music moved to says is happening.
    func remoteUpdate(_ message: KnobShiftTogether.Message) {
        switch message.kind {
        case .state: state = try? JSONDecoder().decode(KnobShiftTogether.State.self, from: message.body)
        case .queue: queue = (try? JSONDecoder().decode([KnobShiftTogether.Song].self, from: message.body)) ?? queue
        case .cover: cover = PlatformImage(data: message.body)
        default: break
        }
    }

    func endPlayOn(saying message: String?) {
        guard isRemote || isPlayingHere else { return }
        stop(saying: message)
    }

    // MARK: Changes

    private func stop(saying message: String?) {
        ticker?.cancel()
        ticker = nil
        watching.removeAll()
        if role == .hosting {
            let goodbye = currentState(ended: true).flatMap { KnobShiftTogether.json(.state, $0) }
            model?.stopTogetherSound()
            host?.stop(state: goodbye)
        }
        guest?.stop()
        player?.detach()
        if let ownEffects { apply(ownEffects) }
        ownEffects = nil
        sharedEffects = nil
        host = nil
        guest = nil
        player = nil
        outbound = nil
        joined = nil
        lostAt = nil
        role = .off
        people = []
        state = nil
        cover = nil
        queue = []
        presetName = nil
        status = message
    }

    private func loadLineUp() { lineUp = UserDefaults.standard.double(forKey: lineUpKey) }

    private func lineUpChanged() {
        guard role != .off else { return }
        UserDefaults.standard.set(lineUp, forKey: lineUpKey)
        (player ?? model?.together)?.setLineUp(lineUp)
    }

    /// The output changed, which stops the engine: everything picks up again on the new one.
    func outputChanged() {
        guard role != .off, let model else { return }
        guard !KnobShiftTogetherOutput.isAirPlay else {
            stop(saying: "AirPlay adds too much delay to stay together, so Listen Together ended.")
            return
        }
        let current = player ?? model.together
        current?.detach()
        current?.attach(to: model.audioEngine, outputDelay: KnobShiftTogetherOutput.delay)
        current?.restartSpeakers()
        loadLineUp()
        do {
            try model.startEngineIfNeeded()
        } catch {
            stop(saying: "Listen Together ended because the sound output changed.")
        }
    }
}
