import Foundation

public enum LogLevel: String, Sendable {
    case debug = "DEBUG", info = "INFO", warn = "WARN", error = "ERROR"
}

/// Append-only file log with size-capped rotation.
///
/// # Why rotation truncates instead of renaming
/// Under launchd the agent's `StandardOutPath`/`StandardErrorPath` point at
/// the SAME file, and launchd holds its own descriptor on it. Renaming the
/// file would leave launchd writing into the rotated-away inode forever.
/// Copying the contents aside and then `ftruncate`-ing to zero keeps the
/// inode — every `O_APPEND` writer, ours and launchd's, carries on correctly.
public final class Log: @unchecked Sendable {
    public static let rotationThresholdBytes = 5 * 1024 * 1024

    private let url: URL
    private let rotatedURL: URL
    private let queue = DispatchQueue(label: "io.syncast.receiver.log")
    private var handle: FileHandle?
    private let mirrorToStderr: Bool
    private let formatter: DateFormatter

    public init(paths: ReceiverPaths = ReceiverPaths(), mirrorToStderr: Bool? = nil) {
        self.url = paths.logURL
        self.rotatedURL = paths.rotatedLogURL
        // Interactive runs echo to the terminal; under launchd stderr is the
        // log file itself, so mirroring would duplicate every line.
        self.mirrorToStderr = mirrorToStderr ?? (isatty(STDERR_FILENO) == 1)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.current
        self.formatter = f
        try? FileManager.default.createDirectory(at: paths.logDirectory,
                                                 withIntermediateDirectories: true)
        openHandle()
    }

    deinit { try? handle?.close() }

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    public func log(_ level: LogLevel, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        queue.async { [weak self] in self?.write(line) }
    }

    public func debug(_ m: @autoclosure () -> String) { log(.debug, m()) }
    public func info(_ m: String) { log(.info, m) }
    public func warn(_ m: String) { log(.warn, m) }
    public func error(_ m: String) { log(.error, m) }

    /// Flush pending lines. Called on SIGTERM so the shutdown reason
    /// actually reaches the file.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private func write(_ line: String) {
        if mirrorToStderr { FileHandle.standardError.write(Data(line.utf8)) }
        guard let handle else { return }
        rotateIfNeeded()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    private func rotateIfNeeded() {
        guard let handle else { return }
        let size = (try? handle.offset()) ?? 0
        guard size >= UInt64(Self.rotationThresholdBytes) else { return }
        // Copy aside, then truncate in place (see the class comment).
        if let contents = try? Data(contentsOf: url) {
            try? contents.write(to: rotatedURL, options: [.atomic])
        }
        try? handle.truncate(atOffset: 0)
        try? handle.seek(toOffset: 0)
    }
}
