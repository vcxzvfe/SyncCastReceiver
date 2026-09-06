import XCTest
@testable import ReceiverCore

/// The buffer re-numbers its frames when the stream restarts or the sender's
/// timestamps jump. The engine's read cursor was placed under the OLD
/// numbering; if it is not placed again, the render thread reads from the
/// buffer's "unanchored" sentinel and reports a fill of 2⁶¹ frames — a
/// two-machine run played nine seconds of silence exactly that way.
final class PlayoutEngineRestartTests: XCTestCase {

    private let blockFrames = 512
    private let packetNanos = Double(WireFormat.framesPerPacket) / WireFormat.sampleRate * 1_000_000_000

    private func makeEngine() -> PlayoutEngine {
        let engine = PlayoutEngine()
        engine.setTargetLatency(milliseconds: 90)
        engine.setRequestedTargetLatency(milliseconds: 90)
        engine.setDeviceLatency(frames: 960)
        engine.setClockOffset(nanos: 1_000_000_000)
        engine.startStream()
        return engine
    }

    private func ingest(_ engine: PlayoutEngine, index: Int, senderStart: UInt64,
                        streamID: UInt32, arrival: UInt64, scratch: inout [Int16]) {
        var samples = [Int16](repeating: 0, count: WireFormat.framesPerPacket * WireFormat.channelCount)
        for f in 0..<WireFormat.framesPerPacket {
            let s = Int16((sin(Double(index * WireFormat.framesPerPacket + f) * 0.05) * 20_000).rounded())
            samples[f * 2] = s
            samples[f * 2 + 1] = s
        }
        let header = AudioPacketHeader(streamID: streamID,
                                       seq: UInt32(truncatingIfNeeded: index),
                                       playAtNanos: senderStart &+ UInt64((Double(index) * packetNanos).rounded()),
                                       frames: UInt32(WireFormat.framesPerPacket))
        samples.withUnsafeBufferPointer {
            _ = engine.ingest(header: header, samples: $0.baseAddress!, arrivalNanos: arrival)
        }
    }

    private func render(_ engine: PlayoutEngine, deadline: UInt64) -> Float {
        let a = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        let b = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames)
        defer { a.deallocate(); b.deallocate() }
        var heads = [a, b]
        heads.withUnsafeMutableBufferPointer { p in
            engine.render(frames: blockFrames, dacDeadlineNanos: deadline, outputs: UnsafePointer(p.baseAddress!))
        }
        var peak: Float = 0
        for f in 0..<blockFrames { peak = max(peak, abs(a[f])) }
        return peak
    }

    func testAStreamRestartPlacesTheCursorAgain() {
        let engine = makeEngine()
        var scratch = [Int16](repeating: 0, count: WireFormat.framesPerPacket * 2)
        let offset: UInt64 = 1_000_000_000
        let blockNanos = UInt64(Double(blockFrames) / WireFormat.sampleRate * 1_000_000_000)

        // Stream A: 40 packets stamped 90 ms ahead, rendered until anchored.
        let startA: UInt64 = 500_000_000_000
        var local = startA &- 90_000_000 &+ offset
        for i in 0..<40 {
            ingest(engine, index: i, senderStart: startA, streamID: 1, arrival: local, scratch: &scratch)
            local &+= UInt64(packetNanos)
        }
        var deadline = startA &+ offset &+ 20_000_000
        var peakA: Float = 0
        for _ in 0..<4 { peakA = max(peakA, render(engine, deadline: deadline)); deadline &+= blockNanos }
        XCTAssertGreaterThan(peakA, 0.1, "stream A did not play")
        XCTAssertLessThan(abs(engine.snapshot.fillMilliseconds), 1_000)

        // Stream B: a new stream ID with timestamps three hours away. The
        // buffer re-anchors on it; the engine must follow.
        let startB: UInt64 = startA &+ 12_000_000_000_000
        local = startB &- 90_000_000 &+ offset
        for i in 0..<40 {
            ingest(engine, index: i, senderStart: startB, streamID: 2, arrival: local, scratch: &scratch)
            local &+= UInt64(packetNanos)
        }
        deadline = startB &+ offset &+ 20_000_000
        var peakB: Float = 0
        for _ in 0..<4 {
            peakB = max(peakB, render(engine, deadline: deadline))
            deadline &+= blockNanos
            XCTAssertLessThan(abs(engine.snapshot.fillMilliseconds), 1_000,
                              "fill \(engine.snapshot.fillMilliseconds) ms is not a level")
            XCTAssertLessThan(abs(engine.snapshot.levelMilliseconds), 1_000)
        }
        XCTAssertGreaterThan(peakB, 0.1, "stream B never played after the restart")
        XCTAssertEqual(engine.snapshot.counters.underrun, 0)
    }
}
