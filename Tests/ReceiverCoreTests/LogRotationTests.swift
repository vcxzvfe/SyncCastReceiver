import XCTest
@testable import ReceiverCore

/// Rotation has to keep the inode (launchd holds its own descriptor on the
/// same file) and must never throw the log away when the copy aside failed.
final class LogRotationTests: XCTestCase {

    private var home: URL!
    private var paths: ReceiverPaths!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccast-log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = ReceiverPaths(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?
            .intValue ?? -1
    }

    func testTheLogIsCappedAndThePreviousContentsAreKeptAside() throws {
        let log = Log(paths: paths, mirrorToStderr: false, rotationThresholdBytes: 400)
        let inodeBefore = try inode(of: paths.logURL, creatingIfNeeded: true, log: log)

        for index in 0..<60 { log.info("line \(index) with enough text to move the needle") }
        log.flush()

        XCTAssertLessThan(size(paths.logURL), 400 * 3,
                          "the live log grew past the cap without rotating")
        XCTAssertGreaterThan(size(paths.rotatedLogURL), 0,
                             "the previous contents were discarded rather than kept")
        // Same file, not a rename: launchd's descriptor points at this inode
        // and would otherwise write into a file nobody reads.
        XCTAssertEqual(try inode(of: paths.logURL, creatingIfNeeded: false, log: log), inodeBefore)
    }

    func testTheMostRecentLinesAreStillInTheLiveFileAfterRotation() throws {
        let log = Log(paths: paths, mirrorToStderr: false, rotationThresholdBytes: 300)
        for index in 0..<50 { log.info("line \(index)") }
        log.info("THE LAST LINE")
        log.flush()
        let live = try String(contentsOf: paths.logURL, encoding: .utf8)
        XCTAssertTrue(live.contains("THE LAST LINE"), live)
    }

    /// A rotation that cannot write the copy must leave the log alone and say
    /// so, rather than truncating and losing everything.
    func testAFailedCopyAsideDoesNotTruncateTheLog() throws {
        let log = Log(paths: paths, mirrorToStderr: false, rotationThresholdBytes: 300)
        // Make the rotated path un-writable by putting a directory there.
        try FileManager.default.createDirectory(at: paths.rotatedLogURL,
                                                withIntermediateDirectories: true)
        for index in 0..<60 { log.info("line \(index) with enough text to move the needle") }
        log.flush()

        let live = try String(contentsOf: paths.logURL, encoding: .utf8)
        XCTAssertTrue(live.contains("line 0"), "the log was truncated despite a failed copy")
        XCTAssertTrue(live.contains("log rotation failed"),
                      "a failed rotation must be reported, not swallowed")
    }

    func testTheDefaultThresholdIsTheDocumentedFiveMegabytes() {
        XCTAssertEqual(Log.rotationThresholdBytes, 5 * 1024 * 1024)
    }

    func testTheLogReportsItsOwnPath() {
        let log = Log(paths: paths, mirrorToStderr: false)
        XCTAssertEqual(log.path, paths.logURL.path)
    }

    private func inode(of url: URL, creatingIfNeeded: Bool, log: Log) throws -> UInt64 {
        if creatingIfNeeded, !FileManager.default.fileExists(atPath: url.path) {
            log.info("priming")
            log.flush()
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
