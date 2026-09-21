import XCTest
@testable import GlowTopCore

/// SPEC.md §13.5 items 1, 3, 4 and 9 for the disk provider. The arithmetic is a static pure
/// function, so the busy clamp and the wrap rejection are tested without touching a disk.
final class DiskProviderTests: XCTestCase {
    private func counters(
        bytesRead: UInt64 = 0, bytesWritten: UInt64 = 0,
        opsRead: UInt64 = 0, opsWritten: UInt64 = 0,
        timeRead: UInt64 = 0, timeWritten: UInt64 = 0,
        deviceCount: Int = 1
    ) -> DiskProvider.Counters {
        var c = DiskProvider.Counters()
        c.bytesRead = bytesRead
        c.bytesWritten = bytesWritten
        c.opsRead = opsRead
        c.opsWritten = opsWritten
        c.timeRead = timeRead
        c.timeWritten = timeWritten
        c.deviceCount = deviceCount
        return c
    }

    func testThroughputIsDeltaOverElapsed() {
        let sample = DiskProvider.rates(
            previous: counters(bytesRead: 1_000, bytesWritten: 2_000),
            current: counters(bytesRead: 5_000, bytesWritten: 4_000),
            seconds: 2
        )
        XCTAssertEqual(sample?.readBytesPerSecond, 2_000)
        XCTAssertEqual(sample?.writeBytesPerSecond, 1_000)
    }

    /// §5.3.2: busy is service time over wall time, as a percentage.
    func testBusyPercentIsServiceTimeOverWallTime() {
        // Half a second of service time in a one-second window is 50 %.
        let sample = DiskProvider.rates(
            previous: counters(timeRead: 0),
            current: counters(timeRead: 500_000_000),
            seconds: 1
        )
        XCTAssertEqual(try XCTUnwrap(sample?.busyPercent), 50, accuracy: 0.001)
    }

    /// §5.3.2: a device servicing overlapping requests can exceed 100 % of wall time, and
    /// clamping is the honest presentation at this resolution.
    func testBusyPercentClampsAtOneHundred() {
        let sample = DiskProvider.rates(
            previous: counters(timeRead: 0, timeWritten: 0),
            current: counters(timeRead: 3_000_000_000, timeWritten: 2_000_000_000),
            seconds: 1
        )
        XCTAssertEqual(sample?.busyPercent, 100, "5 s of service time in a 1 s window clamps, never reads 500 %")
    }

    /// §5.3.3: a missing `Total Time` key costs the busy percentage, not the throughput.
    func testMissingTimeKeysZeroBusyButKeepThroughput() {
        let sample = DiskProvider.rates(
            previous: counters(bytesRead: 0, timeRead: 0, timeWritten: 0),
            current: counters(bytesRead: 4_096, timeRead: 0, timeWritten: 0),
            seconds: 1
        )
        XCTAssertEqual(sample?.busyPercent, 0)
        XCTAssertEqual(sample?.readBytesPerSecond, 4_096, "throughput survives a missing time key")
    }

    /// §5.0.4: a counter going backwards — a device unplugged, a driver set changing —
    /// produces one `.warming`, never a negative or enormous rate.
    func testCounterGoingBackwardsIsRejected() {
        XCTAssertNil(DiskProvider.rates(
            previous: counters(bytesRead: 10_000),
            current: counters(bytesRead: 40),
            seconds: 1
        ))
    }

    func testServiceTimeGoingBackwardsIsRejected() {
        XCTAssertNil(DiskProvider.rates(
            previous: counters(timeWritten: 9_000),
            current: counters(timeWritten: 10),
            seconds: 1
        ))
    }

    func testZeroElapsedIsRejected() {
        XCTAssertNil(DiskProvider.rates(
            previous: counters(bytesRead: 0),
            current: counters(bytesRead: 100),
            seconds: 0
        ))
    }

    func testDeviceCountIsCarriedThrough() {
        let sample = DiskProvider.rates(
            previous: counters(deviceCount: 5),
            current: counters(deviceCount: 5),
            seconds: 1
        )
        XCTAssertEqual(sample?.deviceCount, 5)
    }

    // MARK: - Live provider

    func testFirstSampleWarms() {
        var provider = DiskProvider()
        guard case .warming = provider.sample() else {
            return XCTFail("first sample of a delta provider must be .warming (§5.0.3)")
        }
    }

    /// Any Mac has at least one `IOBlockStorageDriver`. If this ever returns nil the correct
    /// provider behaviour is `.unavailable("no matching IOService")`, not a zero reading.
    func testCountersReadFromTheRealMachine() throws {
        let counters = try XCTUnwrap(DiskProvider.readCounters(), "no IOBlockStorageDriver matched")
        XCTAssertGreaterThan(counters.deviceCount, 0)
        XCTAssertGreaterThan(counters.bytesRead, 0, "a booted machine has read something")
    }

    /// The IOKit leak §13.4 lists as a known trap: objects not released make RSS climb and
    /// then IOKit calls start failing. 400 iterations is 100 seconds of 4 Hz sampling; if
    /// services or the iterator leaked, the later calls would degrade or fail.
    func testRepeatedReadsDoNotExhaustIOKitObjects() throws {
        for _ in 0..<400 {
            XCTAssertNotNil(DiskProvider.readCounters())
        }
        let final = try XCTUnwrap(DiskProvider.readCounters())
        XCTAssertGreaterThan(final.deviceCount, 0, "IOKit still answering after 400 walks")
    }
}
