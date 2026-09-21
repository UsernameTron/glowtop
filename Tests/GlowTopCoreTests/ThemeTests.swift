import XCTest
@testable import GlowTopCore

/// SPEC.md §7.2. A token typed one hex digit off draws a colour that looks plausible on a
/// near-black ground and is wrong in every screenshot from then on — the phase-02 defect
/// shape, in a table of 21 literals transcribed by hand.
final class ThemeTests: XCTestCase {
    func testNeonCarriesEveryTokenInSection72() {
        let neon = Theme.neon
        // §7.2's Neon column, re-read from the spec rather than from Theme.swift.
        XCTAssertEqual(neon.background, "#0B0B0F")
        XCTAssertEqual(neon.sidebarBackground, "#0E0E13")
        XCTAssertEqual(neon.cardBackground, "#101017")
        XCTAssertEqual(neon.cardBorder, "#1E1E28")
        XCTAssertEqual(neon.gridline, "#1A1A22")
        XCTAssertEqual(neon.textPrimary, "#F2F2F7")
        XCTAssertEqual(neon.textSecondary, "#8A8A99")
        XCTAssertEqual(neon.textTertiary, "#6E6E7E")
        XCTAssertEqual(neon.textDisabled, "#5A5A68")
        XCTAssertEqual(neon.accentCPU, "#39FF14")
        XCTAssertEqual(neon.accentMemory, "#FF2D95")
        XCTAssertEqual(neon.accentDisk, "#39FF14")
        XCTAssertEqual(neon.accentNetwork, "#0A84FF")
        XCTAssertEqual(neon.accentEnergy, "#FFD60A")
        XCTAssertEqual(neon.accentGPU, "#0A84FF")
        XCTAssertEqual(neon.accentNPU, "#FF453B")
        XCTAssertEqual(neon.accentThermal, "#FF9F0A")
        XCTAssertEqual(neon.accentKernel, "#FF453B")
        XCTAssertEqual(neon.accentClock, "#FF3B30")
        XCTAssertEqual(neon.warning, "#FFD60A")
        XCTAssertEqual(neon.critical, "#FF453B")
    }

    func testEveryColourTokenIsSevenCharacterHex() {
        for (name, value) in zip(Theme.allTokenNames, Theme.neon.allColorValues) {
            XCTAssertEqual(value.count, 7, "\(name) is \(value)")
            XCTAssertTrue(value.hasPrefix("#"), "\(name) is \(value)")
            XCTAssertTrue(
                value.dropFirst().allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isUppercase) },
                "\(name) is \(value) — §7.2 writes hex uppercase"
            )
        }
    }

    func testGlowOpacityAndRadiusAreNumbersNotHex() {
        XCTAssertEqual(Theme.neon.glowOpacity, 0.55, accuracy: 0.0001)
        XCTAssertEqual(Theme.neon.glowRadius, 6.0, accuracy: 0.0001)
    }

    /// Catches a token silently dropped in transcription, which otherwise surfaces as a card
    /// drawn in the default colour and reads as a design choice.
    func testAllTokenNamesMatchesStoredPropertyCount() {
        XCTAssertEqual(Theme.allTokenNames.count, 22)
        XCTAssertEqual(Theme.neon.allColorValues.count, Theme.allTokenNames.count)
        XCTAssertEqual(Set(Theme.allTokenNames).count, 22, "duplicate token name")
    }

    func testSubscriptResolvesTokenNamesAndRejectsUnknownOnes() {
        XCTAssertEqual(Theme.neon["accentKernel"], "#FF453B")
        XCTAssertEqual(Theme.neon["statusDegraded"], "#FF9F0A", "phase-05 adds this token — §4.7's health colour")
        XCTAssertNil(Theme.neon["accentQuantum"], "no such token")
    }

    /// §7.2 gives these no token, and inventing one would put a row in phase-05's editor that
    /// the spec never specified.
    func testSpecLiteralsAreNotTokens() {
        XCTAssertFalse(Theme.allTokenNames.contains("sidebarRule"))
        XCTAssertNotEqual(SpecLiteralColor.sidebarRule, Theme.neon.cardBorder,
                          "§3.2's #1E1E26 is one digit from cardBorder's #1E1E28")
    }

    func testThemeRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(Theme.neon)
        XCTAssertEqual(try JSONDecoder().decode(Theme.self, from: data), Theme.neon)
    }
}
