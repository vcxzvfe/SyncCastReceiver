import XCTest
@testable import ReceiverCore

final class ControlMessageTests: XCTestCase {

    private func roundTrip(_ message: ControlMessage, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try ControlCodec.encode(message)
        XCTAssertEqual(data.last, 0x0A, "messages must be newline delimited", file: file, line: line)
        let decoded = try ControlCodec.decode(data.dropLast())
        XCTAssertEqual(decoded, message, file: file, line: line)
    }

    func testAllMessagesRoundTrip() throws {
        try roundTrip(.hello(HelloMessage(token: "0123456789abcdef0123456789abcdef",
                                          name: "sender", streamID: 0xFFFF_0000)))
        try roundTrip(.gain(GainMessage(linear: 0.3162, muted: false)))
        try roundTrip(.gain(GainMessage(linear: 0, muted: true)))
        try roundTrip(.latency(LatencyMessage(targetMs: 90)))
        try roundTrip(.ping(PingMessage(t1: 987_654_321_000)))
        try roundTrip(.ping(PingMessage(t1: 987_654_321_000, prevT4: 987_654_999_000)))
        try roundTrip(.bye)
        try roundTrip(.helloAck(HelloAckMessage(udpPort: 51_234, device: "Built-in Output",
                                                deviceUID: "BuiltInSpeakerDevice",
                                                hwVolume: true, bufferMs: 90)))
        try roundTrip(.pong(PongMessage(t1: 1, t2: 2, t3: 3)))
        try roundTrip(.stats(StatsMessage(late: 1, lost: 2, underrun: 3,
                                          bufferMs: 89.5, ratio: 0.99991, clip: 0)))
        try roundTrip(.error(ErrorMessage(message: "bad token")))
    }

    func testWireKeysMatchSpec() throws {
        let line = try ControlCodec.encodeLine(.hello(HelloMessage(token: "t", name: "n", streamID: 5)))
        for key in ["\"type\":\"hello\"", "\"frames_per_packet\":240", "\"stream_id\":5",
                    "\"rate\":48000", "\"channels\":2"] {
            XCTAssertTrue(line.contains(key), "missing \(key) in \(line)")
        }
        let ack = try ControlCodec.encodeLine(
            .helloAck(HelloAckMessage(udpPort: 1, device: "d", deviceUID: "u", hwVolume: false, bufferMs: 90)))
        XCTAssertTrue(ack.contains("\"type\":\"hello_ack\""))
        XCTAssertTrue(ack.contains("\"udp_port\":1"))
        XCTAssertTrue(ack.contains("\"device_uid\":\"u\""))
        XCTAssertTrue(ack.contains("\"hw_volume\":false"))
        let stats = try ControlCodec.encodeLine(
            .stats(StatsMessage(late: 0, lost: 0, underrun: 0, bufferMs: 90, ratio: 1, clip: 0)))
        XCTAssertTrue(stats.contains("\"buffer_ms\":90"))
    }

    func testDecodesSpecLiterals() throws {
        let hello = try ControlCodec.decode(line:
            #"{"type":"hello","v":1,"token":"abc","name":"sender","rate":48000,"channels":2,"frames_per_packet":240,"stream_id":7}"#)
        guard case .hello(let m) = hello else { return XCTFail("not a hello") }
        XCTAssertEqual(m.streamID, 7)
        XCTAssertEqual(m.framesPerPacket, 240)

        let ping = try ControlCodec.decode(line: #"{"type":"ping","t1":123}"#)
        guard case .ping(let p) = ping else { return XCTFail("not a ping") }
        XCTAssertEqual(p.t1, 123)
        XCTAssertNil(p.prevT4)

        XCTAssertEqual(try ControlCodec.decode(line: #"{"type":"bye"}"#), .bye)
    }

    func testRejectsUnknownAndMalformed() {
        XCTAssertThrowsError(try ControlCodec.decode(line: #"{"type":"nope"}"#)) {
            XCTAssertEqual($0 as? ControlCodecError, .unknownType("nope"))
        }
        XCTAssertThrowsError(try ControlCodec.decode(line: #"{"v":1}"#)) {
            XCTAssertEqual($0 as? ControlCodecError, .missingType)
        }
        XCTAssertThrowsError(try ControlCodec.decode(line: "not json")) {
            XCTAssertEqual($0 as? ControlCodecError, .notJSONObject)
        }
        XCTAssertThrowsError(try ControlCodec.decode(line: #"{"type":"latency"}"#))
    }
}

final class LineFramerTests: XCTestCase {

    func testSplitsAndBuffersPartialLines() throws {
        var framer = LineFramer()
        XCTAssertEqual(try framer.append(Data("{\"a\":1}\n{\"b\"".utf8)).map { String(decoding: $0, as: UTF8.self) },
                       ["{\"a\":1}"])
        XCTAssertEqual(try framer.append(Data(":2}\n".utf8)).map { String(decoding: $0, as: UTF8.self) },
                       ["{\"b\":2}"])
    }

    func testTolerantOfCRLFAndBlankLines() throws {
        var framer = LineFramer()
        let lines = try framer.append(Data("one\r\n\n\ntwo\n".utf8)).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(lines, ["one", "two"])
    }

    func testRefusesUnboundedLine() {
        var framer = LineFramer()
        let blob = Data(repeating: 0x41, count: LineFramer.maxLineBytes + 1)
        XCTAssertThrowsError(try framer.append(blob))
    }
}
