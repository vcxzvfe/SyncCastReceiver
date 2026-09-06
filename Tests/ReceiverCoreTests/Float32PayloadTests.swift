import XCTest
@testable import ReceiverCore

/// The `f32le` payload: negotiated in `hello`/`hello_ack`, carried through
/// the parser and the ring without touching the values — including values
/// past full scale, which is the whole reason the format exists.
final class Float32PayloadTests: XCTestCase {

    func testFloatPayloadRoundTripKeepsValuesPastFullScale() throws {
        let samples: [Float] = [0, 0.5, -0.5, 1.0, -1.0, 1.55, -1.55, 0.000001]
        let header = AudioPacketHeader(streamID: 7, seq: 1, playAtNanos: 99, frames: UInt32(samples.count / 2))
        let packet = buildAudioPacket(header: header, floatSamples: samples)
        XCTAssertEqual(packet.count, WireFormat.headerByteCount + samples.count * 4)

        var out = [Float](repeating: 0, count: samples.count)
        try packet.withUnsafeBytes { raw in
            XCTAssertEqual(try AudioPacketHeader.decode(raw), header)
            try out.withUnsafeMutableBufferPointer { buf in
                _ = try decodeFloat32Payload(raw, offset: WireFormat.headerByteCount,
                                             sampleCount: samples.count, into: buf.baseAddress!)
            }
        }
        XCTAssertEqual(out, samples)
    }

    func testNonFiniteFloatSamplesBecomeSilence() throws {
        let samples: [Float] = [.nan, .infinity, -.infinity, 0.25]
        let header = AudioPacketHeader(streamID: 7, seq: 1, playAtNanos: 99, frames: 2)
        let packet = buildAudioPacket(header: header, floatSamples: samples)
        var out = [Float](repeating: 9, count: 4)
        try packet.withUnsafeBytes { raw in
            try out.withUnsafeMutableBufferPointer { buf in
                _ = try decodeFloat32Payload(raw, offset: WireFormat.headerByteCount,
                                             sampleCount: 4, into: buf.baseAddress!)
            }
        }
        XCTAssertEqual(out, [0, 0, 0, 0.25])
    }

    func testPacketSizesPerFormat() {
        XCTAssertEqual(WireFormat.payloadByteCount(for: .int16), 960)
        XCTAssertEqual(WireFormat.payloadByteCount(for: .float32), 1_920)
        XCTAssertEqual(WireFormat.packetByteCount(for: .float32), 1_944)
        XCTAssertEqual(WireFormat.SampleFormat(rawValue: "f32le"), .float32)
        XCTAssertEqual(WireFormat.SampleFormat(rawValue: "s16le"), .int16)
        XCTAssertNil(WireFormat.SampleFormat(rawValue: "opus"))
    }

    func testHelloAndAckCarryTheFormatAndOmitItWhenAbsent() throws {
        let hello = HelloMessage(token: "t", name: "s", streamID: 1, format: "f32le")
        let json = String(decoding: try JSONEncoder().encode(hello), as: UTF8.self)
        XCTAssertTrue(json.contains("\"format\":\"f32le\""), json)
        let v1 = try JSONDecoder().decode(HelloMessage.self, from: Data(#"{"type":"hello","v":1,"token":"t","name":"s","rate":48000,"channels":2,"frames_per_packet":240,"stream_id":1}"#.utf8))
        XCTAssertNil(v1.format, "a v1 sender says nothing and gets s16le")
        let ack = HelloAckMessage(udpPort: 1, device: "d", deviceUID: "u", hwVolume: true, bufferMs: 90, format: "f32le")
        let ackJSON = String(decoding: try JSONEncoder().encode(ack), as: UTF8.self)
        XCTAssertTrue(ackJSON.contains("\"format\":\"f32le\""), ackJSON)
    }

    func testRingStoresFloatSamplesUntouched() {
        let buffer = JitterBuffer()
        let frames = WireFormat.framesPerPacket
        var samples = [Float](repeating: 0, count: frames * 2)
        for f in 0..<frames { samples[f * 2] = 1.55; samples[f * 2 + 1] = -0.25 }
        let header = AudioPacketHeader(streamID: 1, seq: 0, playAtNanos: 1_000_000_000, frames: UInt32(frames))
        let outcome = samples.withUnsafeBufferPointer { buffer.ingest(header: header, floatSamples: $0.baseAddress!) }
        // The first packet of a fresh buffer defines the stream: `.restarted`.
        XCTAssertEqual(outcome, .restarted(index: 0))
        buffer.anchorReadCursor(toSenderNanos: 1_000_000_000)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        var heads = [left, right]
        heads.withUnsafeMutableBufferPointer { p in
            _ = buffer.read(frames: frames, into: UnsafePointer(p.baseAddress!))
        }
        XCTAssertEqual(left[10], 1.55, accuracy: 1e-6, "a hot sample must survive the ring")
        XCTAssertEqual(right[10], -0.25, accuracy: 1e-6)
    }

    func testIOBufferOptionParses() throws {
        XCTAssertEqual(try CLIOptions.parse(["--io-buffer", "128"]).ioBufferFrames, 128)
        XCTAssertEqual(try CLIOptions.parse(["--io-buffer", "0"]).ioBufferFrames, 0)
        XCTAssertEqual(try CLIOptions.parse([]).ioBufferFrames, 256)
        XCTAssertThrowsError(try CLIOptions.parse(["--io-buffer", "7"]))
        XCTAssertEqual(try CLIOptions.parse(["--install", "--io-buffer", "128"]).passthroughArguments, ["--io-buffer", "128"])
    }
}
