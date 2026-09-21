import XCTest
@testable import GlowTopCore

/// §14.6's reader, from fixture trees written into a temp directory (override O-3, precedent
/// `LaunchdReaderTests.swift:10`) -- no real `~` or volume walked by any test here except the
/// one live smoke test, which only asserts non-negative shape, never a specific byte count.
final class DiskSpaceReaderTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskSpaceReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testVolumesReturnsAtLeastTheRootWithNonZeroCapacity() {
        let volumes = DiskSpaceReader.volumes()
        XCTAssertFalse(volumes.isEmpty)
        XCTAssertTrue(volumes.contains { $0.isRootFileSystem })
        for volume in volumes {
            XCTAssertGreaterThan(volume.capacityBytes, 0)
            XCTAssertLessThanOrEqual(volume.freeBytes, volume.capacityBytes)
        }
    }

    func testChildrenSumsBothSizeKeysForAKnownFixture() throws {
        let child = tempDir.appendingPathComponent("known")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let sizes = [100, 200, 300]
        for (index, size) in sizes.enumerated() {
            try Data(count: size).write(to: child.appendingPathComponent("file\(index).bin"))
        }

        let result = DiskSpaceReader.children(of: tempDir)
        XCTAssertEqual(result.children.count, 1)
        let known = result.children[0]
        XCTAssertTrue(known.readable)
        XCTAssertEqual(known.apparentBytes, UInt64(sizes.reduce(0, +)))
        XCTAssertNotNil(known.allocatedBytes)
        XCTAssertEqual(known.allocatedBytes! % 4096, 0, "allocated size rounds up to filesystem blocks")
        XCTAssertGreaterThanOrEqual(known.allocatedBytes!, known.apparentBytes!)
    }

    func testASparseFileReadsSmallerAllocatedThanApparent() throws {
        let child = tempDir.appendingPathComponent("sparse")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let sparseURL = child.appendingPathComponent("hole.bin")
        FileManager.default.createFile(atPath: sparseURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: sparseURL)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        handle.closeFile()

        let result = DiskSpaceReader.children(of: tempDir)
        let sparse = try XCTUnwrap(result.children.first { $0.name == "sparse" })
        XCTAssertNotNil(sparse.apparentBytes)
        XCTAssertNotNil(sparse.allocatedBytes)
        XCTAssertEqual(sparse.apparentBytes, 64 * 1024 * 1024)
        XCTAssertLessThan(sparse.allocatedBytes!, sparse.apparentBytes!,
            "this is the com.docker.docker case in miniature -- a reader silently reading one key for both would fail here")
    }

    func testHardLinkedFilesAreCountedOnce() throws {
        let child = tempDir.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let original = child.appendingPathComponent("original.bin")
        try Data(count: 1_000_000).write(to: original)
        for index in 0..<3 {
            try FileManager.default.linkItem(
                at: original, to: child.appendingPathComponent("link\(index).bin")
            )
        }

        let result = DiskSpaceReader.children(of: tempDir)
        let linked = try XCTUnwrap(result.children.first { $0.name == "linked" })
        // Counted once, matching a per-invocation `du`-style total (F-8's defect, pinned):
        // four directory entries share one inode, so the allocated total is one file's worth,
        // not four.
        XCTAssertNotNil(linked.allocatedBytes)
        XCTAssertLessThan(linked.allocatedBytes!, 2_000_000)
    }

    /// `/System/Volumes/Data` is a volume root on every APFS Mac since 10.15. Crossing it from
    /// `/System/Volumes` re-walks the whole disk (5.3b found a `/` drill doing exactly that
    /// through `/.nofollow` and this firmlink, minutes long at 2.5 GB RSS); `du -x` reads 0.
    func testAVolumeRootBeneathTheNodeIsNotCrossed() throws {
        let started = Date()
        let result = DiskSpaceReader.children(of: URL(fileURLWithPath: "/System/Volumes"))
        let data = try XCTUnwrap(result.children.first { $0.name == "Data" })
        XCTAssertTrue(data.isDirectory)
        XCTAssertTrue(data.readable, "a mount point is not Locked -- it is sized on its own when entered")
        XCTAssertEqual(data.allocatedBytes, 0)
        XCTAssertEqual(data.entries, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "the data volume was walked")
    }

    /// `/.nofollow` (macOS 26) is a root-level alias of `/` itself -- a volume root by every key,
    /// but only through the full key set: a three-key `resourceValues` read answers `isVolume`
    /// false for it, and 5.3b's first fix missed it that way (368.9 GB, 5.2 M entries walked).
    /// Cancels right after the third child so the test never sizes `/Applications`.
    func testTheRootAliasNofollowIsNotWalked() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/.nofollow"), "no /.nofollow on this macOS")
        var calls = 0
        let result = DiskSpaceReader.children(of: URL(fileURLWithPath: "/"), isCancelled: { calls += 1; return calls > 3 })
        let alias = try XCTUnwrap(result.children.first { $0.name == ".nofollow" })
        XCTAssertTrue(alias.isDirectory)
        XCTAssertEqual(alias.entries, 0, "walked into the alias -- a 512-entry checkpoint would have cancelled inside it")
        XCTAssertEqual(alias.allocatedBytes, 0)
    }

    func testASymlinkIsNeverFollowed() throws {
        let child = tempDir.appendingPathComponent("withSymlink")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let outside = tempDir.appendingPathComponent("outside.bin")
        try Data(count: 5_000_000).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: child.appendingPathComponent("link.bin"), withDestinationURL: outside
        )

        let result = DiskSpaceReader.children(of: tempDir)
        let withSymlink = try XCTUnwrap(result.children.first { $0.name == "withSymlink" })
        XCTAssertNotNil(withSymlink.allocatedBytes)
        XCTAssertLessThan(withSymlink.allocatedBytes!, 1_000_000, "the 5 MB symlink target must not be counted")
    }

    func testAnUnreadableChildIsLockedWithNilBytesNotZero() throws {
        let locked = tempDir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(count: 100).write(to: locked.appendingPathComponent("hidden.bin"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = DiskSpaceReader.children(of: tempDir)
        let child = try XCTUnwrap(result.children.first { $0.name == "locked" })
        XCTAssertFalse(child.readable)
        XCTAssertNil(child.allocatedBytes)
        XCTAssertNil(child.apparentBytes)
    }

    func testCancellationMidWalkReturnsAPartialResultFlagged() throws {
        let first = tempDir.appendingPathComponent("aFirst")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        for index in 0..<700 {
            try Data(count: 10).write(to: first.appendingPathComponent("f\(index).bin"))
        }
        let second = tempDir.appendingPathComponent("bSecond")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(count: 10).write(to: second.appendingPathComponent("g.bin"))

        // False on the first (pre-child) check, true on every check after -- lands the
        // cancellation inside `aFirst`'s own 512-entry checkpoint, never reaching `bSecond`.
        var callCount = 0
        let isCancelled: () -> Bool = {
            callCount += 1
            return callCount > 1
        }

        let result = DiskSpaceReader.children(of: tempDir, isCancelled: isCancelled)
        XCTAssertTrue(result.cancelled)
        XCTAssertLessThan(result.sizedCount, result.totalCount)
        XCTAssertEqual(result.children.count, 1, "the children already sized are kept")
        XCTAssertEqual(result.children[0].name, "aFirst")
    }
}
