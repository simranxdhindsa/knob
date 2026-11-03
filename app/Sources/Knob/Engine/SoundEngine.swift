import Foundation

/// Talks to knob-engine. One JSON request per connection, one JSON reply line
/// (`{"version":1,"ok":true,"data":...}`); see engine/command-dispatcher.mm.
protocol SoundEngine: AnyObject {
    func send(_ command: String, _ arguments: [String: Any]) async throws -> Any?
}

/// The volume the panel's knob turns: the Mac's own output volume (SystemVolume), the same one
/// the volume keys change, or the iPhone app's playback volume.
protocol VolumeControl: AnyObject {
    /// Called on the main thread with (volume 0...1, muted, can be controlled).
    var onChange: ((Double, Bool, Bool) -> Void)? { get set }
    func start()
    func setVolume(_ volume: Double)
    func setMuted(_ muted: Bool)
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The real engine over its Unix socket (`$TMPDIR/knob-engine.sock`).
final class SocketEngine: SoundEngine {
    private let path: String
    private let queue = DispatchQueue(label: "knob.engine.socket")

    init(path: String = SocketEngine.defaultPath) { self.path = path }

    static var defaultPath: String {
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()
        return (tmp as NSString).appendingPathComponent("knob-engine.sock")
    }

    func send(_ command: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        var request = arguments
        request["version"] = 1
        request["command"] = command
        let body = try JSONSerialization.data(withJSONObject: request)
        let path = self.path
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try Self.exchange(path: path, body: body)) }
                catch { continuation.resume(throwing: error) }
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw EngineError(message: "unreadable engine reply")
        }
        guard object["ok"] as? Bool == true else {
            throw EngineError(message: object["error"] as? String ?? "engine refused the request")
        }
        return object["data"] is NSNull ? nil : object["data"]
    }

    /// Blocking exchange; runs on `queue`, never on the main thread.
    private static func exchange(path: String, body: Data) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError(message: "socket unavailable") }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw EngineError(message: "socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw EngineError(message: "engine is not running") }

        var line = body
        line.append(0x0A)
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == line.count else { throw EngineError(message: "engine write failed") }

        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while reply.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            reply.append(buffer, count: count)
            if buffer[..<count].contains(0x0A) { break }
        }
        guard let end = reply.firstIndex(of: 0x0A) else { throw EngineError(message: "engine reply incomplete") }
        return reply[..<end]
    }
}
