import AppKit
import GlowTopCore
import QuartzCore

/// §14.1's card 2: a bar per DVFS state, recomputed each tick, x keyed to state rank
/// rather than to time.
///
/// **A new drawing type, deliberately.** `ChartLayer` and `ChartSeries` are built for
/// scrolling time series -- every x is `rect.x + step × (firstSlot + index) − scrollOffset`
/// against a fixed `capacity` (§6.6 rule 4) -- and neither has a categorical path. Adding
/// one would put a second, unrelated geometry inside the type phase-09 shipped so panes
/// could construct it (RENDER-05). So this is its own file, it is the only new
/// path-building code in phase-11, and `ChartLayer` is untouched.
///
/// Nothing here animates: `actions` are nulled at construction and every write sits inside a
/// `CATransaction` with actions disabled, `ChartLayer`'s own rule. Colours are resolved the way
/// `ChartLayer` resolves them -- `Theme.hex(for:theme:)` then `Theme.cgColor(hex:alpha:)` --
/// once per theme change and once per opacity change, never per frame.
@MainActor
final class HistogramLayer: CALayer {
    /// One bar as this layer draws it: a height fraction 0...1, an opacity for the accent,
    /// and an optional x label already formatted by the model (§4.9's one-owner rule).
    struct Bar: Equatable {
        let heightFraction: Double
        let opacity: Double
        let label: String?
    }

    /// `histogramBarGap`, locked: §4.3.2's per-core strip gutter, reused.
    private static let gap: CGFloat = 2
    /// The locked floor. Below it adjacent states merge **at the rendering step only**.
    private static let minWidth: CGFloat = 4
    /// The x labels' line box. They are laid out **below** this layer's own bounds, at
    /// `y = −labelHeight`: `PowerFreqPaneView.statesPlotRect`'s bottom is `inner.minY + 27`,
    /// which is 12 (footer) + 4 (gap) + 11 (this), so a label's bottom edge lands 4 pt above
    /// the footer. The two numbers have to agree and are stated here where both can be read.
    private static let labelHeight: CGFloat = 11
    private static let labelWidth: CGFloat = 48

    private let gridlineLayer = CAShapeLayer()
    /// One per **merged** bar, rebuilt only when the merged count changes.
    private var barLayers: [CAShapeLayer] = []
    /// The opacity each bar layer's `fillColor` was last resolved at; `-1` forces a resolve.
    private var barOpacities: [Double] = []
    /// One per labelled bar.
    private var labelLayers: [CATextLayer] = []
    private var theme: Theme?
    private(set) var accentToken = ""
    private var accentHex = ""
    private var laidOutSize = CGSize.zero
    private var laidOutScale: CGFloat = 0
    private var lastGridlines: [Double]?

    /// `ChartLayer.noActions`' shape, its own copy -- `ChartLayer`'s is `private` and that
    /// file is in the untouched list.
    private static let noActions: [String: CAAction] = [
        "path": NSNull(), "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
        "strokeColor": NSNull(), "fillColor": NSNull(), "hidden": NSNull(),
    ]

    /// Constructed with its colours as parameters, the way `ChartLayer(capacity:)` is -- and,
    /// like it, a designated initializer of its own rather than `override init()`, whose body
    /// would be nonisolated and could not touch this actor-isolated layer's state.
    init(theme: Theme, accentToken: String) {
        super.init()
        actions = Self.noActions
        gridlineLayer.fillColor = nil
        gridlineLayer.lineWidth = 1
        gridlineLayer.actions = Self.noActions
        addSublayer(gridlineLayer)
        applyTheme(theme, accentToken: accentToken)
    }

    /// Core Animation's presentation-tree copy. Never called while nothing in the tree
    /// animates, and an unimplemented designated initializer is a crash the first time
    /// something does (`ChartLayer.swift`'s recorded reason).
    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Parameters

    /// Per tick. An **empty** `bars` clears every path including the gridlines' -- §4.8 omits
    /// the plot area entirely, and gridlines on an omitted plot are a plot (`ChartLayer.apply`'s
    /// own rule, reused rather than re-decided).
    func apply(bars: [Bar], gridlines: [Double]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let size = bounds.size
        if size != laidOutSize || contentsScale != laidOutScale {
            laidOutSize = size
            laidOutScale = contentsScale
            lastGridlines = nil
            frameSublayers()
        }

        guard !bars.isEmpty, size.width > 1, size.height > 1 else {
            gridlineLayer.path = nil
            for bar in barLayers { bar.path = nil }
            for label in labelLayers { label.string = "" }
            return
        }

        if lastGridlines != gridlines {
            lastGridlines = gridlines
            gridlineLayer.path = Self.gridlinePath(gridlines, size: size)
        }

        // Phase 0's geometry, verbatim. At 364 pt columns and 20 bars `maxBars` is 61 and
        // `groupSize` 1: the merge does not fire on this Mac at any window §3.1 allows.
        let merged = Self.merged(bars, width: size.width)
        ensureBars(merged.count)
        let barWidth = (size.width - Self.gap * CGFloat(merged.count - 1)) / CGFloat(merged.count)
        for (index, bar) in merged.enumerated() {
            let x = CGFloat(index) * (barWidth + Self.gap)
            let rect = CGRect(x: x, y: 0, width: barWidth,
                              height: size.height * CGFloat(min(max(bar.heightFraction, 0), 1)))
            barLayers[index].path = CGPath(rect: rect, transform: nil)
            if barOpacities[index] != bar.opacity {
                barOpacities[index] = bar.opacity
                barLayers[index].fillColor = Theme.cgColor(hex: accentHex, alpha: bar.opacity)
            }
        }

        // The sparse labels, centred under their bars and kept inside the column's width so a
        // wide end label does not run into the neighbouring column.
        let labelled = merged.enumerated().filter { $0.element.label != nil }
        ensureLabels(labelled.count)
        for ((index, bar), label) in zip(labelled, labelLayers) {
            let centre = CGFloat(index) * (barWidth + Self.gap) + barWidth / 2
            let x = min(max(centre - Self.labelWidth / 2, 0), max(size.width - Self.labelWidth, 0))
            label.frame = CGRect(x: x, y: -Self.labelHeight, width: Self.labelWidth,
                                 height: Self.labelHeight)
            if (label.string as? String) != bar.label { label.string = bar.label }
        }
    }

    /// On a theme change only. Resolves the accent and the gridline colour once.
    func applyTheme(_ theme: Theme, accentToken: String) {
        self.theme = theme
        self.accentToken = accentToken
        accentHex = Theme.hex(for: accentToken, theme: theme)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gridlineLayer.strokeColor = Theme.cgColor(hex: theme.gridline)
        for (layer, opacity) in zip(barLayers, barOpacities) where opacity >= 0 {
            layer.fillColor = Theme.cgColor(hex: accentHex, alpha: opacity)
        }
        let labelColor = Theme.cgColor(hex: theme.textDisabled)
        for label in labelLayers { label.foregroundColor = labelColor }
        CATransaction.commit()
    }

    // MARK: - The merge (rendering step only; the data keeps every state)

    /// Runs of `groupSize` adjacent bars: heights **sum** (the 100 % total survives),
    /// opacity is the run's **maximum** ("brighter = faster" holds for the group), the label
    /// is the run's **first** (the axis stays ascending).
    static func merged(_ bars: [Bar], width: CGFloat) -> [Bar] {
        let maxBars = max(1, Int((width + gap) / (minWidth + gap)))
        let groupSize = max(1, Int(ceil(Double(bars.count) / Double(maxBars))))
        guard groupSize > 1 else { return bars }
        return stride(from: 0, to: bars.count, by: groupSize).map { start in
            let run = bars[start..<min(start + groupSize, bars.count)]
            return Bar(heightFraction: run.reduce(0) { $0 + $1.heightFraction },
                       opacity: run.map(\.opacity).max() ?? 0,
                       label: run.first?.label)
        }
    }

    // MARK: - Sublayers

    private func ensureBars(_ count: Int) {
        guard barLayers.count != count else { return }
        for layer in barLayers { layer.removeFromSuperlayer() }
        barLayers = (0..<count).map { _ in
            let layer = CAShapeLayer()
            layer.strokeColor = nil
            layer.actions = Self.noActions
            layer.frame = bounds
            layer.contentsScale = contentsScale
            addSublayer(layer)
            return layer
        }
        barOpacities = [Double](repeating: -1, count: count)
    }

    private func ensureLabels(_ count: Int) {
        guard labelLayers.count != count else { return }
        for layer in labelLayers { layer.removeFromSuperlayer() }
        let colour = Theme.cgColor(hex: theme?.textDisabled ?? "#000000")
        labelLayers = (0..<count).map { _ in
            let label = CATextLayer()
            label.font = NSFont.systemFont(ofSize: 9, weight: .regular)
            label.fontSize = 9
            label.alignmentMode = .center
            label.truncationMode = .end
            label.foregroundColor = colour
            label.contentsScale = contentsScale
            label.actions = ["contents": NSNull()]
            addSublayer(label)
            return label
        }
    }

    private func frameSublayers() {
        gridlineLayer.frame = bounds
        gridlineLayer.contentsScale = contentsScale
        for layer in barLayers {
            layer.frame = bounds
            layer.contentsScale = contentsScale
        }
        for label in labelLayers { label.contentsScale = contentsScale }
    }

    private static func gridlinePath(_ values: [Double], size: CGSize) -> CGPath? {
        guard !values.isEmpty else { return nil }
        let path = CGMutablePath()
        for value in values {
            let y = size.height * ChartAxis.percent.normalise(value)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        return path
    }
}
