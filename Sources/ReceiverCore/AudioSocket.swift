import Foundation
import Darwin

/// UDP media socket.
///
/// A plain BSD socket on its own thread rather than an `NWListener`: the
/// media path is a one-way firehose of 200 datagrams a second from a single
/// peer, and `recvfrom` on a blocking socket is both the lowest-overhead and
/// the most predictable way to take it. The thread does nothing but parse and
/// hand frames to the jitter ring — never blocks on a lock the render thread
/// could hold.
public final class AudioSocket: @unchecked Sendable {

    public struct Counters: Sendable {
        public var rejectedPeer = 0
        public var rejectedStream = 0
        public var malformed = 0
    }

    private let engine: PlayoutEngine
    private let onError: @Sendable (String) -> Void
    private let stateLock = NSLock()
    private var fd: Int32 = -1
    private var thread: Thread?
    private var expectedPeer: String?
    private var expectedStreamID: UInt32?
    private var counters = Counters()
    private let closing = AtomicBool(false)

    public private(set) var boundPort: UInt16 = 0

    public init(engine: PlayoutEngine, onError: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.onError = onError
    }

    deinit { close() }

    public enum SocketError: Error, CustomStringConvertible {
        case syscall(String, Int32)
        public var description: String {
            switch self {
            case .syscall(let what, let code):
                return "\(what) failed: \(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }

    /// Bind and start receiving. `port` 0 takes an ephemeral port, which is
    /// what gets reported in `hello_ack.udp_port`.
    @discardableResult
    public func open(port: UInt16 = 0) throws -> UInt16 {
        close()
        closing.value = false
        // Dual stack: one AF_INET6 socket with V6ONLY off also accepts IPv4
        // peers as ::ffff:a.b.c.d, so a sender on either stack works.
        let socketFD = socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketFD >= 0 else { throw SocketError.syscall("socket", errno) }
        var off: Int32 = 0
        setsockopt(socketFD, IPPROTO_IPV6, IPV6_V6ONLY, &off, socklen_t(MemoryLayout<Int32>.size))
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        // A second of audio in kernel buffers: enough to ride out a
        // scheduling hiccup on this side without dropping datagrams.
        var receiveBuffer: Int32 = 1 << 20
        setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout<Int32>.size))
        // Wake up regularly so `close()` is noticed even with no traffic.
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        address.sin6_addr = in6addr_any
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindStatus == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw SocketError.syscall("bind", code)
        }

        var bound = sockaddr_storage()
        var boundLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &boundLength)
            }
        }
        stateLock.lock()
        fd = socketFD
        boundPort = NetworkEndpointHost.port(of: bound)
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.receiveLoop(fd: socketFD) }
        thread.name = "io.syncast.receiver.audio"
        thread.qualityOfService = .userInteractive
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
        return boundPort
    }

    public func close() {
        closing.value = true
        stateLock.lock()
        let socketFD = fd
        fd = -1
        stateLock.unlock()
        if socketFD >= 0 { Darwin.close(socketFD) }
        thread = nil
    }

    /// Only accept media from the host that owns the control channel.
    public func setExpectedPeer(_ host: String?) {
        stateLock.lock(); expectedPeer = host.map(PeerFilter.normalise); stateLock.unlock()
    }

    public func setExpectedStreamID(_ streamID: UInt32?) {
        stateLock.lock(); expectedStreamID = streamID; stateLock.unlock()
    }

    public var counterSnapshot: Counters {
        stateLock.lock(); defer { stateLock.unlock() }
        return counters
    }

    // MARK: - receive thread

    private func receiveLoop(fd socketFD: Int32) {
        let maxDatagram = 2_048
        var packet = [UInt8](repeating: 0, count: maxDatagram)
        var samples = [Int16](repeating: 0, count: 4_096 * WireFormat.channelCount)

        while !closing.value {
            var from = sockaddr_storage()
            var fromLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received: Int = packet.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, raw.baseAddress, maxDatagram, 0, $0, &fromLength)
                    }
                }
            }
            if received < 0 {
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK || code == EINTR { continue }
                if closing.value || code == EBADF { return }
                onError("recvfrom failed: \(String(cString: strerror(code)))")
                // Back off rather than spin on a hard error.
                usleep(100_000)
                continue
            }
            guard received >= WireFormat.headerByteCount else {
                note { $0.malformed += 1 }
                continue
            }
            guard accepts(from: from) else {
                note { $0.rejectedPeer += 1 }
                continue
            }
            handle(packet: packet, byteCount: received, samples: &samples)
        }
    }

    private func handle(packet: [UInt8], byteCount: Int, samples: inout [Int16]) {
        let header: AudioPacketHeader
        do {
            header = try packet.withUnsafeBytes { try AudioPacketHeader.decode($0) }
        } catch {
            note { $0.malformed += 1 }
            return
        }
        stateLock.lock()
        let expected = expectedStreamID
        stateLock.unlock()
        if let expected, expected != header.streamID {
            note { $0.rejectedStream += 1 }
            return
        }
        let sampleCount = Int(header.frames) * WireFormat.channelCount
        guard sampleCount <= samples.count,
              byteCount >= WireFormat.headerByteCount + sampleCount * 2 else {
            note { $0.malformed += 1 }
            return
        }
        do {
            try packet.withUnsafeBytes { raw in
                try samples.withUnsafeMutableBufferPointer { out in
                    _ = try decodeInt16Payload(raw,
                                               offset: WireFormat.headerByteCount,
                                               sampleCount: sampleCount,
                                               into: out.baseAddress!)
                }
            }
        } catch {
            note { $0.malformed += 1 }
            return
        }
        _ = samples.withUnsafeBufferPointer { buffer in
            engine.ingest(header: header, samples: buffer.baseAddress!)
        }
    }

    private func accepts(from: sockaddr_storage) -> Bool {
        guard let host = NetworkEndpointHost.host(of: from) else { return false }
        guard PeerFilter.isAllowed(address: host) else { return false }
        stateLock.lock()
        let expected = expectedPeer
        stateLock.unlock()
        guard let expected else { return true }
        return PeerFilter.normalise(host) == expected || mappedEquivalent(host, expected)
    }

    /// A sender whose control channel is IPv4 may send media from the same
    /// address rendered as `::ffff:a.b.c.d` (or the other way round).
    private func mappedEquivalent(_ a: String, _ b: String) -> Bool {
        func plain(_ s: String) -> String {
            let normalised = PeerFilter.normalise(s)
            if normalised.lowercased().hasPrefix("::ffff:") { return String(normalised.dropFirst(7)) }
            return normalised
        }
        return plain(a) == plain(b)
    }

    private func note(_ mutate: (inout Counters) -> Void) {
        stateLock.lock(); mutate(&counters); stateLock.unlock()
    }
}
