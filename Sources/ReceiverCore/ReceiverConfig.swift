import Foundation

/// Persisted daemon settings: the pairing token plus the last-used device and
/// friendly name, so a `launchctl` restart comes back identical.
///
/// Stored 0600 in `~/Library/Application Support/SyncCastReceiver/config.json`
/// — it holds the shared secret for the link.
public struct ReceiverConfig: Codable, Equatable, Sendable {
    public var token: String
    /// Device UID or name substring chosen with `--device`, nil = default.
    public var device: String?
    public var name: String

    public init(token: String, device: String? = nil, name: String) {
        self.token = token
        self.device = device
        self.name = name
    }

    /// 8 hex characters advertised in the Bonjour TXT record so the sender
    /// can tell two receivers apart before pairing. It is a hint, never the
    /// credential: `hello` must carry the full token.
    public var tokenHint: String { String(token.prefix(8)) }

    /// 128 bits from the system CSPRNG, hex encoded.
    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let fd = open("/dev/urandom", O_RDONLY)
        var filled = false
        if fd >= 0 {
            defer { close(fd) }
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            filled = (n == bytes.count)
        }
        if !filled {
            // `random(in:)` is backed by the system CSPRNG on Darwin; this is
            // the fallback path only if /dev/urandom is somehow unavailable.
            for i in 0..<bytes.count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time comparison: the token check is the only thing between a
    /// LAN peer and the speakers, so it must not leak its prefix by timing.
    public func matches(token candidate: String) -> Bool {
        let a = Array(token.utf8), b = Array(candidate.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

public enum ConfigStoreError: Error {
    case unreadable(URL, Error)
    case unwritable(URL, Error)
    case malformed(URL, Error)
}

/// Load/save with the 0600 + 0700 permissions the token deserves.
public struct ConfigStore: Sendable {
    public let paths: ReceiverPaths

    public init(paths: ReceiverPaths = ReceiverPaths()) { self.paths = paths }

    public func loadIfPresent() throws -> ReceiverConfig? {
        let url = paths.configURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw ConfigStoreError.unreadable(url, error) }
        do { return try JSONDecoder().decode(ReceiverConfig.self, from: data) }
        catch { throw ConfigStoreError.malformed(url, error) }
    }

    public func save(_ config: ReceiverConfig) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: paths.supportDirectory,
                                   withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.supportDirectory.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: paths.configURL, options: [.atomic])
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configURL.path)
        } catch {
            throw ConfigStoreError.unwritable(paths.configURL, error)
        }
    }

    /// Load, or create-and-persist a fresh config on first run.
    public func loadOrCreate(name: String, device: String?) throws -> ReceiverConfig {
        if var existing = try loadIfPresent() {
            var changed = false
            if existing.name != name { existing.name = name; changed = true }
            if existing.device != device { existing.device = device; changed = true }
            if existing.token.count < 16 {
                existing.token = ReceiverConfig.generateToken()
                changed = true
            }
            if changed { try save(existing) }
            return existing
        }
        let fresh = ReceiverConfig(token: ReceiverConfig.generateToken(), device: device, name: name)
        try save(fresh)
        return fresh
    }
}
