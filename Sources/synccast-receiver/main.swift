import Foundation
import ReceiverCore

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let options: CLIOptions
do {
    options = try CLIOptions.parse(arguments)
} catch {
    FileHandle.standardError.write(Data("synccast-receiver: \(error)\n\n".utf8))
    print(CLIOptions.usage)
    exit(2)
}

let paths = ReceiverPaths()
let store = ConfigStore(paths: paths)

switch options.action {
case .help:
    print(CLIOptions.usage)
    exit(0)

case .selfTest:
    // No config, no network, no CoreAudio: this must work on a machine with
    // no audio hardware at all.
    let report = SelfTest.run { print($0) }
    if report.passed {
        print("SELFTEST PASS")
        exit(0)
    }
    let failed = report.checks.filter { !$0.passed }.map(\.name).joined(separator: ", ")
    print("SELFTEST FAIL (\(failed))")
    exit(1)

case .printToken:
    do {
        let config = try store.loadOrCreate(name: options.name, device: options.device)
        print(config.token)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("synccast-receiver: \(error)\n".utf8))
        exit(1)
    }

case .install:
    do {
        let executable = LaunchAgentInstaller.resolvedExecutablePath(argv0: CommandLine.arguments[0])
        let config = try store.loadOrCreate(name: options.name, device: options.device)
        let installer = LaunchAgentInstaller(paths: paths)
        for line in try installer.install(executablePath: executable,
                                          arguments: options.passthroughArguments) {
            print(line)
        }
        print("pairing token: \(config.token)")
        print("enter that token in SyncCast once, for the receiver named \"\(config.name)\".")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("synccast-receiver: install failed: \(error)\n".utf8))
        exit(1)
    }

case .uninstall:
    do {
        for line in try LaunchAgentInstaller(paths: paths).uninstall() { print(line) }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("synccast-receiver: uninstall failed: \(error)\n".utf8))
        exit(1)
    }

case .run:
    break
}

// MARK: - daemon

let log = Log(paths: paths)

let config: ReceiverConfig
do {
    config = try store.loadOrCreate(name: options.name, device: options.device)
} catch {
    // Without a token there is no way to authenticate a sender, so this one
    // really is fatal — but say so in the log launchd is capturing.
    log.error("cannot read or create \(paths.configURL.path): \(error)")
    log.flush()
    exit(1)
}

log.info("pairing token: \(config.token)")

let daemon = ReceiverDaemon(
    options: ReceiverDaemon.Options(name: config.name,
                                    deviceQuery: config.device,
                                    port: options.port),
    config: config,
    log: log)

// SIGTERM is how launchd asks an agent to stop; SIGINT is Ctrl-C. Both must
// tear the AUHAL down cleanly. The hardware volume is left exactly where the
// sender set it — see ReceiverDaemon.shutdown().
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
signal(SIGPIPE, SIG_IGN)
let signalQueue = DispatchQueue(label: "io.syncast.receiver.signal")
var signalSources: [DispatchSourceSignal] = []
for number in [SIGTERM, SIGINT] {
    let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
    source.setEventHandler {
        daemon.shutdown()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

daemon.start()
dispatchMain()
