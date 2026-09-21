import XCTest
@testable import GlowTopCore

/// §10.2's column derivation and §10.4's failure behaviour, from fixture plists written into
/// a temp directory -- no real `~/Library/LaunchAgents` read by any test here.
final class LaunchdReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchdReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ plist: String, name: String) -> URL {
        let url = tempDir.appendingPathComponent(name)
        try! plist.data(using: .utf8)!.write(to: url)
        return url
    }

    func testMalformedPlistProducesUnparseableRow() {
        let url = write("this is not a plist", name: "broken.plist")
        let inventory = LaunchdReader.read(sources: [(tempDir, "Launch Agent")])
        _ = url
        XCTAssertEqual(inventory.jobs.count, 1)
        XCTAssertEqual(inventory.jobs[0].type, "Unparseable")
        XCTAssertEqual(inventory.jobs[0].label, "broken")
    }

    func testUnreadableDirectoryAddsAFooterNote() {
        let locked = tempDir.appendingPathComponent("locked")
        try! FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try! FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let inventory = LaunchdReader.read(sources: [(locked, "Launch Agent")])
        XCTAssertTrue(inventory.jobs.isEmpty)
        XCTAssertEqual(inventory.footerNotes.count, 1)
        XCTAssertTrue(inventory.footerNotes[0].contains(locked.path))
    }

    func testKeepAliveDictionarySummarisesItsKeys() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.glowtop.test</string>
            <key>Program</key><string>/usr/bin/true</string>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key><false/>
                <key>NetworkState</key><true/>
            </dict>
        </dict>
        </plist>
        """
        _ = write(plist, name: "keepalive.plist")
        let inventory = LaunchdReader.read(sources: [(tempDir, "Launch Agent")])
        XCTAssertEqual(inventory.jobs.count, 1)
        XCTAssertEqual(inventory.jobs[0].keepAlive, "NetworkState, SuccessfulExit")
    }

    func testProgramFallsBackToFirstProgramArgument() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.glowtop.args</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/env</string>
                <string>--flag</string>
            </array>
        </dict>
        </plist>
        """
        _ = write(plist, name: "args.plist")
        let inventory = LaunchdReader.read(sources: [(tempDir, "Launch Daemon")])
        XCTAssertEqual(inventory.jobs.count, 1)
        XCTAssertEqual(inventory.jobs[0].program, "/usr/bin/env")
        XCTAssertEqual(inventory.jobs[0].programArguments, ["/usr/bin/env", "--flag"])
    }

    func testDisabledFlagInvertsToEnabledColumn() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.glowtop.disabled</string>
            <key>Program</key><string>/usr/bin/true</string>
            <key>Disabled</key><true/>
        </dict>
        </plist>
        """
        _ = write(plist, name: "disabled.plist")
        let inventory = LaunchdReader.read(sources: [(tempDir, "Launch Agent")])
        XCTAssertEqual(inventory.jobs[0].enabled, false)
    }

    func testMissingDirectoryIsSkippedSilently() {
        let missing = tempDir.appendingPathComponent("does-not-exist")
        let inventory = LaunchdReader.read(sources: [(missing, "Launch Agent")])
        XCTAssertTrue(inventory.jobs.isEmpty)
        XCTAssertTrue(inventory.footerNotes.isEmpty)
    }
}
