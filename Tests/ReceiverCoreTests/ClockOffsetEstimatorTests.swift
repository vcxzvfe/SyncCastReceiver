import XCTest
@testable import ReceiverCore

final class ClockOffsetEstimatorTests: XCTestCase {

    /// Build one NTP exchange for a receiver whose clock reads
    /// `sender + trueOffset`, with an arbitrary forward/return split.
    private func exchange(senderSend t1: UInt64,
                          trueOffset: Int64,
                          forwardDelay: UInt64,
                          processing: UInt64,
                          returnDelay: UInt64) -> (UInt64, UInt64, UInt64, UInt64) {
        let t2 = UInt64(bitPattern: Int64(bitPattern: t1 &+ forwardDelay) &+ trueOffset)
        let t3 = t2 &+ processing
        let t4 = UInt64(bitPattern: Int64(bitPattern: t3 &+ returnDelay) &- trueOffset)
        return (t1, t2, t3, t4)
    }

    func testSymmetricDelayRecoversOffsetExactly() {
        var est = ClockOffsetEstimator()
        // Deliberately large, far-apart uptimes: the estimator must do all
        // its arithmetic on differences, never on absolute values.
        let trueOffset: Int64 = -5_000_000_000
        let e = exchange(senderSend: 900_000_000_000, trueOffset: trueOffset,
                         forwardDelay: 400_000, processing: 50_000, returnDelay: 400_000)
        est.addRoundTrip(t1: e.0, t2: e.1, t3: e.2, t4: e.3)
        XCTAssertEqual(est.offsetNanos, trueOffset)
        XCTAssertEqual(est.roundTripNanos, 800_000)
        XCTAssertEqual(est.mode, .roundTrip)
    }

    func testAsymmetricDelayErrorIsHalfTheAsymmetry() {
        var est = ClockOffsetEstimator(smoothing: 1.0)
        let trueOffset: Int64 = 3_000_000
        let e = exchange(senderSend: 10_000_000_000, trueOffset: trueOffset,
                         forwardDelay: 1_000_000, processing: 0, returnDelay: 3_000_000)
        est.addRoundTrip(t1: e.0, t2: e.1, t3: e.2, t4: e.3)
        // θ̂ = θ + (df − dr)/2 = θ − 1 ms
        XCTAssertEqual(est.offsetNanos!, trueOffset - 1_000_000)
    }

    func testMinimumRTTSampleWinsOverQueuedOnes() {
        var est = ClockOffsetEstimator(smoothing: 1.0)
        let trueOffset: Int64 = 250_000_000
        var t1: UInt64 = 50_000_000_000
        // Fifteen badly queued (asymmetric) exchanges...
        for _ in 0..<15 {
            let e = exchange(senderSend: t1, trueOffset: trueOffset,
                             forwardDelay: 12_000_000, processing: 100_000, returnDelay: 1_000_000)
            est.addRoundTrip(t1: e.0, t2: e.1, t3: e.2, t4: e.3)
            t1 &+= 1_000_000_000
        }
        XCTAssertGreaterThan(abs(est.offsetNanos! - trueOffset), 4_000_000)
        // ...then one clean one. The minimum-RTT rule must adopt it.
        let clean = exchange(senderSend: t1, trueOffset: trueOffset,
                             forwardDelay: 300_000, processing: 20_000, returnDelay: 300_000)
        est.addRoundTrip(t1: clean.0, t2: clean.1, t3: clean.2, t4: clean.3)
        XCTAssertEqual(est.offsetNanos!, trueOffset)
    }

    func testWindowIsBounded() {
        var est = ClockOffsetEstimator(windowSize: 16)
        for i in 0..<100 {
            let e = exchange(senderSend: UInt64(i) * 1_000_000_000 + 1_000_000_000,
                             trueOffset: 0, forwardDelay: 500_000, processing: 0, returnDelay: 500_000)
            est.addRoundTrip(t1: e.0, t2: e.1, t3: e.2, t4: e.3)
        }
        XCTAssertEqual(est.sampleCount, 16)
    }

    func testEMASmoothsAStepInsteadOfJumping() {
        var est = ClockOffsetEstimator(smoothing: 0.25)
        let first = exchange(senderSend: 1_000_000_000, trueOffset: 0,
                             forwardDelay: 200_000, processing: 0, returnDelay: 200_000)
        est.addRoundTrip(t1: first.0, t2: first.1, t3: first.2, t4: first.3)
        XCTAssertEqual(est.offsetNanos, 0)
        // A sample claiming +1 s of offset with an even better RTT.
        let step = exchange(senderSend: 2_000_000_000, trueOffset: 1_000_000_000,
                            forwardDelay: 100_000, processing: 0, returnDelay: 100_000)
        est.addRoundTrip(t1: step.0, t2: step.1, t3: step.2, t4: step.3)
        XCTAssertEqual(est.offsetNanos!, 250_000_000)   // one EMA step of 0.25
    }

    func testOneWayFallbackIsBiasedByMinimumForwardDelay() {
        var est = ClockOffsetEstimator(smoothing: 1.0)
        let trueOffset: Int64 = -700_000_000
        for delay in [3_000_000, 1_400_000, 250_000, 900_000] as [UInt64] {
            let t1: UInt64 = 20_000_000_000 &+ delay
            let t2 = UInt64(bitPattern: Int64(bitPattern: t1 &+ delay) &+ trueOffset)
            est.addOneWay(t1: t1, t2: t2)
        }
        XCTAssertEqual(est.mode, .oneWay)
        // Minimum observed forward delay was 250 µs, so that is the bias.
        XCTAssertEqual(est.offsetNanos!, trueOffset + 250_000)
    }

    func testRoundTripWindowIsNeverDowngradedToOneWay() {
        var est = ClockOffsetEstimator(smoothing: 1.0)
        let e = exchange(senderSend: 1_000_000_000, trueOffset: 42,
                         forwardDelay: 100_000, processing: 0, returnDelay: 100_000)
        est.addRoundTrip(t1: e.0, t2: e.1, t3: e.2, t4: e.3)
        est.addOneWay(t1: 0, t2: 999_999_999)
        XCTAssertEqual(est.mode, .roundTrip)
        XCTAssertEqual(est.offsetNanos, 42)
    }

    func testNegativeRoundTripIsIgnored() {
        var est = ClockOffsetEstimator()
        est.addRoundTrip(t1: 1_000_000, t2: 0, t3: 0, t4: 0)   // t4 < t1: nonsense
        XCTAssertNil(est.offsetNanos)
    }
}
