import Foundation

/// Every on-disk location the daemon uses. Injectable so tests never touch
/// the real home directory.
public struct ReceiverPaths: Sendable {
    public static let bundleIdentifier = "io.syncast.receiver"
    public static let appDirectoryName = "SyncCastReceiver"

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public var supportDirectory: URL {
        home.appendingPathComponent("Library/Application Support/\(Self.appDirectoryName)", isDirectory: true)
    }
    public var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    /// What the running daemon publishes for `--status`. Rewritten roughly
    /// once a second, so it lives next to the config rather than in the log
    /// directory where it would be mistaken for something worth keeping.
    public var statusURL: URL { supportDirectory.appendingPathComponent("status.json") }
    public var logDirectory: URL {
        home.appendingPathComponent("Library/Logs/\(Self.appDirectoryName)", isDirectory: true)
    }
    public var logURL: URL { logDirectory.appendingPathComponent("receiver.log") }
    public var rotatedLogURL: URL { logDirectory.appendingPathComponent("receiver.log.1") }
    public var launchAgentURL: URL {
        home.appendingPathComponent("Library/LaunchAgents/\(Self.bundleIdentifier).plist")
    }
}
