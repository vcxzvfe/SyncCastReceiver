import XCTest
@testable import ReceiverCore

/// The `--selftest` path is the daemon's own health check; a regression in
/// the scheduler shows up here first, so it runs in CI too.
final class SelfTestTests: XCTestCase {
    func testSelfTestPasses() {
        let report = SelfTest.run()
        for check in report.checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.detail)")
        }
        XCTAssertGreaterThan(report.checks.count, 8)
    }

    /// Packets that take 30 ms to arrive must move the ring LEVEL down by
    /// 30 ms and the playout TIME by nothing: the loop holds the level the
    /// schedule produced instead of walking it up to the nominal setpoint
    /// with the trim pinned at +200 ppm (which is what a two-machine run
    /// over Wi-Fi showed for a whole session).
    func testTransitDelayMovesTheLevelNotThePlayout() {
        let report = SelfTest.run(transitNanos: 30_000_000)
        for check in report.checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.detail)")
        }
        XCTAssertGreaterThan(report.checks.count, 8)
    }

    /// The scenario the field failure lives in: burst delivery with the
    /// occasional stall.
    func testBurstyArrivalSelfTestPasses() {
        let report = SelfTest.runBurstyArrival()
        for check in report.checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.detail)")
        }
        XCTAssertGreaterThan(report.checks.count, 6)
    }

    /// A sender that stops sending is silence, not starvation.
    func testIdleResumeSelfTestPasses() {
        let report = SelfTest.runIdleResume()
        for check in report.checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.detail)")
        }
        XCTAssertGreaterThan(report.checks.count, 8)
    }

    /// A sender stamping two timelines gets the second one refused.
    func testOverlappingTimelineSelfTestPasses() {
        let report = SelfTest.runOverlappingTimeline()
        for check in report.checks {
            XCTAssertTrue(check.passed, "\(check.name): \(check.detail)")
        }
        XCTAssertGreaterThan(report.checks.count, 6)
    }

    /// …and the same scenario has teeth: with the OLD rules — one empty
    /// render block is starvation, no matter what the smoothed level says or
    /// whether any audio arrived at all — it splices repeatedly. If this ever
    /// stops failing, the bursty scenario above has stopped testing anything.
    func testTheBurstyScenarioFailsUnderTheOldStarvationRule() {
        let old = ClockFollowLoop.Tuning(starvedBlockLimit: 1,
                                         starvationConfirmMs: -1_000_000,
                                         spliceWithoutNewAudio: true)
        let report = SelfTest.runBurstyArrival(tuning: old)
        let reanchors = report.checks.first { $0.name == "no hard re-anchors" }
        XCTAssertEqual(reanchors?.passed, false,
                       "the old rule did not splice: \(reanchors?.detail ?? "check missing")")
        print("[old starvation rule] \(reanchors?.detail ?? "-")")
    }
}
