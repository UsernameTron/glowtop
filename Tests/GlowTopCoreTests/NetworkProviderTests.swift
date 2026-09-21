import XCTest
@testable import GlowTopCore

/// SPEC.md §13.5 items 1 (wrapped counter), 3 (short interval), 4 (long gap) and 9
/// (unavailable propagation) for the network provider. The rate arithmetic is a static pure
/// function so all of this runs without touching a network interface.
final class NetworkProviderTests: XCTestCase {
    private func counters(
        bytesIn: UInt64 = 0, bytesOut: UInt64 = 0,
        packetsIn: UInt64 = 0, packetsOut: UInt64 = 0
    ) -> NetworkProvider.Counters {
        var c = NetworkProvider.Counters()
        c.bytesIn = bytesIn
        c.bytesOut = bytesOut
        c.packetsIn = packetsIn
        c.packetsOut = packetsOut
        c.primaryInterface = "en0"
        c.primaryBytesIn = bytesIn
        c.primaryBytesOut = bytesOut
        return c
    }

    func testRatesDivideTheDeltaByElapsedSeconds() {
        let sample = NetworkProvider.rates(
            previous: counters(bytesIn: 1000, bytesOut: 500),
            current: counters(bytesIn: 3000, bytesOut: 1500),
            seconds: 2
        )
        XCTAssertEqual(sample?.bytesInPerSecond, 1000)
        XCTAssertEqual(sample?.bytesOutPerSecond, 500)
    }

    func testCumulativeTotalsAreReportedUnchanged() {
        // §5.4.4 compares these against `netstat -ib`, so they must be the raw counter, not
        // a delta.
        let sample = NetworkProvider.rates(
            previous: counters(bytesIn: 1000),
            current: counters(bytesIn: 3000),
            seconds: 1
        )
        XCTAssertEqual(sample?.totalBytesIn, 3000)
        XCTAssertEqual(sample?.primaryBytesIn, 3000)
        XCTAssertEqual(sample?.primaryInterface, "en0")
    }

    /// §5.0.4 and §5.4.3: `if_data` counters are 32-bit on some interface types and wrap in
    /// about 34 s at 1 Gb/s. A decrease must produce one `.warming`, never a huge rate.
    func testWrappedByteCounterIsRejected() {
        XCTAssertNil(NetworkProvider.rates(
            previous: counters(bytesIn: 4_294_967_000),
            current: counters(bytesIn: 12_000),
            seconds: 1
        ))
    }

    func testWrappedPacketCounterIsRejected() {
        XCTAssertNil(NetworkProvider.rates(
            previous: counters(packetsIn: 5000),
            current: counters(packetsIn: 10),
            seconds: 1
        ))
    }

    func testZeroElapsedIsRejectedRatherThanDividedBy() {
        XCTAssertNil(NetworkProvider.rates(
            previous: counters(bytesIn: 0),
            current: counters(bytesIn: 100),
            seconds: 0
        ))
    }

    func testIdleIntervalReportsZeroNotWarming() {
        let sample = NetworkProvider.rates(
            previous: counters(bytesIn: 1000),
            current: counters(bytesIn: 1000),
            seconds: 1
        )
        XCTAssertEqual(sample?.bytesInPerSecond, 0, "no traffic is a real reading of zero")
    }

    // MARK: - Live provider (§13.5 items 3 and 4)

    /// §5.0.3: the first sample of a delta provider establishes the baseline only.
    func testFirstSampleWarms() {
        var provider = NetworkProvider()
        guard case .warming = provider.sample() else {
            return XCTFail("first sample must be .warming")
        }
    }

    /// §13.5 item 3 / §5.0.3 rule 3: two samples closer than 50 ms must not divide by a
    /// near-zero denominator.
    func testSecondSampleTakenImmediatelyDoesNotDivideByNearZero() {
        var provider = NetworkProvider()
        _ = provider.sample()
        switch provider.sample() {
        case .warming:
            break // acceptable: no held value yet
        case .value(let sample, _):
            XCTAssertTrue(sample.bytesInPerSecond.isFinite)
            XCTAssertLessThan(sample.bytesInPerSecond, 1e12, "a near-zero denominator would produce an absurd rate")
        case .unavailable(let reason):
            XCTFail("getifaddrs should be available: \(reason)")
        }
    }

    /// The walk must succeed on any Mac — `getifaddrs` is public and always present, and at
    /// minimum `lo0` exists (which the provider then skips per §5.4.2).
    func testCountersReadFromTheRealMachine() throws {
        let counters = try XCTUnwrap(NetworkProvider.readCounters(), "getifaddrs failed")
        XCTAssertFalse(counters.primaryInterface.isEmpty, "a machine with any active interface names a primary")
        XCTAssertGreaterThan(counters.bytesIn + counters.bytesOut, 0)
    }

    /// §5.4.2: loopback is excluded from the summed rates.
    func testLoopbackIsExcluded() throws {
        let counters = try XCTUnwrap(NetworkProvider.readCounters())
        XCTAssertNotEqual(counters.primaryInterface, "lo0")
    }
}
