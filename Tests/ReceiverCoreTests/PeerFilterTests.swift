import XCTest
@testable import ReceiverCore

final class PeerFilterTests: XCTestCase {

    func testAcceptsPrivateIPv4() {
        for host in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254",
                     "192.168.1.42", "169.254.10.20", "127.0.0.1"] {
            XCTAssertTrue(PeerFilter.isAllowed(address: host), "\(host) should be allowed")
        }
    }

    func testRejectsPublicIPv4() {
        for host in ["192.0.2.10", "203.0.113.5", "8.8.8.8", "172.15.0.1", "172.32.0.1",
                     "192.169.1.1", "11.0.0.1", "0.0.0.0"] {
            XCTAssertFalse(PeerFilter.isAllowed(address: host), "\(host) should be refused")
        }
    }

    func testAcceptsPrivateIPv6() {
        for host in ["fe80::1", "fe80::c0a8:1%en0", "fd00::1234", "fc00::1", "::1"] {
            XCTAssertTrue(PeerFilter.isAllowed(address: host), "\(host) should be allowed")
        }
    }

    func testRejectsPublicIPv6() {
        for host in ["2001:db8::1", "2606:4700::1111", "::"] {
            XCTAssertFalse(PeerFilter.isAllowed(address: host), "\(host) should be refused")
        }
    }

    func testHandlesEndpointFormatting() {
        XCTAssertTrue(PeerFilter.isAllowed(address: "192.168.1.5:47100"))
        XCTAssertTrue(PeerFilter.isAllowed(address: "[fe80::1%en0]:47100"))
        XCTAssertFalse(PeerFilter.isAllowed(address: "[2001:db8::1]:47100"))
        XCTAssertEqual(PeerFilter.normalise("[fe80::1%en0]:47100"), "fe80::1")
        XCTAssertEqual(PeerFilter.normalise("192.168.1.5:47100"), "192.168.1.5")
    }

    func testIPv4MappedIPv6IsJudgedByTheEmbeddedAddress() {
        XCTAssertTrue(PeerFilter.isAllowed(address: "::ffff:192.168.1.10"))
        XCTAssertFalse(PeerFilter.isAllowed(address: "::ffff:203.0.113.10"))
    }

    func testRejectsGarbage() {
        for host in ["", "hostname.local", "999.1.1.1", "1.2.3", "1.2.3.4.5", "notanaddress"] {
            XCTAssertFalse(PeerFilter.isAllowed(address: host), "\(host) should be refused")
        }
    }
}
