import XCTest
@testable import GlowTopCore

/// SPEC.md §9.2's parsers, all pure and run from fixture inputs -- no sysctl, no IOKit, no
/// live process in this file.
final class SystemInfoReaderTests: XCTestCase {
    // MARK: - Kernel version

    func testKernelVersionIsFirstLineOnly() {
        let raw = "Darwin Kernel Version 25.6.0: Mon Jul 1 00:00:00 PDT 2026\n" +
            "root:xnu-1234.56.7~1/RELEASE_ARM64_T6031\n"
        XCTAssertEqual(
            SystemInfoReader.firstLine(raw), "Darwin Kernel Version 25.6.0: Mon Jul 1 00:00:00 PDT 2026"
        )
    }

    // MARK: - Uptime

    func testUptimeFromFixtureBoottime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let boot = now.addingTimeInterval(-3700) // 1h 1m 40s ago
        XCTAssertEqual(SystemInfoReader.uptimeText(bootDate: boot, now: now), "1h 1m")
    }

    // MARK: - Core split

    func testCoreSplitRendersSpecString() {
        XCTAssertEqual(
            SystemInfoReader.coreSplitText(logical: 14, performance: 10, efficiency: 4),
            "14 (10 performance, 4 efficiency)"
        )
    }

    // MARK: - Swap (§5.2.3's existing composition, passed in rather than re-read)

    func testSwapParsesFromFixtureXswUsage() {
        var reader = SystemInfoReader()
        let memory = MemorySample(
            resident: 0, reclaimable: 0, free: 0, total: 100, active: 0, wired: 0,
            compressed: 0, swapUsed: 123_456_789, pageSize: 16384,
            inactive: 0, purgeable: 0, speculative: 0, cached: 0
        )
        let live = reader.liveRows(memory: memory, health: [], frameRate: nil)
        let swapRow = live.memoryAndStorage.first(where: { $0.label == "Swap used" })
        XCTAssertEqual(swapRow?.value, Format.bytes(123_456_789))
    }

    // MARK: - §9.2's Frame rate row

    func testFrameRateTextTruncatesAgeAndRoundsRate() {
        let sampledAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            SystemInfoReader.frameRateText(fps: 99.94, sampledAt: sampledAt,
                                           now: sampledAt.addingTimeInterval(14.6)),
            "99.9 fps · Summary, 14 s ago"
        )
    }

    func testFrameRateTextUsesDurationFormatPastOneMinute() {
        let sampledAt = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            SystemInfoReader.frameRateText(fps: 60, sampledAt: sampledAt,
                                           now: sampledAt.addingTimeInterval(75)),
            "60.0 fps · Summary, 1m 15s ago"
        )
    }

    /// The row that proves "render what is available" rather than "render nothing": with no
    /// memory sample yet, the three memory rows read `—` and Uptime still populates.
    func testLiveRowsRenderWithoutMemorySample() {
        var reader = SystemInfoReader()
        let live = reader.liveRows(memory: nil, health: [], frameRate: nil)

        for label in ["Memory in use", "Memory pressure", "Swap used"] {
            let row = live.memoryAndStorage.first(where: { $0.label == label })
            XCTAssertEqual(row?.value, Format.unknown, "\(label) should read \(Format.unknown)")
            XCTAssertNil(row?.colorToken, "\(label) should carry no colour when there is no reading")
        }

        let frameRate = live.glowTop.first(where: { $0.label == "Frame rate" })
        XCTAssertEqual(frameRate?.value, Format.unknown)

        XCTAssertNotEqual(live.uptime.value, Format.unknown,
                          "Uptime does not depend on the memory sample and must still render")
    }

    // MARK: - Memory pressure bucket (§5.2.3: green < 0.60, yellow 0.60-0.80, red > 0.80)

    func testMemoryPressureBucketThresholds() {
        XCTAssertEqual(SystemInfoReader.pressureBucket(0.10).token, "textPrimary")
        XCTAssertEqual(SystemInfoReader.pressureBucket(0.60).token, "warning")
        XCTAssertEqual(SystemInfoReader.pressureBucket(0.79).token, "warning")
        XCTAssertEqual(SystemInfoReader.pressureBucket(0.81).token, "critical")
    }

    // MARK: - Providers row

    func testProvidersTextCountsHealthyAndUnavailable() {
        let health: [ProviderHealth] = [
            ProviderHealth(id: .cpu, state: .live),
            ProviderHealth(id: .gpu, state: .unavailable(reason: "private APIs disabled")),
        ]
        XCTAssertEqual(SystemInfoReader.providersText(health), "1 healthy · 1 unavailable")
        XCTAssertEqual(SystemInfoReader.providersTooltip(health), "gpu: private APIs disabled")
    }
}
