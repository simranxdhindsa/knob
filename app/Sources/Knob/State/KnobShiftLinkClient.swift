import Foundation
import Network

/// Talks to Knob on the Mac over the link (KnobShiftLink): one request per connection, with a
/// time limit on connecting and on every pause in the reply, so a Mac that sleeps or leaves the
/// Wi-Fi mid sync ends in a plain message instead of a sync that never finishes. The iPhone uses
/// it; the Mac's link check uses it against its own server.
final class KnobShiftLinkClient: @unchecked Sendable {
    let endpoint: NWEndpoint
    /// Seconds to connect, and the longest pause allowed while a reply arrives.
    var connectLimit: TimeInterval = 10
    var idleLimit: TimeInterval = 30

    init(endpoint: NWEndpoint) { self.endpoint = endpoint }

    func get(_ path: String) async throws -> Data {
        try await small(request("GET", path))
    }

    func post(_ path: String, body: Data) async throws -> Data {
        try await small(request("POST", path, body: body))
    }

    /// Copies one file into `file`, which must not exist yet. The byte count must match what the
    /// Mac announced, so a transfer cut short never passes for a whole song.
    func download(_ path: String, to file: URL, expected: Int64?, progress: @escaping @Sendable (Int64) -> Void = { _ in }) async throws {
        let exchange = Exchange(endpoint: endpoint, idleLimit: idleLimit)
        defer { exchange.close() }
        try await exchange.open(limit: connectLimit)
        try await exchange.send(request("GET", path))
        let head = try await exchange.readHead()
        guard head.status == 200 else {
            throw KnobShiftLink.Failure.refused(String(data: try await exchange.readAll(limit: 64 * 1024, after: head.bodyStart), encoding: .utf8) ?? "Your Mac could not send this song.")
        }
        guard let length = head.length, expected == nil || expected == length else { throw KnobShiftLink.Failure.badReply }
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file) else { throw KnobShiftLink.Failure.refused("Could not save the song on this iPhone.") }
        defer { try? handle.close() }
        var written: Int64 = 0
        var chunk = head.bodyStart
        while true {
            if !chunk.isEmpty {
                let room = Int(length - written)
                let piece = chunk.count > room ? chunk.prefix(room) : chunk
                try handle.write(contentsOf: piece)
                written += Int64(piece.count)
                progress(written)
            }
            if written >= length { break }
            guard let next = try await exchange.receive() else { break }
            chunk = next
        }
        guard written == length else { throw KnobShiftLink.Failure.lost }
    }

    private func small(_ request: Data) async throws -> Data {
        let exchange = Exchange(endpoint: endpoint, idleLimit: idleLimit)
        defer { exchange.close() }
        try await exchange.open(limit: connectLimit)
        try await exchange.send(request)
        let head = try await exchange.readHead()
        let body = try await exchange.readAll(limit: 32 * 1024 * 1024, after: head.bodyStart, length: head.length)
        guard head.status == 200 else {
            throw KnobShiftLink.Failure.refused(String(data: body, encoding: .utf8) ?? "Your Mac refused the request.")
        }
        return body
    }

    private func request(_ method: String, _ path: String, body: Data = Data()) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: knob\r\nConnection: close\r\n"
        if method == "POST" { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    /// One connection: open, send, and read with a watchdog that closes it after a long pause.
    private final class Exchange: @unchecked Sendable {
        private let connection: NWConnection
        private let queue = DispatchQueue(label: "knob.link.client")
        private let idleLimit: TimeInterval
        private var watchdog: DispatchWorkItem?

        init(endpoint: NWEndpoint, idleLimit: TimeInterval) {
            connection = NWConnection(to: endpoint, using: .tcp)
            self.idleLimit = idleLimit
        }

        func open(limit: TimeInterval) async throws {
            let once = Once()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    case .failed, .cancelled: once.run { continuation.resume(throwing: KnobShiftLink.Failure.lost) }
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + limit) { [connection] in
                    once.run {
                        connection.cancel()
                        continuation.resume(throwing: KnobShiftLink.Failure.notFound)
                    }
                }
            }
        }

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    if error == nil { continuation.resume() } else { continuation.resume(throwing: KnobShiftLink.Failure.lost) }
                })
            }
        }

        /// The next bytes, or nil once the Mac has sent everything.
        func receive() async throws -> Data? {
            arm()
            defer { disarm() }
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                    if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if error != nil && !complete { continuation.resume(throwing: KnobShiftLink.Failure.lost) }
                    else { continuation.resume(returning: complete || error != nil ? nil : Data()) }
                }
            }
        }

        func readHead() async throws -> (status: Int, length: Int64?, bodyStart: Data) {
            var buffer = Data()
            while true {
                if let head = KnobShiftLink.parseResponseHead(buffer) { return head }
                guard buffer.count < KnobShiftLink.requestLimit, let more = try await receive() else { throw KnobShiftLink.Failure.badReply }
                buffer += more
            }
        }

        func readAll(limit: Int, after start: Data, length: Int64? = nil) async throws -> Data {
            var body = start
            while length.map({ Int64(body.count) < $0 }) ?? true {
                guard let more = try await receive() else { break }
                body += more
                guard body.count <= limit else { throw KnobShiftLink.Failure.badReply }
            }
            if let length, Int64(body.count) < length { throw KnobShiftLink.Failure.lost }
            return length.map { Data(body.prefix(Int($0))) } ?? body
        }

        func close() {
            disarm()
            connection.cancel()
        }

        private func arm() {
            let item = DispatchWorkItem { [connection] in connection.cancel() }
            queue.sync { watchdog?.cancel(); watchdog = item }
            queue.asyncAfter(deadline: .now() + idleLimit, execute: item)
        }

        private func disarm() { queue.sync { watchdog?.cancel(); watchdog = nil } }
    }

    /// Runs its block once, from whichever callback gets there first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ block: () -> Void) {
            lock.lock()
            let first = !done
            done = true
            lock.unlock()
            if first { block() }
        }
    }
}
