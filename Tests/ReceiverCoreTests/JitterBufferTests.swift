import XCTest
@testable import ReceiverCore

/// Helpers shared by the buffer and engine tests: a stream of 5 ms packets
/// stamped on a synthetic sender clock.
struct PacketSource {
    var streamID: UInt32 = 0xA1B2_C3D4
    var startNanos: UInt64 = 100_000_000_000
    var frames = WireFormat.framesPerPacket
    var sampleRate = WireFormat.sampleRate
    var amplitude: Double = 0.5
    var frequency: Double = 440

    func playAtNanos(index: Int) -> UInt64 {
        startNanos &+ UInt64((Double(index * frames) / sampleRate * 1_000_000_000).rounded())
    }

    func header(index: Int, seq: UInt32? = nil) -> AudioPacketHeader {
        AudioPacketHeader(streamID: streamID,
                          seq: seq ?? UInt32(truncatingIfNeeded: index),
                          playAtNanos: playAtNanos(index: index),
                          frames: UInt32(frames))
    }

    /// A continuous sine so a resampled stream can be checked for level.
    func samples(index: Int) -> [Int16] {
        var out = [Int16](repeating: 0, count: frames * WireFormat.channelCount)
        for f in 0..<frames {
            let t = Double(index * frames + f) / sampleRate
            let v = amplitude * sin(2 * .pi * frequency * t)
            let s = Int16(max(-32_767, min(32_767, (v * 32_767).rounded())))
            out[f * 2] = s
            out[f * 2 + 1] = s
        }
        return out
    }
}

final class JitterBufferTests: XCTestCase {

    private let source = PacketSource()

    private func ingest(_ buffer: JitterBuffer, index: Int, seq: UInt32? = nil) -> JitterBuffer.IngestOutcome {
        var samples = source.samples(index: index)
        return samples.withUnsafeMutableBufferPointer {
            buffer.ingest(header: source.header(index: index, seq: seq), samples: $0.baseAddress!)
        }
    }

    private func makeBuffer() -> JitterBuffer {
        let b = JitterBuffer()
        _ = ingest(b, index: 0)
        b.anchorReadCursor(toSenderNanos: source.playAtNanos(index: 0))
        return b
    }

    func testInOrderStreamHasNoLossAndFillsUp() {
        let buffer = makeBuffer()
        for i in 1..<20 { XCTAssertEqual(ingest(buffer, index: i), .accepted(index: Int64(i * 240))) }
        let c = buffer.counterSnapshot
        XCTAssertEqual(c.accepted, 20)
        XCTAssertEqual(c.lost, 0)
        XCTAssertEqual(c.late, 0)
        XCTAssertEqual(c.duplicate, 0)
        XCTAssertEqual(buffer.fillFrames, 20 * 240)
        XCTAssertEqual(buffer.fillMilliseconds, 100, accuracy: 0.001)
    }

    func testTimestampDecidesTheSlotNotArrivalOrder() {
        let buffer = makeBuffer()
        _ = ingest(buffer, index: 5)
        XCTAssertEqual(buffer.writeEndFrame, 6 * 240)
        // The out-of-order packet still lands where its timestamp says.
        XCTAssertEqual(ingest(buffer, index: 3), .reordered(index: 3 * 240))
    }

    func testGapIsCountedLostAndZeroFilled() {
        let buffer = makeBuffer()
        _ = ingest(buffer, index: 1)
        _ = ingest(buffer, index: 4)          // 2 and 3 missing
        XCTAssertEqual(buffer.counterSnapshot.lost, 2)

        var out = [[Float]](repeating: [Float](repeating: 9, count: 240 * 5), count: 2)
        readPlanar(buffer, frames: 240 * 5, into: &out)
        // Frames of packets 2 and 3 must be silence, not stale ring content.
        for f in (2 * 240)..<(4 * 240) {
            XCTAssertEqual(out[0][f], 0, "frame \(f) should be zero-filled")
        }
    }

    func testReorderedPacketTakesBackItsLossCount() {
        let buffer = makeBuffer()
        _ = ingest(buffer, index: 1)
        _ = ingest(buffer, index: 3)
        XCTAssertEqual(buffer.counterSnapshot.lost, 1)
        XCTAssertEqual(ingest(buffer, index: 2), .reordered(index: 2 * 240))
        let c = buffer.counterSnapshot
        XCTAssertEqual(c.lost, 0, "a packet that turned up late is not lost")
        XCTAssertEqual(c.reordered, 1)
    }

    func testDuplicateIsCountedAndDoesNotDisturbTheRing() {
        let buffer = makeBuffer()
        _ = ingest(buffer, index: 1)
        XCTAssertEqual(ingest(buffer, index: 1), .duplicate)
        XCTAssertEqual(ingest(buffer, index: 1), .duplicate)
        let c = buffer.counterSnapshot
        XCTAssertEqual(c.duplicate, 2)
        XCTAssertEqual(c.accepted, 2)
        XCTAssertEqual(buffer.writeEndFrame, 2 * 240)
    }

    func testPacketWhoseTimeHasPassedIsLate() {
        let buffer = makeBuffer()
        for i in 1..<6 { _ = ingest(buffer, index: i) }
        var out = [[Float]](repeating: [Float](repeating: 0, count: 240 * 4), count: 2)
        readPlanar(buffer, frames: 240 * 4, into: &out)    // cursor now at frame 960
        // A packet stamped for frames 240..480 is unplayable now.
        XCTAssertEqual(ingest(buffer, index: 1, seq: 900), .late)
        XCTAssertEqual(buffer.counterSnapshot.late, 1)
    }

    func testUnderrunCountedWhenReadingPastTheWriteHead() {
        let buffer = makeBuffer()
        var out = [[Float]](repeating: [Float](repeating: 1, count: 480), count: 2)
        readPlanar(buffer, frames: 480, into: &out)        // only 240 frames exist
        XCTAssertEqual(buffer.counterSnapshot.underrun, 1)
        for f in 240..<480 { XCTAssertEqual(out[0][f], 0) }
    }

    func testStreamIDChangeRestartsTheTimeline() {
        let buffer = makeBuffer()
        for i in 1..<5 { _ = ingest(buffer, index: i) }
        var other = source
        other.streamID = 0x1111_2222
        other.startNanos = 900_000_000_000
        var samples = other.samples(index: 0)
        let outcome = samples.withUnsafeMutableBufferPointer {
            buffer.ingest(header: other.header(index: 0), samples: $0.baseAddress!)
        }
        XCTAssertEqual(outcome, .restarted(index: 0))
        XCTAssertEqual(buffer.writeEndFrame, 240)
        XCTAssertEqual(buffer.anchorPlayAtNanos, other.playAtNanos(index: 0))
    }

    func testWildTimestampIsRefusedRatherThanCorruptingTheRing() {
        let buffer = makeBuffer()
        let endBefore = buffer.writeEndFrame
        let anchorBefore = buffer.anchorPlayAtNanos
        var wild = source
        wild.startNanos = source.startNanos &+ 60_000_000_000    // a minute into the future
        var samples = wild.samples(index: 0)
        let outcome = samples.withUnsafeMutableBufferPointer {
            buffer.ingest(header: wild.header(index: 0, seq: 5000), samples: $0.baseAddress!)
        }
        // A minute ahead is not a discontinuity to recover from; re-anchoring
        // onto it would park the whole stream in the future. It is refused,
        // counted, and the running stream is left exactly as it was.
        XCTAssertEqual(outcome, .farFuture)
        XCTAssertEqual(buffer.counterSnapshot.farFuture, 1)
        XCTAssertEqual(buffer.writeEndFrame, endBefore)
        XCTAssertEqual(buffer.anchorPlayAtNanos, anchorBefore)
    }

    func testAPacketOverlappingBufferedAudioIsRefused() {
        let buffer = makeBuffer()
        // The fixture has put packet 0 in the ring. Re-stamping a
        // DIFFERENT payload for frames the ring already holds is the shape of
        // the sender-side fault this guard exists for: a second timeline
        // claiming slots the first one filled.
        var samples = source.samples(index: 99)  // different audio…
        let outcome = samples.withUnsafeMutableBufferPointer {
            // …stamped for the frames packet 0 already occupies, with a
            // sequence number the duplicate filter has not seen.
            buffer.ingest(header: source.header(index: 0, seq: 9_000), samples: $0.baseAddress!)
        }
        XCTAssertEqual(outcome, .overlap)
        XCTAssertEqual(buffer.counterSnapshot.overlap, 1)
    }

    func testAReorderedPacketStillFillsTheHoleLeftForIt() {
        // The overlap guard must not break reordering: a hole is zero-filled,
        // not audio, so the packet that turns up late still belongs in it.
        let buffer = JitterBuffer(capacityFrames: 1 << 14)
        var one = source
        one.startNanos = 700_000_000_000
        func put(_ index: Int, seq: UInt32) -> JitterBuffer.IngestOutcome {
            var samples = one.samples(index: index)
            return samples.withUnsafeMutableBufferPointer {
                buffer.ingest(header: one.header(index: index, seq: seq), samples: $0.baseAddress!)
            }
        }
        XCTAssertEqual(put(0, seq: 0), .restarted(index: 0))
        XCTAssertEqual(put(3, seq: 3), .accepted(index: 3 * 240))
        XCTAssertEqual(put(1, seq: 1), .reordered(index: 240))
        XCTAssertEqual(put(2, seq: 2), .reordered(index: 2 * 240))
        XCTAssertEqual(buffer.counterSnapshot.overlap, 0)
    }

    func testDecodedAudioMatchesTheSourceSamples() {
        let buffer = makeBuffer()
        var out = [[Float]](repeating: [Float](repeating: 0, count: 240), count: 2)
        readPlanar(buffer, frames: 240, into: &out)
        let expected = source.samples(index: 0)
        for f in 0..<240 {
            XCTAssertEqual(out[0][f], Float(expected[f * 2]) / 32_768, accuracy: 1e-6)
            XCTAssertEqual(out[1][f], Float(expected[f * 2 + 1]) / 32_768, accuracy: 1e-6)
        }
    }

    func testAnchoringFromTheClockPicksTheRightFrame() {
        let buffer = JitterBuffer()
        _ = ingest(buffer, index: 0)
        for i in 1..<10 { _ = ingest(buffer, index: i) }
        // Ask to start playing 20 ms into the stream: frame 960.
        buffer.anchorReadCursor(toSenderNanos: source.playAtNanos(index: 0) + 20_000_000)
        XCTAssertEqual(buffer.readCursorFrame, 960)
        XCTAssertEqual(buffer.fillFrames, 10 * 240 - 960)
    }

    func testHardReanchorPutsTheCursorAtTheTargetLevel() {
        let buffer = makeBuffer()
        for i in 1..<40 { _ = ingest(buffer, index: i) }
        buffer.reanchorReadCursor(toLevelFrames: 4_320)
        XCTAssertEqual(buffer.fillFrames, 4_320)
    }

    // MARK: - helper

    private func readPlanar(_ buffer: JitterBuffer, frames: Int, into out: inout [[Float]]) {
        var heads = [UnsafeMutablePointer<Float>]()
        for ch in 0..<out.count {
            heads.append(UnsafeMutablePointer<Float>.allocate(capacity: frames))
        }
        heads.withUnsafeBufferPointer { buffer.read(frames: frames, into: $0.baseAddress!) }
        for ch in 0..<out.count {
            for f in 0..<frames { out[ch][f] = heads[ch][f] }
            heads[ch].deallocate()
        }
    }
}
