import XCTest
@testable import ReceiverCore

final class PacketArrivalTrackerTests: XCTestCase {

    func testAnEmptyWindowHasNoOpinion() {
        let tracker = PacketArrivalTracker()
        XCTAssertNil(tracker.p95SpreadMilliseconds)
        tracker.record(playAtNanos: 1_000, arrivalNanos: 2_000)
        XCTAssertNil(tracker.p95SpreadMilliseconds, "one packet is not a measurement")
    }

    func testAPerfectlyPacedStreamHasNoSpread() {
        let tracker = PacketArrivalTracker()
        // Every packet arrives exactly 90 ms before its play time, on a clock
        // one and a half seconds away from the sender's.
        for index in 0..<200 {
            let playAt = UInt64(500_000_000_000 + index * 5_000_000)
            tracker.record(playAtNanos: playAt,
                           arrivalNanos: playAt &+ 1_500_000_000 &- 90_000_000)
        }
        XCTAssertEqual(try XCTUnwrap(tracker.p95SpreadMilliseconds), 0, accuracy: 1e-9)
    }

    func testTheOffsetBetweenTheTwoClocksCancels() {
        // The same jitter measured against a clock a whole second further
        // away must give the same answer: only the spread is used.
        func spread(offset: UInt64) throws -> Double {
            let tracker = PacketArrivalTracker()
            for index in 0..<200 {
                let playAt = UInt64(500_000_000_000 + index * 5_000_000)
                let extra = UInt64(index % 4) * 4_000_000        // 0…12 ms of jitter
                tracker.record(playAtNanos: playAt, arrivalNanos: playAt &+ offset &+ extra)
            }
            return try XCTUnwrap(tracker.p95SpreadMilliseconds)
        }
        XCTAssertEqual(try spread(offset: 1_000_000_000),
                       try spread(offset: 60_000_000_000), accuracy: 1e-9)
    }

    func testTheSpreadIsThePercentileAboveTheBestPacket() {
        let tracker = PacketArrivalTracker()
        // 180 packets on time, 20 of them 40 ms late. p95 of 200 lands inside
        // the late group, so the spread is the 40 ms.
        for index in 0..<200 {
            let playAt = UInt64(500_000_000_000 + index * 5_000_000)
            let late: UInt64 = index >= 180 ? 40_000_000 : 0
            tracker.record(playAtNanos: playAt, arrivalNanos: playAt &+ 1_000_000_000 &+ late)
        }
        XCTAssertEqual(try XCTUnwrap(tracker.p95SpreadMilliseconds), 40, accuracy: 0.001)
    }

    func testTheWindowSlidesSoAnImprovedLinkIsReported() {
        let tracker = PacketArrivalTracker(windowSize: 64)
        for index in 0..<64 {
            let playAt = UInt64(index * 5_000_000)
            tracker.record(playAtNanos: playAt, arrivalNanos: playAt &+ 1_000_000_000
                           &+ UInt64(index % 2) * 50_000_000)
        }
        XCTAssertGreaterThan(try XCTUnwrap(tracker.p95SpreadMilliseconds), 40)
        for index in 64..<128 {
            let playAt = UInt64(index * 5_000_000)
            tracker.record(playAtNanos: playAt, arrivalNanos: playAt &+ 1_000_000_000)
        }
        XCTAssertEqual(try XCTUnwrap(tracker.p95SpreadMilliseconds), 0, accuracy: 1e-9)
    }

    func testResetForgetsThePreviousLink() {
        let tracker = PacketArrivalTracker()
        for index in 0..<200 {
            tracker.record(playAtNanos: UInt64(index * 5_000_000), arrivalNanos: 0)
        }
        XCTAssertNotNil(tracker.p95SpreadMilliseconds)
        tracker.reset()
        XCTAssertNil(tracker.p95SpreadMilliseconds)
    }
}
