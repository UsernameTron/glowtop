import XCTest
@testable import GlowTopCore

/// SPEC.md §7.4, in full: §13.5 item 8's own list, plus what phase-05 adds to it.
final class ThemeStorageTests: XCTestCase {
    /// A full, valid custom theme where every token is a distinct, non-Neon value, so a test
    /// that drops or corrupts one token can tell whether the *others* survived.
    private func distinctFields() -> [String: Any] {
        var fields: [String: Any] = [:]
        for (index, name) in Theme.allTokenNames.enumerated() {
            fields[name] = String(format: "#%06X", index + 1)
        }
        fields["glowOpacity"] = 0.42
        fields["glowRadius"] = 12.0
        return fields
    }

    func testMissingTokenTakesNeonsValue() throws {
        var fields = distinctFields()
        fields.removeValue(forKey: "statusDegraded")
        let data = try JSONSerialization.data(withJSONObject: fields)

        let (theme, presetName) = ThemeStorage.theme(presetName: "Custom", customTokensJSON: data, version: 1)

        XCTAssertEqual(presetName, "Custom")
        XCTAssertEqual(theme.statusDegraded, Theme.neon.statusDegraded, "missing token takes Neon's value")
        for (index, name) in Theme.allTokenNames.enumerated() where name != "statusDegraded" {
            XCTAssertEqual(theme[name], String(format: "#%06X", index + 1), "\(name) should survive")
        }
    }

    func testMalformedHexFallsBackWithoutThrowing() throws {
        var fields = distinctFields()
        fields["accentCPU"] = "not-a-color"
        let data = try JSONSerialization.data(withJSONObject: fields)

        let (theme, presetName) = ThemeStorage.theme(presetName: "Custom", customTokensJSON: data, version: 1)

        XCTAssertEqual(presetName, "Custom")
        XCTAssertEqual(theme.accentCPU, Theme.neon.accentCPU, "malformed hex takes Neon's value for that token")
        XCTAssertEqual(theme.accentMemory, "#00000B", "an unrelated token is unaffected")
    }

    func testUnknownPresetNameYieldsNeon() {
        let (theme, presetName) = ThemeStorage.theme(presetName: "Nonexistent", customTokensJSON: nil, version: 1)
        XCTAssertEqual(theme, Theme.neon)
        XCTAssertEqual(presetName, "Neon")
    }

    func testMissingPresetNameYieldsNeon() {
        let (theme, presetName) = ThemeStorage.theme(presetName: nil, customTokensJSON: nil, version: nil)
        XCTAssertEqual(theme, Theme.neon)
        XCTAssertEqual(presetName, "Neon")
    }

    /// A known preset name ignores `customTokensJSON` — §7.4: custom tokens are written only
    /// when the name is `"Custom"`.
    func testKnownPresetNameIgnoresCustomTokensJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: distinctFields())
        let (theme, presetName) = ThemeStorage.theme(
            presetName: "Classic Green", customTokensJSON: data, version: 1
        )
        XCTAssertEqual(theme, Theme.classicGreen)
        XCTAssertEqual(presetName, "Classic Green")
    }

    func testCustomRoundTripsLosslessly() throws {
        let data = try JSONSerialization.data(withJSONObject: distinctFields())
        let (theme, presetName) = ThemeStorage.theme(presetName: "Custom", customTokensJSON: data, version: 1)

        XCTAssertEqual(presetName, "Custom")
        for (index, name) in Theme.allTokenNames.enumerated() {
            XCTAssertEqual(theme[name], String(format: "#%06X", index + 1), name)
        }
        XCTAssertEqual(theme.glowOpacity, 0.42, accuracy: 0.0001)
        XCTAssertEqual(theme.glowRadius, 12.0, accuracy: 0.0001)
    }

    func testFutureVersionYieldsNeon() throws {
        let data = try JSONSerialization.data(withJSONObject: distinctFields())
        let (theme, presetName) = ThemeStorage.theme(
            presetName: "Custom", customTokensJSON: data, version: ThemeStorage.currentVersion + 1
        )
        XCTAssertEqual(theme, Theme.neon, "a future schema version reads as Neon rather than misreading it")
        XCTAssertEqual(presetName, "Neon")
    }

    func testCustomWithMalformedJSONYieldsNeon() {
        let data = Data("not json".utf8)
        let (theme, presetName) = ThemeStorage.theme(presetName: "Custom", customTokensJSON: data, version: 1)
        XCTAssertEqual(theme, Theme.neon)
        XCTAssertEqual(presetName, "Neon")
    }

    func testCustomWithAbsentJSONYieldsNeon() {
        let (theme, presetName) = ThemeStorage.theme(presetName: "Custom", customTokensJSON: nil, version: 1)
        XCTAssertEqual(theme, Theme.neon)
        XCTAssertEqual(presetName, "Neon")
    }

    func testUnknownExtraKeyIsIgnored() throws {
        var fields = distinctFields()
        fields["accentQuantum"] = "#FFFFFF"
        let data = try JSONSerialization.data(withJSONObject: fields)

        let (theme, presetName) = ThemeStorage.theme(presetName: "Custom", customTokensJSON: data, version: 1)

        XCTAssertEqual(presetName, "Custom")
        XCTAssertEqual(theme.accentCPU, "#00000A")
    }
}
