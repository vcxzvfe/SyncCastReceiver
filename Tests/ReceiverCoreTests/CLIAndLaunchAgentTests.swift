import XCTest
@testable import ReceiverCore

final class CLIOptionsTests: XCTestCase {

    func testDefaults() throws {
        let options = try CLIOptions.parse([])
        XCTAssertEqual(options.action, .run)
        XCTAssertEqual(options.name, "Receiver")
        XCTAssertEqual(options.port, 47_100)
        XCTAssertNil(options.device)
    }

    func testFlags() throws {
        let options = try CLIOptions.parse(["--device", "BuiltInSpeakerDevice",
                                            "--name", "Receiver A", "--port", "0"])
        XCTAssertEqual(options.device, "BuiltInSpeakerDevice")
        XCTAssertEqual(options.name, "Receiver A")
        XCTAssertEqual(options.port, 0)
        XCTAssertEqual(options.action, .run)
    }

    func testPassthroughArgumentsAreWhatTheAgentGetsBaked() throws {
        let options = try CLIOptions.parse(["--install", "--name", "Receiver A", "--port", "47100"])
        XCTAssertEqual(options.action, .install)
        XCTAssertEqual(options.passthroughArguments, ["--name", "Receiver A", "--port", "47100"])
        XCTAssertFalse(options.passthroughArguments.contains("--install"),
                       "the agent must not re-run the installer on every launch")
    }

    func testActions() throws {
        XCTAssertEqual(try CLIOptions.parse(["--selftest"]).action, .selfTest)
        XCTAssertEqual(try CLIOptions.parse(["--print-token"]).action, .printToken)
        XCTAssertEqual(try CLIOptions.parse(["--uninstall"]).action, .uninstall)
        XCTAssertEqual(try CLIOptions.parse(["-h"]).action, .help)
    }

    func testErrors() {
        XCTAssertThrowsError(try CLIOptions.parse(["--nope"])) {
            XCTAssertEqual($0 as? CLIOptions.ParseError, .unknownFlag("--nope"))
        }
        XCTAssertThrowsError(try CLIOptions.parse(["--name"])) {
            XCTAssertEqual($0 as? CLIOptions.ParseError, .missingValue("--name"))
        }
        XCTAssertThrowsError(try CLIOptions.parse(["--port", "99999"])) {
            XCTAssertEqual($0 as? CLIOptions.ParseError, .badPort("99999"))
        }
        XCTAssertThrowsError(try CLIOptions.parse(["--selftest", "--install"])) {
            XCTAssertEqual($0 as? CLIOptions.ParseError, .conflictingActions)
        }
    }
}

final class LaunchAgentTests: XCTestCase {

    private func installer() -> LaunchAgentInstaller {
        LaunchAgentInstaller(paths: ReceiverPaths(home: URL(fileURLWithPath: "/private/tmp/synccast-receiver-test-home")))
    }

    func testPlistShape() throws {
        let plist = installer().plist(executablePath: "/opt/synccast/synccast-receiver",
                                      arguments: ["--name", "Receiver A"])
        XCTAssertEqual(plist["Label"] as? String, "io.syncast.receiver")
        XCTAssertEqual(plist["ProgramArguments"] as? [String],
                       ["/opt/synccast/synccast-receiver", "--name", "Receiver A"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
        XCTAssertEqual(plist["ProcessType"] as? String, "Interactive")
        XCTAssertEqual(plist["StandardOutPath"] as? String,
                       "/private/tmp/synccast-receiver-test-home/Library/Logs/SyncCastReceiver/receiver.log")
        XCTAssertEqual(plist["StandardErrorPath"] as? String, plist["StandardOutPath"] as? String)
    }

    func testPlistSerialises() throws {
        let plist = installer().plist(executablePath: "/usr/local/bin/synccast-receiver", arguments: [])
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let round = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        XCTAssertEqual(round?["Label"] as? String, "io.syncast.receiver")
    }

    func testExecutablePathIsMadeAbsolute() {
        let resolved = LaunchAgentInstaller.resolvedExecutablePath(argv0: ".build/release/synccast-receiver")
        XCTAssertTrue(resolved.hasPrefix("/"), "launchd cannot resolve a relative path: \(resolved)")
        XCTAssertTrue(resolved.hasSuffix("synccast-receiver"))
    }

    func testPathsLayout() {
        let paths = ReceiverPaths(home: URL(fileURLWithPath: "/private/tmp/home"))
        XCTAssertEqual(paths.configURL.path,
                       "/private/tmp/home/Library/Application Support/SyncCastReceiver/config.json")
        XCTAssertEqual(paths.logURL.path, "/private/tmp/home/Library/Logs/SyncCastReceiver/receiver.log")
        XCTAssertEqual(paths.launchAgentURL.path,
                       "/private/tmp/home/Library/LaunchAgents/io.syncast.receiver.plist")
    }
}
