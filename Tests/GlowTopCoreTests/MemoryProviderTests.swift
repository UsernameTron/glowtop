import XCTest
@testable import GlowTopCore

/// The phase-02 additions to §5.2. Total, page size, the sum check and pressure bounds are
/// already covered by `MemoryProviderTests` in `CoreTypesTests.swift` and are not repeated.
///
/// Memory is an absolute gauge, not a delta, so §13.5's items 3 and 4 do not apply — it never
/// warms and has no baseline to divide by.
final class MemoryCompositionTests: XCTestCase {
    /// §4.5's timeline stacks Wired, Active, Compressed and Cached/inactive as four separate
    /// bands. Before phase-02 the payload exposed only the lumped `reclaimable`, so the
    /// fourth band could not be drawn at all, and `external_page_count` — named in §5.2.2's
    /// list of eight fields — was never read.
    func testTheFourChartSeriesAreIndividuallyAddressable() throws {
        var provider = MemoryProvider()
        let sample = try XCTUnwrap(provider.sample().payload)
        XCTAssertGreaterThan(sample.wired, 0)
        XCTAssertGreaterThan(sample.active, 0)
        XCTAssertGreaterThan(sample.compressed, 0)
        XCTAssertGreaterThan(sample.inactive, 0)
        XCTAssertGreaterThan(sample.cached, 0, "external_page_count, §5.2.2's cached figure")
    }

    /// §5.2.3 defines reclaimable as exactly these two terms, so the aggregate and its parts
    /// cannot drift apart once both are exposed. `purgeable` is not one of them: it is an
    /// overlay on the active/inactive/speculative queues, reported in the payload and never
    /// summed.
    func testReclaimableIsTheSumOfItsTwoParts() throws {
        var provider = MemoryProvider()
        let sample = try XCTUnwrap(provider.sample().payload)
        XCTAssertEqual(sample.reclaimable, sample.inactive + sample.speculative)
    }

    /// What made this a defect rather than a definition: summing `purgeable_count` as a fourth
    /// pool double-counts pages already on the queues, and the only headroom under `hw.memsize`
    /// is the ~0.69 GiB firmware carve-out `vm_statistics64` never reports — so `compose`
    /// refused outright whenever purgeable exceeded it. These five counts sum to exactly
    /// 3_145_728 pages (48 GiB at 16384 bytes) and purgeable rides on top of them. **This test
    /// fails on the pre-fix sum and passes after it.**
    func testPurgeableIsAnOverlayNotAPool() throws {
        var stats = vm_statistics64()
        stats.free_count = 60_000            // free_count includes speculative pages
        stats.speculative_count = 12_000
        stats.active_count = 1_300_000
        stats.inactive_count = 1_200_000
        stats.wire_count = 300_000
        stats.compressor_page_count = 285_728
        stats.purgeable_count = 325_000      // an overlay on active/inactive/speculative

        let provider = MemoryProvider(total: 3_145_728 * 16384, pageSize: 16384)
        let sample = try XCTUnwrap(
            provider.compose(stats),
            "purgeable is an overlay on the queues; summing it as a pool exceeds total"
        )
        XCTAssertEqual(sample.reclaimable, sample.inactive + sample.speculative)
        XCTAssertLessThanOrEqual(sample.resident + sample.reclaimable + sample.free, sample.total)
        XCTAssertEqual(sample.purgeable, 325_000 * 16384, "still reported, just not summed")
    }

    /// §5.2.3 defines resident as exactly these three terms.
    func testResidentIsTheSumOfItsThreeParts() throws {
        var provider = MemoryProvider()
        let sample = try XCTUnwrap(provider.sample().payload)
        XCTAssertEqual(sample.resident, sample.active + sample.wired + sample.compressed)
    }

    /// §5.2.3: pressure is GlowTop's own quantity, (wired + compressed) / total, and is
    /// explicitly not a reproduction of the macOS pressure indicator.
    func testPressureIsWiredPlusCompressedOverTotal() {
        let sample = MemorySample(
            resident: 0, reclaimable: 0, free: 0, total: 100,
            active: 0, wired: 30, compressed: 20, swapUsed: 0, pageSize: 16384,
            inactive: 0, purgeable: 0, speculative: 0, cached: 0
        )
        XCTAssertEqual(sample.pressure, 0.5, accuracy: 0.0001)
    }

    func testPressureIsZeroRatherThanNaNWhenTotalIsZero() {
        let sample = MemorySample(
            resident: 0, reclaimable: 0, free: 0, total: 0,
            active: 0, wired: 1, compressed: 1, swapUsed: 0, pageSize: 16384,
            inactive: 0, purgeable: 0, speculative: 0, cached: 0
        )
        XCTAssertEqual(sample.pressure, 0)
    }

    /// Memory is a gauge, so unlike CPU, disk and network it must produce a value on its very
    /// first sample rather than warming.
    func testFirstSampleIsAValueNotWarming() {
        var provider = MemoryProvider()
        guard case .value = provider.sample() else {
            return XCTFail("memory is absolute, not a delta — it must not warm")
        }
    }
}
