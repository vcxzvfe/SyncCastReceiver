import XCTest
@testable import ReceiverCore

/// Parsing `socketfilterfw`'s output, and the advice that follows from it.
///
/// The fixtures below are the real tool's real format, captured from a Mac
/// running the current OS: numbered lines whose path may contain spaces,
/// colons and non-ASCII characters, each followed by an indented verdict
/// line. Parsing it with a whitespace split — the obvious first attempt —
/// truncates half the paths on a typical machine.
final class FirewallCheckTests: XCTestCase {

    // MARK: - global state

    func testGlobalStateIsReadFromTheNumberNotTheProse() {
        XCTAssertEqual(FirewallCheck.parseGlobalState("Firewall is disabled. (State = 0)"), .off)
        XCTAssertEqual(FirewallCheck.parseGlobalState("Firewall is enabled. (State = 1)"), .on)
        XCTAssertEqual(
            FirewallCheck.parseGlobalState("Firewall is enabled. (State = 2)\n"), .blockAll)
    }

    func testAnUnreadableGlobalStateIsUnknownRatherThanAssumedOff() {
        guard case .unknown = FirewallCheck.parseGlobalState("") else {
            return XCTFail("empty output must not be read as a state")
        }
        guard case .unknown = FirewallCheck.parseGlobalState("command not found") else {
            return XCTFail("garbage must not be read as a state")
        }
        // Assuming "off" would be the dangerous default: it would tell the
        // user everything is fine on the machine where it is not.
        XCTAssertFalse(FirewallCheck.parseGlobalState("").blocksIncoming)
        if case .undetermined = FirewallCheck.verdict(
            globalState: FirewallCheck.parseGlobalState(""), entry: nil) {
        } else {
            XCTFail("an unknown state must not produce a confident verdict")
        }
    }

    // MARK: - listapps

    private let listAppsFixture = """
    Total number of apps = 4 \n\
    1 : /Applications/Some App.app/Contents/MacOS/Some App \n\
                 (Allow incoming connections)
    2 : /Users/example/tools/blocked-daemon \n\
                 (Block incoming connections)
    3 : /Applications/名前.app/Contents/MacOS/名前 \n\
                 (Allow incoming connections)
    4 : /opt/homebrew/bin/thing \n\
                 (Allow incoming connections)
    """

    func testListAppsKeepsWholePathsIncludingSpacesAndNonASCII() {
        let entries = FirewallCheck.parseListApps(listAppsFixture)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].path, "/Applications/Some App.app/Contents/MacOS/Some App")
        XCTAssertTrue(entries[0].allowsIncoming)
        XCTAssertEqual(entries[1].path, "/Users/example/tools/blocked-daemon")
        XCTAssertFalse(entries[1].allowsIncoming)
        XCTAssertEqual(entries[2].path, "/Applications/名前.app/Contents/MacOS/名前")
        XCTAssertEqual(entries[3].path, "/opt/homebrew/bin/thing")
    }

    func testTheHeaderAndBlankLinesAreNotMistakenForEntries() {
        XCTAssertTrue(FirewallCheck.parseListApps("Total number of apps = 0 \n\n").isEmpty)
        XCTAssertTrue(FirewallCheck.parseListApps("").isEmpty)
    }

    /// A path line with no verdict after it (a truncated read) must not
    /// silently inherit the next entry's verdict.
    func testAPathWithNoVerdictIsDropped() {
        let entries = FirewallCheck.parseListApps("""
        1 : /a/dangling/path
        2 : /a/complete/path
                     (Block incoming connections)
        """)
        XCTAssertEqual(entries, [FirewallCheck.AppEntry(path: "/a/complete/path",
                                                        allowsIncoming: false)])
    }

    func testAnEntryIsMatchedThroughTrailingSlashesAndDotSegments() {
        let entries = FirewallCheck.parseListApps(listAppsFixture)
        XCTAssertEqual(
            FirewallCheck.entry(for: "/opt/homebrew/bin/./thing", in: entries)?.path,
            "/opt/homebrew/bin/thing")
        XCTAssertNil(FirewallCheck.entry(for: "/opt/homebrew/bin/other", in: entries))
    }

    // MARK: - verdicts

    func testVerdicts() {
        let allowed = FirewallCheck.AppEntry(path: "/x", allowsIncoming: true)
        let blocked = FirewallCheck.AppEntry(path: "/x", allowsIncoming: false)
        XCTAssertEqual(FirewallCheck.verdict(globalState: .off, entry: nil),
                       .willReceiveConnections)
        XCTAssertEqual(FirewallCheck.verdict(globalState: .on, entry: allowed),
                       .willReceiveConnections)
        XCTAssertEqual(FirewallCheck.verdict(globalState: .on, entry: blocked), .blocked)
        // Not listed is the case that actually bit: on a headless Mac the
        // prompt that would add it never gets answered.
        XCTAssertEqual(FirewallCheck.verdict(globalState: .on, entry: nil), .notListed)
        XCTAssertEqual(FirewallCheck.verdict(globalState: .blockAll, entry: allowed),
                       .blockedByBlockAll)
    }

    // MARK: - advice

    private func advice(verdict: FirewallCheck.Verdict,
                        state: FirewallCheck.GlobalState,
                        path: String = "/usr/local/bin/synccast-receiver") -> String {
        FirewallCheck.advice(for: FirewallCheck.Report(
            globalState: state, binaryPath: path, entry: nil, verdict: verdict))
            .joined(separator: "\n")
    }

    func testBlockedAdviceQuotesBothCommandsWithTheResolvedPath() {
        let path = "/Users/example/Library/Application Support/My Tools/synccast-receiver"
        let text = advice(verdict: .notListed, state: .on, path: path)
        XCTAssertTrue(text.contains("sudo \(FirewallCheck.toolPath) --add \"\(path)\""), text)
        XCTAssertTrue(text.contains("sudo \(FirewallCheck.toolPath) --unblockapp \"\(path)\""), text)
        // Quoted, because the real path has spaces in it more often than not.
        XCTAssertTrue(text.contains("\"\(path)\""))
        // And it explains WHY, since the symptom looks like a working link.
        XCTAssertTrue(text.lowercased().contains("hello_ack"), text)
    }

    func testBlockAllAdviceDoesNotOfferAPerApplicationFix() {
        let text = advice(verdict: .blockedByBlockAll, state: .blockAll)
        XCTAssertFalse(text.contains("--add"), "no per-app exception can help here")
        XCTAssertTrue(text.contains("System Settings"), text)
    }

    func testHealthyAdviceSaysSoAndOffersNoCommands() {
        let text = advice(verdict: .willReceiveConnections, state: .off)
        XCTAssertFalse(text.contains("sudo"))
        XCTAssertTrue(text.contains("can accept incoming connections"), text)
    }

    /// Nothing in this type may run a privileged command on the user's
    /// behalf; it prints them and stops.
    func testAdviceNeverClaimsToHaveChangedAnything() {
        for verdict: FirewallCheck.Verdict in [.blocked, .notListed, .blockedByBlockAll] {
            let text = advice(verdict: verdict, state: .on).lowercased()
            XCTAssertFalse(text.contains("added"), text)
            XCTAssertFalse(text.contains("unblocked"), text)
        }
    }
}
