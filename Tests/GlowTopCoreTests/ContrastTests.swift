import XCTest
@testable import GlowTopCore

/// SPEC.md §7.5's 4.5:1 check. Known ratios first, then the measured verdicts for the three
/// shipped presets recorded as assertions — §7.5 warns and does not block, so the shipped
/// palettes failing their own check is a fact to pin down here, not a reason to brighten them.
final class ContrastTests: XCTestCase {
    func testWhiteOnBlackIs21To1() {
        XCTAssertEqual(Contrast.ratio("#FFFFFF", "#000000")!, 21.0, accuracy: 0.05)
    }

    func testOrderDoesNotMatter() {
        XCTAssertEqual(Contrast.ratio("#FFFFFF", "#000000"), Contrast.ratio("#000000", "#FFFFFF"))
    }

    func testUnparseableInputYieldsNil() {
        XCTAssertNil(Contrast.ratio("not-a-color", "#000000"))
        XCTAssertFalse(Contrast.meetsAA("not-a-color", on: "#000000"))
    }

    /// A known boundary pair: `#767676` on white sits right at 4.5:1 (a commonly-cited WCAG
    /// example), asserted with enough slack for the piecewise transfer function's own rounding.
    func testKnownBoundaryPairSitsNear4Point5To1() {
        let ratio = Contrast.ratio("#767676", "#FFFFFF")!
        XCTAssertEqual(ratio, 4.5, accuracy: 0.05)
    }

    // MARK: - The three shipped presets, measured rather than assumed

    func testNeonTextTertiaryAndTextDisabledFailAgainstBackground() {
        let neon = Theme.neon
        XCTAssertFalse(Contrast.meetsAA(neon.textTertiary, on: neon.background))
        XCTAssertFalse(Contrast.meetsAA(neon.textDisabled, on: neon.background))
    }

    func testClassicGreenTextTertiaryAndTextDisabledFailAgainstBackground() {
        let green = Theme.classicGreen
        XCTAssertFalse(Contrast.meetsAA(green.textTertiary, on: green.background))
        XCTAssertFalse(Contrast.meetsAA(green.textDisabled, on: green.background))
    }

    /// Amber Retro's `textTertiary` was chosen to clear 4.5:1 — `textDisabled` was not,
    /// deliberately, same as Neon's and Classic Green's: `—` and `···` are meant to recede.
    func testAmberRetroTextTertiaryClearsButTextDisabledDoesNot() {
        let amber = Theme.amberRetro
        XCTAssertTrue(Contrast.meetsAA(amber.textTertiary, on: amber.background))
        XCTAssertFalse(Contrast.meetsAA(amber.textDisabled, on: amber.background))
    }

    func testAllThreePresetsTextPrimaryClearsAgainstBackground() {
        for (name, theme) in Theme.allPresets {
            XCTAssertTrue(Contrast.meetsAA(theme.textPrimary, on: theme.background), name)
        }
    }
}
