import XCTest
@testable import GlowTopCore

/// SPEC.md §14.3's stable sort (D-25's size-descending default, `—` last both directions),
/// D-25's search and D-22's `Unparseable` preservation -- all pure, so every test here runs
/// against a fixture `InstalledAppsScan`, never a live disk scan.
final class InstalledAppsModelTests: XCTestCase {
    private func app(
        path: String, name: String, version: String? = "1.0", bundleID: String? = "com.example.app",
        size: UInt64? = 1024, signing: String? = "Example Inc.", arch: [String] = ["arm64"]
    ) -> InstalledApp {
        InstalledApp(
            bundlePath: path, name: name, version: version, bundleIdentifier: bundleID,
            allocatedBytes: size, signingIdentity: signing, architectures: arch,
            isUnparseable: bundleID == "Unparseable"
        )
    }

    // MARK: - D-25: size descending default, unknown last both directions

    func testSizeSortsDescendingByDefaultWithUnknownLastRegardlessOfDirection() {
        let apps = [
            app(path: "/a", name: "A", size: 300),
            app(path: "/b", name: "B", size: nil),
            app(path: "/c", name: "C", size: 900),
        ]
        let scan = InstalledAppsScan(apps: apps, scannedCount: 3, totalCount: 3, cancelled: false, unreadableRoots: [], millisecondsElapsed: 1)

        let descending = InstalledAppsModel.project(scan, sort: .size, ascending: false, search: "")
        XCTAssertEqual(descending.rows.map(\.nameText), ["C", "A", "B"], "known sizes descending, unknown last")

        let ascending = InstalledAppsModel.project(scan, sort: .size, ascending: true, search: "")
        XCTAssertEqual(ascending.rows.map(\.nameText), ["A", "C", "B"], "known sizes ascending, unknown still last")
    }

    // MARK: - D-25: search matches Name and Bundle ID

    func testSearchMatchesNameAndBundleID() {
        let apps = [
            app(path: "/a", name: "Safari", bundleID: "com.apple.Safari"),
            app(path: "/b", name: "Chrome", bundleID: "com.google.Chrome"),
            app(path: "/c", name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        ]
        let scan = InstalledAppsScan(apps: apps, scannedCount: 3, totalCount: 3, cancelled: false, unreadableRoots: [], millisecondsElapsed: 1)

        let byName = InstalledAppsModel.project(scan, sort: .name, ascending: true, search: "chrome")
        XCTAssertEqual(byName.rows.map(\.nameText), ["Chrome"])

        let byBundleID = InstalledAppsModel.project(scan, sort: .name, ascending: true, search: "com.apple")
        XCTAssertEqual(byBundleID.rows.map(\.nameText), ["Safari", "Xcode"])
    }

    // MARK: - D-22: `Unparseable` preserved into the Bundle ID cell, not swallowed by `Format.unknown`

    func testUnparseableBundleIdentifierIsPreservedIntoTheCell() {
        let broken = app(path: "/broken", name: "Broken", bundleID: "Unparseable")
        let scan = InstalledAppsScan(apps: [broken], scannedCount: 1, totalCount: 1, cancelled: false, unreadableRoots: [], millisecondsElapsed: 1)
        let detail = InstalledAppsModel.project(scan, sort: .name, ascending: true, search: "").rows[0]
        XCTAssertEqual(detail.bundleIDText, "Unparseable")
        XCTAssertNotEqual(detail.bundleIDText, Format.unknown, "Unparseable and — are different signals (§10.4)")
    }

    // MARK: - Cancelled scan's footer note

    func testCancelledScanAddsItsFooterNoteWithTheRightCounts() {
        let apps = [app(path: "/a", name: "A")]
        let scan = InstalledAppsScan(apps: apps, scannedCount: 5, totalCount: 12, cancelled: true, unreadableRoots: [], millisecondsElapsed: 1)
        let model = InstalledAppsModel.project(scan, sort: .name, ascending: true, search: "")
        XCTAssertTrue(model.footerNotes.contains("Scan stopped at 5 of 12 bundles."))
    }

    // MARK: - Format discipline

    func testProjectionUsesFormatAndNotAdHocStringFormatting() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/GlowTopCoreTests/InstalledAppsModelTests.swift",
            with: "Sources/GlowTopCore/InstalledAppsModel.swift"
        )
        XCTAssertTrue(path.hasSuffix("Sources/GlowTopCore/InstalledAppsModel.swift"), "re-pointed, not copy-pasted")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(source.contains("String(format:"))
        XCTAssertFalse(source.contains("NumberFormatter"))
    }
}
