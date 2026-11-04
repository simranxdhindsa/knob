#if os(macOS)
import Foundation
import Network

/// Knob on the Mac, offering its KnobShift playlists to Knob on the iPhone (KnobShiftLink). It
/// is found with Bonjour on the home Wi-Fi and answers three requests:
///
/// - `GET /v1/library`: every Spotify and YouTube playlist, its songs in order, and which are
///   downloaded (name and size) or still on their way.
/// - `GET /v1/file/<playlist>/<song>`: one downloaded song. Files are found by id inside the
///   playlist's own folder, never by a path the iPhone sends, so nothing else on the Mac can be read.
/// - `POST /v1/add` with a Spotify or YouTube link: read and downloaded here with every song
///   ticked, exactly as if it had been pasted on the Mac.
///
/// Only devices on the local network are answered (KnobShiftLink.isLocal).
@MainActor
final class KnobShiftLinkServer {
    static let shared = KnobShiftLinkServer()

    private var listener: NWListener?
    private weak var model: KnobShiftModel?
    private let queue = DispatchQueue(label: "knob.link.server")
    /// The port it listens on, once ready (the link check connects to it directly).
    private(set) var port: UInt16?

    /// Starts offering the playlists. `advertise` is off for the link check, which connects to
    /// the port itself instead of being found on the network.
    func start(model: KnobShiftModel, advertise: Bool = true, onReady: ((UInt16) -> Void)? = nil) {
        guard listener == nil else { return }
        self.model = model
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        guard let listener = try? NWListener(using: parameters) else {
            model.log("LINK", "Could not offer playlists to the iPhone app.")
            return
        }
        if advertise {
            listener.service = NWListener.Service(name: Host.current().localizedName, type: KnobShiftLink.service)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch state {
                case .ready:
                    self.port = self.listener?.port?.rawValue
                    if let port = self.port {
                        self.model?.log("LINK", "Offering playlists to the iPhone app on the home network.")
                        onReady?(port)
                    }
                case .failed(let error):
                    self.model?.log("LINK", "The iPhone link stopped: \(error).")
                    self.listener?.cancel()
                    self.listener = nil
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard KnobShiftLink.isLocal(connection.endpoint) else { connection.cancel(); return }
            Task { @MainActor [weak self] in self?.serve(connection) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: One request

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A connection that never sends a whole request is dropped after 15 seconds.
        let asked = KnobShiftHelperFlag()
        queue.asyncAfter(deadline: .now() + 15) { [weak connection] in
            if !asked.value { connection?.cancel() }
        }
        read(connection, buffer: Data(), asked: asked)
    }

    private nonisolated func read(_ connection: NWConnection, buffer: Data, asked: KnobShiftHelperFlag) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: KnobShiftLink.requestLimit) { [weak self] data, _, complete, error in
            let buffer = buffer + (data ?? Data())
            do {
                if let request = try KnobShiftLink.parseRequest(buffer) {
                    asked.set()
                    Task { @MainActor [weak self] in self?.answer(request, on: connection) }
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    self?.read(connection, buffer: buffer, asked: asked)
                }
            } catch {
                Self.reply(connection, status: 400, text: "Bad request")
            }
        }
    }

    private func answer(_ request: KnobShiftLink.Request, on connection: NWConnection) {
        guard let model else { return Self.reply(connection, status: 404, text: "KnobShift is not running on this Mac.") }
        let parts = request.path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        switch (request.method, parts.first == "v1" ? Array(parts.dropFirst()) : []) {
        case ("GET", ["library"]):
            let library = Self.library(of: model)
            guard let data = try? KnobShiftLink.encoder().encode(library) else { return Self.reply(connection, status: 404, text: "No playlists") }
            Self.send(connection, status: 200, type: "application/json", body: data)
        case ("GET", let path) where path.count == 3 && path[0] == "file":
            guard let playlist = model.playlists.first(where: { $0.id == path[1] }),
                  let file = KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist))[path[2]] else {
                return Self.reply(connection, status: 404, text: "This song is not on the Mac any more.")
            }
            Self.stream(file, on: connection)
            model.log("LINK", "Sending \(file.lastPathComponent) to the iPhone.")
        case ("POST", ["add"]):
            guard let add = try? JSONDecoder().decode(KnobShiftLink.AddRequest.self, from: request.body) else {
                return Self.reply(connection, status: 400, text: "Paste a Spotify or YouTube link.")
            }
            Task { @MainActor in
                let reply = await Self.add(add.link, to: model)
                let data = (try? JSONEncoder().encode(reply)) ?? Data()
                Self.send(connection, status: 200, type: "application/json", body: data)
            }
        default:
            Self.reply(connection, status: 404, text: "Unknown request")
        }
    }

    // MARK: What the Mac offers

    /// Every playlist with its songs in order. Downloaded songs carry their file; songs still on
    /// their way are listed only while the Mac is still getting them (not ones it could not find).
    static func library(of model: KnobShiftModel) -> KnobShiftLink.Library {
        var waiting: [String: [String: KnobShiftModel.PendingSong]] = [:]
        for song in model.pending where song.failure == nil {
            if let playlist = song.playlistId, let id = song.spotifyId { waiting[playlist, default: [:]][id] = song }
        }
        var names: [String: (String, String?)] = [:]
        for track in model.tracks { if let id = track.spotifyId { names[id] = (track.name, track.artist) } }
        let entries = model.playlists.map { playlist -> KnobShiftLink.Library.Entry in
            let files = KnobShiftPlaylists.files(in: KnobShiftPlaylists.folder(for: playlist))
            let skipped = Set(playlist.skipped ?? [])
            let songs = playlist.spotifyOrder.filter { !skipped.contains($0) }.compactMap { id -> KnobShiftLink.Library.Song? in
                if let file = files[id] {
                    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                    let split = KnobShiftModel.Track.split(file.deletingPathExtension().lastPathComponent)
                    return .init(id: id, file: file.lastPathComponent, size: size,
                                 name: names[id]?.0 ?? split.name, artist: names[id]?.1 ?? split.artist)
                }
                guard let row = waiting[playlist.id]?[id] else { return nil }
                return .init(id: id, file: nil, size: nil, name: row.name, artist: row.artist)
            }
            return .init(playlist: playlist, songs: songs, downloading: model.isDownloading(playlist) || waiting[playlist.id]?.isEmpty == false)
        }
        return .init(version: KnobShiftLink.version, mac: Host.current().localizedName ?? "your Mac", playlists: entries)
    }

    /// A link from the iPhone: read like a pasted one, then every song ticked and downloaded.
    static func add(_ link: String, to model: KnobShiftModel) async -> KnobShiftLink.AddReply {
        let id: String
        if let spotify = KnobShiftPlaylists.parseLink(link) {
            guard model.spotifyAvailable else { return .init(ok: false, message: KnobShiftSpotDL.Failure.unavailable.message) }
            id = spotify.id
            model.log("LINK", "The iPhone asked for \(spotify.link).")
            await model.addFromSpotify(link)
        } else if let youtube = KnobShiftYouTubeParsing.parseLink(link), youtube.kind != .liked {
            guard model.youtubeAvailable else { return .init(ok: false, message: "YouTube import is unavailable in Knob on your Mac.") }
            id = youtube.id
            model.log("LINK", "The iPhone asked for \(youtube.url).")
            await model.addFromYouTube(link)
        } else {
            return .init(ok: false, message: "Paste a Spotify or YouTube playlist, album, song or video link.")
        }
        guard let review = model.spotifyReview, review.playlistId == id else {
            return .init(ok: false, message: model.spotifyStatus ?? "Your Mac could not read this link.")
        }
        model.confirmSpotifyReview(selected: review.initial)
        let name = model.playlists.first { $0.id == id }?.name ?? review.name
        return .init(ok: true, message: "Your Mac is downloading \(name). Its songs come over as they are ready.", playlistId: id)
    }

    // MARK: Replies

    nonisolated static func reply(_ connection: NWConnection, status: Int, text: String) {
        send(connection, status: status, type: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    nonisolated static func send(_ connection: NWConnection, status: Int, type: String, body: Data) {
        let data = KnobShiftLink.responseHead(status: status, type: type, length: Int64(body.count)) + body
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Sends a song in pieces, each after the last has gone, so a large file never sits in memory.
    nonisolated static func stream(_ file: URL, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return reply(connection, status: 404, text: "This song could not be read on the Mac.")
        }
        connection.send(content: KnobShiftLink.responseHead(status: 200, type: "audio/mp4", length: Int64(size)),
                        completion: .contentProcessed { error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            sendPiece(handle, on: connection)
        })
    }

    private nonisolated static func sendPiece(_ handle: FileHandle, on connection: NWConnection) {
        let piece = (try? handle.read(upToCount: 256 * 1024)) ?? nil
        guard let piece, !piece.isEmpty else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: piece, completion: .contentProcessed { error in
            if error != nil { try? handle.close(); connection.cancel(); return }
            sendPiece(handle, on: connection)
        })
    }
}

/// Set once a connection has sent its whole request, read from the link's own queue.
final class KnobShiftHelperFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}
#endif
