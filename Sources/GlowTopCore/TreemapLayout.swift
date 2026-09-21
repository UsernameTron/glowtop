import Foundation

/// SPEC.md §14.6's squarified treemap layout (Bruls, Huizing & van Wijk, "Squarified
/// Treemaps", 2000, §3), as pure arithmetic over the disk-space pane's node children.
///
/// Four `Double`s, not `CGRect`: `GlowTopCore` imports no CoreGraphics (`ChartSeries.swift`'s
/// own header states the rule), and a layout exercised by `swift test` with no window and no
/// context is exactly what §7.1's split is for. `TreemapLayer` converts on the way out.
///
/// **Coordinate convention**, matching every other bottom-left-origin rect in this codebase
/// (`ChartSeries.swift`'s `PlotRect`, and every App-side pane view): `y` increases upward, so
/// the "bottom" of a rect is its low-`y` edge and "up" is the direction of increasing `y`.

/// A rectangle in arbitrary units, bottom-left origin.
public struct TreemapRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { max(width, 0) * max(height, 0) }
}

/// A fixed cell footprint -- the `Locked` rectangle's 60 x 32 pt and the minimum-cell floor's
/// 8 x 8 pt both arrive as one of these.
public struct TreemapSize: Sendable, Equatable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// One child of the node being laid out. `bytes == nil` means **unreadable** (D-20's
/// `Locked`): it is carved out at a fixed size before the readable siblings are laid
/// out proportionally, because it has no area to be proportional to. A child of
/// **zero** bytes is `0`, not `nil`, and lays out normally.
public struct TreemapChild: Sendable, Equatable {
    public let name: String
    public let bytes: UInt64?

    public init(name: String, bytes: UInt64?) {
        self.name = name
        self.bytes = bytes
    }
}

/// One rectangle to draw. `bytes == nil` -> the `Locked` treatment.
/// `aggregatedCount > 0` -> the synthetic `{k} smaller items` cell.
public struct TreemapCell: Sendable, Equatable {
    public let name: String
    public let bytes: UInt64?
    public let aggregatedCount: Int
    public let rect: TreemapRect

    public init(name: String, bytes: UInt64?, aggregatedCount: Int, rect: TreemapRect) {
        self.name = name
        self.bytes = bytes
        self.aggregatedCount = aggregatedCount
        self.rect = rect
    }
}

/// The arrow-key direction for `TreemapLayout.neighbour(of:in:direction:)`.
public enum TreemapDirection: Sendable {
    case left, right, up, down
}

public enum TreemapLayout {
    /// A child carrying its byte total non-optionally and its aggregation count, once the
    /// `Locked` partition and the floor aggregation are both resolved. Internal-only: the
    /// public surface never sees an intermediate weight.
    private struct WeightedItem {
        let name: String
        let bytes: UInt64
        let aggregatedCount: Int
    }

    /// Lays `children` into `rect`. `Locked` children (`bytes == nil`) are carved off the
    /// bottom edge first, at `lockedCell`'s fixed size; the readable remainder squarifies
    /// into whatever is left, aggregating anything below `minimumCell`'s floor.
    public static func layout(
        _ children: [TreemapChild], in rect: TreemapRect,
        lockedCell: TreemapSize, minimumCell: TreemapSize
    ) -> [TreemapCell] {
        let locked = children.filter { $0.bytes == nil }.sorted { $0.name < $1.name }
        let readable = children.filter { $0.bytes != nil }

        // 1. Carve the locked band off the bottom, left-to-right in name order.
        //
        // The 60 x 32 invariant (`lockedCell`'s own size) holds exactly when
        // `locked.count <= perRow` and `lockedCell.height <= rect.height / 2`. Beyond that
        // the grid keeps every cell the same size as its row- and column-mates -- it shrinks
        // uniformly rather than returning overlapping rects to preserve a size it cannot
        // honour.
        var lockedCells: [TreemapCell] = []
        var available = rect
        if !locked.isEmpty, rect.width > 0 {
            let perRow = max(1, Int(rect.width / lockedCell.width))
            let rows = Int((Double(locked.count) / Double(perRow)).rounded(.up))
            let bandHeight = min(Double(rows) * lockedCell.height, rect.height / 2)
            let rowHeight = bandHeight / Double(rows)
            let cellWidth = rect.width / Double(perRow)
            let bandTop = rect.y + bandHeight // the edge touching the readable area above it

            for (index, child) in locked.enumerated() {
                let row = index / perRow
                let column = index % perRow
                let cellRect = TreemapRect(
                    x: rect.x + Double(column) * cellWidth,
                    y: bandTop - Double(row + 1) * rowHeight,
                    width: cellWidth, height: rowHeight)
                lockedCells.append(
                    TreemapCell(name: child.name, bytes: nil, aggregatedCount: 0, rect: cellRect))
            }
            available = TreemapRect(
                x: rect.x, y: bandTop, width: rect.width, height: rect.height - bandHeight)
        }

        // 2. Aggregate children below the minimum-cell floor into one synthetic cell.
        //
        // The threshold is computed once, in bytes, from the *unaggregated* total: aggregating
        // changes the layout, so testing against a recomputed threshold would be circular
        // (area is proportional to bytes under squarified, so one byte-threshold pass is the
        // area test done once). Fewer than two children below the floor are left alone -- an
        // aggregate of one is a rename, not an aggregation.
        let totalBytes = readable.reduce(UInt64(0)) { $0 + ($1.bytes ?? 0) }
        var items = readable.map {
            WeightedItem(name: $0.name, bytes: $0.bytes ?? 0, aggregatedCount: 0)
        }
        if available.area > 0, totalBytes > 0 {
            let minBytes =
                Double(totalBytes) * minimumCell.width * minimumCell.height / available.area
            let small = items.filter { Double($0.bytes) < minBytes }
            if small.count >= 2 {
                let keep = items.filter { Double($0.bytes) >= minBytes }
                let sum = small.reduce(UInt64(0)) { $0 + $1.bytes }
                let aggregate = WeightedItem(
                    name: "\(Format.count(small.count)) smaller items", bytes: sum,
                    aggregatedCount: small.count)
                items = keep + [aggregate]
            }
        }

        // 3. Sort descending by (bytes, name ascending) -- two walks of an unchanged disk
        // produce the same map.
        items.sort { lhs, rhs in
            lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : lhs.name < rhs.name
        }

        return lockedCells + squarify(items, in: available)
    }

    /// `neighbour(of:in:direction:)` -- the arrow-key rule (UI-SPEC Open Item 3).
    ///
    /// Candidates are cells whose centre lies strictly in `direction` from `origin`'s centre.
    /// The winner minimises `primaryAxisDistance + 0.5 * crossAxisDistance`. Nil when no
    /// candidate exists -- the selection does not wrap and does not move.
    ///
    /// The half-weighted cross axis is deliberate: a pure nearest-centre rule skips the
    /// visually obvious neighbour whenever squarified produces rows of very different
    /// heights, which it routinely does.
    public static func neighbour(
        of index: Int, in cells: [TreemapCell], direction: TreemapDirection
    ) -> Int? {
        guard cells.indices.contains(index) else { return nil }
        let origin = center(of: cells[index].rect)

        var best: Int?
        var bestScore = Double.infinity
        for (candidateIndex, cell) in cells.enumerated() where candidateIndex != index {
            let candidate = center(of: cell.rect)
            let dx = candidate.x - origin.x
            let dy = candidate.y - origin.y

            let inDirection: Bool
            let primary: Double
            let cross: Double
            switch direction {
            case .left: inDirection = dx < 0; primary = -dx; cross = abs(dy)
            case .right: inDirection = dx > 0; primary = dx; cross = abs(dy)
            case .up: inDirection = dy > 0; primary = dy; cross = abs(dx)
            case .down: inDirection = dy < 0; primary = -dy; cross = abs(dx)
            }
            guard inDirection else { continue }

            let score = primary + 0.5 * cross
            if score < bestScore {
                bestScore = score
                best = candidateIndex
            }
        }
        return best
    }

    private static func center(of rect: TreemapRect) -> (x: Double, y: Double) {
        (x: rect.x + rect.width / 2, y: rect.y + rect.height / 2)
    }

    // MARK: - Squarify

    /// `totalBytes == 0` (a directory of empty files, which exists) lays out equally by count
    /// rather than divide by zero.
    private static func squarify(_ items: [WeightedItem], in rect: TreemapRect) -> [TreemapCell]
    {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let totalBytes = items.reduce(0.0) { $0 + Double($1.bytes) }
        let weights = totalBytes > 0 ? items.map { Double($0.bytes) } : items.map { _ in 1.0 }
        return squarifyRows(items, weights: weights, in: rect)
    }

    /// The row-building loop: a child is added to the current row while `worst` does not
    /// increase; otherwise the row is placed and a new one starts in what remains. Rows are
    /// laid along the shorter side of the remaining rect, filling from its `minX`/`maxY`
    /// corner inward -- the largest cell (index 0, after the caller's sort) lands top-left,
    /// where a reader looks first.
    private static func squarifyRows(
        _ items: [WeightedItem], weights: [Double], in rect: TreemapRect
    ) -> [TreemapCell] {
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return [] }
        let scale = rect.area / totalWeight

        var cells: [TreemapCell] = []
        var remaining = rect
        var row: [WeightedItem] = []
        var rowAreas: [Double] = []
        var index = 0

        while index < items.count {
            let area = weights[index] * scale
            let side = min(remaining.width, remaining.height)
            let candidateAreas = rowAreas + [area]
            if rowAreas.isEmpty || worst(rowAreas, side) >= worst(candidateAreas, side) {
                row.append(items[index])
                rowAreas.append(area)
                index += 1
            } else {
                remaining = place(row, rowAreas, in: remaining, into: &cells)
                row = []
                rowAreas = []
            }
        }
        if !row.isEmpty {
            remaining = place(row, rowAreas, in: remaining, into: &cells)
        }
        _ = remaining
        return cells
    }

    /// `worst(R, w)` -- the worst aspect ratio of a row `R` laid along a side of length `w`,
    /// with `s = sum(R)`: `max(w^2*max(R)/s^2, s^2/(w^2*min(R)))`. Bruls, Huizing & van Wijk,
    /// "Squarified Treemaps" (2000), §3.
    private static func worst(_ row: [Double], _ w: Double) -> Double {
        guard !row.isEmpty, w > 0 else { return .infinity }
        let s = row.reduce(0, +)
        guard s > 0 else { return .infinity }
        let maxR = row.max() ?? 0
        let minR = row.min() ?? 0
        // ponytail: a zero-weight row (a zero-byte child sharing a row with nothing else
        // positive) has no well-defined aspect ratio; treating it as infinitely bad forces the
        // row to close immediately, and `place` below gives the zero-weight item its own
        // degenerate cell rather than dropping it.
        guard minR > 0 else { return .infinity }
        return max((w * w * maxR) / (s * s), (s * s) / (w * w * minR))
    }

    /// Places one row into `rect`, appends its cells, and returns what remains. Rows are laid
    /// along the shorter side: a horizontal band across the top when `width <= height`, a
    /// vertical strip down the left otherwise -- both anchored at the `minX`/`maxY` corner.
    private static func place(
        _ row: [WeightedItem], _ areas: [Double], in rect: TreemapRect,
        into cells: inout [TreemapCell]
    ) -> TreemapRect {
        let total = areas.reduce(0, +)
        guard total > 0 else {
            // A degenerate (zero-area) row: still emit one cell per item, at the rect's own
            // corner, so a zero-byte child is laid out rather than silently dropped.
            for item in row {
                cells.append(
                    TreemapCell(
                        name: item.name, bytes: item.bytes, aggregatedCount: item.aggregatedCount,
                        rect: TreemapRect(x: rect.x, y: rect.y, width: 0, height: 0)))
            }
            return rect
        }

        if rect.width <= rect.height {
            let thickness = total / rect.width
            let bandY = rect.y + rect.height - thickness
            var x = rect.x
            for (item, area) in zip(row, areas) {
                let width = area / thickness
                cells.append(
                    TreemapCell(
                        name: item.name, bytes: item.bytes, aggregatedCount: item.aggregatedCount,
                        rect: TreemapRect(x: x, y: bandY, width: width, height: thickness)))
                x += width
            }
            return TreemapRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height - thickness)
        } else {
            let thickness = total / rect.height
            var y = rect.y + rect.height
            for (item, area) in zip(row, areas) {
                let height = area / thickness
                y -= height
                cells.append(
                    TreemapCell(
                        name: item.name, bytes: item.bytes, aggregatedCount: item.aggregatedCount,
                        rect: TreemapRect(x: rect.x, y: y, width: thickness, height: height)))
            }
            return TreemapRect(
                x: rect.x + thickness, y: rect.y, width: rect.width - thickness, height: rect.height)
        }
    }
}
