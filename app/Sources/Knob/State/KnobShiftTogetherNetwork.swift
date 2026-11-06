import Foundation
import Network

/// The host's side of the wire: offers the session with Bonjour, sends the mix to each listener
/// and answers clock pings. Called from the capture thread, so it keeps to its own lock.
final class KnobShiftTogetherHost: @unchecked Sendable {
    private final class Client {
        let connection: NWConnection
        var name = "Someone"
        var reader = KnobShiftTogether.Reader()
        var waiting = 0
        var joined = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let name: String
    private let queue = DispatchQueue(label: "knob.together.host", qos: .userInitiated)
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: Client] = [:]
    private var listener: NWListener?
    private var clock: NWListener?
    private var clockPort: UInt16?
    private var lastState: KnobShiftTogether.Message?
    private var lastCover: KnobShiftTogether.Message?
    private var lastEffects: KnobShiftTogether.Message?
    var onPeople: (@Sendable ([String]) -> Void)?
    var onCommand: (@Sendable (KnobShiftTogether.Command) -> Void)?
    var onEffects: (@Sendable (KnobShiftTogether.Effects) -> Void)?
    var onFailure: (@Sendable () -> Void)?

    init(name: String) { self.name = name }

    func start() throws {
        let clock = try NWListener(using: .udp)
        clock.newConnectionHandler = { [weak self] connection in self?.answerClock(connection) }
        clock.stateUpdateHandler = { [weak self, weak clock] state in
            if case .ready = state { self?.lock.withLock { self?.clockPort = clock?.port?.rawValue } }
        }
        clock.start(queue: queue)
        self.clock = clock

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(name: name, type: KnobShiftTogether.service)
        listener.newConnectionHandler = { [weak self] connection in
            guard KnobShiftLink.isLocal(connection.endpoint) else { connection.cancel(); return }
            self?.welcome(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.onFailure?() }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop(state: KnobShiftTogether.Message?) {
        if let state { send(state) }
        listener?.cancel()
        clock?.cancel()
        listener = nil
        clock = nil
        let all = lock.withLock { () -> [Client] in
            defer { clients.removeAll() }
            return Array(clients.values)
        }
        // Long enough for the goodbye to leave.
        queue.asyncAfter(deadline: .now() + 0.3) { all.forEach { $0.connection.cancel() } }
    }

    // MARK: Sending

    func send(block: KnobShiftTogetherCapture.Block) {
        let data = KnobShiftTogether.encode(KnobShiftTogether.sound(firstFrame: block.firstFrame, samples: block.samples))
        lock.lock()
        let ready = clients.values.filter { $0.joined && $0.waiting < KnobShiftTogether.mostWaiting }
        for client in ready { client.waiting += data.count }
        lock.unlock()
        for client in ready { push(data, to: client) }
    }

    func send(_ message: KnobShiftTogether.Message) {
        lock.lock()
        if message.kind == .state { lastState = message }
        if message.kind == .cover { lastCover = message }
        if message.kind == .effects { lastEffects = message }
        let ready = clients.values.filter(\.joined)
        lock.unlock()
        let data = KnobShiftTogether.encode(message)
        for client in ready { push(data, to: client, counted: false) }
    }

    private func push(_ data: Data, to client: Client, counted: Bool = true) {
        client.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard counted else { return }
            self?.lock.withLock { client.waiting -= data.count }
        })
    }

    // MARK: Listeners

    private func welcome(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        lock.lock()
        let full = clients.count >= KnobShiftTogether.mostListeners
        if !full { clients[id] = client }
        let port = clockPort
        lock.unlock()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        connection.start(queue: queue)
        let hello = KnobShiftTogether.Hello(version: KnobShiftTogether.version, name: name, clockPort: port, full: full ? true : nil)
        if let message = KnobShiftTogether.json(.hello, hello) {
            connection.send(content: KnobShiftTogether.encode(message), completion: .contentProcessed { _ in })
        }
        if full {
            queue.asyncAfter(deadline: .now() + 0.3) { connection.cancel() }
            return
        }
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: KnobShiftTogether.longestRequest) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try client.reader.add(data) where message.body.count <= KnobShiftTogether.longestRequest {
                        self.handle(message, from: client)
                    }
                } catch {
                    client.connection.cancel()
                    return
                }
            }
            if done || error != nil { client.connection.cancel() } else { self.receive(client) }
        }
    }

    private func handle(_ message: KnobShiftTogether.Message, from client: Client) {
        switch message.kind {
        case .hello:
            guard let hello = try? JSONDecoder().decode(KnobShiftTogether.Hello.self, from: message.body),
                  hello.version == KnobShiftTogether.version else {
                client.connection.cancel()
                return
            }
            lock.lock()
            client.name = String(hello.name.prefix(60))
            client.joined = true
            let waiting = [lastState, lastCover, lastEffects].compactMap { $0 }
            lock.unlock()
            for message in waiting { push(KnobShiftTogether.encode(message), to: client, counted: false) }
            announce()
        case .command:
            guard client.joined, let command = try? JSONDecoder().decode(KnobShiftTogether.Command.self, from: message.body) else { return }
            onCommand?(command)
        case .effects:
            guard client.joined, let effects = try? JSONDecoder().decode(KnobShiftTogether.Effects.self, from: message.body), effects.isValid else { return }
            onEffects?(effects)
        default: break // A listener has no business sending anything else.
        }
    }

    private func remove(_ id: ObjectIdentifier) {
        lock.withLock { _ = clients.removeValue(forKey: id) }
        announce()
    }

    /// Takes a listener out of the session.
    func removeListener(named name: String) {
        let found = lock.withLock { clients.values.first { $0.name == name } }
        found?.connection.cancel()
    }

    private func announce() {
        onPeople?(lock.withLock { clients.values.filter(\.joined).map(\.name).sorted() })
    }

    // MARK: Clock

    private func answerClock(_ connection: NWConnection) {
        guard KnobShiftLink.isLocal(connection.endpoint) else { connection.cancel(); return }
        connection.start(queue: queue)
        func receive() {
            connection.receiveMessage { data, _, _, error in
                if let data, data.count == 8 {
                    var reply = data
                    withUnsafeBytes(of: KnobShiftTogether.now().littleEndian) { reply.append(contentsOf: $0) }
                    connection.send(content: reply, completion: .contentProcessed { _ in })
                }
                if error == nil { receive() }
            }
        }
        receive()
    }
}

/// A listener's side of the wire: joins a host, fills the ring and follows its clock.
final class KnobShiftTogetherGuest: @unchecked Sendable {
    enum Ending: Sendable { case lost, ended, full, version }

    private let queue = DispatchQueue(label: "knob.together.guest", qos: .userInitiated)
    private let connection: NWConnection
    private let player: KnobShiftTogetherPlayer
    private let name: String
    private var reader = KnobShiftTogether.Reader()
    private var clock = KnobShiftTogetherClock()
    private var pinger: NWConnection?
    private var timer: DispatchSourceTimer?
    private var finished = false
    var onState: (@Sendable (KnobShiftTogether.State) -> Void)?
    var onCover: (@Sendable (Data) -> Void)?
    var onEffects: (@Sendable (KnobShiftTogether.Effects) -> Void)?
    var onEnd: (@Sendable (Ending) -> Void)?
    var onHello: (@Sendable (String) -> Void)?

    init(endpoint: NWEndpoint, name: String, player: KnobShiftTogetherPlayer) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        connection = NWConnection(to: endpoint, using: parameters)
        self.name = name
        self.player = player
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish(.lost)
            default: break
            }
        }
        connection.start(queue: queue)
        if let hello = KnobShiftTogether.json(.hello, KnobShiftTogether.Hello(version: KnobShiftTogether.version, name: name)) {
            send(hello)
        }
        receive()
    }

    func stop() {
        queue.async { [self] in
            finished = true
            timer?.cancel()
            pinger?.cancel()
            connection.cancel()
        }
    }

    func send(_ effects: KnobShiftTogether.Effects) {
        if let message = KnobShiftTogether.json(.effects, effects) { send(message) }
    }

    func send(_ command: KnobShiftTogether.Command) {
        if let message = KnobShiftTogether.json(.command, command) { send(message) }
    }

    private func send(_ message: KnobShiftTogether.Message) {
        connection.send(content: KnobShiftTogether.encode(message), completion: .contentProcessed { _ in })
    }

    private func finish(_ ending: Ending) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        pinger?.cancel()
        connection.cancel()
        onEnd?(ending)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.reader.add(data) { self.handle(message) }
                } catch {
                    self.finish(.lost)
                    return
                }
            }
            if done || error != nil { self.finish(.lost) } else if !self.finished { self.receive() }
        }
    }

    private func handle(_ message: KnobShiftTogether.Message) {
        switch message.kind {
        case .hello:
            guard let hello = try? JSONDecoder().decode(KnobShiftTogether.Hello.self, from: message.body) else { return }
            guard hello.version == KnobShiftTogether.version else { finish(.version); return }
            if hello.full == true { finish(.full); return }
            onHello?(hello.name)
            if let port = hello.clockPort { followClock(port) }
        case .sound:
            guard let first = KnobShiftTogether.soundFrame(message.body) else { return }
            let samples = message.body.dropFirst(8).withUnsafeBytes { Array($0.bindMemory(to: UInt8.self)) }
            let values = samples.withUnsafeBytes { raw in (0..<(raw.count / 2)).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
            values.withUnsafeBufferPointer { player.ring.write(firstFrame: first, samples: $0) }
        case .anchor:
            guard let anchor = KnobShiftTogether.readAnchor(message.body) else { return }
            player.tick()
            player.add(frame: anchor.frame, hostNanoseconds: anchor.hostNanoseconds, rate: anchor.rate)
        case .state:
            guard let state = try? JSONDecoder().decode(KnobShiftTogether.State.self, from: message.body) else { return }
            if state.ended == true { finish(.ended) } else { onState?(state) }
        case .cover:
            onCover?(message.body)
        case .effects:
            guard let effects = try? JSONDecoder().decode(KnobShiftTogether.Effects.self, from: message.body), effects.isValid else { return }
            onEffects?(effects)
        case .command: break
        }
    }

    private func followClock(_ port: UInt16) {
        guard case .hostPort(let host, _)? = connection.currentPath?.remoteEndpoint, let port = NWEndpoint.Port(rawValue: port) else { return }
        let pinger = NWConnection(host: host, port: port, using: .udp)
        self.pinger = pinger
        pinger.start(queue: queue)
        func listen() {
            pinger.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, data.count == 16 {
                    let received = KnobShiftTogether.now()
                    let (sent, answered) = data.withUnsafeBytes { bytes in
                        (Int64(littleEndian: bytes.loadUnaligned(as: Int64.self)), Int64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: Int64.self)))
                    }
                    self.clock.add(sent: sent, hostAnswered: answered, received: received)
                    if let offset = self.clock.offset { self.player.setClockOffset(offset) }
                }
                if error == nil, !self.finished { listen() }
            }
        }
        listen()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.2)
        timer.setEventHandler {
            var stamp = KnobShiftTogether.now().littleEndian
            pinger.send(content: Data(bytes: &stamp, count: 8), completion: .contentProcessed { _ in })
        }
        timer.resume()
        self.timer = timer
    }
}
