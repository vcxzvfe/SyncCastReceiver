import XCTest
@testable import ReceiverCore

/// The plant the controller sees: the sender fills the ring at
/// `R·(1 + mismatch)` frames per second, we drain it at `R/ratio`.
private struct RingPlant {
    var rate: Double
    var mismatchPpm: Double
    var fill: Double

    mutating func advance(dt: Double, ratio: Double) {
        let produced = rate * (1 + mismatchPpm * 1e-6) * dt
        let consumed = rate / ratio * dt
        fill += produced - consumed
    }
}

final class ClockFollowLoopTests: XCTestCase {

    private let rate = WireFormat.sampleRate
    private var targetFrames: Double { 0.090 * rate }   // 90 ms

    /// Run the loop against the plant and report the ratio history.
    private func simulate(mismatchPpm: Double,
                          seconds: Double,
                          tick: Double = 0.01,
                          jitterFrames: Double = 0,
                          loop: inout ClockFollowLoop) -> (ratios: [Double], fills: [Double]) {
        var plant = RingPlant(rate: rate, mismatchPpm: mismatchPpm, fill: targetFrames)
        var ratios: [Double] = []
        var fills: [Double] = []
        var jitterPhase = 0.0
        let steps = Int(seconds / tick)
        for _ in 0..<steps {
            jitterPhase += 1
            // Delivery jitter is ONE-SIDED: a packet can only arrive late,
            // which makes the observed write head lag. Model it that way.
            let measured = plant.fill - jitterFrames * abs(sin(jitterPhase * 0.7))
            loop.update(fillFrames: measured, targetFrames: targetFrames, dt: tick)
            plant.advance(dt: tick, ratio: loop.ratio)
            ratios.append(loop.ratio)
            fills.append(plant.fill)
        }
        return (ratios, fills)
    }

    func testConvergesOnPositiveHundredPPMWithinTwentyFiveSeconds() {
        var loop = ClockFollowLoop()
        let result = simulate(mismatchPpm: 100, seconds: 25, loop: &loop)
        // Steady state is ratio = 1/(1 + m) ≈ 1 − 100 ppm.
        let expected = 1.0 / (1 + 100e-6)
        XCTAssertEqual(loop.ratio, expected, accuracy: 10e-6,
                       "ratio \(loop.ratio) did not converge to \(expected)")
        // ...and the level is back at the setpoint, not merely stable.
        XCTAssertEqual(result.fills.last!, targetFrames, accuracy: 0.002 * rate)
    }

    func testConvergesOnNegativeHundredPPMWithinTwentyFiveSeconds() {
        var loop = ClockFollowLoop()
        _ = simulate(mismatchPpm: -100, seconds: 25, loop: &loop)
        XCTAssertEqual(loop.ratio, 1.0 / (1 - 100e-6), accuracy: 10e-6)
    }

    func testNeverExceedsTwoHundredPPM() {
        for mismatch in [-100.0, -50, 0, 50, 100, 500] {
            var loop = ClockFollowLoop()
            let result = simulate(mismatchPpm: mismatch, seconds: 30, jitterFrames: 240, loop: &loop)
            let worst = result.ratios.map { abs($0 - 1) }.max() ?? 0
            XCTAssertLessThanOrEqual(worst, 200e-6 + 1e-12,
                                     "mismatch \(mismatch) ppm drove the trim to \(worst * 1e6) ppm")
        }
    }

    func testSlewRateStaysInaudible() {
        var loop = ClockFollowLoop()
        let result = simulate(mismatchPpm: 100, seconds: 25, loop: &loop)
        var worstStep = 0.0
        for i in 1..<result.ratios.count {
            worstStep = max(worstStep, abs(result.ratios[i] - result.ratios[i - 1]))
        }
        // 400 ppm/s over a 10 ms tick.
        XCTAssertLessThanOrEqual(worstStep, 400e-6 * 0.01 + 1e-12)
    }

    func testDeliveryJitterBiasesTheLevelNotThePitch() {
        // 5 ms of one-sided delivery jitter — a bad Wi-Fi link. Kp is finite,
        // so some of that noise does reach the trim; what must NOT happen is
        // a systematic pitch offset (the mean trim has to stay at zero when
        // the clocks agree) or an excursion past the ±200 ppm clamp. The
        // resulting level bias is the price and is harmless: it just parks
        // the buffer a few ms away from the nominal setpoint.
        var loop = ClockFollowLoop()
        let result = simulate(mismatchPpm: 0, seconds: 60, jitterFrames: 240, loop: &loop)
        let tail = Array(result.ratios.suffix(2_000))
        let meanPpm = tail.reduce(0) { $0 + ($1 - 1) * 1e6 } / Double(tail.count)
        XCTAssertLessThan(abs(meanPpm), 30, "jitter biased the pitch by \(meanPpm) ppm")
        XCTAssertLessThanOrEqual(tail.map { abs($0 - 1) }.max()!, 200e-6 + 1e-12)
    }

    func testAPersistentLevelErrorReanchorsAndATransientOneDoesNot() {
        // The level jumps 21 ms past the setpoint and stays there. The loop
        // must NOT splice on the first tick that sees it — a burst of late
        // packets looks exactly like this for a moment — but must give up
        // once the error has proved itself.
        var loop = ClockFollowLoop()
        let far = targetFrames + 0.030 * rate
        var outcome = loop.update(fillFrames: far, targetFrames: targetFrames, dt: 0.01)
        XCTAssertEqual(outcome, .tracking, "one tick past the threshold is not a fault")
        var elapsed = 0.01
        var fired = false
        for _ in 0..<200 {
            outcome = loop.update(fillFrames: far, targetFrames: targetFrames, dt: 0.01)
            elapsed += 0.01
            if outcome == .reanchorNeeded(.error) { fired = true; break }
        }
        XCTAssertTrue(fired, "a level error that never goes away must eventually re-anchor")
        XCTAssertGreaterThanOrEqual(elapsed, ClockFollowLoop.Tuning().reanchorHoldSeconds)

        // A single spike, then back: never a splice.
        var transient = ClockFollowLoop()
        for step in 0..<200 {
            let fill = step == 100 ? targetFrames + 0.100 * rate : targetFrames
            XCTAssertEqual(
                transient.update(fillFrames: fill, targetFrames: targetFrames, dt: 0.01),
                .tracking,
                "a one-tick spike must not re-anchor")
        }
    }

    func testASingleEmptyRenderIsNotAReanchor() {
        // The exact field symptom: one render block finds the ring empty
        // because a packet is a millisecond away. Zero-fill and count an
        // underrun — do not splice.
        var loop = ClockFollowLoop()
        for _ in 0..<400 {
            loop.update(fillFrames: targetFrames, targetFrames: targetFrames, dt: 0.01)
        }
        XCTAssertEqual(loop.update(fillFrames: 0, targetFrames: targetFrames, dt: 0.01), .tracking)
        XCTAssertEqual(loop.update(fillFrames: targetFrames, targetFrames: targetFrames, dt: 0.01),
                       .tracking)
        XCTAssertEqual(loop.consecutiveStarvedBlocks, 0)
    }

    func testSustainedStarvationDoesReanchor() {
        // The sender stopped: the ring stays empty and the smoothed level
        // walks down with it. That is a real fault and must be spliced.
        var loop = ClockFollowLoop()
        for _ in 0..<400 {
            loop.update(fillFrames: targetFrames, targetFrames: targetFrames, dt: 0.01)
        }
        var fired = false
        for _ in 0..<400 {
            if loop.update(fillFrames: -240, targetFrames: targetFrames, dt: 0.01)
                == .reanchorNeeded(.starved) {
                fired = true
                break
            }
        }
        XCTAssertTrue(fired, "a ring that stays empty must re-anchor")
    }

    func testAStarvedBlockWithAHealthySmoothedLevelIsNotAFault() {
        // Burst delivery: the ring empties at the end of every gap and is
        // full again a moment later. Two starved blocks in a row happen, but
        // the smoothed level says the buffer is fine, so nothing is spliced.
        var loop = ClockFollowLoop()
        for _ in 0..<400 {
            loop.update(fillFrames: targetFrames, targetFrames: targetFrames, dt: 0.01)
        }
        XCTAssertEqual(loop.update(fillFrames: 0, targetFrames: targetFrames, dt: 0.01), .tracking)
        XCTAssertEqual(loop.update(fillFrames: 0, targetFrames: targetFrames, dt: 0.01), .tracking)
        XCTAssertEqual(loop.consecutiveStarvedBlocks, 2)
    }

    func testResetClearsWindup() {
        var loop = ClockFollowLoop()
        _ = simulate(mismatchPpm: 100, seconds: 25, loop: &loop)
        XCTAssertNotEqual(loop.ratio, 1.0)
        loop.reset(fillFrames: targetFrames)
        XCTAssertEqual(loop.ratio, 1.0)
        XCTAssertEqual(loop.filteredFillFrames, targetFrames)
    }
}
