import XCTest
@testable import ReceiverCore

final class ConfigStoreTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("synccast-receiver-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testFirstRunCreatesTokenAndTightPermissions() throws {
        let store = ConfigStore(paths: ReceiverPaths(home: home))
        let config = try store.loadOrCreate(name: "Receiver A", device: nil)
        XCTAssertEqual(config.token.count, 32)
        XCTAssertEqual(config.tokenHint.count, 8)
        XCTAssertTrue(config.token.allSatisfy { $0.isHexDigit })

        let attrs = try FileManager.default.attributesOfItem(atPath: store.paths.configURL.path)
        XCTAssertEqual(attrs[.posixPermissions] as? NSNumber, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: store.paths.supportDirectory.path)
        XCTAssertEqual(dirAttrs[.posixPermissions] as? NSNumber, 0o700)
    }

    func testTokenSurvivesRestartsButFlagsAreUpdated() throws {
        let store = ConfigStore(paths: ReceiverPaths(home: home))
        let first = try store.loadOrCreate(name: "Receiver A", device: nil)
        let second = try store.loadOrCreate(name: "Receiver B", device: "BuiltInSpeakerDevice")
        XCTAssertEqual(first.token, second.token, "the pairing token must be stable")
        XCTAssertEqual(second.name, "Receiver B")
        XCTAssertEqual(second.device, "BuiltInSpeakerDevice")
    }

    func testTokensAreDistinct() {
        let tokens = Set((0..<64).map { _ in ReceiverConfig.generateToken() })
        XCTAssertEqual(tokens.count, 64)
    }

    func testTokenComparisonIsExact() {
        let config = ReceiverConfig(token: "0123456789abcdef0123456789abcdef", name: "n")
        XCTAssertTrue(config.matches(token: "0123456789abcdef0123456789abcdef"))
        XCTAssertFalse(config.matches(token: "0123456789abcdef0123456789abcde0"))
        XCTAssertFalse(config.matches(token: "0123456789abcdef"))
        XCTAssertFalse(config.matches(token: ""))
    }

    func testMalformedConfigIsReportedNotSwallowed() throws {
        let paths = ReceiverPaths(home: home)
        try FileManager.default.createDirectory(at: paths.supportDirectory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: paths.configURL)
        XCTAssertThrowsError(try ConfigStore(paths: paths).loadIfPresent())
    }
}
