import Foundation

/// What the running daemon publishes about itself, so `--status` in a second
/// process can answer "is it up, on what ports, playing what, from whom?"
/// without attaching to it.
///
/// A file rather than a socket or a signal: `--status` must work when the
/// daemon is wedged, when it has just died, and when the person asking is on
/// an SSH session with no audio session of their own.
public struct ReceiverStatus: Codable, Equatable, Sendable {
    /// Bumped when a field's meaning changes, so an old file left behind by a
    /// previous build is reported as unusable rather than misread.
    public static let currentVersion = 1

    public var version: Int = ReceiverStatus.currentVersion
    public var pid: Int32
    public var name: String
    public var startedAtEpoch: Double
    public var updatedAtEpoch: Double
    /// 0 while the listener has not come up yet.
    public var controlPort: UInt16
    public var udpPort: UInt16
    public var deviceName: String?
    public var deviceUID: String?
    public var hardwareVolume: Bool
    public var streaming: Bool
    /// Address of the sender currently on the control channel.
    public var peer: String?
    /// The most recent stats line, verbatim as it went to the log.
    public var lastStats: String?
    public var logPath: String

    public init(pid: Int32,
                name: String,
                startedAtEpoch: Double,
                updatedAtEpoch: Double,
                controlPort: UInt16 = 0,
                udpPort: UInt16 = 0,
                deviceName: String? = nil,
                deviceUID: String? = nil,
                hardwareVolume: Bool = false,
                streaming: Bool = false,
                peer: String? = nil,
                lastStats: String? = nil,
                logPath: String) {
        self.pid = pid
        self.name = name
        self.startedAtEpoch = startedAtEpoch
        self.updatedAtEpoch = updatedAtEpoch
        self.controlPort = controlPort
        self.udpPort = udpPort
        self.deviceName = deviceName
        self.deviceUID = deviceUID
        self.hardwareVolume = hardwareVolume
        self.streaming = streaming
        self.peer = peer
        self.lastStats = lastStats
        self.logPath = logPath
    }
}

/// Reads and writes `ReceiverStatus` at `ReceiverPaths.statusURL`.
public struct StatusFile: Sendable {

    /// A status file not touched for longer than this is reported as stale.
    /// The daemon rewrites it on every stats tick (1 s), so anything past a
    /// few seconds means it stopped without cleaning up — a crash, a `kill
    /// -9`, or a wedge.
    public static let stalenessThresholdSeconds: Double = 6

    public let paths: ReceiverPaths

    public init(paths: ReceiverPaths = ReceiverPaths()) { self.paths = paths }

    public enum ReadError: Error, CustomStringConvertible {
        case missing(URL)
        case unreadable(URL, Error)
        case wrongVersion(Int)

        public var description: String {
            switch self {
            case .missing(let url):
                return "no status file at \(url.path) — the daemon is not running, "
                    + "or this build never wrote one"
            case .unreadable(let url, let error):
                return "could not read \(url.path): \(error)"
            case .wrongVersion(let version):
                return "status file is version \(version), this build understands "
                    + "\(ReceiverStatus.currentVersion); restart the daemon"
            }
        }
    }

    /// Write the file. Atomic, so a reader never sees a half-written JSON
    /// object, and best-effort: failing to publish status must never take the
    /// audio path down with it. Returns the error for the caller to log.
    @discardableResult
    public func write(_ status: ReceiverStatus) -> Error? {
        do {
            try FileManager.default.createDirectory(at: paths.supportDirectory,
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(status).write(to: paths.statusURL, options: [.atomic])
            return nil
        } catch {
            return error
        }
    }

    public func remove() {
        try? FileManager.default.removeItem(at: paths.statusURL)
    }

    public func read() throws -> ReceiverStatus {
        let url = paths.statusURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ReadError.missing(url)
        }
        let status: ReceiverStatus
        do {
            status = try JSONDecoder().decode(ReceiverStatus.self, from: Data(contentsOf: url))
        } catch {
            throw ReadError.unreadable(url, error)
        }
        guard status.version == ReceiverStatus.currentVersion else {
            throw ReadError.wrongVersion(status.version)
        }
        return status
    }

    /// Render the report `--status` prints.
    ///
    /// Pure, and takes `now` and the liveness answer as parameters, so the
    /// exact wording — including the stale and dead cases — is testable
    /// without a running daemon.
    public static func render(_ status: ReceiverStatus,
                              now: Double,
                              processIsAlive: Bool) -> [String] {
        let age = now - status.updatedAtEpoch
        var lines: [String] = []
        lines.append("name:        \(status.name)")
        if !processIsAlive {
            lines.append("process:     pid \(status.pid) is GONE — the daemon died without "
                         + "clearing its status file")
        } else if age > stalenessThresholdSeconds {
            lines.append(String(format: "process:     pid %d, but the status is %.0f s stale "
                                + "— the daemon may be wedged", status.pid, age))
        } else {
            lines.append("process:     pid \(status.pid), up "
                         + duration(now - status.startedAtEpoch))
        }
        lines.append("control:     TCP port "
                     + (status.controlPort == 0 ? "not listening" : "\(status.controlPort)"))
        lines.append("media:       UDP port "
                     + (status.udpPort == 0 ? "not open" : "\(status.udpPort)"))
        if let device = status.deviceName {
            let uid = status.deviceUID.map { " [\($0)]" } ?? ""
            lines.append("device:      \(device)\(uid)")
        } else {
            lines.append("device:      none (no output device could be opened)")
        }
        lines.append("hw volume:   \(status.hardwareVolume ? "yes" : "no (software gain)")")
        lines.append("sender:      \(status.peer ?? "none connected")")
        lines.append("streaming:   \(status.streaming ? "yes" : "no")")
        lines.append("last stats:  \(status.lastStats ?? "none yet")")
        lines.append("log:         \(status.logPath)")
        return lines
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "?" }
        if seconds < 90 { return String(format: "%.0f s", seconds) }
        if seconds < 5_400 { return String(format: "%.0f min", seconds / 60) }
        if seconds < 172_800 { return String(format: "%.1f h", seconds / 3_600) }
        return String(format: "%.1f days", seconds / 86_400)
    }

    /// Whether a pid is still around. `kill(pid, 0)` fails with ESRCH for a
    /// dead process and EPERM for one this user cannot signal — the latter
    /// still means it exists.
    public static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
