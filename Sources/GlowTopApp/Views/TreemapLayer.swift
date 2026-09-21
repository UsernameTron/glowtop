import AppKit
import GlowTopCore
import QuartzCore

/// A fourth drawing type, deliberately: `ChartLayer` is a scrolling time series, `HistogramLayer`
/// a bar per bucket, `MeterLayer` a lit fraction of a track. None packs rectangles, and none is
/// extended here (§14.6, D-12). The layout itself is `TreemapLayout` in `GlowTopCore` -- this
/// file only draws what that function returns.
///
/// Colours are resolved once per theme change or per distinct rank-opacity value, never per
/// frame (`HistogramLayer.barOpacities`'s exact mechanism): `apply(cells:selected:hovered:)`
/// runs from the hosting view's `layout()` on every window resize, so a hex parse per cell here
/// is a per-resize-frame cost at up to `~`-level fan-out (32 children, D-10).
@MainActor
final class TreemapLayer: CALayer {
    /// `HistogramLayer.noActions`'s shape, its own copy -- that one is `private` and its file is
    /// in the untouched list.
    private static let noActions: [String: CAAction] = [
        "path": NSNull(), "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
        "strokeColor": NSNull(), "fillColor": NSNull(), "hidden": NSNull(),
    ]

    /// A pool slot's last-applied fill state: `0.25...1` is a resolved rank opacity, this
    /// sentinel means "the Locked treatment" -- neither is a value the other can produce, so
    /// `apply` recolours a slot only when its state actually changes (`HistogramLayer.
    /// barOpacities`'s `-1` idiom, generalised to two paint styles instead of one).
    private static let lockedSentinel: Double = -2

    /// UI-SPEC's label thresholds (Open Item 2's defaults) and the minimum-cell floor. Adjustable
    /// in 4.2 only, against the built pane at the reference Mac's `~`-level fan-out.
    static let twoLineThreshold = CGSize(width: 60, height: 32)
    static let oneLineThreshold = CGSize(width: 32, height: 16)
    static let minimumCell = TreemapSize(width: 8, height: 8)
    static let lockedCellSize = TreemapSize(width: 60, height: 32)

    private var cellLayers: [CAShapeLayer] = []
    private var scrimLayers: [CAShapeLayer] = []
    private var nameLabels: [CATextLayer] = []
    private var sizeLabels: [CATextLayer] = []
    /// Parallel to the four pools above; see `lockedSentinel`.
    private var cellFillState: [Double] = []

    /// One overlay each for selection and hover -- both `textPrimary`, never a fill change
    /// (the fill's opacity encodes rank; recolouring it on hover/selection destroys that).
    private let selectionLayer = CAShapeLayer()
    private let hoverLayer = CAShapeLayer()

    private var theme: Theme?
    private var accentHex = ""
    private var scrimColor = Theme.fallbackColor
    private var lockedFillColor = Theme.fallbackColor
    private var lockedStrokeColor = Theme.fallbackColor
    private var lockedTextColor = Theme.fallbackColor
    private var nameColor = Theme.fallbackColor
    private var sizeColor = Theme.fallbackColor

    init(theme: Theme) {
        super.init()
        actions = Self.noActions
        selectionLayer.fillColor = nil
        selectionLayer.lineWidth = 2
        selectionLayer.actions = Self.noActions
        hoverLayer.fillColor = nil
        hoverLayer.lineWidth = 1
        hoverLayer.actions = Self.noActions
        addSublayer(selectionLayer)
        addSublayer(hoverLayer)
        applyTheme(theme)
    }

    /// Core Animation's presentation-tree copy. Never called while nothing in the tree animates,
    /// and an unimplemented designated initializer is a crash the first time something does
    /// (`ChartLayer.swift`'s recorded reason).
    nonisolated override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - Drawing

    /// `TreemapRect` -> `CGRect` happens here and nowhere else -- the Core/App boundary is one
    /// line wide (D-12). `selected`/`hovered` index into `cells`; either may be out of range or
    /// nil, in which case that overlay simply draws nothing.
    func apply(cells: [TreemapCell], selected: Int?, hovered: Int?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        ensurePool(cells.count)

        // Rank 0 = smallest ... N-1 = largest, over every non-Locked cell (a real child or the
        // aggregate both qualify -- only `bytes == nil` is excluded, per the UI-SPEC's "the
        // aggregate participates in the same rank/opacity rule as any real child").
        let rankable = cells.indices.filter { cells[$0].bytes != nil }
            .sorted { (cells[$0].bytes ?? 0) < (cells[$1].bytes ?? 0) }
        var opacityByIndex: [Int: Double] = [:]
        let rankCount = rankable.count
        for (rank, index) in rankable.enumerated() {
            let fraction = rankCount > 1 ? Double(rank) / Double(rankCount - 1) : 0
            opacityByIndex[index] = 0.25 + fraction * 0.75
        }

        for (index, cell) in cells.enumerated() {
            let rect = CGRect(x: cell.rect.x, y: cell.rect.y,
                              width: cell.rect.width, height: cell.rect.height)
            cellLayers[index].path = CGPath(rect: rect, transform: nil)

            let isLocked = opacityByIndex[index] == nil
            if let opacity = opacityByIndex[index] {
                if cellFillState[index] != opacity {
                    cellFillState[index] = opacity
                    cellLayers[index].fillColor = Theme.cgColor(hex: accentHex, alpha: opacity)
                    cellLayers[index].strokeColor = nil
                    cellLayers[index].lineWidth = 0
                }
            } else if cellFillState[index] != Self.lockedSentinel {
                cellFillState[index] = Self.lockedSentinel
                cellLayers[index].fillColor = lockedFillColor
                cellLayers[index].strokeColor = lockedStrokeColor
                cellLayers[index].lineWidth = 1
            }

            applyLabel(index: index, cell: cell, rect: rect, isLocked: isLocked)
        }

        applyOverlay(selectionLayer, cells: cells, index: selected)
        applyOverlay(hoverLayer, cells: cells, index: hovered)
    }

    /// On a theme change only. Resolves every colour once; a pool slot's name/size labels are
    /// re-coloured here too, keyed off `cellFillState`'s already-recorded locked/ranked split,
    /// so a theme change does not wait for the next `apply(...)` to look right.
    func applyTheme(_ theme: Theme) {
        self.theme = theme
        accentHex = Theme.hex(for: "accentDisk", theme: theme)
        scrimColor = Theme.cgColor(hex: theme.background, alpha: 0.55)
        lockedFillColor = Theme.cgColor(hex: theme.textDisabled, alpha: 0.15)
        lockedStrokeColor = Theme.cgColor(hex: theme.textDisabled, alpha: 1)
        lockedTextColor = Theme.cgColor(hex: theme.textDisabled, alpha: 1)
        nameColor = Theme.cgColor(hex: theme.textPrimary, alpha: 1)
        sizeColor = Theme.cgColor(hex: theme.textSecondary, alpha: 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, state) in cellFillState.enumerated() {
            let isLocked = state == Self.lockedSentinel
            if isLocked {
                cellLayers[index].fillColor = lockedFillColor
                cellLayers[index].strokeColor = lockedStrokeColor
            } else if state >= 0 {
                cellLayers[index].fillColor = Theme.cgColor(hex: accentHex, alpha: state)
            }
            nameLabels[index].foregroundColor = isLocked ? lockedTextColor : nameColor
            sizeLabels[index].foregroundColor = isLocked ? lockedTextColor : sizeColor
        }
        for scrim in scrimLayers { scrim.fillColor = scrimColor }
        selectionLayer.strokeColor = Theme.cgColor(hex: theme.textPrimary, alpha: 1)
        hoverLayer.strokeColor = Theme.cgColor(hex: theme.textPrimary, alpha: 0.4)
        CATransaction.commit()
    }

    // MARK: - Labels (a scrim plate, never bare text on the fill)

    /// `≥ 60x32` -> name + size, two lines on the plate; `≥ 32x16` -> name only; below -> no
    /// label. The Locked cell is always labelled at its fixed 60x32 pt (D-20 -- never
    /// label-less) and carries no scrim: its own `textDisabled`@15% fill already reads as
    /// categorically different, and a plate on top of a cell that size has nowhere to go.
    private func applyLabel(index: Int, cell: TreemapCell, rect: CGRect, isLocked: Bool) {
        let nameLabel = nameLabels[index]
        let sizeLabel = sizeLabels[index]
        let scrim = scrimLayers[index]

        let showTwoLine = rect.width >= Self.twoLineThreshold.width
            && rect.height >= Self.twoLineThreshold.height
        let showOneLine = !showTwoLine
            && rect.width >= Self.oneLineThreshold.width
            && rect.height >= Self.oneLineThreshold.height

        guard isLocked || showTwoLine || showOneLine else {
            scrim.path = nil
            nameLabel.string = ""
            sizeLabel.string = ""
            return
        }

        let twoLine = isLocked || showTwoLine
        let labelInset: CGFloat = 4
        let lineHeight: CGFloat = 12

        nameLabel.string = cell.name
        nameLabel.fontSize = isLocked ? 10 : 11
        nameLabel.font = NSFont.systemFont(ofSize: isLocked ? 10 : 11)
        nameLabel.foregroundColor = isLocked ? lockedTextColor : nameColor
        nameLabel.truncationMode = .middle
        nameLabel.alignmentMode = .left

        sizeLabel.string = twoLine ? (cell.bytes.map(Format.bytes) ?? Format.unknown) : ""
        sizeLabel.fontSize = 10
        sizeLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        sizeLabel.foregroundColor = isLocked ? lockedTextColor : sizeColor
        sizeLabel.alignmentMode = .left

        if isLocked {
            scrim.path = nil
        } else {
            let plateHeight = min(twoLine ? lineHeight * 2 + labelInset : lineHeight + labelInset, rect.height)
            let plateRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: plateHeight)
            scrim.path = CGPath(rect: plateRect, transform: nil)
            scrim.fillColor = scrimColor
        }

        let textWidth = max(rect.width - labelInset * 2, 0)
        let nameY = rect.minY + (twoLine ? lineHeight + 2 : 2)
        nameLabel.frame = CGRect(x: rect.minX + labelInset, y: nameY, width: textWidth, height: lineHeight)
        sizeLabel.frame = CGRect(x: rect.minX + labelInset, y: rect.minY + 2, width: textWidth, height: lineHeight)
    }

    private func applyOverlay(_ layer: CAShapeLayer, cells: [TreemapCell], index: Int?) {
        guard let index, cells.indices.contains(index) else {
            layer.path = nil
            return
        }
        let r = cells[index].rect
        layer.path = CGPath(rect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height), transform: nil)
    }

    // MARK: - Sublayer pooling (`HistogramLayer.ensureBars`'s shape)

    private func ensurePool(_ count: Int) {
        guard cellLayers.count != count else { return }
        for layer in cellLayers { layer.removeFromSuperlayer() }
        for layer in scrimLayers { layer.removeFromSuperlayer() }
        for layer in nameLabels { layer.removeFromSuperlayer() }
        for layer in sizeLabels { layer.removeFromSuperlayer() }

        cellLayers = (0..<count).map { _ in
            let layer = CAShapeLayer()
            layer.actions = Self.noActions
            addSublayer(layer)
            return layer
        }
        scrimLayers = (0..<count).map { _ in
            let layer = CAShapeLayer()
            layer.strokeColor = nil
            layer.actions = Self.noActions
            addSublayer(layer)
            return layer
        }
        nameLabels = (0..<count).map { _ in makeTextLayer() }
        sizeLabels = (0..<count).map { _ in makeTextLayer() }
        cellFillState = [Double](repeating: -1, count: count)

        // The overlays must stay above every cell/scrim/label -- re-added last so they end up
        // at the top of the sublayer stack.
        selectionLayer.removeFromSuperlayer()
        hoverLayer.removeFromSuperlayer()
        addSublayer(selectionLayer)
        addSublayer(hoverLayer)
    }

    private func makeTextLayer() -> CATextLayer {
        let label = CATextLayer()
        label.contentsScale = contentsScale
        label.actions = ["contents": NSNull()]
        addSublayer(label)
        return label
    }
}
