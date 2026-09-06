import Foundation

/// A world-readable "a stream is playing right now" flag for helpers that
/// run outside this process — `scripts/awdl-guard.sh` in particular, whose
/// root LaunchDaemon keeps the peer-to-peer Wi-Fi radio down only while this
/// file is fresh, so AirDrop and Universal Control keep working whenever
/// nothing is playing.
///
/// The file is touched once a second while streaming and removed when the
/// stream stops; a reader treats it as stale after `staleSeconds`, so a
/// crashed daemon cannot leave the radio pinned down.
public enum StreamingMarker {
    /// `/tmp` rather than the user's home: the reader is root and must not
    /// depend on which user is running the receiver.
    public static let path = "/tmp/io.syncast.receiver.streaming"
    public static let staleSeconds: TimeInterval = 10

    public static func touch(at path: String = path) {
        let now = Date()
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: path)
        } else {
            FileManager.default.createFile(atPath: path, contents: Data("streaming\n".utf8),
                                           attributes: [.posixPermissions: 0o644])
        }
    }

    public static func remove(at path: String = path) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Whether a reader should currently treat the marker as live.
    public static func isFresh(at path: String = path, now: Date = Date()) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return false }
        return now.timeIntervalSince(modified) < staleSeconds
    }
}
