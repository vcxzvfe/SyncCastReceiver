import Foundation

/// Hand-rolled argument parsing: the daemon has eight flags and adding a
/// package dependency for that would be the only dependency in the tree.
public struct CLIOptions: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case run
        case printToken
        case selfTest
        case install
        case uninstall
        /// Report the Application Firewall verdict for this binary, and the
        /// commands to fix it. Reads only; never runs sudo.
        case doctor
        /// Print what the RUNNING daemon last published: ports, device,
        /// hardware volume, current sender, last stats line.
        case status
        case help
    }

    public var action: Action = .run
    public var device: String?
    public var name: String = "Receiver"
    public var port: UInt16 = WireFormat.defaultControlPort
    /// IO buffer to ask the output device for; 0 leaves it alone.
    public var ioBufferFrames: Int = 256
    /// Flags to bake into the LaunchAgent, i.e. everything except the
    /// install verb itself.
    public var passthroughArguments: [String] = []

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownFlag(String)
        case missingValue(String)
        case badPort(String)
        case badFrames(String)
        case conflictingActions

        public var description: String {
            switch self {
            case .unknownFlag(let f): return "unknown option \(f)"
            case .missingValue(let f): return "\(f) needs a value"
            case .badPort(let v): return "\(v) is not a valid TCP port (0-65535)"
            case .badFrames(let v): return "\(v) is not a valid IO buffer size (0, or 32-4096 frames)"
            case .conflictingActions: return "only one of --selftest/--install/--uninstall/--print-token/--doctor/--status may be given"
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> CLIOptions {
        var options = CLIOptions()
        var actionSet = false
        var index = 0
        func setAction(_ action: Action) throws {
            guard !actionSet || options.action == action else { throw ParseError.conflictingActions }
            options.action = action
            actionSet = true
        }
        func value(for flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw ParseError.missingValue(flag) }
            return arguments[index]
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--device":
                let v = try value(for: argument)
                options.device = v
                options.passthroughArguments += ["--device", v]
            case "--name":
                let v = try value(for: argument)
                options.name = v
                options.passthroughArguments += ["--name", v]
            case "--port":
                let v = try value(for: argument)
                guard let port = UInt16(v) else { throw ParseError.badPort(v) }
                options.port = port
                options.passthroughArguments += ["--port", v]
            case "--io-buffer":
                let v = try value(for: argument)
                guard let frames = Int(v), frames == 0 || (32...4_096).contains(frames) else {
                    throw ParseError.badFrames(v)
                }
                options.ioBufferFrames = frames
                options.passthroughArguments += ["--io-buffer", v]
            case "--print-token": try setAction(.printToken)
            case "--selftest": try setAction(.selfTest)
            case "--install": try setAction(.install)
            case "--doctor": try setAction(.doctor)
            case "--status": try setAction(.status)
            case "--uninstall": try setAction(.uninstall)
            case "--help", "-h": try setAction(.help)
            default:
                throw ParseError.unknownFlag(argument)
            }
            index += 1
        }
        return options
    }

    public static let usage = """
    synccast-receiver — play a SyncCast LAN PCM stream on this Mac's speakers

    USAGE
      synccast-receiver [--device <uid|name>] [--name <friendly>] [--port <n>]
      synccast-receiver --print-token
      synccast-receiver --selftest
      synccast-receiver --doctor | --status
      synccast-receiver --install [flags…] | --uninstall

    OPTIONS
      --device <uid|name>  Output device: exact CoreAudio UID, exact name, or a
                           name substring. Default: the built-in speakers.
      --name <friendly>    Name advertised over Bonjour. Default: Receiver
      --port <n>           TCP control port. Default: \(WireFormat.defaultControlPort);
                           0 picks an ephemeral port (the sender finds it via Bonjour).
      --io-buffer <frames> IO buffer to ask the output device for. Default: 256
                           (5.3 ms); 0 leaves the device's setting alone. Two of
                           these blocks are the floor of every playout target.
      --print-token        Print the pairing token and exit.
      --selftest           Run the offline packet/scheduler/resampler self-test.
      --doctor             Report whether the Application Firewall will let this
                           binary accept connections, and how to allow it.
      --status             Print what the running daemon last published.
      --install            Write and bootstrap the LaunchAgent, then exit.
      --uninstall          Bootout and remove the LaunchAgent, then exit.
      -h, --help           This text.
    """
}
