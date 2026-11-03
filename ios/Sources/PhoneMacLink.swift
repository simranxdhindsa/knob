import Foundation
import Network
import UIKit

/// The iPhone's side of the link with Knob on the Mac (KnobShiftLink): finds the Mac on the home
/// Wi-Fi, syncs its Spotify and YouTube playlists into the app, and hands it links to download.
/// What to copy and where new songs go is worked out by KnobShiftSyncPlan; this file carries it
/// out: one sync at a time, songs copied one by one into a ".part" file and moved into place only
/// once whole, and songs the Mac is still downloading picked up by a follow up sync while the
/// app is open.
@MainActor
final class PhoneMacLink: ObservableObject {
    static let shared = PhoneMacLink()

    enum Phase: Equatable { case idle, looking, adding, syncing }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var macName: String?
    /// The last outcome, as a plain sentence for the sheet.
    @Published private(set) var status: String?
    @Published private(set) var failed = false
    /// Songs copied so far in this sync, and how many it copies.
    @Published private(set) var copied = 0
    @Published private(set) var toCopy = 0
    /// The Mac's playlists as last read, for the sheet's list.
    @Published private(set) var library: KnobShiftLink.Library?

    private var follow: Task<Void, Never>?
    private var followRounds = 0
    /// Follow up syncs while the Mac still downloads: every 20 seconds, for up to 15 minutes.
    private static let followEvery: Duration = .seconds(20)
    private static let followLimit = 45

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopFollowing() }
        }
    }

    var busy: Bool { phase != .idle }

    // MARK: Finding the Mac

    /// The first Knob found on the local network. iOS asks for Local Network access the first
    /// time; while that is unanswered, or if it was turned down, the Mac cannot be seen.
    private func findMac(within seconds: Double = 6) async throws -> (NWEndpoint, String) {
        let browser = NWBrowser(for: .bonjour(type: KnobShiftLink.service, domain: nil), using: .tcp)
        defer { browser.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            // Every callback runs on the main queue, so the first answer wins without a lock.
            let done = Box()
            let finish: @Sendable (Result<(NWEndpoint, String), Error>) -> Void = { result in
                guard !done.value else { return }
                done.value = true
                continuation.resume(with: result)
            }
            browser.browseResultsChangedHandler = { results, _ in
                guard let found = results.first(where: { if case .service = $0.endpoint { return true }; return false }),
                      case .service(let name, _, _, _) = found.endpoint else { return }
                finish(.success((found.endpoint, name)))
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .waiting(let error), .failed(let error):
                    // -65570: Local Network access is turned off for Knob.
                    if case .dns(let code) = error, code == -65570 {
                        finish(.failure(KnobShiftLink.Failure.refused("Allow Local Network for Knob in Settings, then tap Sync again.")))
                    }
                default: break
                }
            }
            browser.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish(.failure(KnobShiftLink.Failure.notFound)) }
        }
    }

    // MARK: Adding a link

    /// Asks the Mac to download a pasted Spotify or YouTube link, then syncs, so its songs show
    /// in the queue at once and fill in as the Mac gets them.
    func add(_ text: String, to model: KnobShiftModel) async {
        let link = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard KnobShiftPlaylists.parseLink(link) != nil || Self.looksLikeYouTube(link) else {
            report("Paste a Spotify or YouTube playlist, album, song or video link.", failed: true)
            return
        }
        guard !busy else { return }
        phase = .looking
        status = "Looking for Knob on your Mac."
        failed = false
        do {
            let (endpoint, name) = try await findMac()
            macName = name
            phase = .adding
            status = "Your Mac is reading the songs. Long playlists take a minute."
            let client = KnobShiftLinkClient(endpoint: endpoint)
            // Reading a long playlist on the Mac can take a while before it answers.
            client.idleLimit = 180
            let body = try JSONEncoder().encode(KnobShiftLink.AddRequest(link: link))
            let reply = try KnobShiftLink.decoder().decode(KnobShiftLink.AddReply.self, from: try await client.post("/v1/add", body: body))
            model.log("LINK", "Asked \(name) for \(link): \(reply.message)")
            phase = .idle
            guard reply.ok else { return report(reply.message, failed: true) }
            followRounds = 0
            await sync(model, found: (endpoint, name), opening: reply.message)
        } catch {
            phase = .idle
            report(Self.message(error), failed: true)
        }
    }

    static func looksLikeYouTube(_ text: String) -> Bool {
        guard let host = URL(string: text)?.host?.lowercased() else { return false }
        return host == "youtu.be" || host.hasSuffix("youtube.com")
    }

    // MARK: Sync

    /// Brings every playlist on the Mac into the app (KnobShiftSyncPlan says what and where).
    /// `following` is a sync the app started by itself while the Mac still downloads.
    func sync(_ model: KnobShiftModel, found: (NWEndpoint, String)? = nil, opening: String? = nil, following: Bool = false) async {
        guard !busy else { return }
        if !following && found == nil { followRounds = 0 }
        phase = .looking
        failed = false
        status = opening ?? "Looking for Knob on your Mac."
        do {
            let (endpoint, name): (NWEndpoint, String)
            if let found { (endpoint, name) = found } else { (endpoint, name) = try await findMac() }
            macName = name
            phase = .syncing
            if opening == nil { status = "Syncing with \(name)." }
            let client = KnobShiftLinkClient(endpoint: endpoint)
            let library = try KnobShiftLink.decoder().decode(KnobShiftLink.Library.self, from: try await client.get("/v1/library"))
            if library.version > KnobShiftLink.version { throw KnobShiftLink.Failure.newerMac }
            if library.version < KnobShiftLink.version { throw KnobShiftLink.Failure.olderMac }
            self.library = library
            let plan = KnobShiftSyncPlan.plan(library, phone: phoneState(model))
            model.log("LINK", "Sync with \(name): \(plan.transfers.count) to copy, \(plan.copies.count) copied here, \(plan.rows.count) new in the queue, \(plan.onMac) still on the Mac.")
            apply(plan, to: model)
            let result = await copy(plan, from: client, into: model)
            finish(plan, result: result, mac: name, library: library, model: model)
            if !following, result.error == nil { closeSheetSoon() }
        } catch {
            phase = .idle
            report(Self.message(error), failed: true)
            model.log("LINK", "Sync stopped: \(error).")
        }
    }

    private func phoneState(_ model: KnobShiftModel) -> KnobShiftSyncPlan.Phone {
        var files: [String: [String: (url: URL, size: Int64)]] = [:]
        for playlist in model.playlists {
            for (id, url) in KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist)) {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                files[playlist.id, default: [:]][id] = (url, size)
            }
        }
        let free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        return KnobShiftSyncPlan.Phone(playlists: model.playlists, removedIds: Set(model.removedPlaylists.map(\.playlist.id)),
                                       files: files, queued: Self.queuedIds(model),
                                       declined: KnobShiftSyncPlan.declined, playing: model.nowPlaying?.url, freeSpace: free)
    }

    /// Song ids in the queue, in order. Songs brought back after a relaunch are matched to their
    /// id only once prepared, so a song still preparing is known by the id in its file name.
    static func queuedIds(_ model: KnobShiftModel) -> [String] {
        func id(_ url: URL, _ known: String?) -> String? {
            known ?? KnobShiftPlaylists.songId(inFileName: url.deletingPathExtension().lastPathComponent)
        }
        return model.tracks.compactMap { id($0.url, $0.spotifyId) } + model.pending.compactMap { id($0.url, $0.spotifyId) }
    }

    /// The playlists and the new queue rows, all in one change, so the songs show at once.
    private func apply(_ plan: KnobShiftSyncPlan.Result, to model: KnobShiftModel) {
        model.playlists = plan.playlists
        model.savePlaylists()
        for playlist in plan.playlists {
            let folder = KnobShiftPlaylists.folder(for: playlist)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // A copy cut off by a lost connection last time.
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "part" {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let coming = Set(plan.transfers.map(\.songId) + plan.copies.map(\.songId))
        // Never a file already in the queue, however it got there.
        let rows = plan.rows.filter { $0.url.pathExtension == "pending" || !model.isQueued($0.url) }.map { row -> KnobShiftModel.PendingSong in
            var song = KnobShiftModel.PendingSong(url: row.url)
            song.spotifyId = row.songId
            song.playlistId = row.playlistId
            song.spotifyName = row.name
            song.spotifyArtist = row.artist
            song.waitingForDownload = row.waiting
            song.stage = row.waiting ? (coming.contains(row.songId) ? "Coming from your Mac" : "Downloading on your Mac") : nil
            song.placement = row.placement
            return song
        }
        guard !rows.isEmpty else { return }
        model.pending.append(contentsOf: rows)
        model.persistQueue()
        if rows.contains(where: { !$0.waitingForDownload }) { Task { await model.processPending() } }
    }

    /// Copies the songs one by one. A lost connection is tried once more after finding the Mac
    /// again; a song the Mac no longer has is skipped.
    private func copy(_ plan: KnobShiftSyncPlan.Result, from client: KnobShiftLinkClient, into model: KnobShiftModel) async -> (copied: Int, missing: Int, error: Error?) {
        copied = 0
        toCopy = plan.transfers.count
        var client = client
        var missing = 0
        var retried = false
        var index = 0
        while index < plan.transfers.count {
            let transfer = plan.transfers[index]
            setStage("Copying from your Mac", for: transfer.songId, in: transfer.playlistId, model: model)
            let part = transfer.destination.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: part)
            do {
                try await client.download(KnobShiftLink.filePath(playlistId: transfer.playlistId, songId: transfer.songId),
                                          to: part, expected: transfer.size)
                if FileManager.default.fileExists(atPath: transfer.destination.path) {
                    _ = try FileManager.default.replaceItemAt(transfer.destination, withItemAt: part)
                } else {
                    try FileManager.default.moveItem(at: part, to: transfer.destination)
                }
                landed(transfer.songId, in: transfer.playlistId, at: transfer.destination, model: model)
                copied += 1
                index += 1
            } catch KnobShiftLink.Failure.refused(_), KnobShiftLink.Failure.badReply {
                try? FileManager.default.removeItem(at: part)
                setStage("Downloading on your Mac", for: transfer.songId, in: transfer.playlistId, model: model)
                missing += 1
                index += 1
            } catch {
                try? FileManager.default.removeItem(at: part)
                guard !retried, let again = try? await findMac(within: 8) else {
                    for rest in plan.transfers[index...] { setStage("Coming on the next sync", for: rest.songId, in: rest.playlistId, model: model) }
                    return (copied, missing, error)
                }
                retried = true
                client = KnobShiftLinkClient(endpoint: again.0)
            }
        }
        for copy in plan.copies where FileManager.default.fileExists(atPath: copy.from.path) {
            if !FileManager.default.fileExists(atPath: copy.to.path) { try? FileManager.default.copyItem(at: copy.from, to: copy.to) }
            if FileManager.default.fileExists(atPath: copy.to.path) { landed(copy.songId, in: copy.playlistId, at: copy.to, model: model) }
        }
        return (copied, missing, nil)
    }

    /// A song's file is in place: its waiting row (from this sync or an earlier one) is prepared.
    private func landed(_ songId: String, in playlistId: String, at url: URL, model: KnobShiftModel) {
        var ready = false
        for index in model.pending.indices where model.pending[index].spotifyId == songId && model.pending[index].waitingForDownload {
            guard model.pending[index].playlistId == playlistId || model.pending[index].url.pathExtension == "pending" else { continue }
            model.pending[index].url = url
            model.pending[index].waitingForDownload = false
            model.pending[index].stage = nil
            ready = true
        }
        if ready {
            model.persistQueue()
            Task { await model.processPending() }
        }
    }

    private func setStage(_ stage: String, for songId: String, in playlistId: String, model: KnobShiftModel) {
        for index in model.pending.indices where model.pending[index].spotifyId == songId
            && model.pending[index].playlistId == playlistId && model.pending[index].waitingForDownload {
            model.pending[index].stage = stage
        }
    }

    private func finish(_ plan: KnobShiftSyncPlan.Result, result: (copied: Int, missing: Int, error: Error?), mac: String,
                        library: KnobShiftLink.Library, model: KnobShiftModel) {
        phase = .idle
        var parts: [String] = []
        if let error = result.error {
            parts.append(Self.message(error))
        } else if plan.transfers.isEmpty && plan.rows.isEmpty && plan.onMac == 0 {
            parts.append("Everything from \(mac) is on this iPhone.")
        } else {
            parts.append("Synced with \(mac).")
        }
        if result.copied > 0 { parts.append("\(Self.songs(result.copied)) copied.") }
        let waiting = plan.onMac + result.missing
        if waiting > 0 { parts.append("\(Self.songs(waiting)) still downloading on your Mac will come over by themselves.") }
        if plan.noRoom > 0 { parts.append("This iPhone is almost full, so \(Self.songs(plan.noRoom)) stayed on your Mac.") }
        if plan.keptRemoved > 0 { parts.append("\(plan.keptRemoved) playlist\(plan.keptRemoved == 1 ? "" : "s") you removed here stayed removed.") }
        report(parts.joined(separator: " "), failed: result.error != nil)
        let stillComing = waiting > 0 || library.playlists.contains(where: \.downloading)
        if stillComing, result.error == nil { followUp(model) } else { stopFollowing() }
    }

    /// A sync the person started closes its sheet once it went well, back to the player, after
    /// a moment to read how it went. One that failed stays open with its message.
    private func closeSheetSoon() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard let self, !self.busy, !self.failed else { return }
            PhoneSheets.shared.mac = nil
        }
    }

    private func followUp(_ model: KnobShiftModel) {
        follow?.cancel()
        guard followRounds < Self.followLimit, UIApplication.shared.applicationState != .background else { return }
        followRounds += 1
        follow = Task { [weak self, weak model] in
            try? await Task.sleep(for: Self.followEvery)
            guard !Task.isCancelled, let self, let model else { return }
            await self.sync(model, following: true)
        }
    }

    private func stopFollowing() {
        follow?.cancel()
        follow = nil
    }

    private func report(_ message: String, failed: Bool) {
        status = message
        self.failed = failed
    }

    private static func songs(_ count: Int) -> String { count == 1 ? "1 song" : "\(count) songs" }

    private static func message(_ error: Error) -> String {
        (error as? KnobShiftLink.Failure)?.message ?? KnobShiftLink.Failure.lost.message
    }

    private final class Box: @unchecked Sendable { var value = false }
}
