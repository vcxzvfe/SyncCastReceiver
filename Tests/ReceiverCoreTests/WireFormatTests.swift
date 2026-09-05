import XCTest
@testable import ReceiverCore

final class WireFormatTests: XCTestCase {

    func testHeaderRoundTrip() throws {
        let header = AudioPacketHeader(streamID: 0xDEAD_BEEF,
                                       seq: 12_345,
                                       playAtNanos: 1_234_567_890_123,
                                       frames: UInt32(WireFormat.framesPerPacket))
        let bytes = header.encoded
        XCTAssertEqual(bytes.count, WireFormat.headerByteCount)
        XCTAssertEqual(try AudioPacketHeader.decode(bytes), header)
    }

    func testHeaderIsLittleEndianOnTheWire() throws {
        let header = AudioPacketHeader(streamID: 0x0403_0201, seq: 1, playAtNanos: 0, frames: 240)
        let bytes = header.encoded
        // magic "SCPC" = 0x53435043 little-endian
        XCTAssertEqual(Array(bytes[0..<4]), [0x43, 0x50, 0x43, 0x53])
        XCTAssertEqual(Array(bytes[4..<8]), [0x01, 0x02, 0x03, 0x04])
    }

    func testSequenceNumberWrapRoundTrip() throws {
        for seq: UInt32 in [0, 1, UInt32.max - 1, UInt32.max] {
            let header = AudioPacketHeader(streamID: 7, seq: seq, playAtNanos: UInt64.max / 2, frames: 240)
            XCTAssertEqual(try AudioPacketHeader.decode(header.encoded).seq, seq)
        }
    }

    func testSequenceDistanceWrapsForward() {
        XCTAssertEqual(seqDistance(UInt32.max, 0), 1)
        XCTAssertEqual(seqDistance(UInt32.max - 2, 1), 4)
        XCTAssertEqual(seqDistance(5, 4), -1)
        XCTAssertEqual(seqDistance(0, UInt32.max), -1)
    }

    func testPlayAtNanosSurvivesFullRange() throws {
        for value: UInt64 in [0, 1, 1 << 33, UInt64.max - 1] {
            let header = AudioPacketHeader(streamID: 1, seq: 2, playAtNanos: value, frames: 240)
            XCTAssertEqual(try AudioPacketHeader.decode(header.encoded).playAtNanos, value)
        }
    }

    func testRejectsBadMagic() {
        var bytes = AudioPacketHeader(streamID: 1, seq: 1, playAtNanos: 0, frames: 240).encoded
        bytes[0] = 0x00
        XCTAssertThrowsError(try AudioPacketHeader.decode(bytes)) { error in
            guard case PacketParseError.badMagic = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testRejectsShortBuffer() {
        let bytes = Array(AudioPacketHeader(streamID: 1, seq: 1, playAtNanos: 0, frames: 240).encoded.prefix(20))
        XCTAssertThrowsError(try AudioPacketHeader.decode(bytes)) { error in
            guard case PacketParseError.tooShort = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testRejectsImplausibleFrameCount() {
        let bytes = AudioPacketHeader(streamID: 1, seq: 1, playAtNanos: 0, frames: 1_000_000).encoded
        XCTAssertThrowsError(try AudioPacketHeader.decode(bytes)) { error in
            guard case PacketParseError.implausibleFrameCount = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testPayloadRoundTrip() throws {
        let samples: [Int16] = [0, 1, -1, Int16.max, Int16.min, 12_345, -12_345, 4]
        let header = AudioPacketHeader(streamID: 3, seq: 9, playAtNanos: 42, frames: UInt32(samples.count / 2))
        let packet = buildAudioPacket(header: header, samples: samples)
        XCTAssertEqual(packet.count, WireFormat.headerByteCount + samples.count * 2)

        var out = [Int16](repeating: 0, count: samples.count)
        try packet.withUnsafeBytes { raw in
            let parsed = try AudioPacketHeader.decode(raw)
            XCTAssertEqual(parsed, header)
            try out.withUnsafeMutableBufferPointer { buf in
                _ = try decodeInt16Payload(raw,
                                           offset: WireFormat.headerByteCount,
                                           sampleCount: samples.count,
                                           into: buf.baseAddress!)
            }
        }
        XCTAssertEqual(out, samples)
    }

    func testPayloadLengthMismatchThrows() {
        let packet = buildAudioPacket(header: AudioPacketHeader(streamID: 1, seq: 1, playAtNanos: 0, frames: 2),
                                      samples: [1, 2, 3, 4])
        var out = [Int16](repeating: 0, count: 64)
        let thrown: Error? = packet.withUnsafeBytes { raw -> Error? in
            out.withUnsafeMutableBufferPointer { buf -> Error? in
                do {
                    _ = try decodeInt16Payload(raw,
                                               offset: WireFormat.headerByteCount,
                                               sampleCount: 64,
                                               into: buf.baseAddress!)
                    return nil
                } catch { return error }
            }
        }
        XCTAssertNotNil(thrown)
    }

    func testFullSizePacketMatchesSpec() {
        XCTAssertEqual(WireFormat.payloadByteCount, 960)
        XCTAssertEqual(WireFormat.packetByteCount, 984)
    }
}
