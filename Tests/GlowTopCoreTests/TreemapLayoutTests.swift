import XCTest
@testable import GlowTopCore

/// SPEC.md §14.6's squarified layout, exercised with no window and no context (D-12, O-1).
final class TreemapLayoutTests: XCTestCase {
    private let zeroFloor = TreemapSize(width: 0, height: 0)
    private let lockedSize = TreemapSize(width: 60, height: 32)

    private func overlapArea(_ a: TreemapRect, _ b: TreemapRect) -> Double {
        let width = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let height = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        return width * height
    }

    func testAreasAreProportionalToBytes() {
        let rect = TreemapRect(x: 0, y: 0, width: 1000, height: 1000)
        let byName: [String: UInt64] = ["A": 500, "B": 300, "C": 100, "D": 80, "E": 20]
        let children = byName.map { TreemapChild(name: $0.key, bytes: $0.value) }
        let totalBytes = Double(byName.values.reduce(0, +))

        let cells = TreemapLayout.layout(
            children, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        XCTAssertEqual(cells.count, byName.count)
        for cell in cells {
            let expectedFraction = Double(byName[cell.name]!) / totalBytes
            let actualFraction = cell.rect.area / rect.area
            XCTAssertEqual(actualFraction, expectedFraction, accuracy: 0.005, cell.name)
        }
    }

    func testCellsDoNotOverlap() {
        let rect = TreemapRect(x: 0, y: 0, width: 2000, height: 1000)
        let children = (1...20).map { TreemapChild(name: "child\($0)", bytes: UInt64($0 * $0)) }

        let cells = TreemapLayout.layout(
            children, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        for i in cells.indices {
            for j in cells.indices where j > i {
                XCTAssertEqual(overlapArea(cells[i].rect, cells[j].rect), 0, accuracy: 1e-6)
            }
        }
    }

    func testCellsFillTheContainerWithinHalfAPercent() {
        let rect = TreemapRect(x: 0, y: 0, width: 733, height: 511)
        let children = [
            TreemapChild(name: "A", bytes: 4000), TreemapChild(name: "B", bytes: 3200),
            TreemapChild(name: "C", bytes: 2100), TreemapChild(name: "D", bytes: 1500),
            TreemapChild(name: "E", bytes: 900), TreemapChild(name: "F", bytes: 400),
            TreemapChild(name: "G", bytes: 245),
        ]

        let cells = TreemapLayout.layout(
            children, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        let summedArea = cells.reduce(0.0) { $0 + $1.rect.area }
        XCTAssertEqual(summedArea, rect.area, accuracy: rect.area * 0.005)
    }

    func testASingleChildFillsTheWholeRect() {
        let rect = TreemapRect(x: 0, y: 0, width: 400, height: 300)
        let children = [TreemapChild(name: "only", bytes: 1)]

        let cells = TreemapLayout.layout(
            children, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].rect, rect)
    }

    func testAZeroByteChildIsLaidOutNotCarvedOut() {
        let rect = TreemapRect(x: 0, y: 0, width: 400, height: 300)
        let children = [
            TreemapChild(name: "Locked1", bytes: nil),
            TreemapChild(name: "Zero", bytes: 0),
            TreemapChild(name: "Big", bytes: 1000),
        ]

        let cells = TreemapLayout.layout(
            children, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        XCTAssertEqual(cells.count, 3)
        let zero = try! XCTUnwrap(cells.first { $0.name == "Zero" })
        XCTAssertEqual(zero.bytes, 0)
        XCTAssertEqual(zero.aggregatedCount, 0)
        let locked = try! XCTUnwrap(cells.first { $0.name == "Locked1" })
        XCTAssertNil(locked.bytes)
    }

    func testEqualValuesLayOutStablyAndByName() {
        let rect = TreemapRect(x: 0, y: 0, width: 500, height: 500)
        let shuffleOne = ["Echo", "Alpha", "Delta", "Charlie", "Bravo"]
            .map { TreemapChild(name: $0, bytes: 100) }
        let shuffleTwo = ["Bravo", "Delta", "Alpha", "Echo", "Charlie"]
            .map { TreemapChild(name: $0, bytes: 100) }

        let cellsOne = TreemapLayout.layout(
            shuffleOne, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)
        let cellsTwo = TreemapLayout.layout(
            shuffleTwo, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        XCTAssertEqual(cellsOne, cellsTwo)
        XCTAssertEqual(cellsOne.map(\.name), ["Alpha", "Bravo", "Charlie", "Delta", "Echo"])
    }

    func testLockedChildrenAreCarvedAtTheFixedSizeAndExcludedFromProportion() {
        let rect = TreemapRect(x: 0, y: 0, width: 300, height: 300)
        let children = [
            TreemapChild(name: "Locked1", bytes: nil),
            TreemapChild(name: "A", bytes: 700),
            TreemapChild(name: "B", bytes: 300),
        ]

        let cells = TreemapLayout.layout(
            children, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        let locked = try! XCTUnwrap(cells.first { $0.name == "Locked1" })
        XCTAssertEqual(locked.rect, TreemapRect(x: 0, y: 0, width: 60, height: 32))

        // The band spans the container's full width (one row, height 32) -- the whole strip is
        // carved out of the readable area, not just the one locked cell's own footprint.
        let readableArea = cells.filter { $0.bytes != nil }.reduce(0.0) { $0 + $1.rect.area }
        let expectedAvailableArea = rect.area - rect.width * 32
        XCTAssertEqual(readableArea, expectedAvailableArea, accuracy: expectedAvailableArea * 0.005)
    }

    func testTooManyLockedChildrenShrinkUniformlyRatherThanOverlap() {
        let rect = TreemapRect(x: 0, y: 0, width: 400, height: 200)
        let children = (1...40).map { TreemapChild(name: String(format: "n%02d", $0), bytes: nil) }

        let cells = TreemapLayout.layout(
            children, in: rect, lockedCell: lockedSize, minimumCell: zeroFloor)

        XCTAssertEqual(cells.count, 40)
        // The band is capped at half the container height, so every row's height is shrunk
        // below `lockedCell.height` -- confirmed via the returned rects rather than re-deriving
        // the internal band arithmetic.
        for cell in cells {
            XCTAssertLessThanOrEqual(cell.rect.y + cell.rect.height, rect.height / 2 + 1e-9)
            XCTAssertLessThan(cell.rect.height, lockedSize.height)
        }
        for i in cells.indices {
            for j in cells.indices where j > i {
                XCTAssertEqual(overlapArea(cells[i].rect, cells[j].rect), 0, accuracy: 1e-6)
            }
        }
    }

    func testChildrenBelowTheFloorAggregateIntoOneCell() {
        let rect = TreemapRect(x: 0, y: 0, width: 1000, height: 1000)
        let floor = TreemapSize(width: 8, height: 8)
        let large = [
            TreemapChild(name: "Big1", bytes: 100_000), TreemapChild(name: "Big2", bytes: 100_000),
        ]
        let tiny = (1...12).map { TreemapChild(name: "tiny\($0)", bytes: 1) }

        let cells = TreemapLayout.layout(large + tiny, in: rect, lockedCell: lockedSize, minimumCell: floor)

        let aggregate = try! XCTUnwrap(cells.first { $0.aggregatedCount > 0 })
        XCTAssertEqual(aggregate.aggregatedCount, 12)
        XCTAssertEqual(aggregate.name, "12 smaller items")
        XCTAssertEqual(cells.count, large.count + 1)

        let oneTinyCells = TreemapLayout.layout(
            large + [TreemapChild(name: "onlyTiny", bytes: 1)], in: rect, lockedCell: lockedSize,
            minimumCell: floor)
        XCTAssertTrue(oneTinyCells.allSatisfy { $0.aggregatedCount == 0 })
        XCTAssertTrue(oneTinyCells.contains { $0.name == "onlyTiny" })
    }

    func testNeighbourMovesInEachDirectionAndStopsAtTheEdge() {
        let cells = [
            TreemapCell(name: "A", bytes: 1, aggregatedCount: 0,
                        rect: TreemapRect(x: 0, y: 0, width: 50, height: 50)),
            TreemapCell(name: "B", bytes: 1, aggregatedCount: 0,
                        rect: TreemapRect(x: 50, y: 0, width: 50, height: 50)),
            TreemapCell(name: "C", bytes: 1, aggregatedCount: 0,
                        rect: TreemapRect(x: 0, y: 50, width: 50, height: 50)),
            TreemapCell(name: "D", bytes: 1, aggregatedCount: 0,
                        rect: TreemapRect(x: 50, y: 50, width: 50, height: 50)),
        ]

        XCTAssertEqual(TreemapLayout.neighbour(of: 0, in: cells, direction: .right), 1)
        XCTAssertEqual(TreemapLayout.neighbour(of: 0, in: cells, direction: .up), 2)
        XCTAssertNil(TreemapLayout.neighbour(of: 0, in: cells, direction: .left))
        XCTAssertNil(TreemapLayout.neighbour(of: 0, in: cells, direction: .down))

        XCTAssertEqual(TreemapLayout.neighbour(of: 3, in: cells, direction: .left), 2)
        XCTAssertEqual(TreemapLayout.neighbour(of: 3, in: cells, direction: .down), 1)
        XCTAssertNil(TreemapLayout.neighbour(of: 3, in: cells, direction: .right))
        XCTAssertNil(TreemapLayout.neighbour(of: 3, in: cells, direction: .up))
    }
}
