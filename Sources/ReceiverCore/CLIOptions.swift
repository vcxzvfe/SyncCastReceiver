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
        case help
    }

    public var action: Action = .run
    public var device: String?
    public var name: String = "Receiver"
    public var port: UInt16 = WireFormat.defaultControlPort
    /// Flags to bake into the LaunchAgent, i.e. everything except the
    /// install verb itself.
    public var passthroughArguments: [String] = []

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknownFlag(String)
        case missingValue(String)
        case badPort(String)
        case conflictingActions

        public var description: String {
            switch self {
            case .unknownFlag(let f): return "unknown option \(f)"
            case .missingValue(let f): return "\(f) needs a value"
            case .badPort(let v): return "\(v) is not a valid TCP port (0-65535)"
            case .conflictingActions: return "only one of --selftest/--install/--uninstall/--print-token may be given"
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
            case "--print-token": try setAction(.printToken)
            case "--selftest": try setAction(.selfTest)
            case "--install": try setAction(.install)
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
      synccast-receiver --install [flags…] | --uninstall

    OPTIONS
      --device <uid|name>  Output device: exact CoreAudio UID, exact name, or a
                           name substring. Default: the built-in speakers.
      --name <friendly>    Name advertised over Bonjour. Default: Receiver
      --port <n>           TCP control port. Default: \(WireFormat.defaultControlPort);
                           0 picks an ephemeral port (the sender finds it via Bonjour).
      --print-token        Print the pairing token and exit.
      --selftest           Run the offline packet/scheduler/resampler self-test.
      --install            Write and bootstrap the LaunchAgent, then exit.
      --uninstall          Bootout and remove the LaunchAgent, then exit.
      -h, --help           This text.
    """
}
