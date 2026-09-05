import XCTest
@testable import ReceiverCore

/// The decision that keeps the sender's level on the device without the
/// daemon fighting its own writes.
final class VolumeReassertionPolicyTests: XCTestCase {

    private let now: UInt64 = 1_000_000_000_000
    private var openWindow: UInt64 { now + 100_000_000 }   // 100 ms left to run
    private var closedWindow: UInt64 { now - 100_000_000 } // expired 100 ms ago

    // MARK: - volume

    func testAMatchingLevelIsLeftAlone() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.5, desired: 0.5, nowNanos: now, suppressedUntilNanos: nil),
            .matches)
    }

    /// Drivers round what they store; a written 0.5 reading back as 0.4999 is
    /// not somebody moving the slider.
    func testDriverRoundingIsNotTreatedAsAnExternalChange() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.4990, desired: 0.5, nowNanos: now, suppressedUntilNanos: nil),
            .matches)
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.5009, desired: 0.5, nowNanos: now, suppressedUntilNanos: nil),
            .matches)
    }

    func testSomethingElseMovingTheLevelIsReasserted() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.0, desired: 0.5, nowNanos: now, suppressedUntilNanos: nil),
            .reassert)
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.9, desired: 0.5, nowNanos: now, suppressedUntilNanos: closedWindow),
            .reassert)
    }

    /// The loop guard: our own write comes back through the same property
    /// listener, and re-applying on that notification would never stop.
    func testOurOwnWriteEchoingBackIsSuppressed() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.2, desired: 0.5, nowNanos: now, suppressedUntilNanos: openWindow),
            .suppressed)
    }

    /// A value that already matches is reported as matching even inside the
    /// window — "suppressed" would suggest a change worth logging.
    func testAMatchInsideTheWindowIsAMatchNotASuppression() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.5, desired: 0.5, nowNanos: now, suppressedUntilNanos: openWindow),
            .matches)
    }

    func testAnUnreadableDeviceValueIsRewrittenRatherThanTrusted() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: .nan, desired: 0.5, nowNanos: now, suppressedUntilNanos: nil),
            .reassert)
        // …but still not inside our own window.
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: .nan, desired: 0.5, nowNanos: now, suppressedUntilNanos: openWindow),
            .suppressed)
    }

    /// No hardware level to assert (software gain path, or no sender).
    func testNoDesiredLevelMeansNothingToAssert() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideScalar(
                observed: 0.1, desired: .nan, nowNanos: now, suppressedUntilNanos: nil),
            .matches)
    }

    // MARK: - mute

    /// The case that motivated this: a remote-desktop session mutes the Mac
    /// on connect, and the listener hears nothing while the sender's UI still
    /// shows the level it set.
    func testAnExternalMuteIsUndone() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideMute(
                observed: true, desired: false, nowNanos: now, suppressedUntilNanos: nil),
            .reassert)
    }

    func testOurOwnMuteWriteIsSuppressed() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideMute(
                observed: true, desired: false, nowNanos: now, suppressedUntilNanos: openWindow),
            .suppressed)
    }

    func testAMuteWeAskedForIsLeftEngaged() {
        XCTAssertEqual(
            VolumeReassertionPolicy.decideMute(
                observed: true, desired: true, nowNanos: now, suppressedUntilNanos: nil),
            .matches)
    }

    // MARK: - the window itself

    func testTheSuppressionWindowOpensAheadOfNowAndExpires() {
        let deadline = VolumeReassertionPolicy.suppressionDeadline(nowNanos: now)
        XCTAssertGreaterThan(deadline, now)
        XCTAssertTrue(VolumeReassertionPolicy.isSuppressed(nowNanos: now, until: deadline))
        XCTAssertFalse(
            VolumeReassertionPolicy.isSuppressed(
                nowNanos: deadline + 1, until: deadline))
        XCTAssertFalse(VolumeReassertionPolicy.isSuppressed(nowNanos: now, until: nil))
    }

    /// The post-write sweep must land AFTER the window closes, or it would
    /// suppress itself and an external change that arrived during the window
    /// would stick forever.
    func testTheVerificationSweepRunsAfterTheWindowCloses() {
        XCTAssertGreaterThan(VolumeReassertionPolicy.verifyDelayNanos,
                             VolumeReassertionPolicy.defaultSuppressionNanos)
        // And the whole react-and-restore path stays inside ~200 ms of an
        // external change, which is the responsiveness this is specified at.
        XCTAssertLessThanOrEqual(VolumeReassertionPolicy.coalesceDelayNanos, 200_000_000)
    }
}
