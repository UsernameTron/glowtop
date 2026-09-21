import XCTest
@testable import GlowTopCore

/// §14.3's scan, from fixture bundles written into a temp directory -- no real
/// `/Applications` or `~/Applications` read by any test here (override O-6, precedent
/// `LaunchdReaderTests.swift:10`).
final class InstalledAppsReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledAppsReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeBundle(at url: URL, infoPlist: [String: Any]?) throws {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plistURL = contents.appendingPathComponent("Info.plist")
        if let infoPlist {
            let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
            try data.write(to: plistURL)
        } else {
            try Data("this is not a plist".utf8).write(to: plistURL)
        }
    }

    func testAppAtReadsNameVersionAndIdentifierFromAWellFormedInfoPlist() throws {
        let url = tempDir.appendingPathComponent("Fixture.app")
        try makeBundle(at: url, infoPlist: [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleName": "Fixture",
        ])
        let app = InstalledAppsReader.app(at: url)
        XCTAssertFalse(app.isUnparseable)
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertEqual(app.bundleIdentifier, "com.example.fixture")
        XCTAssertEqual(app.name, "Fixture")
    }

    func testAMalformedInfoPlistYieldsAnUnparseableRowNotOmission() throws {
        let url = tempDir.appendingPathComponent("Broken.app")
        try makeBundle(at: url, infoPlist: nil)
        try Data(count: 128).write(to: url.appendingPathComponent("Contents/payload.bin"))

        let app = InstalledAppsReader.app(at: url)
        XCTAssertTrue(app.isUnparseable)
        XCTAssertEqual(app.bundleIdentifier, "Unparseable")
        XCTAssertEqual(app.name, "Broken") // folder-stem fallback, §5.5.1's rule
        // APPS-04: size is still computed even though the plist failed.
        XCTAssertNotNil(app.allocatedBytes)
        XCTAssertGreaterThan(app.allocatedBytes ?? 0, 0)
    }

    func testAllocatedSizeSumsRegularFilesUnderTheBundle() throws {
        let url = tempDir.appendingPathComponent("Sized.app")
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        for (index, size) in [100, 200, 300].enumerated() {
            try Data(count: size).write(to: contents.appendingPathComponent("file\(index).bin"))
        }
        // A symlink inside the bundle pointing outside it, to a file large enough that
        // double-counting it would be unmistakable -- must not be double-counted.
        let outside = tempDir.appendingPathComponent("outside.bin")
        try Data(count: 5_000_000).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: contents.appendingPathComponent("link.bin"), withDestinationURL: outside
        )

        let total = InstalledAppsReader.allocatedSize(of: url)
        XCTAssertNotNil(total)
        // Allocated size rounds each file up to a filesystem block, so three small files sum
        // to a few blocks, not their 600-byte logical total -- the assertion is a generous
        // ceiling, not the exact block count, so it is not filesystem-specific.
        XCTAssertGreaterThan(total ?? 0, 0)
        XCTAssertLessThan(total ?? 0, 1_000_000, "the 5 MB symlink target must not be counted")
    }

    func testAllocatedSizeReturnsNilWhenCancelledMidWalk() throws {
        let url = tempDir.appendingPathComponent("Big.app")
        let resources = url.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for index in 0..<513 {
            try Data(count: 0).write(to: resources.appendingPathComponent("f\(index).bin"))
        }
        let result = InstalledAppsReader.allocatedSize(of: url, isCancelled: { true })
        XCTAssertNil(result)
    }

    func testBundleURLsFindsOneLevelDeepAndFollowsSymlinks() throws {
        let root = tempDir.appendingPathComponent("Root")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Plain.app/Contents"), withIntermediateDirectories: true
        )
        let sub = root.appendingPathComponent("SubFolder")
        try FileManager.default.createDirectory(
            at: sub.appendingPathComponent("Nested.app/Contents"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sub.appendingPathComponent("TooDeep/Ghost.app/Contents"), withIntermediateDirectories: true
        )
        let real = tempDir.appendingPathComponent("RealTarget.app")
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Linked.app"), withDestinationURL: real
        )

        let (urls, unreadable) = InstalledAppsReader.bundleURLs(under: [root])
        XCTAssertTrue(unreadable.isEmpty)
        let names = Set(urls.map(\.lastPathComponent))
        XCTAssertTrue(names.contains("Plain.app"))
        XCTAssertTrue(names.contains("Nested.app"))
        XCTAssertTrue(names.contains("RealTarget.app"), "symlink should resolve to its real target")
        XCTAssertFalse(names.contains("Ghost.app"), "two levels deep must not be found")
    }

    func testUnreadableRootProducesNoRowsAndAFooterNote() {
        let missing = tempDir.appendingPathComponent("DoesNotExist")
        let (urls, unreadable) = InstalledAppsReader.bundleURLs(under: [missing])
        XCTAssertTrue(urls.isEmpty)
        XCTAssertEqual(unreadable, [missing.path])
    }

    func testArchitectureNamesMapsTheTwoKnownConstants() {
        // A `Bundle` stub is not constructible without a real executable (finding F-16), so
        // this asserts the mapping directly against `NSBundle.h`'s two raw values, plus an
        // unknown third value dropped.
        let numbers: [NSNumber] = [
            NSNumber(value: 0x0100000c), // NSBundleExecutableArchitectureARM64
            NSNumber(value: 0x01000007), // NSBundleExecutableArchitectureX86_64
            NSNumber(value: 0x00000001), // unknown -- dropped
        ]
        XCTAssertEqual(InstalledAppsReader.architectureNames(from: numbers), ["arm64", "x86_64"])
    }
}
