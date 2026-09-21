import AppKit
import GlowTopCore
import QuartzCore

/// One chart plot, composited by Core Animation. SPEC.md §4.4, §4.5, §4.6, §6.5.
///
/// RENDER-05: takes its series and its resolved colours as parameters and holds no
/// Summary-private state, so any pane constructs one. Phase 10's Performance pane
/// constructs this type; it does not copy it.
///
/// One container per plot rect, `masksToBounds` standing in for `context.clip(to: plot)`.
/// Beneath it: one `CAShapeLayer` per stroked series, one per `.solid` band, one
/// `CAGradientLayer` masked by a shape layer per `.gradient` fill, and one shape layer for the
/// gridlines. Assigning one series' `path` leaves every other layer's rasterization alone,
/// which is the whole reason this path exists (phase-09 plan, Phase 0). Paths are built in the
/// container's own space -- `PlotRect(x: 0, y: 0, ...)` -- so no coordinate conversion exists
/// to get wrong; the view is unflipped and a layer's `geometryFlipped` is false, so both are
/// bottom-left origin and the mapping is the identity.
///
/// Nothing here animates. `actions` are nulled at construction and every write sits inside a
/// `CATransaction` with actions disabled: §6.6 rule 4 forbids interpolating a time series'
/// *values*, and an implicit 0.25 s `path` animation is exactly that, ten times a second.
@MainActor
final class ChartLayer: CALayer {
    /// The ring buffer's capacity (§6.4), not `values.count` — 600 for §4.4 and §4.5, 240 for
    /// §4.6's tiles. Fixed per plot, so it is an initializer parameter.
    nonisolated let capacity: Int

    private let gridlineLayer = CAShapeLayer()
    private var slots: [Slot] = []
    private var slotKeys: [SlotKey] = []
    private var gridKey: GridKey?
    private var laidOutSize = CGSize.zero
    private var laidOutScale: CGFloat = 0
    private var theme: Theme?
    private var colors: ThemeColors?

    /// The sublayers one `SeriesDescriptor` owns, in z-order: its fill, then its stroke.
    private struct Slot {
        let stroke: CAShapeLayer
        let band: CAShapeLayer?
        let gradient: CAGradientLayer?
        let area: CAShapeLayer?
        let key: SlotKey

        func clear() {
            stroke.path = nil
            band?.path = nil
            area?.path = nil
        }
    }

    /// Everything about a descriptor other than its values. Slots are rebuilt when this
    /// changes (a series appearing or vanishing, §4.4's temperature line) and reused otherwise,
    /// so a per-tick `apply` touches `path` and nothing else.
    private struct SlotKey: Equatable {
        let colorToken: String
        let opacity: Double
        let lineWidth: Double
        let dash: [Double]?
        let fill: Fill?

        init(_ descriptor: SeriesDescriptor) {
            colorToken = descriptor.colorToken
            opacity = descriptor.opacity
            lineWidth = descriptor.lineWidth
            dash = descriptor.dash
            fill = descriptor.fill
        }
    }

    private struct GridKey: Equatable {
        let gridlines: [Double]
        let axis: ChartAxis
        let rightGridlines: [Double]
        let rightAxis: ChartAxis?
        let size: CGSize
    }

    private static let noActions: [String: CAAction] = [
        "path": NSNull(), "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
        "strokeColor": NSNull(), "fillColor": NSNull(), "colors": NSNull(), "hidden": NSNull(),
    ]

    init(capacity: Int) {
        self.capacity = capacity
        super.init()
        masksToBounds = true
        actions = Self.noActions
        gridlineLayer.fillColor = nil
        gridlineLayer.lineWidth = 1
        gridlineLayer.actions = Self.noActions
        addSublayer(gridlineLayer)
    }

    /// Core Animation's presentation-tree copy. Never called while nothing in the tree
    /// animates, and an unimplemented designated initializer is a crash the first time
    /// something does (`presentation()`, or any animation on a sibling).
    nonisolated override init(layer: Any) {
        capacity = (layer as? ChartLayer)?.capacity ?? 0
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Parameters

    /// Per tick. Touches `path` and nothing else once the sublayers exist. An empty `series`
    /// clears every path including the gridlines' and returns — §4.8 omits the plot area
    /// entirely, and gridlines on an omitted plot are a plot.
    func apply(series: [SeriesDescriptor], gridlines: [Double], axis: ChartAxis,
               rightGridlines: [Double] = [], rightAxis: ChartAxis? = nil,
               scrollOffset: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let size = bounds.size
        if size != laidOutSize || contentsScale != laidOutScale {
            laidOutSize = size
            laidOutScale = contentsScale
            gridKey = nil
            frameSublayers()
        }

        // A degenerate plot draws nothing, gridlines included (the CoreGraphics path's own guard).
        guard !series.isEmpty, size.width > 1, size.height > 1 else {
            gridlineLayer.path = nil
            for slot in slots { slot.clear() }
            return
        }

        let key = GridKey(gridlines: gridlines, axis: axis, rightGridlines: rightGridlines,
                          rightAxis: rightAxis, size: size)
        if key != gridKey {
            gridKey = key
            gridlineLayer.path = Self.gridlinePath(key)
        }

        let keys = series.map(SlotKey.init)
        if keys != slotKeys {
            rebuildSlots(keys)
        }

        let rect = PlotRect(x: 0, y: 0, width: size.width, height: size.height)
        var previous: [(x: Double, y: Double)] = []
        for (descriptor, slot) in zip(series, slots) {
            let points = ChartSeries.points(descriptor, in: rect, scrollOffset: scrollOffset)
            guard points.count > 1 else {
                slot.clear()
                previous = points
                continue
            }
            switch descriptor.fill {
            case .gradient:
                slot.area?.path = Self.areaPath(points)
            case .solid:
                slot.band?.path = Self.bandPath(upper: points, lower: previous)
            case nil:
                break
            }
            slot.stroke.path = descriptor.lineWidth > 0 ? Self.linePath(points) : nil
            previous = points
        }
    }

    /// On a theme change only. Touches `strokeColor`, `fillColor` and the gradient `colors`
    /// array, and nothing else. Resolved once here, never per frame (§7.3's one-owner rule).
    func applyTheme(_ theme: Theme, colors: ThemeColors) {
        self.theme = theme
        self.colors = colors
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridlineLayer.strokeColor = colors.color("gridline")
        for slot in slots { colour(slot) }
        CATransaction.commit()
    }

    // MARK: - Sublayers

    private func rebuildSlots(_ keys: [SlotKey]) {
        for slot in slots {
            slot.stroke.removeFromSuperlayer()
            slot.band?.removeFromSuperlayer()
            slot.gradient?.removeFromSuperlayer()
        }
        slots = keys.map { key in
            let stroke = CAShapeLayer()
            stroke.fillColor = nil
            stroke.lineWidth = key.lineWidth
            // §4.4: round joins and caps, no per-point markers.
            stroke.lineJoin = .round
            stroke.lineCap = .round
            stroke.lineDashPattern = key.dash.map { $0.map { NSNumber(value: $0) } }
            stroke.actions = Self.noActions

            var band: CAShapeLayer?
            var gradient: CAGradientLayer?
            var area: CAShapeLayer?
            switch key.fill {
            case .solid:
                let layer = CAShapeLayer()
                layer.strokeColor = nil
                layer.actions = Self.noActions
                band = layer
            case .gradient:
                // The CoreGraphics path drew from the plot's top (alpha 0) to its
                // baseline (`topOpacity`), clipped to the area under the line. Same here: the
                // gradient fills the container and the area path is its mask. A layer's unit
                // space is bottom-left origin, so `startPoint` y 0 is the baseline.
                let layer = CAGradientLayer()
                layer.startPoint = CGPoint(x: 0.5, y: 0)
                layer.endPoint = CGPoint(x: 0.5, y: 1)
                layer.actions = Self.noActions
                let mask = CAShapeLayer()
                mask.strokeColor = nil
                mask.fillColor = CGColor(gray: 0, alpha: 1)
                mask.actions = Self.noActions
                layer.mask = mask
                gradient = layer
                area = mask
            case nil:
                break
            }
            return Slot(stroke: stroke, band: band, gradient: gradient, area: area, key: key)
        }
        slotKeys = keys
        // Z-order is the CoreGraphics path's: series in order, each one's fill beneath its stroke.
        for slot in slots {
            if let band = slot.band { addSublayer(band) }
            if let gradient = slot.gradient { addSublayer(gradient) }
            addSublayer(slot.stroke)
        }
        frameSublayers()
        for slot in slots { colour(slot) }
    }

    private func frameSublayers() {
        let scale = contentsScale
        for layer in sublayers ?? [] {
            layer.frame = bounds
            layer.contentsScale = scale
            if let mask = layer.mask {
                mask.frame = bounds
                mask.contentsScale = scale
            }
        }
    }

    private func colour(_ slot: Slot) {
        guard let theme, let colors else { return }
        let hex = Theme.hex(for: slot.key.colorToken, theme: theme)
        slot.stroke.strokeColor = colors.color(hex: hex, alpha: slot.key.opacity)
        switch slot.key.fill {
        case .solid(let opacity):
            slot.band?.fillColor = colors.color(hex: hex, alpha: opacity)
        case .gradient(let topOpacity):
            // §4.4's two stops: the accent at `topOpacity`, then fully transparent.
            slot.gradient?.colors = [Theme.cgColor(hex: hex, alpha: topOpacity),
                                     Theme.cgColor(hex: hex, alpha: 0)]
        case nil:
            break
        }
    }

    // MARK: - Paths, in container space

    private static func gridlinePath(_ key: GridKey) -> CGPath? {
        guard !key.gridlines.isEmpty || (key.rightAxis != nil && !key.rightGridlines.isEmpty)
        else { return nil }
        let path = CGMutablePath()
        func add(_ values: [Double], _ axis: ChartAxis) {
            for value in values {
                let y = key.size.height * axis.normalise(value)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: key.size.width, y: y))
            }
        }
        add(key.gridlines, key.axis)
        if let rightAxis = key.rightAxis { add(key.rightGridlines, rightAxis) }
        return path
    }

    private static func linePath(_ points: [(x: Double, y: Double)]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x, y: points[0].y))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        return path
    }

    /// §4.4's gradient clip: the area between the line and the baseline.
    private static func areaPath(_ points: [(x: Double, y: Double)]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x, y: 0))
        for point in points {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: 0))
        path.closeSubpath()
        return path
    }

    /// §4.5's stacked band: between this cumulative path and the one below it,
    /// or down to the baseline when there is none of matching length.
    private static func bandPath(upper: [(x: Double, y: Double)],
                                 lower: [(x: Double, y: Double)]) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: upper[0].x, y: upper[0].y))
        for point in upper.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.y))
        }
        if lower.count == upper.count, !lower.isEmpty {
            for point in lower.reversed() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
        } else {
            path.addLine(to: CGPoint(x: upper[upper.count - 1].x, y: 0))
            path.addLine(to: CGPoint(x: upper[0].x, y: 0))
        }
        path.closeSubpath()
        return path
    }
}

extension Theme {
    /// Resolves a `SeriesDescriptor.colorToken` to hex.
    ///
    /// Most tokens are §7.2 rows. §4.5's timeline layers 3 and 4 are named literally in §4.5
    /// with no §7.2 token, and `SummaryModel` marks them with a `specLiteral.` prefix rather
    /// than inventing token names — a token phase-05's editor would show as a row the spec
    /// never specified is worse than a literal citing its section.
    static func hex(for token: String, theme: Theme) -> String {
        switch token {
        case SummaryModel.memoryCompressedToken: return SpecLiteralColor.memoryCompressed
        case SummaryModel.memoryCachedToken: return SpecLiteralColor.memoryCached
        default: return theme[token] ?? theme.textDisabled
        }
    }
}
