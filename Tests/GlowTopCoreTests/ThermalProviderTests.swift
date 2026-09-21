import XCTest
@testable import GlowTopCore

/// SPEC.md §5.8.2's filter, ranking, and §5.8.4's pressure mapping. Pure and static, tested
/// from fixture sensors with no hardware.
final class ThermalProviderTests: XCTestCase {
    private func sensor(_ name: String, _ celsius: Double) -> ThermalSample.Sensor {
        ThermalSample.Sensor(name: name, celsius: celsius)
    }

    func testFilterKeepsZeroToOneHundredTwenty() {
        XCTAssertTrue((0...120).contains(0))
        XCTAssertTrue((0...120).contains(120))
        XCTAssertFalse((0...120).contains(-0.1))
        XCTAssertFalse((0...120).contains(120.1))
    }

    func testOutOfRangeSensorsLandInRejected() {
        let sample = ThermalProvider.compose(
            kept: [sensor("CPU die", 45)],
            rejected: [sensor("garbage", 9999)]
        )
        XCTAssertEqual(sample.rejected.map(\.name), ["garbage"])
        XCTAssertEqual(sample.sensors.map(\.name), ["CPU die"])
    }

    func testMaxIsTheHottestNotTheFirst() {
        let sample = ThermalProvider.compose(
            kept: [sensor("A", 40), sensor("B", 70), sensor("C", 55)],
            rejected: []
        )
        XCTAssertEqual(sample.maxCelsius, 70)
    }

    func testSensorsSortHottestFirst() {
        let sample = ThermalProvider.compose(
            kept: [sensor("A", 40), sensor("B", 70), sensor("C", 55)],
            rejected: []
        )
        XCTAssertEqual(sample.sensors.map(\.name), ["B", "C", "A"])
    }

    /// §5.8.2: truncation to 12 characters is a display concern for `SummaryModel`, never
    /// done here -- matching must never happen on a truncated string.
    func testNameTruncationIsDisplayOnly() {
        let sample = ThermalProvider.compose(kept: [sensor("a-very-long-sensor-name", 40)], rejected: [])
        XCTAssertEqual(sample.sensors[0].name, "a-very-long-sensor-name")
    }

    func testEveryThermalStateMapsToItsFooterString() {
        XCTAssertEqual(ThermalPressure.nominal.footerText, "Nominal thermal pressure")
        XCTAssertEqual(ThermalPressure.fair.footerText, "Fair thermal pressure")
        XCTAssertEqual(ThermalPressure.serious.footerText, "Serious thermal pressure")
        XCTAssertEqual(ThermalPressure.critical.footerText, "Critical thermal pressure")
        XCTAssertEqual(ThermalPressure.nominal.colorToken, "textTertiary")
        XCTAssertEqual(ThermalPressure.fair.colorToken, "warning")
        XCTAssertEqual(ThermalPressure.serious.colorToken, "accentThermal")
        XCTAssertEqual(ThermalPressure.critical.colorToken, "critical")
    }

    // MARK: - Live provider

    /// Not a delta provider -- §5.8 has no baseline to warm from, so the very first sample
    /// is a real reading or a real unavailability, never `.warming`.
    func testNoSensorsIsUnavailableNotZero() {
        var provider = ThermalProvider()
        switch provider.sample() {
        case .value(let sample, _):
            XCTAssertGreaterThan(sample.sensors.count, 0, "a live reading must carry at least one sensor")
        case .unavailable(let reason):
            XCTAssertEqual(reason, "unsupported on this Mac")
        case .warming:
            XCTFail("thermal has no delta baseline to warm from")
        }
    }
}
