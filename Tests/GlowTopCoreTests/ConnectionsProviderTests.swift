import Darwin
import XCTest
@testable import GlowTopCore

/// 2.1's decode, fixture-driven -- no live sockets needed for `decode(_:pid:fd:processName:)`
/// itself; `fetchSocketInfo` (the syscall) is exercised only by the live check recorded in
/// `## What was built` and by 2.2's probe arm.
final class ConnectionsProviderTests: XCTestCase {
    func testTcpStateNamesMatchLsofSpellingForAllTwelveValues() {
        let expected = [
            "CLOSED", "LISTEN", "SYN_SENT", "SYN_RCVD", "ESTABLISHED", "CLOSE_WAIT",
            "FIN_WAIT_1", "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT", "RESERVED",
        ]
        for (state, name) in expected.enumerated() {
            XCTAssertEqual(ConnectionsProvider.tcpStateName(state), name)
        }
        XCTAssertEqual(ConnectionsProvider.tcpStateName(12), "state 12")
    }

    func testIPv4AddressRoundTripsThroughInetNtop() {
        var addr4 = in_addr()
        addr4.s_addr = inet_addr("127.0.0.1")
        let ina46 = in4in6_addr(i46a_pad32: (0, 0, 0), i46a_addr4: addr4)
        let (text, scope) = ConnectionsProvider.address(ina46: ina46, ina6: in6_addr(), isIPv6: false, ifindex: 0)
        XCTAssertEqual(text, "127.0.0.1")
        XCTAssertEqual(scope, "")
    }

    func testIPv6LinkLocalCarriesItsScope() {
        // `lo0` always exists on macOS, so this is a real, deterministic interface index --
        // no mock of `if_indextoname` is needed.
        let index = if_nametoindex("lo0")
        XCTAssertNotEqual(index, 0, "lo0 should exist on any Mac")
        var addr6 = in6_addr()
        withUnsafeMutableBytes(of: &addr6) { raw in
            raw[0] = 0xfe
            raw[1] = 0x80
            raw[15] = 0x01
        }
        let (text, scope) = ConnectionsProvider.address(
            ina46: in4in6_addr(), ina6: addr6, isIPv6: true, ifindex: UInt16(index)
        )
        XCTAssertTrue(text.hasPrefix("fe80"), "got \(text)")
        XCTAssertEqual(scope, "lo0")
    }

    func testUDPRowsCarryNoTcpState() {
        var info = socket_fdinfo()
        info.psi.soi_kind = Int32(SOCKINFO_IN)
        info.psi.soi_protocol = IPPROTO_UDP
        info.psi.soi_proto.pri_in.insi_lport = Int32(UInt16(53).bigEndian)
        let row = ConnectionsProvider.decode(info, pid: 1, fd: 4, processName: "mDNSResponder")
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.transport, .udp)
        XCTAssertNil(row?.tcpState)
        XCTAssertEqual(row?.localPort, 53)
    }

    func testNonSocketAndNonTcpUdpKindsAreSkipped() {
        var unInfo = socket_fdinfo()
        unInfo.psi.soi_kind = Int32(SOCKINFO_UN)
        XCTAssertNil(ConnectionsProvider.decode(unInfo, pid: 1, fd: 1, processName: "x"))

        var kernInfo = socket_fdinfo()
        kernInfo.psi.soi_kind = Int32(SOCKINFO_KERN_EVENT)
        XCTAssertNil(ConnectionsProvider.decode(kernInfo, pid: 1, fd: 2, processName: "x"))
    }

    func testFirstSampleIsLiveNotWarming() {
        // Unlike every `MetricProvider`, this reader has no delta arithmetic, so its first
        // sample is `.value`, never `.warming` -- the one place this type's contract differs
        // from every provider before it.
        var provider = ConnectionsProvider()
        switch provider.sample() {
        case .value: break
        case .warming: XCTFail("first sample should not be .warming")
        case .unavailable(let reason): XCTFail("first sample unavailable: \(reason)")
        }
    }
}
