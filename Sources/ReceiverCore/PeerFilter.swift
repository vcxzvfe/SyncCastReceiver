import Foundation

/// Which peers may talk to the daemon at all.
///
/// The link is LAN-only by design: a receiver reachable from the internet
/// would be an open audio sink and an open UDP amplifier. Anything that is
/// not RFC1918 private, link-local, loopback, or IPv6 unique-local /
/// link-local is refused before the token is even looked at.
public enum PeerFilter {

    public static func isAllowed(address: String) -> Bool {
        let host = normalise(address)
        if let v4 = IPv4Address(host) { return isPrivateIPv4(v4) }
        if let v6 = IPv6Bytes(host) { return isPrivateIPv6(v6) }
        return false
    }

    /// Strip a `%en0` scope id and a `[…]:port` wrapper, which is how
    /// Network.framework renders endpoints.
    public static func normalise(_ address: String) -> String {
        var host = address
        if host.hasPrefix("[") , let close = host.firstIndex(of: "]") {
            host = String(host[host.index(after: host.startIndex)..<close])
        } else if host.contains("."), let colon = host.lastIndex(of: ":"),
                  host.firstIndex(of: ":") == colon {
            host = String(host[host.startIndex..<colon])   // "a.b.c.d:port"
        }
        if let pct = host.firstIndex(of: "%") { host = String(host[host.startIndex..<pct]) }
        return host
    }

    private static func isPrivateIPv4(_ a: IPv4Address) -> Bool {
        switch (a.b0, a.b1) {
        case (10, _): return true                      // 10.0.0.0/8
        case (127, _): return true                     // loopback
        case (169, 254): return true                   // link-local
        case (172, 16...31): return true               // 172.16.0.0/12
        case (192, 168): return true                   // 192.168.0.0/16
        default: return false
        }
    }

    private static func isPrivateIPv6(_ b: [UInt8]) -> Bool {
        if b == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }   // ::1
        if b[0] == 0xFE && (b[1] & 0xC0) == 0x80 { return true }                    // fe80::/10
        if (b[0] & 0xFE) == 0xFC { return true }                                    // fc00::/7 ULA
        // IPv4-mapped (::ffff:a.b.c.d) — judge by the embedded v4 address.
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {
            return isPrivateIPv4(IPv4Address(b0: b[12], b1: b[13], b2: b[14], b3: b[15]))
        }
        return false
    }

    struct IPv4Address {
        let b0: UInt8, b1: UInt8, b2: UInt8, b3: UInt8
        init(b0: UInt8, b1: UInt8, b2: UInt8, b3: UInt8) {
            self.b0 = b0; self.b1 = b1; self.b2 = b2; self.b3 = b3
        }
        init?(_ text: String) {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 4 else { return nil }
            var bytes = [UInt8]()
            for p in parts {
                guard let v = UInt16(p), v <= 255, !p.isEmpty else { return nil }
                bytes.append(UInt8(v))
            }
            self.init(b0: bytes[0], b1: bytes[1], b2: bytes[2], b3: bytes[3])
        }
    }

    static func IPv6Bytes(_ text: String) -> [UInt8]? {
        var storage = in6_addr()
        let ok = text.withCString { cstr in
            inet_pton(AF_INET6, cstr, &storage) == 1
        }
        guard ok else { return nil }
        return withUnsafeBytes(of: &storage) { Array($0) }
    }
}
