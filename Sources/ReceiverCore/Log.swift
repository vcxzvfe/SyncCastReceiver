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
    private let rotationThresholdBytes: Int
    /// Set after a rotation failed, so the next write does not try (and
    /// report) the same thing again on every line.
    private var rotationBroken = false

    /// Where the lines are going. Reported by `--status` and by the install
    /// summary, so nobody has to guess at the path.
    public var path: String { url.path }

    public init(paths: ReceiverPaths = ReceiverPaths(),
                mirrorToStderr: Bool? = nil,
                rotationThresholdBytes: Int = Log.rotationThresholdBytes) {
        self.url = paths.logURL
        self.rotatedURL = paths.rotatedLogURL
        // Injectable so rotation is testable with a few hundred bytes rather
        // than five megabytes of synthetic log.
        self.rotationThresholdBytes = max(1, rotationThresholdBytes)
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
        guard let handle, !rotationBroken else { return }
        let size = (try? handle.offset()) ?? 0
        guard size >= UInt64(rotationThresholdBytes) else { return }
        // Copy aside, THEN truncate — and only if the copy actually landed.
        // Truncating after a failed copy would throw the log away silently,
        // which is the one outcome worse than an oversized log.
        do {
            try Data(contentsOf: url).write(to: rotatedURL, options: [.atomic])
        } catch {
            rotationBroken = true
            let line = "\(formatter.string(from: Date())) [\(LogLevel.error.rawValue)] "
                + "log rotation failed, the log will keep growing: \(error)\n"
            FileHandle.standardError.write(Data(line.utf8))
            try? handle.write(contentsOf: Data(line.utf8))
            return
        }
        do {
            try handle.truncate(atOffset: 0)
            try handle.seek(toOffset: 0)
        } catch {
            rotationBroken = true
            FileHandle.standardError.write(
                Data("could not truncate \(url.path) after rotation: \(error)\n".utf8))
        }
    }
}
