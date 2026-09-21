import XCTest
@testable import GlowTopCore

/// SPEC.md §5.6.3 (package power) and §5.6.4 (the ANE). The unit conversion and channel
/// selection are static pure functions, tested from fixture `IOReportChannel`s with no
/// hardware.
final class EnergyProviderTests: XCTestCase {
    private func channel(_ name: String, unit: String, value: Int64) -> IOReportChannel {
        IOReportChannel(group: "Energy Model", subGroup: "", name: name, unit: unit, states: [], value: value)
    }

    func testMilliJoulesConvertToJoules() {
        XCTAssertEqual(EnergyProvider.joules(1_500, unit: "mJ"), 1.5)
    }

    func testNanoJoulesConvertToJoules() {
        XCTAssertEqual(EnergyProvider.joules(1_500_000_000, unit: "nJ"), 1.5)
    }

    func testUnknownUnitLabelExcludesTheChannel() {
        XCTAssertNil(EnergyProvider.joules(1_500, unit: "ticks"))

        let channels = [channel("CPU Energy", unit: "wat", value: 1_000)]
        let composed = EnergyProvider.compose(channels: channels, seconds: 1)
        XCTAssertNil(composed, "no target channel converted -- nothing to report")
    }

    /// The single most likely way this provider ships a plausible wrong wattage: the group
    /// carries both `GPU` (mJ) and `GPU Energy` (nJ), a million units apart.
    func testGPUAndGPUEnergyAreNotBothSummed() throws {
        let channels = [
            channel("CPU Energy", unit: "mJ", value: 1_000),
            channel("GPU", unit: "mJ", value: 500),
            channel("GPU Energy", unit: "nJ", value: 999_999_999_999), // would swamp the sum if included
            channel("ANE", unit: "mJ", value: 100),
        ]
        let composed = try XCTUnwrap(EnergyProvider.compose(channels: channels, seconds: 1))
        XCTAssertEqual(composed.gpuWatts, 0.5)
        XCTAssertFalse(composed.contributingChannels.contains("GPU Energy"))
        XCTAssertEqual(composed.watts, 1.6, accuracy: 0.0001, "1.0 (CPU) + 0.5 (GPU) + 0.1 (ANE), never the nJ channel")
    }

    func testPowerAboveTwoHundredWattsIsUnavailableNotClamped() {
        XCTAssertFalse(EnergyProvider.isWithinPowerRange(200.1))
        XCTAssertTrue(EnergyProvider.isWithinPowerRange(200))
        XCTAssertTrue(EnergyProvider.isWithinPowerRange(0))
    }

    /// §5.0.4: a negative delta (a reset or wrapped counter) warms the whole sample rather
    /// than silently excluding one channel.
    func testNegativeEnergyDeltaWarms() {
        let channels = [channel("CPU Energy", unit: "mJ", value: -5)]
        XCTAssertNil(EnergyProvider.compose(channels: channels, seconds: 1))
    }

    func testANECeilingIsNamedAndProvisional() {
        XCTAssertEqual(EnergyProvider.provisionalANECeilingWatts, 8.0)
    }

    func testANEUtilizationFallsBackToPowerOverCeilingWhenNoResidencyChannel() {
        let result = EnergyProvider.aneUtilization(channels: [], aneWatts: 4.0)
        XCTAssertEqual(result.utilization, 0.5)
        XCTAssertEqual(result.source, "power/8W")
    }

    // MARK: - §14.1's DRAM band (phase-11, D-07)

    /// D-07 held exactly: DRAM is read, and the tile's sum and tooltip list do not move.
    func testDRAMIsReadBesideTheHeadlineAndNotIntoIt() throws {
        let channels = [
            channel("CPU Energy", unit: "mJ", value: 3_000),
            channel("GPU", unit: "mJ", value: 900),
            channel("ANE", unit: "mJ", value: 0),
            channel("DRAM", unit: "mJ", value: 1_200),
        ]
        let composed = try XCTUnwrap(EnergyProvider.compose(channels: channels, seconds: 1))
        XCTAssertEqual(composed.watts, 3.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(composed.dramWatts), 1.2, accuracy: 1e-9)
        XCTAssertEqual(composed.contributingChannels, ["CPU Energy", "GPU", "ANE"])
    }

    func testDRAMAbsentLeavesDramWattsNilAndTheSumUnchanged() throws {
        let channels = [
            channel("CPU Energy", unit: "mJ", value: 3_000),
            channel("GPU", unit: "mJ", value: 900),
            channel("ANE", unit: "mJ", value: 0),
        ]
        let composed = try XCTUnwrap(EnergyProvider.compose(channels: channels, seconds: 1))
        XCTAssertEqual(composed.watts, 3.9, accuracy: 1e-9)
        XCTAssertNil(composed.dramWatts)
        XCTAssertEqual(composed.contributingChannels, ["CPU Energy", "GPU", "ANE"])
    }

    // MARK: - Live provider

    func testFirstSampleWarms() {
        var provider = EnergyProvider()
        guard case .warming = provider.sample() else {
            return XCTFail("first sample of a delta provider must be .warming (§5.0.3)")
        }
    }
}
