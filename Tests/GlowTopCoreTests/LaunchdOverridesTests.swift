import XCTest
@testable import GlowTopCore

/// SPEC.md §14.4's override store: `LaunchdOverrides.read` in isolation, then
/// `LaunchdReader.read(sources:overrides:)`'s "the store wins" rule end to end.
final class LaunchdOverridesTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchdOverridesTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writePlist(_ contents: String, name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! contents.data(using: .utf8)!.write(to: url)
        return url
    }

    private static let flatDictionaryPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>com.glowtop.disabled-in-store</key><true/>
        <key>com.glowtop.enabled-in-store</key><false/>
    </dict>
    </plist>
    """

    func testFixtureStoreDecodesTrueAndFalse() {
        let url = writePlist(Self.flatDictionaryPlist, name: "disabled.501.plist")
        let (overrides, note) = LaunchdOverrides.read(uid: 501, storeURL: url)
        XCTAssertEqual(overrides["com.glowtop.disabled-in-store"], true)
        XCTAssertEqual(overrides["com.glowtop.enabled-in-store"], false)
        XCTAssertNil(note)
    }

    func testAbsentStoreYieldsEmptyOverridesAndANote() {
        let missing = tempDir.appendingPathComponent("does-not-exist.plist")
        let (overrides, note) = LaunchdOverrides.read(uid: 501, storeURL: missing)
        XCTAssertTrue(overrides.isEmpty)
        XCTAssertEqual(note, LaunchdOverrides.unreadableNote)
    }

    func testNonDictionaryPlistYieldsEmptyOverridesAndANote() {
        let url = writePlist("this is not a plist", name: "broken.501.plist")
        let (overrides, note) = LaunchdOverrides.read(uid: 501, storeURL: url)
        XCTAssertTrue(overrides.isEmpty)
        XCTAssertEqual(note, LaunchdOverrides.unreadableNote)
    }

    /// The store's `true` flips a job with **no** `Disabled` key to `enabled == false`.
    func testStoreTrueFlipsAJobWithNoDisabledKeyToDisabled() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.glowtop.store-disabled</string>
            <key>Program</key><string>/usr/bin/true</string>
        </dict>
        </plist>
        """
        _ = writePlist(plist, name: "job.plist")
        let inventory = LaunchdReader.read(
            sources: [(tempDir, "Launch Agent")],
            overrides: ["com.glowtop.store-disabled": true]
        )
        XCTAssertEqual(inventory.jobs[0].enabled, false)
    }

    /// The store's `false` overrides a plist that **has** `Disabled: true` -- the direction
    /// that proves "store wins", not merely "store agrees with the plist".
    func testStoreFalseOverridesAPlistDisabledTrue() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.glowtop.plist-disabled</string>
            <key>Program</key><string>/usr/bin/true</string>
            <key>Disabled</key><true/>
        </dict>
        </plist>
        """
        _ = writePlist(plist, name: "job.plist")
        let inventory = LaunchdReader.read(
            sources: [(tempDir, "Launch Agent")],
            overrides: ["com.glowtop.plist-disabled": false]
        )
        XCTAssertEqual(inventory.jobs[0].enabled, true)
    }

    /// A label absent from the store falls back to the plist's own `Disabled` key --
    /// `LaunchdReaderTests`' existing cases keep passing because this is the default path.
    func testLabelAbsentFromStoreFallsBackToPlistKey() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.glowtop.not-in-store</string>
            <key>Program</key><string>/usr/bin/true</string>
            <key>Disabled</key><true/>
        </dict>
        </plist>
        """
        _ = writePlist(plist, name: "job.plist")
        let inventory = LaunchdReader.read(
            sources: [(tempDir, "Launch Agent")],
            overrides: ["com.glowtop.some-other-label": true]
        )
        XCTAssertEqual(inventory.jobs[0].enabled, false)
    }

    /// The real store path, read as-is: either it decodes (this Mac has one, §14.4's recon)
    /// or the read reports the note -- recorded either way, not asserted to be one or the other.
    func testRealStorePathEitherDecodesOrReportsTheNote() {
        let (overrides, note) = LaunchdOverrides.read()
        if let note {
            XCTAssertEqual(note, LaunchdOverrides.unreadableNote)
            XCTAssertTrue(overrides.isEmpty)
        } else {
            XCTAssertNil(note)
        }
    }
}
