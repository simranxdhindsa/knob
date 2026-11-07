import AVFoundation
import Combine
import Network
import SwiftUI

/// Moving the music to another device and back, for the screens to show. The rules are in
/// KnobShiftPlayOn.swift. A device sends or receives on the same connection, so the music can go
/// back the way it came.
@MainActor
final class KnobShiftPlayOnSession: ObservableObject {
    static let shared = KnobShiftPlayOnSession()

    struct Device: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    /// What the other device needs to hear when the switch happens.
    struct Go: Codable, Equatable {
        var position: Double
        var isPlaying: Bool
        var startIn: Double
    }

    struct FileStart: Codable, Equatable {
        var key: String
        var fileName: String
        var size: Int64
        var playlist: KnobShiftPlayOn.Playlist?
    }

    enum Refusal: String, Codable { case noSpace, noOutput, badQueue, olderVersion }

    private static let chunk = 128 * 1024
    private static let startIn = 0.35
    /// The most songs a handover lists, from the one playing on.
    private static let longestList = 1_500

    @Published var showing = false
    @Published private(set) var devices: [Device] = []
    @Published private(set) var handoff: KnobShiftPlayOn.Handoff?
    /// Someone asking to send music here for the first time.
    @Published var asking: String?
    /// What this device is receiving, for its own screen.
    @Published private(set) var receiving: String?

    private weak var model: KnobShiftModel?
    private let offer = KnobShiftPlayOnOffer()
    private var browser: NWBrowser?
    private var link: KnobShiftPlayOnLink?
    private var peerName = ""
    private var pendingAllow: (id: String, link: KnobShiftPlayOnLink, name: String)?
    private var files: [String: URL] = [:]
    private var plan: KnobShiftPlayOn.Handover?
    private var waitingForMix: AnyCancellable?
    private var ownQueueAsked = false
    // Receiving.
    private var incoming: KnobShiftPlayOn.Incoming?
    private var incomingKey: String?
    private var incomingStart: FileStart?
    private var have: [String: URL] = [:]
    private var arriving: KnobShiftPlayOn.Handover?
    private var preparedForGo = false
    /// The queue has been replaced, so songs landing now simply join it.
    private var queueTaken = false

    private var deviceName: String {
        if let name = ProcessInfo.processInfo.environment["KNOB_PLAYON_NAME"] { return name }
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    private var deviceId: String {
        let key = PersistKey.playOnDeviceId.rawValue
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    private var allowed: KnobShiftPlayOn.Allowed {
        get { KnobShiftPlayOn.Allowed(ids: Set(UserDefaults.standard.stringArray(forKey: PersistKey.playOnAllowed.rawValue) ?? [])) }
        set { UserDefaults.standard.set(Array(newValue.ids).sorted(), forKey: PersistKey.playOnAllowed.rawValue) }
    }

    // MARK: Finding devices

    /// Offers this device while Knob is open. Called once at launch.
    func start(model: KnobShiftModel) {
        self.model = model
        offer.onConnection = { connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        offer.start(name: deviceName)
    }

    func show(_ model: KnobShiftModel) {
        self.model = model
        showing = true
    }

    func startLooking() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: KnobShiftPlayOn.service, domain: nil), using: parameters)
        let mine = deviceName
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Device? in
                guard case .service(let name, _, _, _) = result.endpoint, name != mine else { return nil }
                return Device(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor [weak self] in self?.devices = found.sorted { $0.name < $1.name } }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Keeps the list of nearby devices up the whole time Knob is open, for Listen Together.
    func keepLooking() {
        alwaysLooking = true
        startLooking()
    }
    private var alwaysLooking = false

    func stopLooking() {
        guard !alwaysLooking else { return }
        browser?.cancel()
        browser = nil
    }

    // MARK: Sending the music away

    func move(to device: Device) {
        guard let model, handoff == nil || handoff?.stage.musicIsHere == true else { return }
        let session = KnobShiftTogetherSession.shared
        if session.role == .hosting || session.isListening {
            handoff = failed(device.name, "Leave Listen Together first.")
            return
        }
        guard model.nowPlaying != nil else {
            handoff = failed(device.name, "Play a song first.")
            return
        }
        var state = KnobShiftPlayOn.Handoff(device: device.name)
        state.handle(.start)
        // Already joined to that device, the music having come from it: no need to ask again.
        if case .playing(let name) = session.role, name == device.name, link != nil {
            state.handle(.allowed)
            handoff = state
            session.endPlayOn(saying: nil)
            sendHandover()
            return
        }
        session.endPlayOn(saying: nil)
        self.link?.close()
        handoff = state
        peerName = device.name
        let link = KnobShiftPlayOnLink(to: device.endpoint)
        attach(link)
        link.start()
        if let hello = KnobShiftTogether.json(.playHello, KnobShiftPlayOn.Hello(version: KnobShiftPlayOn.version, deviceId: deviceId, name: deviceName)) {
            link.send(hello)
        }
    }

    private func failed(_ device: String, _ message: String) -> KnobShiftPlayOn.Handoff {
        var state = KnobShiftPlayOn.Handoff(device: device)
        state.handle(.start)
        state.handle(.refused)
        return state.replacingFailure(message)
    }

    /// Brings the music back to this device from the one it moved to.
    func bringBack() {
        guard KnobShiftTogetherSession.shared.isRemote, let link else { return }
        link.send(KnobShiftTogether.Message(kind: .takeBack, body: Data()))
    }

    private func attach(_ link: KnobShiftPlayOnLink) {
        self.link = link
        link.onMessage = { message in Task { @MainActor [weak self] in self?.handle(message, on: link) } }
        link.onClose = { Task { @MainActor [weak self] in self?.closed(link) } }
    }

    private func update(_ event: KnobShiftPlayOn.Event) {
        handoff?.handle(event)
    }

    /// Writes down what this device is playing, in a form the other can use.
    private func sendHandover() {
        guard let model, let link, let index = model.tracks.firstIndex(where: { $0.id == model.nowPlaying?.id }) else {
            update(.connectionLost)
            return
        }
        // The whole queue, not just what's ahead, or the songs before this one would be lost when
        // the music comes back. A very long queue keeps the part around the song playing.
        let first = max(0, min(index - Self.longestList / 2, model.tracks.count - Self.longestList))
        let tracks = Array(model.tracks[first...].prefix(Self.longestList))
        let current = index - first
        // Going back where it came from: that device's own list, with songs never copied here.
        let original = arriving
        let playlists = model.playlists
        let position = model.playbackTime, isPlaying = model.isPlaying, isShuffled = model.isShuffled
        let rows = tracks.map { (url: $0.url, title: $0.name, artist: $0.artist, playlist: $0.playlistId) }
        let effects = KnobShiftTogetherSession.shared.currentSound
        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [String: URL] = [:]
            let songs = rows.compactMap { row -> KnobShiftPlayOn.Song? in
                guard let key = KnobShiftPlayOn.key(for: row.url),
                      let size = (try? row.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
                found[key] = row.url
                let list = playlists.first { $0.id == row.playlist }.map { KnobShiftPlayOn.Playlist(id: $0.id, name: $0.name, link: $0.link) }
                return KnobShiftPlayOn.Song(key: key, title: row.title, artist: row.artist, fileName: row.url.lastPathComponent, size: Int64(size), playlist: list)
            }
            var list = songs, at = current
            if let original, current < songs.count, let found = original.songs.firstIndex(where: { $0.key == songs[current].key }) {
                list = original.songs
                at = found
            }
            let handover = KnobShiftPlayOn.Handover(songs: list, current: at, position: position, isPlaying: isPlaying, isShuffled: isShuffled,
                                                    sentAt: KnobShiftTogether.now(), effects: effects)
            await self?.finishHandover(handover, files: found, on: link)
        }
    }

    private func finishHandover(_ handover: KnobShiftPlayOn.Handover, files: [String: URL], on link: KnobShiftPlayOnLink) {
        self.files = files
        plan = handover
        guard !handover.songs.isEmpty, let message = KnobShiftTogether.json(.handover, handover) else {
            update(.connectionLost)
            return
        }
        link.send(message)
    }

    /// Sends songs one at a time, each in pieces, with its saved analysis after it.
    private func sendFiles(_ keys: [String], on link: KnobShiftPlayOnLink) {
        guard let plan else { return }
        let wanted = keys.compactMap { key in plan.songs.first { $0.key == key }.flatMap { song in files[key].map { (song, $0) } } }
        model?.log("PLAYON", "Asked for \(keys.count) song(s), sending \(wanted.count).")
        Task.detached(priority: .userInitiated) { [weak self] in
            for (number, item) in wanted.enumerated() {
                let (song, url) = item
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                defer { try? handle.close() }
                let start = FileStart(key: song.key, fileName: song.fileName, size: song.size, playlist: song.playlist)
                guard let opening = KnobShiftTogether.json(.fileStart, start), await link.sendAndWait(opening) else { return }
                var sent: Int64 = 0
                while let piece = try? handle.read(upToCount: Self.chunk), !piece.isEmpty {
                    guard await link.sendAndWait(KnobShiftTogether.Message(kind: .fileChunk, body: piece)) else { return }
                    sent += Int64(piece.count)
                    if number == 0 {
                        let share = Double(sent) / Double(max(song.size, 1))
                        await self?.update(.copied(share))
                    }
                }
                let analysis = KnobShiftAnalysisCache.exported(for: url) ?? Data()
                guard await link.sendAndWait(KnobShiftTogether.Message(kind: .fileEnd, body: analysis)) else { return }
            }
        }
    }

    /// Ready on both sides, and any mix finished: the moment of the switch.
    private func switchWhenFree(on link: KnobShiftPlayOnLink) {
        guard let model else { return }
        if model.mixState == .mixing {
            update(.mixRunning)
            waitingForMix = model.$mixState.dropFirst().sink { [weak self] state in
                guard state != .mixing else { return }
                Task { @MainActor [weak self] in
                    self?.waitingForMix = nil
                    self?.update(.mixEnded)
                    self?.switchNow(on: link)
                }
            }
            return
        }
        switchNow(on: link)
    }

    private func switchNow(on link: KnobShiftPlayOnLink) {
        guard let model, let plan else { return }
        let carried = KnobShiftPlayOn.Handover(songs: plan.songs, current: plan.current, position: model.playbackTime, isPlaying: model.isPlaying,
                                               isShuffled: model.isShuffled, sentAt: KnobShiftTogether.now(), effects: nil)
        let goAt = carried.sentAt + Int64(Self.startIn * 1e9)
        let position = KnobShiftPlayOn.startPosition(carried, goAt: goAt, duration: model.playbackDuration)
        let go = Go(position: position, isPlaying: carried.isPlaying, startIn: Self.startIn)
        guard let message = KnobShiftTogether.json(.go, go) else { return }
        link.send(message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.startIn))
            guard let self, let model = self.model else { return }
            if model.isPlaying { model.pauseOrResume() }
            self.update(.switched)
            KnobShiftTogetherSession.shared.beginRemote(of: self.peerName, model: model) { message in link.send(message) }
            model.log("PLAYON", "The music moved to \(self.peerName).")
        }
    }

    // MARK: Receiving the music

    private func accept(_ connection: NWConnection) {
        let incoming = KnobShiftPlayOnLink(connection: connection)
        incoming.onMessage = { message in Task { @MainActor [weak self] in self?.handle(message, on: incoming) } }
        incoming.onClose = { Task { @MainActor [weak self] in self?.closed(incoming) } }
        incoming.start()
    }

    func answerAsking(allow: Bool) {
        guard let request = pendingAllow else { return }
        pendingAllow = nil
        asking = nil
        if allow {
            var list = allowed
            list.allow(request.id)
            allowed = list
            link = request.link
            peerName = request.name
        }
        reply(allow, on: request.link)
    }

    private func reply(_ allow: Bool, on link: KnobShiftPlayOnLink) {
        link.send(KnobShiftTogether.Message(kind: .playAllow, body: Data([allow ? 1 : 0])))
    }

    private func refuse(_ reason: Refusal, on link: KnobShiftPlayOnLink) {
        receiving = nil
        if let message = KnobShiftTogether.json(.refused, reason) { link.send(message) }
    }

    private func receive(_ handover: KnobShiftPlayOn.Handover, on link: KnobShiftPlayOnLink) {
        guard let model, KnobShiftPlayOn.isValid(handover) else {
            refuse(.badQueue, on: link)
            return
        }
        arriving = handover
        preparedForGo = false
        queueTaken = false
        receiving = "Getting music from \(peerName)"
        let tracks = model.tracks.map(\.url)
        let folders = model.playlists.map { KnobShiftPlaylists.folder(for: $0) }
        Task.detached(priority: .userInitiated) { [weak self] in
            var found: [String: URL] = [:]
            for folder in folders {
                for (id, url) in KnobShiftPlaylists.files(in: folder) { found["id:\(id)"] = url }
            }
            for url in tracks { if let key = KnobShiftPlayOn.key(for: url) { found[key] = url } }
            await self?.answerHandover(handover, have: found, on: link)
        }
    }

    private func answerHandover(_ handover: KnobShiftPlayOn.Handover, have found: [String: URL], on link: KnobShiftPlayOnLink) {
        guard let model else { return }
        have = found
        let needed = KnobShiftPlayOn.sendOrder(handover.songs, current: handover.current, have: Set(found.keys))
        model.log("PLAYON", "\(peerName) sent \(handover.songs.count) song(s), playing number \(handover.current + 1). This device needs \(needed.count).")
        let space = (try? KnobShiftPlaylists.home.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        #if DEBUG
        // KNOB_PLAYON_FAKE stands in for a full disk or a dead output, which a check can't cause.
        let fake = ProcessInfo.processInfo.environment["KNOB_PLAYON_FAKE"]
        #else
        let fake: String? = nil
        #endif
        guard fake != "nospace", space > needed.reduce(Int64(500_000_000), { $0 + $1.size }) else {
            refuse(.noSpace, on: link)
            return
        }
        Task { [weak self] in
            guard fake != "nooutput", await model.outputIsWorking() else {
                self?.refuse(.noOutput, on: link)
                return
            }
            if let message = KnobShiftTogether.json(.need, needed.map(\.key)) { link.send(message) }
            self?.prepareIfReady(on: link)
        }
    }

    /// The playlist a copied song goes in: the same one by id, or a new one with the same name.
    private func folder(for playlist: KnobShiftPlayOn.Playlist?) -> URL {
        guard let model else { return KnobShiftPlaylists.home }
        guard let playlist else { return KnobShiftPlaylists.root.appendingPathComponent("From other devices", isDirectory: true) }
        if let mine = model.playlists.first(where: { $0.id == playlist.id }) ?? model.playlists.first(where: { $0.name == playlist.name }) {
            return KnobShiftPlaylists.folder(for: mine)
        }
        return KnobShiftPlaylists.folder(for: model.adoptPlaylist(id: playlist.id, name: playlist.name, link: playlist.link))
    }

    private func beginFile(_ start: FileStart, on link: KnobShiftPlayOnLink) {
        incoming?.cancel()
        let folder = folder(for: start.playlist)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        KnobShiftPlayOn.Incoming.clearLeftovers(in: folder)
        let space = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        do {
            incoming = try KnobShiftPlayOn.Incoming(name: start.fileName, key: start.key, size: start.size, folder: folder, freeSpace: space)
            incomingKey = start.key
            incomingStart = start
        } catch {
            model?.log("PLAYON", "Refused \(start.fileName): \(error).")
            incoming = nil
            incomingKey = nil
        }
    }

    private func endFile(analysis: Data, on link: KnobShiftPlayOnLink) {
        guard var file = incoming, let key = incomingKey else { return }
        incoming = nil
        incomingKey = nil
        guard let url = try? file.finish() else { return }
        if !analysis.isEmpty { KnobShiftAnalysisCache.adopt(analysis, for: url) }
        have[key] = url
        model?.log("PLAYON", "Copied \(url.lastPathComponent).")
        model?.addPlayOnSong(url, song: arriving?.songs.first { $0.key == key })
        if queueTaken, let model { Task { await model.addTracks([url]) } }
        prepareIfReady(on: link)
    }

    /// As soon as the song playing has landed, it's queued and prepared, and the other side told.
    private func prepareIfReady(on link: KnobShiftPlayOnLink) {
        guard !preparedForGo, let model, let handover = arriving, let url = have[handover.songs[handover.current].key] else { return }
        preparedForGo = true
        let known = handover.songs.compactMap { have[$0.key] }
        Task { [weak self] in
            await model.takeQueue(known)
            _ = url
            // Songs that landed while the queue was being replaced.
            let late = handover.songs.compactMap { self?.have[$0.key] }.filter { !known.contains($0) }
            self?.queueTaken = true
            if !late.isEmpty { await model.addTracks(late) }
            self?.receiving = "Getting ready"
            link.send(KnobShiftTogether.Message(kind: .ready, body: Data()))
        }
    }

    private func start(_ go: Go, on link: KnobShiftPlayOnLink) {
        guard let model, let handover = arriving, let url = have[handover.songs[handover.current].key],
              let track = model.tracks.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let name = peerName
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(go.startIn))
            guard let self else { return }
            model.startPlayOn(track, at: go.position, playing: go.isPlaying)
            if handover.isShuffled != model.isShuffled { model.toggleShuffle() }
            self.receiving = nil
            KnobShiftTogetherSession.shared.beginPlaying(from: name, model: model) { message in link.send(message) }
            if let effects = handover.effects { KnobShiftTogetherSession.shared.received(effects) }
            model.log("PLAYON", "The music moved here from \(name), at \(Int(go.position))s.")
        }
    }

    // MARK: Messages

    private func handle(_ message: KnobShiftTogether.Message, on link: KnobShiftPlayOnLink) {
        let decoder = JSONDecoder()
        // Only a hello may come from a device that hasn't been allowed. Anything else from a
        // stranger could read songs, stop the music or put files here.
        guard message.kind == .playHello || link === self.link else { return }
        switch message.kind {
        case .playHello:
            guard let hello = try? decoder.decode(KnobShiftPlayOn.Hello.self, from: message.body) else { return }
            guard hello.version == KnobShiftPlayOn.version else {
                refuse(.olderVersion, on: link)
                return
            }
            let name = String(hello.name.prefix(60))
            if allowed.contains(hello.deviceId) {
                self.link = link
                peerName = name
                reply(true, on: link)
            } else {
                pendingAllow = (hello.deviceId, link, name)
                asking = name
            }
        case .playAllow:
            if message.body.first == 1 {
                update(.allowed)
                sendHandover()
            } else {
                update(.refused)
                link.close()
            }
        case .handover:
            guard let handover = try? decoder.decode(KnobShiftPlayOn.Handover.self, from: message.body) else { return }
            receive(handover, on: link)
        case .need:
            guard let keys = try? decoder.decode([String].self, from: message.body) else { return }
            update(.needs(keys.count))
            sendFiles(keys, on: link)
        case .fileStart:
            guard let start = try? decoder.decode(FileStart.self, from: message.body) else { return }
            beginFile(start, on: link)
        case .fileChunk:
            do { try incoming?.add(message.body) } catch { incoming = nil; incomingKey = nil }
        case .fileEnd:
            endFile(analysis: message.body, on: link)
        case .ready:
            update(.ready)
            switchWhenFree(on: link)
        case .go:
            guard let go = try? decoder.decode(Go.self, from: message.body), go.position.isFinite, go.position >= 0,
                  go.startIn >= 0, go.startIn <= 2 else { return }
            start(go, on: link)
        case .refused:
            let reason = try? decoder.decode(Refusal.self, from: message.body)
            update(reason == .noOutput ? .noOutput : reason == .noSpace ? .noSpace : .connectionLost)
            link.close()
        case .takeBack:
            guard let model else { return }
            var state = KnobShiftPlayOn.Handoff(device: peerName)
            state.handle(.start)
            state.handle(.allowed)
            handoff = state
            KnobShiftTogetherSession.shared.endPlayOn(saying: nil)
            _ = model
            sendHandover()
        case .state, .queue, .cover:
            KnobShiftTogetherSession.shared.remoteUpdate(message)
        case .command:
            guard let command = try? decoder.decode(KnobShiftTogether.Command.self, from: message.body) else { return }
            KnobShiftTogetherSession.shared.run(command)
        case .effects:
            guard let effects = try? decoder.decode(KnobShiftTogether.Effects.self, from: message.body), effects.isValid else { return }
            KnobShiftTogetherSession.shared.received(effects)
        default: break
        }
    }

    private func closed(_ gone: KnobShiftPlayOnLink) {
        if pendingAllow?.link === gone {
            pendingAllow = nil
            asking = nil
        }
        guard gone === link else { return }
        link = nil
        incoming?.cancel()
        incoming = nil
        incomingKey = nil
        receiving = nil
        update(.connectionLost)
        KnobShiftTogetherSession.shared.endPlayOn(saying: KnobShiftTogetherSession.shared.isRemote ? "Lost the connection." : nil)
    }

    /// Ready for a new move, once the last one is over.
    func handoffReset() { handoff = nil }

    func clearFailure() {
        if let stage = handoff?.stage, stage.musicIsHere { handoff = nil }
    }
}

extension KnobShiftPlayOn.Handoff {
    /// A failure with its own words, for what the device itself knows before anything is sent.
    func replacingFailure(_ message: String) -> KnobShiftPlayOn.Handoff {
        var copy = self
        copy.fail(message)
        return copy
    }
}
