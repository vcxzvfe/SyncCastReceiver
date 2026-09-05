import Foundation
import Network

/// Host-string extraction for the peer filter, kept in one place because
/// Network.framework and BSD sockets describe the same address differently.
public enum NetworkEndpointHost {

    public static func host(of endpoint: NWEndpoint?) -> String? {
        guard let endpoint else { return nil }
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let v4): return trimmedDescription(v4)
        case .ipv6(let v6): return trimmedDescription(v6)
        case .name(let name, _): return name
        @unknown default: return nil
        }
    }

    /// Presentation form of a `sockaddr_storage` (the UDP peer).
    public static func host(of storage: sockaddr_storage) -> String? {
        var copy = storage
        let length = socklen_t(copy.ss_len)
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let ok = buffer.withUnsafeMutableBufferPointer { host -> Bool in
            withUnsafePointer(to: &copy) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, length, host.baseAddress, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
                }
            }
        }
        guard ok else { return nil }
        return String(cString: buffer)
    }

    public static func port(of storage: sockaddr_storage) -> UInt16 {
        var copy = storage
        let family = Int32(copy.ss_family)
        return withUnsafePointer(to: &copy) { pointer in
            switch family {
            case AF_INET:
                return pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin_port)
                }
            case AF_INET6:
                return pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    UInt16(bigEndian: $0.pointee.sin6_port)
                }
            default:
                return 0
            }
        }
    }

    /// `NWEndpoint`'s IP descriptions carry a `%interface` suffix.
    private static func trimmedDescription(_ address: CustomDebugStringConvertible) -> String {
        let text = String(describing: address)
        if let pct = text.firstIndex(of: "%") { return String(text[text.startIndex..<pct]) }
        return text
    }
}
