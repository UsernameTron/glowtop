import XCTest
@testable import GlowTopCore

/// SPEC.md §14.6's projection: D-14's sort key, D-15's computed disclosure (both directions,
/// not just the sparse one), and the three failure footers that must never collapse into one
/// string (§14.6's closing sentence) -- all pure, so every test here runs against fixtures,
/// never a live disk read.
final class DiskSpaceModelTests: XCTestCase {
    private func child(
        name: String, readable: Bool = true, allocated: UInt64?, apparent: UInt64?, entries: Int = 0
    ) -> DirectoryChild {
        DirectoryChild(
            name: name, path: "/fixture/\(name)", isDirectory: true, readable: readable,
            allocatedBytes: allocated, apparentBytes: apparent, entries: entries
        )
    }

    private func volume(free: UInt64, importantFree: UInt64?) -> VolumeInfo {
        VolumeInfo(
            name: "Macintosh HD", path: "/", capacityBytes: 494_000_000_000, freeBytes: free,
            importantUsageFreeBytes: importantFree, isRemovable: false, isInternal: true,
            isRootFileSystem: true
        )
    }

    // MARK: - D-15: both disclosure directions are real and both are tested

    func testDisclosureNamesBothNumbersWhenApparentExceedsAllocated() {
        // com.docker.docker's own magnitudes (CONTEXT, 2026-09-08): 212x sparse.
        let allocated: UInt64 = 5_186_609_152
        let apparent: UInt64 = 1_099_589_118_849
        let node = child(name: "com.docker.docker", allocated: allocated, apparent: apparent)

        let expected = "On-disk sizes. \(Format.bytes(allocated)) here, from files whose logical size is "
            + "\(Format.bytes(apparent)) — sparse, cloned or cloud-evicted."
        XCTAssertEqual(DiskSpaceModel.disclosureText(for: node), expected)
    }

    func testDisclosureNamesBlockRoundingWhenAllocatedExceedsApparent() {
        // NOTE: SPEC §14.6 / CONTEXT D-15 cite ~/Documents's own reference-machine magnitudes
        // (3 812 725 259 apparent / 3 925 614 592 allocated, "ratio 0.97") as the worked example
        // of "allocated larger" -- but that pair is only a ~2.96 % gap, which does *not* cross
        // this same document's >10 % threshold; run through the real rule it renders as form 3
        // (within 10 %), not form 2. The plan's own worked numbers contradict its own threshold,
        // so this fixture keeps the 183 063-file flavour but scales the gap to genuinely clear
        // 10 %, which is what the "allocated larger" form actually requires to fire.
        let apparent: UInt64 = 3_000_000_000
        let allocated: UInt64 = 3_500_000_000
        let node = child(name: "Documents", allocated: allocated, apparent: apparent, entries: 183_063)

        let expected = "On-disk sizes; \(Format.count(183_063)) small files round up to 4 KB blocks."
        XCTAssertEqual(DiskSpaceModel.disclosureText(for: node), expected)
    }

    func testDisclosureFallsBackWithinTenPercentEitherWay() {
        let closeNode = child(name: "close", allocated: 1_000_000, apparent: 1_050_000)
        XCTAssertEqual(
            DiskSpaceModel.disclosureText(for: closeNode),
            "On-disk sizes; clones, sparse files and snapshots can differ from logical size."
        )

        let locked = child(name: "Locked", readable: false, allocated: nil, apparent: nil)
        XCTAssertNil(DiskSpaceModel.disclosureText(for: locked), "nothing to disclose about a size never read")
    }

    // MARK: - D-14: descending by allocated, nil last, name ascending tie-break

    func testChildrenSortByAllocatedDescendingWithNilLastAndNameTieBreak() {
        let level = LevelResult(
            rootPath: "/fixture",
            children: [
                child(name: "B", allocated: 100, apparent: 100),
                child(name: "A", allocated: 100, apparent: 100),
                child(name: "Locked", readable: false, allocated: nil, apparent: nil),
                child(name: "C", allocated: 500, apparent: 500),
            ],
            sizedCount: 4, totalCount: 4, cancelled: false, rootUnavailableReason: nil,
            millisecondsElapsed: 1, unreadableCount: 0
        )

        let cells = DiskSpaceModel.project(level)
        // C (largest) first; A before B on the equal-byte tie (name ascending); Locked last
        // regardless of which end a naive ascending-vs-descending read would place it at.
        XCTAssertEqual(cells.map(\.name), ["C", "A", "B", "Locked"])
        XCTAssertEqual(cells.map(\.bytes), [500, 100, 100, nil])
    }

    // MARK: - §14.6's closing sentence: the three footers are never confusable

    func testTheThreeFailureFootersAreDistinctAndNoneIsEmpty() {
        func level(cancelled: Bool, rootUnavailableReason: String?, unreadableCount: Int) -> LevelResult {
            LevelResult(
                rootPath: "/fixture", children: [], sizedCount: 5, totalCount: 12,
                cancelled: cancelled, rootUnavailableReason: rootUnavailableReason,
                millisecondsElapsed: 1, unreadableCount: unreadableCount
            )
        }

        let cancelledText = DiskSpaceModel.footerText(
            for: level(cancelled: true, rootUnavailableReason: nil, unreadableCount: 0))
        let partialText = DiskSpaceModel.footerText(
            for: level(cancelled: false, rootUnavailableReason: nil, unreadableCount: 4))
        let unavailableText = DiskSpaceModel.footerText(
            for: level(cancelled: false, rootUnavailableReason: "Permission denied", unreadableCount: 0))

        XCTAssertEqual(cancelledText, "Sizing stopped at 5 of 12 items.")
        XCTAssertEqual(partialText, "4 items could not be read; their sizes are not included.")
        XCTAssertEqual(unavailableText, "Permission denied")

        XCTAssertNotEqual(cancelledText, partialText)
        XCTAssertNotEqual(cancelledText, unavailableText)
        XCTAssertNotEqual(partialText, unavailableText)
        for text in [cancelledText, partialText, unavailableText] {
            XCTAssertFalse(text.isEmpty)
        }
    }

    // MARK: - D-07: the purgeable clause only above a 1 GB gap

    func testPurgeableClauseAppearsOnlyAboveOneGigabyte() {
        let bigGap = volume(free: 60_000_000_000, importantFree: 60_000_000_000 + 13_500_000_000)
        XCTAssertEqual(
            DiskSpaceModel.purgeableClause(bigGap),
            "\(Format.bytes(13_500_000_000)) more is purgeable (snapshots, caches)"
        )

        let smallGap = volume(free: 60_000_000_000, importantFree: 60_000_000_000 + 500_000_000)
        XCTAssertNil(DiskSpaceModel.purgeableClause(smallGap))
    }

    // MARK: - Format discipline

    func testProjectionUsesFormatAndNotAdHocStringFormatting() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/GlowTopCoreTests/DiskSpaceModelTests.swift",
            with: "Sources/GlowTopCore/DiskSpaceModel.swift"
        )
        XCTAssertTrue(path.hasSuffix("Sources/GlowTopCore/DiskSpaceModel.swift"), "re-pointed, not copy-pasted")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(source.contains("String(format:"))
        XCTAssertFalse(source.contains("NumberFormatter"))
    }
}
