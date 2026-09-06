import Foundation

/// Fixed parameters of the PCM link. Both ends hard-code them; a `hello`
/// that disagrees is rejected rather than silently renegotiated.
public enum WireFormat {
    public static let sampleRate: Double = 48_000
    public static let channelCount = 2
    public static let framesPerPacket = 240          // 5 ms
    public static let bytesPerSample = 2             // Int16 LE (the v1 default)
    public static let headerByteCount = 24
    public static var payloadByteCount: Int {
        framesPerPacket * channelCount * bytesPerSample
    }
    public static var packetByteCount: Int { headerByteCount + payloadByteCount }

    /// Sample format of the UDP payload, negotiated in `hello` / `hello_ack`.
    ///
    /// `s16le` is the v1 wire format and the default when a sender says
    /// nothing. `f32le` carries the sender's Float32 mix untouched: the
    /// sender's master level is applied on THIS side (in hardware when the
    /// device has it), so the signal on the wire is pre-volume and can
    /// legitimately exceed full scale — a hot programme, an EQ boost — and an
    /// Int16 payload would have to clip it where the sender's own outputs,
    /// which scale before their DAC, do not. 3 Mbit/s instead of 1.5 on a
    /// LAN is nothing.
    public enum SampleFormat: String, Sendable, CaseIterable {
        case int16 = "s16le"
        case float32 = "f32le"

        public var bytesPerSample: Int {
            switch self {
            case .int16: return 2
            case .float32: return 4
            }
        }
    }

    public static func payloadByteCount(for format: SampleFormat) -> Int {
        framesPerPacket * channelCount * format.bytesPerSample
    }

    public static func packetByteCount(for format: SampleFormat) -> Int {
        headerByteCount + payloadByteCount(for: format)
    }
    /// Bonjour service type. `_udp` because the media path is UDP; the
    /// advertised port is the TCP control port (see `hello_ack.udp_port`
    /// for the media port).
    public static let bonjourServiceType = "_synccast-pcm._udp"
    public static let defaultControlPort: UInt16 = 47_100
    public static let protocolVersion = 1
}

public enum PacketParseError: Error, Equatable {
    case tooShort(Int)
    case badMagic(UInt32)
    case implausibleFrameCount(UInt32)
    case payloadLengthMismatch(expected: Int, got: Int)
}

/// 24-byte little-endian audio packet header.
///
/// ```
/// u32 magic = 0x53435043 ("SCPC")
/// u32 stream_id
/// u32 seq
/// u64 play_at_ns     (SENDER monotonic ns for the first frame, at the DAC)
/// u32 frames
/// ```
/// `play_at_ns` sits at offset 12, i.e. 8-byte-unaligned, so every field is
/// assembled byte by byte instead of by `load(as:)`.
public struct AudioPacketHeader: Equatable, Sendable {
    public static let magic: UInt32 = 0x5343_5043   // "SCPC"

    public var streamID: UInt32
    public var seq: UInt32
    public var playAtNanos: UInt64
    public var frames: UInt32

    public init(streamID: UInt32, seq: UInt32, playAtNanos: UInt64, frames: UInt32) {
        self.streamID = streamID
        self.seq = seq
        self.playAtNanos = playAtNanos
        self.frames = frames
    }

    public func encode(into out: inout [UInt8]) {
        appendLE(UInt32(Self.magic), &out)
        appendLE(streamID, &out)
        appendLE(seq, &out)
        appendLE(playAtNanos, &out)
        appendLE(frames, &out)
    }

    public var encoded: [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(WireFormat.headerByteCount)
        encode(into: &out)
        return out
    }

    /// Parse a header from `bytes` at `offset`. Throws rather than returning
    /// nil so the caller can log *why* a datagram from the network was
    /// rejected (external data, validated at the boundary).
    public static func decode(_ bytes: UnsafeRawBufferPointer, at offset: Int = 0) throws -> AudioPacketHeader {
        guard bytes.count - offset >= WireFormat.headerByteCount else {
            throw PacketParseError.tooShort(bytes.count - offset)
        }
        let magic = readLE32(bytes, offset)
        guard magic == Self.magic else { throw PacketParseError.badMagic(magic) }
        let frames = readLE32(bytes, offset + 20)
        // A frame count is bounded by the MTU-sized datagram we accept; a
        // wild value here would otherwise size an allocation from the wire.
        guard frames > 0, frames <= 4_096 else {
            throw PacketParseError.implausibleFrameCount(frames)
        }
        return AudioPacketHeader(
            streamID: readLE32(bytes, offset + 4),
            seq: readLE32(bytes, offset + 8),
            playAtNanos: readLE64(bytes, offset + 12),
            frames: frames
        )
    }

    public static func decode(_ data: [UInt8]) throws -> AudioPacketHeader {
        try data.withUnsafeBytes { try decode($0) }
    }
}

/// Wrap-aware distance between two 32-bit sequence numbers: how far `b` is
/// ahead of `a`. `seqDistance(0xFFFFFFFF, 0) == 1`.
public func seqDistance(_ a: UInt32, _ b: UInt32) -> Int32 {
    Int32(bitPattern: b &- a)
}

@inline(__always)
private func appendLE(_ v: UInt32, _ out: inout [UInt8]) {
    out.append(UInt8(truncatingIfNeeded: v))
    out.append(UInt8(truncatingIfNeeded: v >> 8))
    out.append(UInt8(truncatingIfNeeded: v >> 16))
    out.append(UInt8(truncatingIfNeeded: v >> 24))
}

@inline(__always)
private func appendLE(_ v: UInt64, _ out: inout [UInt8]) {
    for shift in stride(from: 0, through: 56, by: 8) {
        out.append(UInt8(truncatingIfNeeded: v >> UInt64(shift)))
    }
}

@inline(__always)
private func readLE32(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

@inline(__always)
private func readLE64(_ b: UnsafeRawBufferPointer, _ o: Int) -> UInt64 {
    var v: UInt64 = 0
    for i in 0..<8 { v |= UInt64(b[o + i]) << UInt64(8 * i) }
    return v
}

/// Build a complete packet (header + Int16 LE interleaved payload). Used by
/// the tests and `--selftest`; the daemon itself only ever decodes.
public func buildAudioPacket(header: AudioPacketHeader, samples: [Int16]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(WireFormat.headerByteCount + samples.count * 2)
    header.encode(into: &out)
    for s in samples {
        let u = UInt16(bitPattern: s)
        out.append(UInt8(truncatingIfNeeded: u))
        out.append(UInt8(truncatingIfNeeded: u >> 8))
    }
    return out
}

/// Decode the interleaved Int16 LE payload into `out` (which must have room
/// for `frames * channels` samples). Returns the sample count written.
@discardableResult
/// Decode an interleaved Float32 LE payload. Values are passed through as
/// they are — including anything past ±1.0, which is the point of the format
/// (see `WireFormat.SampleFormat`); non-finite values become silence so a
/// corrupt packet cannot poison the DAC.
public func decodeFloat32Payload(
    _ bytes: UnsafeRawBufferPointer,
    offset: Int,
    sampleCount: Int,
    into out: UnsafeMutablePointer<Float>
) throws -> Int {
    let needed = sampleCount * 4
    guard bytes.count - offset >= needed else {
        throw PacketParseError.payloadLengthMismatch(expected: needed, got: bytes.count - offset)
    }
    for i in 0..<sampleCount {
        let o = offset + i * 4
        let bits = UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8
            | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        let value = Float(bitPattern: bits)
        out[i] = value.isFinite ? value : 0
    }
    return sampleCount
}

/// Build a packet with a Float32 payload (tests and the self-test).
public func buildAudioPacket(header: AudioPacketHeader, floatSamples: [Float]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(WireFormat.headerByteCount + floatSamples.count * 4)
    header.encode(into: &out)
    for sample in floatSamples {
        let bits = sample.bitPattern
        out.append(UInt8(truncatingIfNeeded: bits))
        out.append(UInt8(truncatingIfNeeded: bits >> 8))
        out.append(UInt8(truncatingIfNeeded: bits >> 16))
        out.append(UInt8(truncatingIfNeeded: bits >> 24))
    }
    return out
}

public func decodeInt16Payload(
    _ bytes: UnsafeRawBufferPointer,
    offset: Int,
    sampleCount: Int,
    into out: UnsafeMutablePointer<Int16>
) throws -> Int {
    let needed = sampleCount * 2
    guard bytes.count - offset >= needed else {
        throw PacketParseError.payloadLengthMismatch(expected: needed, got: bytes.count - offset)
    }
    for i in 0..<sampleCount {
        let o = offset + i * 2
        let u = UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8
        out[i] = Int16(bitPattern: u)
    }
    return sampleCount
}
