import Foundation
import Network

/// TCP control channel plus the Bonjour advertisement.
///
/// One sender at a time: a second connection replaces the first (a sender
/// that crashed and reconnected must not be locked out), and the displaced
/// one is told why before it is closed.
public final class ControlServer: @unchecked Sendable {

    public struct Advertisement: Sendable {
        public var name: String
        public var tokenHint: String
        public init(name: String, tokenHint: String) {
            self.name = name
            self.tokenHint = tokenHint
        }
    }

    public enum Event: Sendable {
        case listening(port: UInt16)
        case connected(peer: String)
        case message(ControlMessage, peer: String)
        case rejected(peer: String, reason: String)
        case disconnected(peer: String)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "io.syncast.receiver.control")
    private let requestedPort: UInt16
    private let advertisement: Advertisement
    private let handler: @Sendable (Event) -> Void

    private var listener: NWListener?
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var peerDescription = "?"

    public private(set) var boundPort: UInt16 = 0

    public init(port: UInt16, advertisement: Advertisement, handler: @escaping @Sendable (Event) -> Void) {
        self.requestedPort = port
        self.advertisement = advertisement
        self.handler = handler
    }

    public func start() throws {
        queue.sync {
            guard listener == nil else { return }
            do { try startLocked() } catch { handler(.failed("\(error)")) }
        }
    }

    private func startLocked() throws {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        // Low latency, and no Nagle: control messages are tiny and must not
        // wait for a coalescing timer.
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 10
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 10
        }
        let listener: NWListener
        if requestedPort == 0 {
            listener = try NWListener(using: parameters)
        } else {
            guard let port = NWEndpoint.Port(rawValue: requestedPort) else {
                throw NWError.posix(.EINVAL)
            }
            listener = try NWListener(using: parameters, on: port)
        }
        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["name"] = advertisement.name
        txt["token"] = advertisement.tokenHint
        txt["rate"] = String(Int(WireFormat.sampleRate))
        listener.service = NWListener.Service(name: advertisement.name,
                                              type: WireFormat.bonjourServiceType,
                                              domain: nil,
                                              txtRecord: txt)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.boundPort = self.listener?.port?.rawValue ?? 0
                self.handler(.listening(port: self.boundPort))
            case .failed(let error):
                self.handler(.failed("listener failed: \(error)"))
            case .cancelled:
                break
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        queue.sync {
            connection?.cancel()
            connection = nil
            listener?.cancel()
            listener = nil
        }
    }

    /// Send one message to the connected sender. No-op when nobody is
    /// connected — the caller (stats timer, pong) must not care.
    public func send(_ message: ControlMessage) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            guard let data = try? ControlCodec.encode(message) else { return }
            connection.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    public func disconnectPeer(reason: String) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            if let data = try? ControlCodec.encode(.error(ErrorMessage(message: reason))) {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
            connection.cancel()
            self.connection = nil
            self.handler(.disconnected(peer: self.peerDescription))
        }
    }

    // MARK: - connection handling

    private func accept(_ incoming: NWConnection) {
        let peer = NetworkEndpointHost.host(of: incoming.endpoint) ?? "?"
        guard PeerFilter.isAllowed(address: peer) else {
            handler(.rejected(peer: peer, reason: "peer is not on a private network"))
            incoming.cancel()
            return
        }
        if let existing = connection {
            if let data = try? ControlCodec.encode(.error(ErrorMessage(message: "replaced by a new sender"))) {
                existing.send(content: data, completion: .contentProcessed { _ in })
            }
            existing.cancel()
            handler(.disconnected(peer: peerDescription))
        }
        connection = incoming
        peerDescription = peer
        framer.reset()
        incoming.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.handler(.connected(peer: peer))
            case .failed, .cancelled:
                if self.connection === incoming {
                    self.connection = nil
                    self.handler(.disconnected(peer: peer))
                }
            default:
                break
            }
        }
        incoming.start(queue: queue)
        receive(on: incoming, peer: peer)
    }

    private func receive(on connection: NWConnection, peer: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for line in try self.framer.append(data) {
                        do {
                            self.handler(.message(try ControlCodec.decode(line), peer: peer))
                        } catch {
                            // One malformed line is not a reason to drop a
                            // working link; report and keep reading.
                            self.handler(.rejected(peer: peer, reason: "malformed control message: \(error)"))
                        }
                    }
                } catch {
                    self.handler(.rejected(peer: peer, reason: "control framing error: \(error)"))
                    connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                if self.connection === connection {
                    self.connection = nil
                    self.handler(.disconnected(peer: peer))
                }
                connection.cancel()
                return
            }
            self.receive(on: connection, peer: peer)
        }
    }
}
