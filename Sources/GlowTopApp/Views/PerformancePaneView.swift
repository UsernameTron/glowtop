import AppKit
import GlowTopCore
import QuartzCore

/// §14.10's Performance pane: three stacked full-width cards in §4.2's chrome — the per-core
/// grid, the CPU history chart and the memory history chart.
///
/// Built the way `SummaryPaneView` is built — one `NSView`, every mark a `CALayer`, the
/// view itself draws nothing — and out of the same parts: `CardChrome` for §4.1/§4.2,
/// `MeterLayer.perCoreStrip(width:)` for the grid's cells, `ChartLayer` for both charts.
/// Nothing in this file builds a chart path.
@MainActor
final class PerformancePaneView: NSView {
    // MARK: - §14.10's grid geometry (phase-10 plan, Phase 0)

    enum Grid {
        /// §4.3.2's strip gutter, verbatim. A second gutter width on a second pane is a
        /// §4.1 the document does not have.
        static let gutter: CGFloat = 2
        /// D-07's label is `NN  NN%` — 8 glyphs of SF Mono 9 pt ≈ 43.2 pt; 48 leaves room
        /// so a 3-digit index truncates rather than the common case. The only number in the
        /// grid derived from a font metric, and it is derived from the widest string D-07
        /// can produce.
        static let minCellWidth: CGFloat = 48
        /// §4.3.2: "height 6 pt each" — `MeterGeometry.perCoreStrip(width:)`'s thickness.
        static let cellHeight: CGFloat = 6
        /// SF Mono 9 pt line box, the height Summary's strip gives its captions.
        static let labelHeight: CGFloat = 11
        /// Cell to its label.
        static let labelGap: CGFloat = 2
        /// Between rows inside one cluster block.
        static let rowGap: CGFloat = 6
        /// The block caption, SF Mono 9 pt.
        static let captionHeight: CGFloat = 11
        /// Caption to its first row.
        static let captionGap: CGFloat = 4
        /// Between the P block and the E block — larger than `rowGap`, because the gap *is*
        /// the grouping D-06 asks for.
        static let blockGap: CGFloat = 10
        /// §4.2's 24 pt headline band, the height `layoutCardText` gives a headline.
        static let headerHeight: CGFloat = 29
        /// Header band to the first block caption.
        static let headerGap: CGFloat = 8
        /// §4.2's footer, `layoutCardText`'s own value.
        static let footerHeight: CGFloat = 12
        /// Last row's label to the footer.
        static let footerGap: CGFloat = 6

        /// Capped at the larger cluster's core count so every cell in the grid is one width:
        /// two clusters at two cell widths would make an E core at 100 % look different
        /// from a P core at 100 % by *size* as well as by caption (§5.1.4).
        static func cellsPerRow(cardWidth: CGFloat, performanceCores: Int,
                                efficiencyCores: Int) -> Int {
            let inner = cardWidth - CardMetrics.cardPadding * 2
            let fits = max(1, Int((inner + gutter) / (minCellWidth + gutter)))
            return max(1, min(fits, max(performanceCores, efficiencyCores)))
        }

        static func cellWidth(cardWidth: CGFloat, cellsPerRow: Int) -> CGFloat {
            let inner = cardWidth - CardMetrics.cardPadding * 2
            return (inner - CGFloat(cellsPerRow - 1) * gutter) / CGFloat(cellsPerRow)
        }

        static func rows(_ cores: Int, cellsPerRow: Int) -> Int {
            cores == 0 ? 0 : Int((Double(cores) / Double(cellsPerRow)).rounded(.up))
        }

        static func blockHeight(_ cores: Int, cellsPerRow: Int) -> CGFloat {
            let rows = rows(cores, cellsPerRow: cellsPerRow)
            guard rows > 0 else { return 0 }
            return captionHeight + captionGap
                + CGFloat(rows) * (cellHeight + labelGap + labelHeight)
                + CGFloat(rows - 1) * rowGap
        }

        /// 157 pt at 14 cores (10 P + 4 E) at every window width §3.1 allows.
        static func gridHeight(performanceCores: Int, efficiencyCores: Int,
                               cardWidth: CGFloat) -> CGFloat {
            let perRow = cellsPerRow(cardWidth: cardWidth, performanceCores: performanceCores,
                                     efficiencyCores: efficiencyCores)
            let pBlock = blockHeight(performanceCores, cellsPerRow: perRow)
            let eBlock = efficiencyCores > 0
                ? blockGap + blockHeight(efficiencyCores, cellsPerRow: perRow) : 0
            return CardMetrics.cardPadding + headerHeight + headerGap
                + pBlock + eBlock
                + footerGap + footerHeight + CardMetrics.cardPadding
        }
    }

    // MARK: - State

    /// Defaults to `.shared`; gate 12's self-check renders against an isolated store.
    private var themeStore: ThemeStore = .shared
    private var theme: Theme { themeStore.theme }
    private var model: PerformanceModel?
    private var sampledAt: ContinuousClock.Instant?
    private var sampleInterval: Duration = SampleRate.hz10

    /// §6.8 and §6.2. Both stop the display link; neither stops the store from this view.
    var isPaused = false { didSet { updateLinkState() } }
    var isOccluded = false { didSet { updateLinkState() } }

    var onKey: ((KeyAction) -> Void)?
    enum KeyAction { case pause, forceSample }

    // MARK: - Layers

    /// §14.10's three cards, in order: grid, CPU history, memory history.
    private var cardLayers: [CALayer] = []
    private var textLayers: [String: CATextLayer] = [:]
    /// The charts, one `ChartLayer` per plot rect: CPU history, then memory history.
    /// Constructed with their series and colours as parameters (RENDER-05); this pane
    /// builds no path of its own.
    private var chartLayers: [ChartLayer] = []
    private var lastPlottedSignature: Int = 0
    private var lastScrollStep: Int = -1

    // MARK: - §6.2's link and §6.7's counter

    private var link: CADisplayLink?
    private let counter = FrameRateCounter()
    private let logFPS = ProcessInfo.processInfo.environment["GLOWTOP_LOG_FPS"] != nil

    /// The grid: one `MeterLayer` per logical core, one label per cell, one caption per
    /// cluster block. Rebuilt when the core count or the cell width changes — a
    /// `MeterLayer` is constructed with its width.
    private var perCoreMeters: [MeterLayer] = []
    private var cellLabels: [CATextLayer] = []
    private var blockCaptions: [CATextLayer] = []
    private var builtCoreCount = 0
    private var builtPerformanceCores = 0
    private var builtCellWidth: CGFloat = 0

    /// Phase 0's grid-card height: 157 pt until the first sample says how many cores there
    /// are, then `Grid.gridHeight` from the model's own counts.
    private var gridHeight: CGFloat = 157

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        buildStaticLayers()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange(_:)),
            name: ThemeStore.didChange, object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// Gate 12's self-check entry point: renders against `themeStore` instead of `.shared`.
    convenience init(frame frameRect: NSRect, themeStore: ThemeStore) {
        self.init(frame: frameRect)
        self.themeStore = themeStore
        applyThemeChange()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Data

    func apply(_ model: PerformanceModel, sampledAt: ContinuousClock.Instant?, interval: Duration) {
        self.model = model
        self.sampledAt = sampledAt
        self.sampleInterval = interval

        if ensureGrid(for: model) {
            needsLayout = true
        }
        applyGrid(model, interval: interval)
        applyText(model)

        // A chart redraws when a plotted value changed, not on every tick.
        let signature = plotSignature(model)
        if signature != lastPlottedSignature {
            lastPlottedSignature = signature
            applyChartLayers()
        }
    }

    private func plotSignature(_ model: PerformanceModel) -> Int {
        var hasher = Hasher()
        hasher.combine(model.cpuSeries.first?.values.last)
        hasher.combine(model.cpuSeries.last?.values.last)
        hasher.combine(model.memory.series.first?.values.last)
        return hasher.finalize()
    }

    /// §4.8 through `CardChrome.applyCardText`, the same routine Summary's cards go through.
    /// The CPU history card has no headline (Phase 0's discretion table): its layer is passed
    /// as `nil` so the total CPU % is printed once, on the grid card.
    private func applyText(_ model: PerformanceModel) {
        // §4.10: titles are the model's. `setText` writes only on change.
        for (key, title) in zip(["grid", "cpu", "memory"], model.titles) {
            CardChrome.setText(textLayers["\(key).title"], title, token: "textSecondary", theme: theme)
        }
        let grid = CardModel(
            title: "PER-CORE UTILIZATION", headline: model.cpuHeadline, footer: "",
            colorToken: "accentCPU", state: model.cpuState, series: [], axis: nil, rightAxis: nil
        )
        CardChrome.applyCardText(
            grid, headline: textLayers["grid.headline"], footer: textLayers["grid.footer"],
            unavailable: textLayers["grid.unavailable"], theme: theme
        )
        let cpu = CardModel(
            title: "CPU HISTORY", headline: "", footer: model.cpuFooter,
            colorToken: "accentCPU", state: model.cpuState, series: model.cpuSeries,
            axis: .percent, rightAxis: nil
        )
        CardChrome.applyCardText(
            cpu, headline: nil, footer: textLayers["cpu.footer"],
            unavailable: textLayers["cpu.unavailable"], theme: theme
        )
        CardChrome.applyCardText(
            model.memory, headline: textLayers["memory.headline"],
            footer: textLayers["memory.footer"], unavailable: textLayers["memory.unavailable"],
            theme: theme
        )
    }

    // MARK: - The per-core grid (§14.10, D-05..D-07)

    private var gridCardWidth: CGFloat { contentWidth }

    /// Rebuilds the grid's layers when the core count, the cluster split or the cell width
    /// changed. Returns `true` when it did.
    @discardableResult
    private func ensureGrid(for model: PerformanceModel) -> Bool {
        let count = model.perCore.count
        let pCores = min(model.performanceCores, count)
        let eCores = count - pCores
        guard bounds.width > 1, count > 0 else { return false }

        let perRow = Grid.cellsPerRow(cardWidth: gridCardWidth, performanceCores: pCores,
                                      efficiencyCores: eCores)
        let width = Grid.cellWidth(cardWidth: gridCardWidth, cellsPerRow: perRow)
        let height = Grid.gridHeight(performanceCores: pCores, efficiencyCores: eCores,
                                     cardWidth: gridCardWidth)
        let changed = count != builtCoreCount || pCores != builtPerformanceCores
            || abs(width - builtCellWidth) > 0.01 || height != gridHeight
        guard changed else { return false }

        gridHeight = height
        buildGrid(coreCount: count, performanceCores: pCores, cellWidth: width)
        return true
    }

    private func buildGrid(coreCount: Int, performanceCores: Int, cellWidth: CGFloat) {
        for meter in perCoreMeters {
            meter.unlit.removeFromSuperlayer()
            meter.lit.removeFromSuperlayer()
        }
        for label in cellLabels { label.removeFromSuperlayer() }
        for caption in blockCaptions { caption.removeFromSuperlayer() }
        perCoreMeters = []
        cellLabels = []
        blockCaptions = []
        builtCoreCount = coreCount
        builtPerformanceCores = performanceCores
        builtCellWidth = cellWidth
        guard let root = layer, coreCount > 0 else { return }

        let scale = window?.backingScaleFactor ?? 2
        for _ in 0..<coreCount {
            let meter = MeterLayer(geometry: .perCoreStrip(width: cellWidth),
                                   accentHex: theme.accentCPU, theme: theme)
            meter.addTo(root)
            meter.updateScale(scale)
            perCoreMeters.append(meter)

            let label = Self.monoLabel(hex: theme.textTertiary, scale: scale)
            root.addSublayer(label)
            cellLabels.append(label)
        }

        // §4.3.2's cluster caption colours — literals with no §7.2 token, so they stay
        // call-site constants naming their section (`SpecLiteralColor`).
        for hex in [SpecLiteralColor.clusterCaptionP, SpecLiteralColor.clusterCaptionE] {
            let caption = Self.monoLabel(hex: hex, scale: scale)
            root.addSublayer(caption)
            blockCaptions.append(caption)
        }
    }

    /// SF Mono 9 pt, left-aligned, no `contents` crossfade — Summary's per-core caption.
    private static func monoLabel(hex: String, scale: CGFloat) -> CATextLayer {
        let label = CATextLayer()
        label.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        label.fontSize = 9
        label.alignmentMode = .left
        label.truncationMode = .end
        label.foregroundColor = Theme.cgColor(hex: hex)
        label.contentsScale = scale
        label.actions = ["contents": NSNull()]
        return label
    }

    /// Per cell: §4.8's warming and unavailable are `fraction == nil`, which `MeterLayer`
    /// already renders as unlit — this pane adds no second treatment. Per label: the logical
    /// core index and §4.9's percentage, through `Format` (D-07).
    private func applyGrid(_ model: PerformanceModel, interval: Duration) {
        for (index, core) in model.perCore.enumerated() where index < perCoreMeters.count {
            perCoreMeters[index].set(fraction: core.fraction, state: core.state, over: interval)
            let text = if core.state == .live || core.state == .stalled, let value = core.fraction {
                String(format: "%2d  %@", index, Format.percent(fraction: value))
            } else {
                String(format: "%2d  %@", index, Format.unknown)
            }
            CardChrome.setText(cellLabels[index], text, theme: theme)
        }

        let pCores = min(model.performanceCores, model.perCore.count)
        let eCores = model.perCore.count - pCores
        guard blockCaptions.count == 2 else { return }
        // The counts come from the model, never from index order (§5.1.4).
        CardChrome.setText(blockCaptions[0], "\(model.clusterWords.performance) · \(pCores) cores", theme: theme)
        CardChrome.setText(blockCaptions[1], eCores > 0 ? "\(model.clusterWords.efficiency) · \(eCores) cores" : "", theme: theme)
    }

    /// Bottom-left origin, laid out top-down from `inner.maxY`: the header band, the P
    /// block (caption, then rows), `blockGap`, then the E block. A cell's `layout(origin:)`
    /// takes the bottom-left of its unlit body; its label sits `labelGap` below.
    private func layoutGrid(in cardFrame: CGRect, scale: CGFloat) {
        guard !perCoreMeters.isEmpty else { return }
        let inner = cardFrame.insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        let pCores = builtPerformanceCores
        let eCores = builtCoreCount - pCores
        let perRow = Grid.cellsPerRow(cardWidth: cardFrame.width, performanceCores: pCores,
                                      efficiencyCores: eCores)
        let cellWidth = builtCellWidth

        var y = inner.maxY - Grid.headerHeight - Grid.headerGap
        var first = 0
        for (block, cores) in [pCores, eCores].enumerated() {
            let caption = blockCaptions[block]
            caption.contentsScale = scale
            guard cores > 0 else {
                caption.frame = .zero
                continue
            }
            if block == 1 { y -= Grid.blockGap }
            caption.frame = CGRect(x: inner.minX, y: y - Grid.captionHeight,
                                   width: inner.width, height: Grid.captionHeight)
            y -= Grid.captionHeight + Grid.captionGap

            let rows = Grid.rows(cores, cellsPerRow: perRow)
            for row in 0..<rows {
                let cellBottom = y - Grid.cellHeight
                for column in 0..<perRow {
                    let index = first + row * perRow + column
                    guard index < first + cores else { break }
                    let x = inner.minX + CGFloat(column) * (cellWidth + Grid.gutter)
                    perCoreMeters[index].updateScale(scale)
                    perCoreMeters[index].layout(origin: CGPoint(x: x, y: cellBottom))
                    let label = cellLabels[index]
                    label.contentsScale = scale
                    label.frame = CGRect(x: x, y: cellBottom - Grid.labelGap - Grid.labelHeight,
                                         width: cellWidth, height: Grid.labelHeight)
                }
                y = cellBottom - Grid.labelGap - Grid.labelHeight
                if row < rows - 1 { y -= Grid.rowGap }
            }
            first += cores
        }
    }

    // MARK: - Theme

    @objc private func handleThemeDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === themeStore else { return }
        applyThemeChange()
    }

    private static let cardKeys = ["grid", "cpu", "memory"]

    /// §7.3's live-apply: every built layer's colour re-derived from the new theme. The shared
    /// texture cache is cleared **before** any meter reads it again, or a meter reads back
    /// its own stale image under the new key (`SummaryPaneView.applyThemeChange`'s order).
    private func applyThemeChange() {
        MeterLayer.invalidateTextureCache()
        for meter in perCoreMeters {
            meter.updateTheme(accentHex: theme.accentCPU, theme: theme)
        }

        layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        for chrome in cardLayers {
            chrome.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
            chrome.borderColor = Theme.cgColor(hex: theme.cardBorder)
        }
        let titleColor = Theme.cgColor(hex: theme.textSecondary)
        for key in Self.cardKeys {
            textLayers["\(key).title"]?.foregroundColor = titleColor
        }
        let labelColor = Theme.cgColor(hex: theme.textTertiary)
        for label in cellLabels { label.foregroundColor = labelColor }
        let disabledColor = Theme.cgColor(hex: theme.textDisabled)
        for value in CardMetrics.percentGridlines {
            textLayers["cpu.axis.\(Int(value))"]?.foregroundColor = disabledColor
        }
        if let model {
            applyText(model)
        }
        for chart in chartLayers { chart.applyTheme(theme, colors: themeStore.colors) }
    }

    // MARK: - Static layer construction

    private func buildStaticLayers() {
        guard let root = layer else { return }

        // §14.10's table: title, headline, footer per card. `accent` is a §7.2 token name.
        let cards: [(key: String, accent: String, title: String)] = [
            ("grid", "accentCPU", "PER-CORE UTILIZATION"),
            ("cpu", "accentCPU", "CPU HISTORY"),
            ("memory", "accentMemory", "MEMORY HISTORY"),
        ]

        // Sublayer order is z-order (gate 12's `render(in:)` honours only that): chrome
        // first, then everything drawn on it.
        for _ in cards {
            let chrome = CardChrome.makeCardLayer(theme: theme)
            root.addSublayer(chrome)
            cardLayers.append(chrome)
        }

        // §6.5: the charts, one container per plot rect, above the chrome and below the
        // marks (phase-03's G1: a chart beneath its chrome is composited away). §4.4 and
        // §4.5 both plot 600.
        let cpuChart = ChartLayer(capacity: 600)
        cpuChart.applyTheme(theme, colors: themeStore.colors)
        root.addSublayer(cpuChart)
        chartLayers.append(cpuChart)
        let memoryChart = ChartLayer(capacity: 600)
        memoryChart.applyTheme(theme, colors: themeStore.colors)
        root.addSublayer(memoryChart)
        chartLayers.append(memoryChart)

        for card in cards {
            addText("\(card.key).title", card.title, size: 11, weight: .semibold,
                    token: "textSecondary", alignment: .left, tracking: 0.66)
            // The CPU history card's headline layer exists for §4.2's uniform chrome and
            // stays `""` — the total CPU % is printed once, on the grid card.
            addText("\(card.key).headline", card.key == "cpu" ? "" : "···", size: 24,
                    weight: .medium, token: card.accent, alignment: .right,
                    monospacedDigits: true)
            addText("\(card.key).footer", "", size: 10, weight: .regular,
                    token: "textTertiary", alignment: .left)
            addText("\(card.key).unavailable", "", size: 11, weight: .regular,
                    token: "textDisabled", alignment: .center)
        }

        // §4.4's left axis labels. No right-hand axis exists on this pane (§14.10): there is
        // no temperature series for one to belong to, so none is created, blank or hidden.
        for value in CardMetrics.percentGridlines {
            addText("cpu.axis.\(Int(value))", "\(Int(value))", size: 9, weight: .regular,
                    token: "textDisabled", alignment: .right)
        }
    }

    private func addText(_ key: String, _ string: String, size: CGFloat,
                         weight: NSFont.Weight, token: String,
                         alignment: CATextLayerAlignmentMode, tracking: CGFloat = 0,
                         monospacedDigits: Bool = false) {
        let layer = CardChrome.makeTextLayer(
            string, size: size, weight: weight, token: token, alignment: alignment,
            tracking: tracking, monospacedDigits: monospacedDigits, theme: theme
        )
        textLayers[key] = layer
        self.layer?.addSublayer(layer)
    }

    // MARK: - Layout

    private var contentWidth: CGFloat { bounds.width - CardMetrics.outerPadding * 2 }

    private let logGeometry = ProcessInfo.processInfo.environment["GLOWTOP_LOG_GEOM"] != nil

    override func layout() {
        super.layout()
        if let model { ensureGrid(for: model) }
        layoutCards()
        // `GLOWTOP_LOG_GEOM`, Summary's own hook: the grid's arithmetic as laid out, so a
        // record can quote `cellsPerRow` / `cellWidth` at a width rather than eyeball them.
        if logGeometry, bounds.width > 1, builtCoreCount > 0 {
            let perRow = Grid.cellsPerRow(cardWidth: gridCardWidth,
                                          performanceCores: builtPerformanceCores,
                                          efficiencyCores: builtCoreCount - builtPerformanceCores)
            print(String(format: "perf grid bounds=%.1fx%.1f cores=%d/%d cellsPerRow=%d cellWidth=%.1f gridHeight=%.1f history=%.1f",
                         bounds.width, bounds.height, builtPerformanceCores,
                         builtCoreCount - builtPerformanceCores, perRow, builtCellWidth,
                         gridHeight, cardFrames()[1].height))
            fflush(stdout)
        }
    }

    /// A window dragged from a 2× panel to a 1× external otherwise keeps 2× text (soft) and
    /// 2× textures (half size).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        MeterLayer.invalidateTextureCache()
        needsLayout = true
    }

    /// §14.10: the grid card takes only what its rows need; the two history cards split the
    /// remainder equally. Bottom-left origin, so the memory card's y is the lowest.
    func cardFrames() -> [CGRect] {
        let content = contentWidth
        let available = bounds.height - CardMetrics.outerPadding * 2 - CardMetrics.gap * 2
        let historyHeight = (available - gridHeight) / 2
        let x0 = CardMetrics.outerPadding
        let memoryY = CardMetrics.outerPadding
        let cpuY = memoryY + historyHeight + CardMetrics.gap
        let gridY = cpuY + historyHeight + CardMetrics.gap
        return [
            CGRect(x: x0, y: gridY, width: content, height: gridHeight),
            CGRect(x: x0, y: cpuY, width: content, height: historyHeight),
            CGRect(x: x0, y: memoryY, width: content, height: historyHeight),
        ]
    }

    private func layoutCards() {
        guard bounds.width > 1 else { return }
        let frames = cardFrames()
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, frame) in frames.enumerated() where index < cardLayers.count {
            cardLayers[index].frame = frame
        }
        for (index, key) in Self.cardKeys.enumerated() where index < frames.count {
            layoutCardText(key, in: frames[index], scale: scale)
        }
        layoutGrid(in: frames[0], scale: scale)

        // Each container is framed to its plot rect, in the pane's own bottom-left space.
        // No conversion: the view is unflipped and a layer's `geometryFlipped` is false.
        // `contentsScale` before `frame`, so the layer never rasterizes at the wrong scale.
        let plots = [cpuPlotRect(frames[1]), memoryPlotRect(frames[2])]
        for (chart, plot) in zip(chartLayers, plots) {
            chart.contentsScale = scale
            chart.frame = plot
        }
        layoutAxisLabels(in: frames[1], scale: scale)
        CATransaction.commit()

        // The paths are built in each container's own space, so a new frame is a new path.
        applyChartLayers()
    }

    /// §14.10's card 2: no headline, so the plot's top is 18 pt under the inner edge (the
    /// title line); the footer takes 16 pt at the bottom.
    func cpuPlotRect(_ cardFrame: CGRect) -> CGRect {
        let inner = cardFrame.insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        // 26, not Phase 0's 18: the `100` label sits 11 pt above the plot's top edge and at
        // 18 it overlapped the 13 pt title band (seen in 4.2's first screenshot).
        let top = inner.maxY - 26
        let bottom = inner.minY + 16
        return CGRect(x: inner.minX, y: bottom, width: inner.width,
                      height: max(top - bottom, 0))
    }

    /// §14.10's card 3: a headline, so the plot's top is 31 pt under the inner edge; the
    /// full inner width — §4.5's 260 pt meter is Summary's and is not repeated here.
    func memoryPlotRect(_ cardFrame: CGRect) -> CGRect {
        let inner = cardFrame.insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        let top = inner.maxY - 31
        let bottom = inner.minY + 16
        return CGRect(x: inner.minX, y: bottom, width: inner.width,
                      height: max(top - bottom, 0))
    }

    private func layoutAxisLabels(in cardFrame: CGRect, scale: CGFloat) {
        let plot = cpuPlotRect(cardFrame)
        guard plot.height > 1 else { return }
        for value in CardMetrics.percentGridlines {
            guard let label = textLayers["cpu.axis.\(Int(value))"] else { continue }
            label.contentsScale = scale
            let y = plot.minY + plot.height * ChartAxis.percent.normalise(value)
            label.frame = CGRect(x: plot.minX, y: y + 1, width: 22, height: 11)
        }
    }

    // MARK: - Charts

    /// §6.5: the charts as parameters to their `ChartLayer`s at the current scroll offset.
    /// One transaction, actions disabled. Called when a plotted value changed (`apply(_:)`),
    /// when the scroll crossed a backing pixel (`tick()`), and on layout. §6.7's second
    /// number is counted here, where new pixels are actually produced.
    private func applyChartLayers() {
        guard let model, chartLayers.count == 2 else { return }
        counter.countDraw()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cpu = chartLayers[0]
        cpu.apply(series: model.cpuSeries, gridlines: CardMetrics.percentGridlines,
                  axis: .percent, scrollOffset: scrollOffset(for: cpu.bounds, capacity: 600))

        // §4.5's timeline, argument for argument Summary's call: the four layers arrive
        // already cumulative from `projectMemory`, swap is the unstacked fifth descriptor,
        // and without an axis nothing is drawn — an empty series is that, in parameters.
        let memory = chartLayers[1]
        memory.apply(series: model.memory.axis == nil ? [] : model.memory.series,
                     gridlines: [], axis: model.memory.axis ?? .percent,
                     scrollOffset: scrollOffset(for: memory.bounds, capacity: 600))
        CATransaction.commit()
    }

    /// Gate 12 renders into a 1× context; a layer rasterized at one scale and captured at
    /// another reads as a quarter-pixel phase difference along every stroke (phase-09). The
    /// charts are pinned to the context's own scale here, for the offscreen check only.
    func pinChartsToOffscreenScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for chart in chartLayers { chart.contentsScale = 1 }
        CATransaction.commit()
        applyChartLayers()
    }

    /// §6.6 rule 4: the plot's x-offset advances continuously between samples and each
    /// plotted point keeps its measured value. `sampledAt == nil` pins the offset at 0 —
    /// gate 12's fixed fixture must not read the wall clock.
    private func scrollOffset(for plot: CGRect, capacity: Int) -> Double {
        guard let sampledAt else { return 0 }
        let fraction = Interpolation.fraction(now: ContinuousClock().now,
                                              sampledAt: sampledAt, interval: sampleInterval)
        let rect = PlotRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height)
        return ChartSeries.sampleWidth(in: rect, capacity: capacity) * fraction
    }

    private var plotWidth: Double {
        Double(contentWidth - CardMetrics.cardPadding * 2)
    }

    /// §4.2's placements: title top-leading, headline top-trailing (29 pt band), footer
    /// bottom-leading, the unavailable line centred.
    private func layoutCardText(_ key: String, in frame: CGRect, scale: CGFloat) {
        let inner = frame.insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        if let title = textLayers["\(key).title"] {
            title.contentsScale = scale
            title.frame = CGRect(x: inner.minX, y: inner.maxY - 13, width: inner.width, height: 13)
        }
        if let headline = textLayers["\(key).headline"] {
            headline.contentsScale = scale
            headline.frame = CGRect(x: inner.minX, y: inner.maxY - 29, width: inner.width, height: 29)
        }
        if let footer = textLayers["\(key).footer"] {
            footer.contentsScale = scale
            footer.frame = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 12)
        }
        if let unavailable = textLayers["\(key).unavailable"] {
            unavailable.contentsScale = scale
            unavailable.frame = CGRect(x: inner.minX, y: inner.midY - 7, width: inner.width, height: 14)
        }
    }

    // MARK: - Display link (§6.2)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLinkState()
        window?.makeFirstResponder(self)
    }

    private func updateLinkState() {
        link?.invalidate()
        link = nil
        // §6.2 and §6.8: no window, occluded, or paused means no per-frame callback at all.
        guard window != nil, !isPaused, !isOccluded else { return }
        // The counter window starts over with the link (`FrameRateCounter.reset()`).
        counter.reset()
        let newLink = displayLink(target: self, selector: #selector(tick))
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    @objc private func tick() {
        // §6.6 rule 4: the plot's x-offset advances continuously between samples. Redraw
        // only when that offset crosses a whole backing pixel — a tick whose output would be
        // pixel-identical to the frame already on screen is skipped (§6.7).
        if let sampledAt {
            let fraction = Interpolation.fraction(now: ContinuousClock().now,
                                                  sampledAt: sampledAt, interval: sampleInterval)
            let scale = Double(window?.backingScaleFactor ?? 2)
            let step = Int((fraction * plotWidth / Double(599) * scale).rounded(.down))
            if step != lastScrollStep {
                lastScrollStep = step
                applyChartLayers()
            }
        }

        // §6.7's counter closes a whole second and prints the harness's `fps` line itself —
        // which is what gives the Performance-visible arm an `fps` number (F-2).
        _ = counter.tick(window: window, logFPS: logFPS)
    }

    // MARK: - §3.5's view-local keys

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " " where !event.modifierFlags.contains(.command):
            onKey?(.pause)
        case "r" where event.modifierFlags.contains(.command):
            onKey?(.forceSample)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - Gate 12's Performance arm (§14.10, D-14; plan sub-step 5.1)

extension PerformancePaneView {
    private static let selfCheckWidth = 1172
    private static let selfCheckHeight = 778

    /// Renders one fixture offscreen at Summary's own self-check size. `sampledAt: nil`
    /// pins §6.6's scroll offset at 0 — a fixed fixture must not read the wall clock. The
    /// context is part of the return value on purpose (`renderPaneOffscreen`'s comment).
    private static func renderSelfCheck(
        _ frames: SummaryFrames, themeStore: ThemeStore = .shared
    ) -> (view: PerformancePaneView, context: CGContext, scan: PixelScan)? {
        let width = selfCheckWidth, height = selfCheckHeight
        let view = PerformancePaneView(
            frame: NSRect(x: 0, y: 0, width: width, height: height), themeStore: themeStore
        )
        let model = PerformanceModel.project(frames)
        view.apply(model, sampledAt: nil, interval: SampleRate.hz10)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.pinChartsToOffscreenScale()
        guard let (context, scan) = renderPaneOffscreen(view, width: width, height: height)
        else { return nil }
        return (view, context, scan)
    }

    /// Five assertions over rendered pixels: the grid's cells, both charts' marks, §4.4's
    /// omitted right axis, and §4.8's warming appearance — a presence and two absences in
    /// one assertion, because an absence-only check passes on a blank render.
    static func paneSelfCheck() -> [PaneAssertion] {
        // `context` must keep its name so ARC keeps the bitmap `scan` points into alive.
        guard let (view, context, scan) = renderSelfCheck(selfCheckFrames()) else {
            return [PaneAssertion(name: "perf-render", pass: false, detail: "no bitmap")]
        }
        if let path = ProcessInfo.processInfo.environment["GLOWTOP_SELFCHECK_PNG_PERF"] {
            writeSelfCheckPNG(context, to: path)
        }

        let theme = view.theme
        let cards = view.cardFrames()
        var results: [PaneAssertion] = []

        // 1 — the grid's cells are lit somewhere inside the grid card.
        let gridInner = cards[0].insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        let gridHits = scan.hits(in: gridInner, ofHex: theme.accentCPU, tolerance: 24)
        results.append(PaneAssertion(
            name: "perf-grid-cells-present", pass: gridHits > 0, detail: "hits=\(gridHits)"
        ))

        // 2 — the CPU chart has pixels inside its plot (phase-03's gap record G1's shape: a
        // chart drawn beneath its chrome, or clipped away by a wrong rect, leaves this at 0).
        let cpuPlot = view.cpuPlotRect(cards[1])
        let cpuHits = scan.hits(in: cpuPlot, ofHex: theme.accentCPU, tolerance: 60)
        results.append(PaneAssertion(
            name: "perf-cpu-chart-pixels", pass: cpuHits > 0, detail: "hits=\(cpuHits)"
        ))

        // 3 — the memory chart likewise.
        let memoryPlot = view.memoryPlotRect(cards[2])
        let memoryHits = scan.hits(in: memoryPlot, ofHex: theme.accentMemory, tolerance: 60)
        results.append(PaneAssertion(
            name: "perf-memory-chart-pixels", pass: memoryHits > 0, detail: "hits=\(memoryHits)"
        ))

        // 4 — §4.4: no right-hand axis labels along the CPU plot's right edge.
        let rightStrip = CGRect(x: cpuPlot.maxX - 22, y: cpuPlot.minY, width: 22,
                                height: cpuPlot.height)
        let axisHits = scan.hits(in: rightStrip, ofHex: theme.textDisabled, tolerance: 12)
        results.append(PaneAssertion(
            name: "perf-right-axis-omitted", pass: axisHits == 0, detail: "hits=\(axisHits)"
        ))

        // 5 — §4.8's warming appearance over a warming fixture: `···` on the grid card's
        // headline, and nothing plotted in either chart.
        guard let (warmView, warmContext, warmScan) = renderSelfCheck(selfCheckFrames(cpuAndMemory: .warming))
        else {
            results.append(PaneAssertion(name: "perf-render-warming", pass: false, detail: "no bitmap"))
            _ = context
            return results
        }
        let warmCards = warmView.cardFrames()
        let warmInner = warmCards[0].insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        let headlineRect = CGRect(x: warmInner.minX, y: warmInner.maxY - 29,
                                  width: warmInner.width, height: 29)
        let headlineHits = warmScan.hits(in: headlineRect, ofHex: theme.textDisabled, tolerance: 24)
        let warmCPUHits = warmScan.hits(in: warmView.cpuPlotRect(warmCards[1]),
                                        ofHex: theme.accentCPU, tolerance: 60)
        let warmMemoryHits = warmScan.hits(in: warmView.memoryPlotRect(warmCards[2]),
                                           ofHex: theme.accentMemory, tolerance: 60)
        results.append(PaneAssertion(
            name: "perf-warming-headline",
            pass: headlineHits > 0 && warmCPUHits == 0 && warmMemoryHits == 0,
            detail: "headline_hits=\(headlineHits) cpu_hits=\(warmCPUHits) memory_hits=\(warmMemoryHits)"
        ))

        _ = context
        _ = warmContext
        return results
    }
}
