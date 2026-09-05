import Foundation

/// `~/Library/LaunchAgents/io.syncast.receiver.plist` management.
///
/// A user agent, not a daemon: the receiver needs a user audio session to
/// open an output device at all, so it must run in the user's GUI domain
/// (`gui/<uid>`), never in `system/`.
public struct LaunchAgentInstaller: Sendable {

    public let paths: ReceiverPaths
    public let label = ReceiverPaths.bundleIdentifier

    public init(paths: ReceiverPaths = ReceiverPaths()) { self.paths = paths }

    public enum InstallError: Error, CustomStringConvertible {
        case launchctl(String, Int32, String)
        case write(URL, Error)

        public var description: String {
            switch self {
            case .launchctl(let command, let status, let output):
                return "launchctl \(command) exited \(status): \(output)"
            case .write(let url, let error):
                return "could not write \(url.path): \(error)"
            }
        }
    }

    /// The plist contents for a given binary and flag set.
    public func plist(executablePath: String, arguments: [String]) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executablePath] + arguments,
            "RunAtLoad": true,
            "KeepAlive": true,
            // Interactive gives the process a foreground-quality scheduling
            // band: an audio render thread throttled to a background band
            // would glitch under load.
            "ProcessType": "Interactive",
            "StandardOutPath": paths.logURL.path,
            "StandardErrorPath": paths.logURL.path,
            "EnvironmentVariables": ["SYNCCAST_RECEIVER_MANAGED": "launchd"],
        ]
    }

    /// Write the plist and (re)bootstrap it. Returns the lines to print.
    public func install(executablePath: String, arguments: [String]) throws -> [String] {
        var report: [String] = []
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.logDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: paths.launchAgentURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist(executablePath: executablePath, arguments: arguments),
                format: .xml, options: 0)
            try data.write(to: paths.launchAgentURL, options: [.atomic])
        } catch {
            throw InstallError.write(paths.launchAgentURL, error)
        }
        report.append("wrote \(paths.launchAgentURL.path)")
        report.append("program: \(([executablePath] + arguments).joined(separator: " "))")

        let domain = "gui/\(getuid())"
        // bootout first so a re-install picks up the new arguments; it fails
        // harmlessly when nothing is loaded.
        let previous = run(["launchctl", "bootout", "\(domain)/\(label)"])
        report.append(previous.status == 0 ? "booted out the previous agent"
                                           : "no previous agent was loaded")
        let bootstrap = run(["launchctl", "bootstrap", domain, paths.launchAgentURL.path])
        guard bootstrap.status == 0 else {
            throw InstallError.launchctl("bootstrap", bootstrap.status, bootstrap.output)
        }
        report.append("bootstrapped \(domain)/\(label)")
        report.append("logs: \(paths.logURL.path)")
        return report
    }

    public func uninstall() throws -> [String] {
        var report: [String] = []
        let domain = "gui/\(getuid())"
        let bootout = run(["launchctl", "bootout", "\(domain)/\(label)"])
        report.append(bootout.status == 0 ? "booted out \(domain)/\(label)"
                                          : "the agent was not loaded")
        if FileManager.default.fileExists(atPath: paths.launchAgentURL.path) {
            do {
                try FileManager.default.removeItem(at: paths.launchAgentURL)
                report.append("removed \(paths.launchAgentURL.path)")
            } catch {
                throw InstallError.write(paths.launchAgentURL, error)
            }
        } else {
            report.append("no plist at \(paths.launchAgentURL.path)")
        }
        report.append("config and logs were left in place")
        return report
    }

    /// Absolute path of the running binary, for the plist. `launchd` has no
    /// working directory to resolve a relative path against.
    public static func resolvedExecutablePath(argv0: String) -> String {
        var candidate = argv0
        if !candidate.hasPrefix("/") {
            candidate = FileManager.default.currentDirectoryPath + "/" + candidate
        }
        return URL(fileURLWithPath: candidate).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func run(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = Array(arguments.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
