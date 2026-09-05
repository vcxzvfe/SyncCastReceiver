import XCTest
import Network
@testable import ReceiverCore

/// Where the daemon gets the sender's address from.
///
/// # The bug this pins
///
/// The peer used to be read from `NWConnection.endpoint` at the moment the
/// listener handed the connection over — before it was started, before the
/// kernel had a negotiated path. On real hardware that reported `127.0.0.1`
/// for a sender on another machine. The address is not cosmetic: the UDP
/// media socket filters incoming packets against it (`setExpectedPeer`), so a
/// wrong value silently discards every audio packet that arrives.
final class ControlServerPeerTests: XCTestCase {

    private var server: ControlServer?
    private var client: NWConnection?

    override func tearDown() {
        client?.cancel()
        server?.stop()
        client = nil
        server = nil
        super.tearDown()
    }

    // MARK: - the resolver itself

    /// Before a connection is started there is no path, so the endpoint is
    /// all there is — the resolver must fall back rather than return nothing.
    func testRemoteHostFallsBackToTheEndpointBeforeThereIsAPath() {
        let connection = NWConnection(host: "192.0.2.7", port: 4242, using: .tcp)
        XCTAssertNil(connection.currentPath)
        XCTAssertEqual(NetworkEndpointHost.remoteHost(of: connection), "192.0.2.7")
    }

    /// Network framework renders link-local addresses with an interface
    /// scope; the peer filter and the log both want it gone.
    func testTheInterfaceScopeIsStrippedFromAHost() {
        let connection = NWConnection(host: "fe80::1%lo0", port: 4242, using: .tcp)
        let host = NetworkEndpointHost.remoteHost(of: connection)
        XCTAssertEqual(host, "fe80::1")
        XCTAssertTrue(PeerFilter.isAllowed(address: host ?? ""))
    }

    // MARK: - end to end on loopback

    func testTheConnectedPeerIsResolvedAndCarriedOnEveryMessage() throws {
        let events = EventLog()
        let server = ControlServer(
            port: 0,
            advertisement: .init(name: "SyncCastReceiverUnitTest", tokenHint: "0000")
        ) { event in events.append(event) }
        self.server = server
        try server.start()

        guard let port = events.waitForPort(upTo: 5) else {
            return XCTFail("the listener never reported a port")
        }

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: .tcp)
        self.client = client
        client.start(queue: .global())
        let hello = try ControlCodec.encode(.hello(HelloMessage(
            token: "whatever", name: "SyncCast", rate: Int(WireFormat.sampleRate),
            channels: WireFormat.channelCount,
            framesPerPacket: WireFormat.framesPerPacket, streamID: 7)))
        client.send(content: hello, completion: .idempotent)

        XCTAssertTrue(events.wait(upTo: 5) { log in
            log.contains { if case .message = $0 { return true } else { return false } }
        }, "the hello never arrived: \(events.snapshot.count) events")

        // One `connected`, not one per read, and the peer on it is a real
        // private address the filter accepted.
        let connectedPeers = events.snapshot.compactMap { event -> String? in
            if case .connected(let peer) = event { return peer } else { return nil }
        }
        XCTAssertEqual(connectedPeers.count, 1, "peers: \(connectedPeers)")
        let peer = try XCTUnwrap(connectedPeers.first)
        XCTAssertTrue(PeerFilter.isAllowed(address: peer), "unusable peer \(peer)")
        XCTAssertFalse(peer.contains("%"), "the interface scope leaked into \(peer)")
        XCTAssertFalse(peer.contains(":\(port)"), "the port leaked into \(peer)")

        // The message carries the SAME peer the connection was validated on —
        // this is the value the daemon hands to the media socket's filter.
        let messagePeers = events.snapshot.compactMap { event -> String? in
            if case .message(_, let peer) = event { return peer } else { return nil }
        }
        XCTAssertEqual(Set(messagePeers), [peer])
        XCTAssertTrue(events.snapshot.allSatisfy { event in
            if case .rejected = event { return false } else { return true }
        }, "a loopback sender was rejected")
    }

    /// A thread-safe collector, because the events arrive on the server's own
    /// queue while the test body polls from the main thread.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ControlServer.Event] = []

        func append(_ event: ControlServer.Event) {
            lock.lock(); events.append(event); lock.unlock()
        }

        var snapshot: [ControlServer.Event] {
            lock.lock(); defer { lock.unlock() }
            return events
        }

        func wait(upTo seconds: TimeInterval,
                  for predicate: ([ControlServer.Event]) -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if predicate(snapshot) { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return predicate(snapshot)
        }

        func waitForPort(upTo seconds: TimeInterval) -> UInt16? {
            _ = wait(upTo: seconds) { log in
                log.contains { if case .listening = $0 { return true } else { return false } }
            }
            for event in snapshot {
                if case .listening(let port) = event, port != 0 { return port }
            }
            return nil
        }
    }
}
