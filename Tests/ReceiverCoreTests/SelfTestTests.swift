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
}
