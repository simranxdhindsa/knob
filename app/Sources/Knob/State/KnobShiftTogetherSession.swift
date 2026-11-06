import AVFoundation
import Combine
import Network
import SwiftUI

/// One Listen Together session on this device, hosting or listening, for the screens to show.
@MainActor
final class KnobShiftTogetherSession: ObservableObject {
    static let shared = KnobShiftTogetherSession()

    enum Role: Equatable { case off, hosting, listening(String) }
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
    @Published var lineUp = 0.0 { didSet { lineUpChanged() } }

    private weak var model: KnobShiftModel?
    private var browser: NWBrowser?
    private var host: KnobShiftTogetherHost?
    private var guest: KnobShiftTogetherGuest?
    private var player: KnobShiftTogetherPlayer?
    private var joined: Nearby?
    private var lostAt: Date?
    private var ticker: Task<Void, Never>?
    private var watching: Set<AnyCancellable> = []

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
        model.$nowPlaying.sink { [weak self] _ in Task { @MainActor [weak self] in self?.sendCover(); self?.sendState() } }.store(in: &watching)
        model.$isPlaying.sink { [weak self] _ in Task { @MainActor [weak self] in self?.sendState() } }.store(in: &watching)
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.sendState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        model.log("TOGETHER", "Hosting as \(deviceName).")
    }

    private func currentState(ended: Bool? = nil) -> KnobShiftTogether.State? {
        guard let model else { return nil }
        return KnobShiftTogether.State(title: model.nowPlaying?.name, artist: model.nowPlaying?.artist,
                                       time: max(0, model.playbackTime - KnobShiftTogether.delay), duration: model.playbackDuration,
                                       isPlaying: model.isPlaying, ended: ended)
    }

    private func sendState() {
        guard let host, let state = currentState(), let message = KnobShiftTogether.json(.state, state) else { return }
        self.state = state
        host.send(message)
    }

    private func sendCover() {
        guard let url = model?.nowPlaying?.url else { return }
        Task { [weak self] in
            guard let image = await KnobShiftArtwork.load(url), let data = Self.jpeg(image), data.count < KnobShiftTogether.longestMessage - 8 else { return }
            self?.cover = image
            self?.host?.send(KnobShiftTogether.Message(kind: .cover, body: data))
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
    private func run(_ command: KnobShiftTogether.Command) {
        guard let model else { return }
        switch command.action {
        case .playPause: model.pauseOrResume()
        case .next: model.next()
        case .previous: model.previous()
        case .seek:
            guard let time = command.time, time.isFinite, time >= 0, time <= model.playbackDuration else { return }
            model.seek(to: time)
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

    func send(_ action: KnobShiftTogether.Action, time: Double? = nil) {
        let command = KnobShiftTogether.Command(action: action, time: time)
        if role == .hosting { run(command) } else { guest?.send(command) }
    }

    func leave() { stop(saying: nil) }

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
        host = nil
        guest = nil
        player = nil
        joined = nil
        lostAt = nil
        role = .off
        people = []
        state = nil
        cover = nil
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
