import Foundation

/// Reads macOS's Application Firewall (ALF) state and says whether this
/// binary will actually be allowed to accept the sender's connection.
///
/// # Why the daemon has to care
///
/// ALF adjudicates AFTER the kernel completes the TCP handshake. A blocked
/// listener therefore looks, from every direction, like a working one: the
/// port answers, `nc -z` reports success, and the daemon simply never sees a
/// connection. On a headless second Mac nobody is there to answer the "do you
/// want the application to accept incoming network connections?" dialog, so
/// an unsigned or ad-hoc-signed binary stays blocked indefinitely and the
/// only symptom is silence.
///
/// Nothing here ever runs `sudo`, or changes any setting. It reports, and
/// prints the two commands the user can run themselves.
public enum FirewallCheck {

    /// Where Apple keeps the ALF command-line tool. Stable since 10.6.
    public static let toolPath = "/usr/libexec/ApplicationFirewall/socketfilterfw"

    /// The three values `--getglobalstate` reports.
    public enum GlobalState: Equatable, Sendable {
        case off
        /// On, adjudicating per application.
        case on
        /// On, and refusing every incoming connection regardless of the
        /// per-application list. No `--add` can fix this one.
        case blockAll
        /// The tool was missing, failed, or said something unrecognised.
        case unknown(String)

        public var blocksIncoming: Bool {
            switch self {
            case .off, .unknown: return false
            case .on, .blockAll: return true
            }
        }

        public var description: String {
            switch self {
            case .off: return "off"
            case .on: return "on (per-application)"
            case .blockAll: return "on, blocking ALL incoming connections"
            case .unknown(let raw): return "unknown (\(raw))"
            }
        }
    }

    /// One row of `--listapps`.
    public struct AppEntry: Equatable, Sendable {
        public let path: String
        public let allowsIncoming: Bool
        public init(path: String, allowsIncoming: Bool) {
            self.path = path
            self.allowsIncoming = allowsIncoming
        }
    }

    /// What the firewall means for this particular binary.
    public enum Verdict: Equatable, Sendable {
        /// The firewall is off, or the binary is explicitly allowed.
        case willReceiveConnections
        /// Listed and explicitly blocked.
        case blocked
        /// Not in the list at all. On a machine with nobody at the keyboard
        /// this is indistinguishable from blocked, because the dialog that
        /// would add it never gets answered.
        case notListed
        /// Global "block all incoming connections" — no per-app fix exists.
        case blockedByBlockAll
        /// The state could not be read.
        case undetermined(String)
    }

    /// Everything one `--doctor` run found.
    public struct Report: Sendable {
        public let globalState: GlobalState
        public let binaryPath: String
        public let entry: AppEntry?
        public let verdict: Verdict
    }

    // MARK: - Parsing (pure, and therefore tested)

    /// `--getglobalstate` prints e.g. `Firewall is enabled. (State = 1)`.
    /// The number is the contract; the sentence is localised prose.
    public static func parseGlobalState(_ output: String) -> GlobalState {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let equals = trimmed.range(of: "State = ") else {
            return .unknown(trimmed.isEmpty ? "no output" : trimmed)
        }
        let digits = trimmed[equals.upperBound...].prefix { $0.isNumber }
        switch Int(digits) {
        case 0: return .off
        case 1: return .on
        case 2: return .blockAll
        default: return .unknown(trimmed)
        }
    }

    /// `--listapps` prints numbered path lines, each followed by an
    /// indented `(Allow incoming connections)` or `(Block incoming
    /// connections)`. Paths contain spaces and non-ASCII characters, so the
    /// path is "everything after the first colon", not a whitespace split.
    public static func parseListApps(_ output: String) -> [AppEntry] {
        var entries: [AppEntry] = []
        var pendingPath: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.contains("incoming connections") {
                guard let path = pendingPath else { continue }
                entries.append(AppEntry(path: path, allowsIncoming: line.contains("Allow")))
                pendingPath = nil
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let number = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            guard !number.isEmpty, number.allSatisfy(\.isNumber) else { continue }
            let path = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            pendingPath = path.isEmpty ? nil : path
        }
        return entries
    }

    /// ALF stores whatever path it was given; a symlinked or relatively
    /// invoked binary must still match. Both sides are standardised before
    /// comparison, and a trailing slash is ignored.
    public static func entry(for binaryPath: String, in entries: [AppEntry]) -> AppEntry? {
        let wanted = canonical(binaryPath)
        return entries.first { canonical($0.path) == wanted }
    }

    static func canonical(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var text = url.path
        while text.count > 1, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public static func verdict(globalState: GlobalState, entry: AppEntry?) -> Verdict {
        switch globalState {
        case .unknown(let raw): return .undetermined(raw)
        case .off: return .willReceiveConnections
        case .blockAll: return .blockedByBlockAll
        case .on:
            guard let entry else { return .notListed }
            return entry.allowsIncoming ? .willReceiveConnections : .blocked
        }
    }

    /// The lines `--doctor` and `--install` print. Pure, so the wording is
    /// under test and cannot drift away from what actually needs running.
    ///
    /// The commands are printed, never executed: this process must not
    /// prompt for an administrator password, and a daemon that edits the
    /// firewall behind the user's back would be exactly the behaviour the
    /// firewall exists to prevent.
    public static func advice(for report: Report) -> [String] {
        var lines = ["Application Firewall: \(report.globalState.description)"]
        switch report.verdict {
        case .willReceiveConnections:
            lines.append("this binary can accept incoming connections: \(report.binaryPath)")
        case .undetermined(let raw):
            lines.append("could not read the firewall state (\(raw));")
            lines.append("check it by hand in System Settings › Network › Firewall.")
        case .blockedByBlockAll:
            lines.append("the firewall is set to block ALL incoming connections, so no")
            lines.append("per-application exception can help. Turn that option off in")
            lines.append("System Settings › Network › Firewall › Options.")
        case .blocked, .notListed:
            let missing = report.verdict == .notListed
            lines.append(missing
                ? "this binary is NOT in the firewall's application list:"
                : "this binary is listed as BLOCKED:")
            lines.append("  \(report.binaryPath)")
            lines.append("")
            lines.append("The firewall decides AFTER the TCP handshake completes, so the")
            lines.append("sender's connect appears to succeed and this daemon never sees it —")
            lines.append("the sender then sits waiting for a hello_ack that cannot come.")
            lines.append("On a Mac with nobody at the keyboard the \"allow incoming")
            lines.append("connections?\" prompt is never answered, so run these two by hand:")
            lines.append("")
            lines.append("  sudo \(toolPath) --add \"\(report.binaryPath)\"")
            lines.append("  sudo \(toolPath) --unblockapp \"\(report.binaryPath)\"")
        }
        return lines
    }

    // MARK: - Running the tool

    /// Read the live firewall state. Never throws: an unreadable firewall is
    /// a diagnostic gap, not a reason for the daemon to fail.
    public static func inspect(binaryPath: String) -> Report {
        guard FileManager.default.isExecutableFile(atPath: toolPath) else {
            return Report(globalState: .unknown("\(toolPath) is not present"),
                          binaryPath: binaryPath,
                          entry: nil,
                          verdict: .undetermined("\(toolPath) is not present"))
        }
        let state = parseGlobalState(run([toolPath, "--getglobalstate"]))
        let entries = parseListApps(run([toolPath, "--listapps"]))
        let match = entry(for: binaryPath, in: entries)
        return Report(globalState: state,
                      binaryPath: binaryPath,
                      entry: match,
                      verdict: verdict(globalState: state, entry: match))
    }

    private static func run(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
