import XCTest
@testable import GlowTopCore

/// SPEC.md §7.2's Classic Green column and the phase-05 plan's Amber Retro table, transcribed
/// by hand into `ThemePresets.swift` — the exact defect shape `ThemeTests` already guards
/// against for Neon, one preset over.
final class ThemePresetsTests: XCTestCase {
    private static let allThemes: [(name: String, theme: Theme)] = Theme.allPresets

    func testEveryPresetCarriesEveryTokenAsSevenCharacterUppercaseHex() {
        for (name, theme) in Self.allThemes {
            for (token, value) in zip(Theme.allTokenNames, theme.allColorValues) {
                XCTAssertEqual(value.count, 7, "\(name).\(token) is \(value)")
                XCTAssertTrue(value.hasPrefix("#"), "\(name).\(token) is \(value)")
                XCTAssertTrue(
                    value.dropFirst().allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) },
                    "\(name).\(token) is \(value) — hex is written uppercase"
                )
            }
        }
    }

    /// The plan's "Amber Retro, defined" table, row for row.
    func testAmberRetroMatchesThePlanTable() {
        let amber = Theme.amberRetro
        XCTAssertEqual(amber.background, "#0F0B00")
        XCTAssertEqual(amber.sidebarBackground, "#140E00")
        XCTAssertEqual(amber.cardBackground, "#1A1200")
        XCTAssertEqual(amber.cardBorder, "#3A2A00")
        XCTAssertEqual(amber.gridline, "#2A1E00")
        XCTAssertEqual(amber.textPrimary, "#FFB000")
        XCTAssertEqual(amber.textSecondary, "#C88600")
        XCTAssertEqual(amber.textTertiary, "#A87000")
        XCTAssertEqual(amber.textDisabled, "#7A5200")
        XCTAssertEqual(amber.accentCPU, "#FFB000")
        XCTAssertEqual(amber.accentMemory, "#FFB000")
        XCTAssertEqual(amber.accentDisk, "#FFB000")
        XCTAssertEqual(amber.accentNetwork, "#FFB000")
        XCTAssertEqual(amber.accentEnergy, "#FFB000")
        XCTAssertEqual(amber.accentGPU, "#FFB000")
        XCTAssertEqual(amber.accentNPU, "#FFB000")
        XCTAssertEqual(amber.accentThermal, "#FFB000")
        XCTAssertEqual(amber.accentKernel, "#B37A00")
        XCTAssertEqual(amber.accentClock, "#FFB000")
        XCTAssertEqual(amber.warning, "#FFD60A")
        XCTAssertEqual(amber.critical, "#FF453B")
        XCTAssertEqual(amber.statusDegraded, "#FF9F0A")
        XCTAssertEqual(amber.glowOpacity, 0.70, accuracy: 0.0001)
        XCTAssertEqual(amber.glowRadius, 8.0, accuracy: 0.0001)
    }

    /// §7.2's Classic Green column.
    func testClassicGreenMatchesSection72() {
        let green = Theme.classicGreen
        XCTAssertEqual(green.background, "#000000")
        XCTAssertEqual(green.textPrimary, "#33FF33")
        XCTAssertEqual(green.accentCPU, "#33FF33")
        XCTAssertEqual(green.accentMemory, "#33FF33")
        XCTAssertEqual(green.accentKernel, "#1F7A1F")
        XCTAssertEqual(green.warning, "#FFD60A")
        XCTAssertEqual(green.critical, "#FF453B")
        XCTAssertEqual(green.glowOpacity, 0.75, accuracy: 0.0001)
        XCTAssertEqual(green.glowRadius, 8.0, accuracy: 0.0001)
    }

    /// The alarm tokens stay red/yellow/orange in every preset — a thermal alarm rendered in
    /// the palette's own colour is not an alarm.
    func testAlarmTokensAreIdenticalAcrossAllPresets() {
        for (name, theme) in Self.allThemes {
            XCTAssertEqual(theme.warning, "#FFD60A", "\(name).warning")
            XCTAssertEqual(theme.critical, "#FF453B", "\(name).critical")
            XCTAssertEqual(theme.statusDegraded, "#FF9F0A", "\(name).statusDegraded")
        }
    }

    /// The one-chart separability rule: the kernel series must stay distinguishable from
    /// utilization even in a monochrome preset.
    func testAccentKernelDiffersFromAccentCPUInEveryPreset() {
        for (name, theme) in Self.allThemes {
            XCTAssertNotEqual(theme.accentKernel, theme.accentCPU, name)
        }
    }

    func testAllPresetsListsMenuOrder() {
        XCTAssertEqual(Theme.allPresets.map(\.name), ["Neon", "Classic Green", "Amber Retro"])
    }
}
