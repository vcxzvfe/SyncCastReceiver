import Foundation

// MARK: - Sender → receiver

public struct HelloMessage: Codable, Equatable, Sendable {
    public var v: Int
    public var token: String
    public var name: String
    public var rate: Int
    public var channels: Int
    public var framesPerPacket: Int
    public var streamID: UInt32

    enum CodingKeys: String, CodingKey {
        case v, token, name, rate, channels
        case framesPerPacket = "frames_per_packet"
        case streamID = "stream_id"
    }

    public init(v: Int = WireFormat.protocolVersion,
                token: String,
                name: String,
                rate: Int = Int(WireFormat.sampleRate),
                channels: Int = WireFormat.channelCount,
                framesPerPacket: Int = WireFormat.framesPerPacket,
                streamID: UInt32) {
        self.v = v; self.token = token; self.name = name; self.rate = rate
        self.channels = channels; self.framesPerPacket = framesPerPacket
        self.streamID = streamID
    }
}

public struct GainMessage: Codable, Equatable, Sendable {
    public var linear: Double
    public var muted: Bool
    public init(linear: Double, muted: Bool) { self.linear = linear; self.muted = muted }
}

public struct LatencyMessage: Codable, Equatable, Sendable {
    public var targetMs: Int
    enum CodingKeys: String, CodingKey { case targetMs = "target_ms" }
    public init(targetMs: Int) { self.targetMs = targetMs }
}

public struct PingMessage: Codable, Equatable, Sendable {
    /// Sender monotonic ns at which this ping was written.
    public var t1: UInt64
    /// OPTIONAL extension to the v1 spec: the sender's `t4` (its receive
    /// timestamp) for the PREVIOUS pong. When present the receiver can close
    /// the NTP 4-timestamp loop itself instead of falling back to a one-way
    /// minimum-delay estimate. Absent = plain v1 sender, still works.
    public var prevT4: UInt64?

    enum CodingKeys: String, CodingKey { case t1, prevT4 = "prev_t4" }
    public init(t1: UInt64, prevT4: UInt64? = nil) { self.t1 = t1; self.prevT4 = prevT4 }
}

// MARK: - Receiver → sender

public struct HelloAckMessage: Codable, Equatable, Sendable {
    public var v: Int
    public var udpPort: Int
    public var device: String
    public var deviceUID: String
    public var hwVolume: Bool
    public var bufferMs: Int

    enum CodingKeys: String, CodingKey {
        case v
        case udpPort = "udp_port"
        case device
        case deviceUID = "device_uid"
        case hwVolume = "hw_volume"
        case bufferMs = "buffer_ms"
    }

    public init(v: Int = WireFormat.protocolVersion, udpPort: Int, device: String,
                deviceUID: String, hwVolume: Bool, bufferMs: Int) {
        self.v = v; self.udpPort = udpPort; self.device = device
        self.deviceUID = deviceUID; self.hwVolume = hwVolume; self.bufferMs = bufferMs
    }
}

public struct PongMessage: Codable, Equatable, Sendable {
    public var t1: UInt64
    public var t2: UInt64
    public var t3: UInt64
    public init(t1: UInt64, t2: UInt64, t3: UInt64) { self.t1 = t1; self.t2 = t2; self.t3 = t3 }
}

public struct StatsMessage: Codable, Equatable, Sendable {
    public var late: Int
    public var lost: Int
    public var underrun: Int
    public var bufferMs: Double
    public var ratio: Double
    public var clip: Int

    enum CodingKeys: String, CodingKey {
        case late, lost, underrun, ratio, clip
        case bufferMs = "buffer_ms"
    }

    public init(late: Int, lost: Int, underrun: Int, bufferMs: Double, ratio: Double, clip: Int) {
        self.late = late; self.lost = lost; self.underrun = underrun
        self.bufferMs = bufferMs; self.ratio = ratio; self.clip = clip
    }
}

public struct ErrorMessage: Codable, Equatable, Sendable {
    public var message: String
    public init(message: String) { self.message = message }
}

// MARK: - Envelope

public enum ControlMessage: Equatable, Sendable {
    case hello(HelloMessage)
    case gain(GainMessage)
    case latency(LatencyMessage)
    case ping(PingMessage)
    case bye
    case helloAck(HelloAckMessage)
    case pong(PongMessage)
    case stats(StatsMessage)
    case error(ErrorMessage)

    public var typeName: String {
        switch self {
        case .hello: return "hello"
        case .gain: return "gain"
        case .latency: return "latency"
        case .ping: return "ping"
        case .bye: return "bye"
        case .helloAck: return "hello_ack"
        case .pong: return "pong"
        case .stats: return "stats"
        case .error: return "error"
        }
    }
}

public enum ControlCodecError: Error, Equatable {
    case notJSONObject
    case missingType
    case unknownType(String)
    case malformedPayload(String)
}

/// Newline-delimited JSON codec for the TCP control channel.
///
/// Encoding merges `{"type": ...}` into the payload object by re-serialising,
/// which keeps the payload structs plain `Codable` and the wire shape flat as
/// the spec requires.
public enum ControlCodec {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        // Deterministic key order keeps the round-trip tests and the log
        // output readable; it costs nothing at one message per second.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func encode(_ message: ControlMessage) throws -> Data {
        var object: [String: Any]
        switch message {
        case .hello(let m):    object = try jsonObject(m)
        case .gain(let m):     object = try jsonObject(m)
        case .latency(let m):  object = try jsonObject(m)
        case .ping(let m):     object = try jsonObject(m)
        case .bye:             object = [:]
        case .helloAck(let m): object = try jsonObject(m)
        case .pong(let m):     object = try jsonObject(m)
        case .stats(let m):    object = try jsonObject(m)
        case .error(let m):    object = try jsonObject(m)
        }
        object["type"] = message.typeName
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data + Data([0x0A])
    }

    public static func encodeLine(_ message: ControlMessage) throws -> String {
        String(decoding: try encode(message), as: UTF8.self)
    }

    public static func decode(_ line: Data) throws -> ControlMessage {
        guard let any = try? JSONSerialization.jsonObject(with: line),
              let object = any as? [String: Any] else {
            throw ControlCodecError.notJSONObject
        }
        guard let type = object["type"] as? String else { throw ControlCodecError.missingType }
        switch type {
        case "hello":     return .hello(try decodePayload(line))
        case "gain":      return .gain(try decodePayload(line))
        case "latency":   return .latency(try decodePayload(line))
        case "ping":      return .ping(try decodePayload(line))
        case "bye":       return .bye
        case "hello_ack": return .helloAck(try decodePayload(line))
        case "pong":      return .pong(try decodePayload(line))
        case "stats":     return .stats(try decodePayload(line))
        case "error":     return .error(try decodePayload(line))
        default:          throw ControlCodecError.unknownType(type)
        }
    }

    public static func decode(line: String) throws -> ControlMessage {
        try decode(Data(line.utf8))
    }

    private static func decodePayload<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ControlCodecError.malformedPayload(String(describing: error))
        }
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try encoder.encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ControlCodecError.notJSONObject
        }
        return object
    }
}
