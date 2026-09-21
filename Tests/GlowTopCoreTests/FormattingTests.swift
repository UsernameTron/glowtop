import XCTest
@testable import GlowTopCore

/// SPEC.md §13.5 item 7: "every row of §4.9's table is a test case."
final class FormattingTests: XCTestCase {
    func testPercentage() {
        XCTAssertEqual(Format.percent(points: 0), "0.0%")
        XCTAssertEqual(Format.percent(points: 7.3), "7.3%")
        XCTAssertEqual(Format.percent(points: 100), "100.0%")
        XCTAssertEqual(Format.percent(fraction: 0.073), "7.3%")
        XCTAssertEqual(Format.percent(fraction: 1.0), "100.0%")
    }

    /// §5.5.2: a process saturating all 14 cores reads 1400 % and the UI shows it unchanged.
    func testPercentageDoesNotClampAboveOneHundred() {
        XCTAssertEqual(Format.percent(points: 1400), "1400.0%")
    }

    func testByteSizes() {
        XCTAssertEqual(Format.bytes(512 * 1024), "512 KB")
        XCTAssertEqual(Format.bytes(UInt64(18.4 * 1024 * 1024 * 1024)), "18.4 GB")
        XCTAssertEqual(Format.bytes(128 * 1024 * 1024 * 1024), "128 GB")
    }

    func testByteSizesBelowGigabyteCarryNoDecimal() {
        XCTAssertEqual(Format.bytes(0), "0 B")
        XCTAssertEqual(Format.bytes(999), "999 B")
        XCTAssertEqual(Format.bytes(4 * 1024 * 1024), "4 MB")
    }

    /// §4.9 is explicit that base-1024 with KB/MB/GB labels is deliberate, chosen to match
    /// Activity Monitor on the same screen. 1024 bytes is 1 KB here, never 1.024 KB.
    func testByteSizesAreBaseTenTwentyFourNotBaseOneThousand() {
        XCTAssertEqual(Format.bytes(1024), "1 KB")
        XCTAssertEqual(Format.bytes(1000), "1000 B")
    }

    func testByteRates() {
        XCTAssertEqual(Format.byteRate(948), "948 B/s")
        XCTAssertEqual(Format.byteRate(12.4 * 1024 * 1024), "12.4 MB/s")
    }

    /// "auto-scaled to keep 1–999 in the mantissa" (§4.9).
    func testByteRateMantissaStaysInRange() {
        XCTAssertEqual(Format.byteRate(0), "0 B/s")
        XCTAssertEqual(Format.byteRate(1023), "1023 B/s")
        XCTAssertEqual(Format.byteRate(1024), "1 KB/s")
        XCTAssertEqual(Format.byteRate(3.1 * 1024 * 1024 * 1024), "3.1 GB/s")
    }

    func testTemperatureUsesANonBreakingSpace() {
        XCTAssertEqual(Format.temperature(celsius: 37.5), "37.5\u{00A0}°C")
        XCTAssertFalse(Format.temperature(celsius: 37.5).contains(" "), "must not contain a plain space")
    }

    func testPower() {
        XCTAssertEqual(Format.power(watts: 8.4), "8.4 W")
        XCTAssertEqual(Format.power(watts: 0), "0.0 W")
    }

    func testFrequency() {
        XCTAssertEqual(Format.frequency(megahertz: 600), "600 MHz")
        XCTAssertEqual(Format.frequency(megahertz: 4050), "4.05 GHz")
    }

    /// The boundary §4.9 names: below 1000 is MHz, at or above is GHz.
    func testFrequencyBoundary() {
        XCTAssertEqual(Format.frequency(megahertz: 999), "999 MHz")
        XCTAssertEqual(Format.frequency(megahertz: 1000), "1.00 GHz")
    }

    func testDuration() {
        XCTAssertEqual(Format.duration(seconds: 100_800), "1d 4h")
        XCTAssertEqual(Format.duration(seconds: 15_120), "4h 12m")
        XCTAssertEqual(Format.duration(seconds: 750), "12m 30s")
        XCTAssertEqual(Format.duration(seconds: 30.4), "30.4s")
    }

    func testDurationBoundaries() {
        XCTAssertEqual(Format.duration(seconds: 0), "0.0s")
        XCTAssertEqual(Format.duration(seconds: 59.9), "59.9s")
        XCTAssertEqual(Format.duration(seconds: 60), "1m 0s")
        XCTAssertEqual(Format.duration(seconds: 3600), "1h 0m")
        XCTAssertEqual(Format.duration(seconds: 86_400), "1d 0h")
    }

    func testCountGroupsWithThinSpacesAboveNineThousandNineHundredNinetyNine() {
        XCTAssertEqual(Format.count(1138), "1138")
        XCTAssertEqual(Format.count(12_400), "12\u{2009}400")
    }

    func testCountGroupingBoundary() {
        XCTAssertEqual(Format.count(9999), "9999")
        XCTAssertEqual(Format.count(10_000), "10\u{2009}000")
        XCTAssertEqual(Format.count(1_234_567), "1\u{2009}234\u{2009}567")
    }

    func testUnknownIsAnEmDash() {
        XCTAssertEqual(Format.unknown, "—")
    }

    /// A monitor that reads `18,4 GB` in one locale and `18.4 GB` in another has two
    /// presentations of one number; §4.9 is one set of rules applied everywhere.
    func testFormattingIsLocaleIndependent() {
        XCTAssertEqual(Format.bytes(UInt64(18.4 * 1024 * 1024 * 1024)), "18.4 GB")
        XCTAssertEqual(Format.percent(points: 7.3), "7.3%")
        XCTAssertFalse(Format.bytes(128 * 1024 * 1024 * 1024).contains(","))
    }
}
