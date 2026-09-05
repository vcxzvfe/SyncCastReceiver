import XCTest
@testable import ReceiverCore

/// The `--status` report: what it says, and what it must not claim.
final class ReceiverStatusTests: XCTestCase {

    private var home: URL!
    private var paths: ReceiverPaths!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccast-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        paths = ReceiverPaths(home: home)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func sample(streaming: Bool = true,
                        updatedAtEpoch: Double = 2_000,
                        peer: String? = "192.0.2.7") -> ReceiverStatus {
        ReceiverStatus(pid: 4321,
                       name: "Receiver",
                       startedAtEpoch: 1_000,
                       updatedAtEpoch: updatedAtEpoch,
                       controlPort: 51_234,
                       udpPort: 51_235,
                       deviceName: "Built-in Output",
                       deviceUID: "BuiltInSpeakerDevice",
                       hardwareVolume: true,
                       streaming: streaming,
                       peer: peer,
                       lastStats: "late=0 lost=0 underrun=0 buffer=89.4ms",
                       logPath: "/path/to/receiver.log")
    }

    // MARK: - round trip

    func testAStatusSurvivesAWriteAndRead() throws {
        let file = StatusFile(paths: paths)
        XCTAssertNil(file.write(sample()))
        XCTAssertEqual(try file.read(), sample())
    }

    func testReadingWithNoDaemonSaysSoRatherThanThrowingSomethingOpaque() {
        let file = StatusFile(paths: paths)
        XCTAssertThrowsError(try file.read()) { error in
            XCTAssertTrue("\(error)".contains("not running"), "\(error)")
        }
    }

    func testShutdownRemovesTheFileSoAStaleOneCannotBeMisread() throws {
        let file = StatusFile(paths: paths)
        XCTAssertNil(file.write(sample()))
        file.remove()
        XCTAssertThrowsError(try file.read())
    }

    func testAFileFromAnotherSchemaVersionIsRejected() throws {
        var status = sample()
        status.version = ReceiverStatus.currentVersion + 1
        try FileManager.default.createDirectory(at: paths.supportDirectory,
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(status).write(to: paths.statusURL)
        XCTAssertThrowsError(try StatusFile(paths: paths).read()) { error in
            XCTAssertTrue("\(error)".contains("version"), "\(error)")
        }
    }

    // MARK: - rendering

    func testAFreshStatusReportsEverythingTheSpecAsksFor() {
        let text = StatusFile.render(sample(), now: 2_001, processIsAlive: true)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("51234"), "the control port must be shown: \(text)")
        XCTAssertTrue(text.contains("51235"), "the media port must be shown: \(text)")
        XCTAssertTrue(text.contains("Built-in Output"), text)
        XCTAssertTrue(text.contains("BuiltInSpeakerDevice"), text)
        XCTAssertTrue(text.contains("192.0.2.7"), "the current sender must be shown: \(text)")
        XCTAssertTrue(text.contains("buffer=89.4ms"), "the last stats line must be shown: \(text)")
        XCTAssertTrue(text.contains("/path/to/receiver.log"), text)
        XCTAssertFalse(text.contains("stale"), text)
        XCTAssertFalse(text.contains("GONE"), text)
    }

    /// The file outliving the process is the case that matters: without this
    /// check `--status` would confidently describe a daemon that died an hour
    /// ago.
    func testADeadProcessIsReportedEvenThoughTheFileIsThere() {
        let text = StatusFile.render(sample(), now: 2_001, processIsAlive: false)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("GONE"), text)
    }

    func testAnOldStatusFromALiveProcessIsReportedAsStale() {
        let text = StatusFile.render(sample(), now: 2_000 + 30, processIsAlive: true)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("stale"), text)
    }

    func testNoSenderAndNoDeviceAreStatedRatherThanLeftBlank() {
        var status = sample(streaming: false, peer: nil)
        status.deviceName = nil
        status.deviceUID = nil
        status.controlPort = 0
        status.udpPort = 0
        status.hardwareVolume = false
        let text = StatusFile.render(status, now: 2_001, processIsAlive: true)
            .joined(separator: "\n")
        XCTAssertTrue(text.contains("none connected"), text)
        XCTAssertTrue(text.contains("not listening"), text)
        XCTAssertTrue(text.contains("not open"), text)
        XCTAssertTrue(text.contains("software gain"), text)
        XCTAssertTrue(text.contains("no output device could be opened"), text)
    }

    func testOurOwnProcessIsAliveAndPidZeroIsNot() {
        XCTAssertTrue(StatusFile.processIsAlive(ProcessInfo.processInfo.processIdentifier))
        XCTAssertFalse(StatusFile.processIsAlive(0))
        XCTAssertFalse(StatusFile.processIsAlive(-1))
    }
}
