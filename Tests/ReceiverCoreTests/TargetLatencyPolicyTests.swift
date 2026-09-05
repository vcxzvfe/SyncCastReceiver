import XCTest
@testable import ReceiverCore

final class TargetLatencyPolicyTests: XCTestCase {

    private let rate = WireFormat.sampleRate

    func testAnUnmeasuredLinkGetsWhatItAskedFor() {
        XCTAssertEqual(
            TargetLatencyPolicy.effectiveMilliseconds(
                requestedMs: 90, p95JitterMs: nil, blockFrames: 512, sampleRate: rate),
            90)
    }

    func testAQuietLinkGetsWhatItAskedFor() {
        // 5 ms of jitter plus two 10.7 ms blocks is 26 ms: well under the
        // request, so the request stands.
        XCTAssertEqual(
            TargetLatencyPolicy.effectiveMilliseconds(
                requestedMs: 90, p95JitterMs: 5, blockFrames: 512, sampleRate: rate),
            90)
    }

    func testAJitteryLinkRaisesTheTarget() {
        // 60 ms of measured spread cannot be played out of a 30 ms buffer.
        let effective = TargetLatencyPolicy.effectiveMilliseconds(
            requestedMs: 30, p95JitterMs: 60, blockFrames: 512, sampleRate: rate)
        XCTAssertEqual(effective, 60 + 2 * 512 / rate * 1000, accuracy: 1e-9)
        XCTAssertGreaterThan(effective, 30)
    }

    func testTheTargetIsNeverLoweredBelowTheRequest() {
        for jitter in [0.0, 1, 5, 20] {
            XCTAssertGreaterThanOrEqual(
                TargetLatencyPolicy.effectiveMilliseconds(
                    requestedMs: 120, p95JitterMs: jitter, blockFrames: 512, sampleRate: rate),
                120)
        }
    }

    func testABrokenLinkIsCappedRatherThanBuffered() {
        XCTAssertEqual(
            TargetLatencyPolicy.effectiveMilliseconds(
                requestedMs: 90, p95JitterMs: 5_000, blockFrames: 512, sampleRate: rate),
            TargetLatencyPolicy.maximumMilliseconds)
    }

    func testABiggerRenderBlockNeedsMoreHeadroom() {
        let small = TargetLatencyPolicy.effectiveMilliseconds(
            requestedMs: 30, p95JitterMs: 40, blockFrames: 256, sampleRate: rate)
        let large = TargetLatencyPolicy.effectiveMilliseconds(
            requestedMs: 30, p95JitterMs: 40, blockFrames: 2_048, sampleRate: rate)
        XCTAssertGreaterThan(large, small)
    }
}
