import Foundation
import Network

/// One Play On connection. Both devices run the same code and either can send the music, so this
/// only carries messages; what they mean is KnobShiftPlayOnSession's business.
final class KnobShiftPlayOnLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "knob.playon.link", qos: .userInitiated)
    private var reader = KnobShiftTogether.Reader()
    private var closed = false
    private var isConnected = false
    var onMessage: (@Sendable (KnobShiftTogether.Message) -> Void)?
    var onClose: (@Sendable () -> Void)?

    init(connection: NWConnection) { self.connection = connection }

    convenience init(to endpoint: NWEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        self.init(connection: NWConnection(to: endpoint, using: parameters))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled, .waiting: self?.finish()
            case .ready: self?.isConnected = true
            default: break
            }
        }
        connection.start(queue: queue)
        // A device that has gone never fails a connection: it just stays "preparing".
        queue.asyncAfter(deadline: .now() + KnobShiftTogether.connectSeconds) { [weak self] in
            if self?.isConnected == false { self?.finish() }
        }
        receive()
    }

    func close() {
        queue.async { [self] in
            onClose = nil
            finish()
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    func send(_ message: KnobShiftTogether.Message) {
        connection.send(content: KnobShiftTogether.encode(message), completion: .contentProcessed { _ in })
    }

    /// Waits until the bytes have left, so a big file goes out at the speed the Wi-Fi takes it.
    func sendAndWait(_ message: KnobShiftTogether.Message) async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            connection.send(content: KnobShiftTogether.encode(message), completion: .contentProcessed { error in
                done.resume(returning: error == nil)
            })
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.reader.add(data) { self.onMessage?(message) }
                } catch {
                    self.finish()
                    return
                }
            }
            if done || error != nil { self.finish() } else if !self.closed { self.receive() }
        }
    }
}

/// Offers this device to the others while Knob is open.
final class KnobShiftPlayOnOffer: @unchecked Sendable {
    private var listener: NWListener?
    var onConnection: (@Sendable (NWConnection) -> Void)?

    func start(name: String) {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.service = NWListener.Service(name: name, type: KnobShiftPlayOn.service)
        listener.newConnectionHandler = { [weak self] connection in
            guard KnobShiftLink.isLocal(connection.endpoint) else { connection.cancel(); return }
            self?.onConnection?(connection)
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}
