import AppKit
import GlowTopCore
import QuartzCore

/// §14.1's Power & Freq pane: three stacked full-width cards in §4.2's chrome — frequency
/// residency (three cluster columns), DVFS states (three histogram columns aligned under
/// card 1's) and package power (full width).
///
/// Built the way `PerformancePaneView` is built — one `NSView`, every mark a `CALayer`, the
/// view itself draws nothing — and out of the same parts: `CardChrome` for §4.1/§4.2,
/// `ChartLayer` for cards 1 and 3, `HistogramLayer` (phase-11's one new drawing type) for
/// card 2. Nothing in this file builds a chart path.
@MainActor
final class PowerFreqPaneView: NSView {
    // MARK: - State

    /// Defaults to `.shared`; gate 12's self-check renders against an isolated store.
    private var themeStore: ThemeStore = .shared
    private var theme: Theme { themeStore.theme }
    private var model: PowerFreqModel?
    private var sampledAt: ContinuousClock.Instant?
    /// The frequency frame's — this pane's fastest provider is `hz2`.
    private var sampleInterval: Duration = SampleRate.hz2

    /// §6.8 and §6.2. Both stop the display link; neither stops the store from this view.
    var isPaused = false { didSet { updateLinkState() } }
    var isOccluded = false { didSet { updateLinkState() } }

    var onKey: ((KeyAction) -> Void)?
    enum KeyAction { case pause, forceSample }

    // MARK: - Layers

    /// §14.1's three cards, in order: residency, states, power.
    private var cardLayers: [CALayer] = []
    private var textLayers: [String: CATextLayer] = [:]
    /// Card 1: one `ChartLayer(capacity: 120)` per cluster column, built at a fixed count of
    /// three -- the cluster count cannot change at runtime on a given machine -- and any
    /// beyond `model.columns.count` framed to `.zero`. Constructed with their series and
    /// colours as parameters (RENDER-05); this pane builds no path of its own.
    private var residencyCharts: [ChartLayer] = []
    /// Card 2: one `HistogramLayer` per cluster column, framed by the identical `columnRect`
    /// call card 1 makes (D-18). Each carries its column's accent, set from the model.
    private var histograms: [HistogramLayer] = []
    /// Card 3: one `ChartLayer` over the `hz1` energy buffer's 60, full card width.
    private let powerChart = ChartLayer(capacity: 60)
    /// `addToolTipRect(_:owner:)` does not retain its owner; this does, for the footer's tip.
    private var tooltipOwner: NSString?
    private static let columnCount = 3
    /// The locked order's accents, P0 / P1 / E, for a histogram before its first model.
    private static let defaultAccents = ["accentClock", "accentClock", "accentGPU"]
    /// How many columns `layoutCards()` last framed; `apply(_:)` requests a layout when the
    /// model's count differs.
    private var laidOutColumns = 0
    private var lastPlottedSignature: Int = 0
    private var lastScrollStep: Int = -1

    // MARK: - §6.2's link and §6.7's counter

    private var link: CADisplayLink?
    private let counter = FrameRateCounter()
    private let logFPS = ProcessInfo.processInfo.environment["GLOWTOP_LOG_FPS"] != nil
    private let logGeometry = ProcessInfo.processInfo.environment["GLOWTOP_LOG_GEOM"] != nil

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

    func apply(_ model: PowerFreqModel, sampledAt: ContinuousClock.Instant?, interval: Duration) {
        self.model = model
        self.sampledAt = sampledAt
        self.sampleInterval = interval
        // The column frames depend on the model's column count (0 before the first live
        // frame), so a count change is a layout pass, the way Performance's grid rebuild is.
        if model.columns.count != laidOutColumns {
            needsLayout = true
        }
        applyText(model)

        // A chart redraws when a plotted value changed, not on every tick.
        let signature = plotSignature(model)
        if signature != lastPlottedSignature {
            lastPlottedSignature = signature
            applyChartLayers()
        }
    }

    /// Each column's newest idle share (the bottom band's last value), newest average MHz and
    /// the histogram's idle bar.
    private func plotSignature(_ model: PowerFreqModel) -> Int {
        var hasher = Hasher()
        for column in model.columns {
            hasher.combine(column.residencySeries.first?.values.last)
            hasher.combine(column.averageSeries?.values.last)
            hasher.combine(column.bins.first?.share)
        }
        hasher.combine(model.powerSeries.last?.values.last)
        return hasher.finalize()
    }

    /// §4.8 through `CardChrome.applyCardText`, the same routine Summary's cards go through.
    /// Cards 1 and 2 have no headline (D-20) and key their whole-card state on the
    /// **frequency** frame's (`model.frequencyState`), so a failed frequency subscription
    /// reads `Unavailable on this Mac` on both while card 3 keeps working. Every string is the
    /// model's; the view formats nothing (§4.9).
    private func applyText(_ model: PowerFreqModel) {
        let residency = CardModel(
            title: "FREQUENCY RESIDENCY", headline: "", footer: "",
            colorToken: "accentClock", state: model.frequencyState
        )
        CardChrome.applyCardText(
            residency, headline: nil, footer: textLayers["residency.footer"],
            unavailable: textLayers["residency.unavailable"], theme: theme
        )
        applyColumnText(model, card: "residency")

        // The span footer only under a plot: an omitted plot (§4.8) has no span to print, and
        // `0 s` under `Unavailable on this Mac` read as a reading (4.4's flag screenshot).
        let states = CardModel(
            title: "DVFS STATES", headline: "", footer: model.columns.isEmpty ? "" : model.spanFooter,
            colorToken: "accentClock", state: model.frequencyState
        )
        CardChrome.applyCardText(
            states, headline: nil, footer: textLayers["states.footer"],
            unavailable: textLayers["states.unavailable"], theme: theme
        )
        applyColumnText(model, card: "states")

        // Card 3: the model's `CardModel` whole -- `accentEnergy` headline, the footer with its
        // one `W` and trailing word, and the energy frame's own §4.8 state. The five axis labels
        // are the model's too, through `Format.power`; `""` when there is nothing to plot.
        CardChrome.applyCardText(
            model.power, headline: textLayers["power.headline"], footer: textLayers["power.footer"],
            unavailable: textLayers["power.unavailable"], theme: theme
        )
        for index in 0..<5 {
            CardChrome.setText(textLayers["power.axis.\(index)"],
                               index < model.powerAxisLabels.count ? model.powerAxisLabels[index] : "",
                               theme: theme)
        }
    }

    /// The per-column caption in the cluster's own accent, the per-column §4.8 body (D-11),
    /// and card 1's right-axis MHz labels. Columns beyond the model's read `""`. The left
    /// percent labels follow the leftmost column: an omitted plot has no axis (§4.8).
    private func applyColumnText(_ model: PowerFreqModel, card: String) {
        for index in 0..<Self.columnCount {
            let column = index < model.columns.count ? model.columns[index] : nil
            CardChrome.setText(textLayers["\(card).caption.\(index)"], column?.caption ?? "",
                               token: column?.accentToken, theme: theme)
            CardChrome.setText(textLayers["\(card).column.unavailable.\(index)"],
                               column?.unavailableText ?? "", theme: theme)
            if card == "residency" {
                for tick in 0..<3 {
                    let labels = column?.megahertzLabels ?? []
                    CardChrome.setText(textLayers["residency.mhz.\(index).\(tick)"],
                                       tick < labels.count ? labels[tick] : "", theme: theme)
                }
            }
        }
        for value in CardMetrics.percentGridlines {
            CardChrome.setText(textLayers["\(card).axis.\(Int(value))"],
                               model.columns.isEmpty ? "" : "\(Int(value))", theme: theme)
        }
    }

    // MARK: - Theme

    @objc private func handleThemeDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === themeStore else { return }
        applyThemeChange()
    }

    private static let cardKeys = ["residency", "states", "power"]

    /// §7.3's live-apply: every built layer's colour re-derived from the new theme.
    private func applyThemeChange() {
        layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        for chrome in cardLayers {
            chrome.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
            chrome.borderColor = Theme.cgColor(hex: theme.cardBorder)
        }
        let titleColor = Theme.cgColor(hex: theme.textSecondary)
        for key in Self.cardKeys {
            textLayers["\(key).title"]?.foregroundColor = titleColor
        }
        textLayers["power.headline"]?.foregroundColor = theme.cgColor("accentEnergy")
        let disabledColor = Theme.cgColor(hex: theme.textDisabled)
        for (key, layer) in textLayers where key.contains(".axis.") || key.contains(".mhz.")
            || key.contains(".column.unavailable.") {
            layer.foregroundColor = disabledColor
        }
        // The captions take their colour per column from the model's accent token.
        if let model {
            applyText(model)
        }
        for chart in residencyCharts { chart.applyTheme(theme, colors: themeStore.colors) }
        for histogram in histograms { histogram.applyTheme(theme, accentToken: histogram.accentToken) }
        powerChart.applyTheme(theme, colors: themeStore.colors)
    }

    // MARK: - Static layer construction

    private func buildStaticLayers() {
        guard let root = layer else { return }

        // §14.1's table: title per card. `accent` is a §7.2 token name.
        let cards: [(key: String, accent: String, title: String)] = [
            ("residency", "accentClock", "FREQUENCY RESIDENCY"),
            ("states", "accentClock", "DVFS STATES"),
            ("power", "accentEnergy", "PACKAGE POWER"),
        ]

        // Sublayer order is z-order (gate 12's `render(in:)` honours only that): chrome
        // first, then everything drawn on it.
        for _ in cards {
            let chrome = CardChrome.makeCardLayer(theme: theme)
            root.addSublayer(chrome)
            cardLayers.append(chrome)
        }

        // §6.5: the charts, one container per column, above the chrome and below the marks
        // (phase-03's G1: a chart beneath its chrome is composited away). Card 1 plots the
        // `hz2` buffer's 120.
        for _ in 0..<Self.columnCount {
            let chart = ChartLayer(capacity: 120)
            chart.applyTheme(theme, colors: themeStore.colors)
            root.addSublayer(chart)
            residencyCharts.append(chart)
        }
        // Card 2's histograms, the same z-position for the same reason.
        for accent in Self.defaultAccents {
            let histogram = HistogramLayer(theme: theme, accentToken: accent)
            root.addSublayer(histogram)
            histograms.append(histogram)
        }
        // Card 3's chart, themed the same way.
        powerChart.applyTheme(theme, colors: themeStore.colors)
        root.addSublayer(powerChart)

        for card in cards {
            addText("\(card.key).title", card.title, size: 11, weight: .semibold,
                    token: "textSecondary", alignment: .left, tracking: 0.66)
            // Cards 1 and 2's headline layers exist for §4.2's uniform chrome and stay `""`
            // (D-20): the per-column caption carries the live value. Card 3 keeps the 24 pt W.
            addText("\(card.key).headline", card.key == "power" ? "···" : "", size: 24,
                    weight: .medium, token: card.accent, alignment: .right,
                    monospacedDigits: true)
            addText("\(card.key).footer", "", size: 10, weight: .regular,
                    token: "textTertiary", alignment: .left)
            addText("\(card.key).unavailable", "", size: 11, weight: .regular,
                    token: "textDisabled", alignment: .center)
        }

        // Cards 1 and 2's per-column text: the caption (SF Mono 10 pt, the cluster's accent --
        // set per column from the model) and D-11's one-size-down unavailable body.
        for card in ["residency", "states"] {
            for index in 0..<Self.columnCount {
                let caption = Self.monoCaption(theme: theme)
                textLayers["\(card).caption.\(index)"] = caption
                root.addSublayer(caption)
                addText("\(card).column.unavailable.\(index)", "", size: 10, weight: .regular,
                        token: "textDisabled", alignment: .center)
            }
            // The left axis's labels, leftmost column only: the percent scale is the same in
            // every column and three copies of it is noise (Phase 0's discretion table).
            for value in CardMetrics.percentGridlines {
                addText("\(card).axis.\(Int(value))", "", size: 9, weight: .regular,
                        token: "textDisabled", alignment: .right)
            }
        }
        // Card 1's right-hand MHz labels, every column: that scale is per column (D-14).
        for index in 0..<Self.columnCount {
            for tick in 0..<3 {
                addText("residency.mhz.\(index).\(tick)", "", size: 9, weight: .regular,
                        token: "textDisabled", alignment: .left)
            }
        }
        // Card 3's five left-axis labels, 0/25/50/75/100 % of the auto-scaled max, in W.
        for index in 0..<5 {
            addText("power.axis.\(index)", "", size: 9, weight: .regular,
                    token: "textDisabled", alignment: .right)
        }
    }

    /// SF Mono 10 pt, left-aligned, no `contents` crossfade -- the UI-SPEC's column caption.
    /// 10, not phase-10's 9: this caption carries a live value in the cluster's accent.
    private static func monoCaption(theme: Theme) -> CATextLayer {
        let label = CATextLayer()
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        label.fontSize = 10
        label.alignmentMode = .left
        label.truncationMode = .end
        label.foregroundColor = Theme.cgColor(hex: theme.textDisabled)
        label.actions = ["contents": NSNull()]
        return label
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

    override func layout() {
        super.layout()
        layoutCards()
        // §5.6.3's tooltip over card 3's footer, and only there (`NSView.toolTip` would
        // fire over all three cards). `removeAllToolTips()` first: `layout()` runs on every
        // resize and `addToolTipRect` accumulates. A pane laid out before its first sample
        // registers nothing.
        removeAllToolTips()
        if let model, bounds.width > 1 {
            let inner = cardFrames()[2].insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
            let footerRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: 12)
            let owner = model.powerTooltip as NSString
            tooltipOwner = owner
            // AppKit's Swift name for `addToolTipRect:owner:userData:`; the tag is not kept
            // because `removeAllToolTips()` is how the rect is cleared.
            _ = addToolTip(footerRect, owner: owner, userData: nil)
        }
        // `GLOWTOP_LOG_GEOM`, Summary's own hook: the card height as laid out, so 5.2 can
        // quote the measured value rather than the UI-SPEC's estimate (override O-4).
        if logGeometry, bounds.width > 1 {
            print(String(format: "power grid bounds=%.1fx%.1f cardHeight=%.1f columnWidth=%.1f",
                         bounds.width, bounds.height, cardFrames()[0].height,
                         columnRect(0, of: 3, in: residencyPlotRect(cardFrames()[0])).width))
            fflush(stdout)
        }
    }

    /// A window dragged from a 2× panel to a 1× external otherwise keeps 2× text.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// D-19: equal thirds of the detail area after §4.1's padding and gaps. Bottom-left
    /// origin, so the power card's y is the lowest. Nothing scrolls; all three shrink with
    /// the window.
    func cardFrames() -> [CGRect] {
        let content = bounds.width - CardMetrics.outerPadding * 2
        let cardHeight = (bounds.height - CardMetrics.outerPadding * 2 - CardMetrics.gap * 2) / 3
        let x0 = CardMetrics.outerPadding
        let powerY = CardMetrics.outerPadding
        let statesY = powerY + cardHeight + CardMetrics.gap
        let residencyY = statesY + cardHeight + CardMetrics.gap
        return [
            CGRect(x: x0, y: residencyY, width: content, height: cardHeight),
            CGRect(x: x0, y: statesY, width: content, height: cardHeight),
            CGRect(x: x0, y: powerY, width: content, height: cardHeight),
        ]
    }

    /// §14.1's column geometry, computed **once** and applied by cluster identity, not by
    /// list index -- which is what makes a cluster occupy the same x-range in cards 1 and 2.
    func columnRect(_ index: Int, of count: Int, in plot: CGRect) -> CGRect {
        let gutter = CardMetrics.gap                       // 12 pt, locked
        let width = (plot.width - gutter * CGFloat(max(count - 1, 0))) / CGFloat(max(count, 1))
        return CGRect(x: plot.minX + CGFloat(index) * (width + gutter),
                      y: plot.minY, width: width, height: plot.height)
    }

    /// Card 1: 13 pt title + 2 + 12 pt caption + 4 above the plot; nothing below it.
    func residencyPlotRect(_ card: CGRect) -> CGRect {
        plotRect(card, top: 31, bottom: 0)
    }

    /// Card 2: the same top; 12 pt footer + 4 + 11 pt x labels below.
    func statesPlotRect(_ card: CGRect) -> CGRect {
        plotRect(card, top: 31, bottom: 27)
    }

    /// Card 3: `PerformancePaneView.memoryPlotRect`'s numbers exactly -- a headline band
    /// above, a footer below.
    func powerPlotRect(_ card: CGRect) -> CGRect {
        plotRect(card, top: 31, bottom: 16)
    }

    private func plotRect(_ card: CGRect, top: CGFloat, bottom: CGFloat) -> CGRect {
        let inner = card.insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        return CGRect(x: inner.minX, y: inner.minY + bottom, width: inner.width,
                      height: max(inner.maxY - top - (inner.minY + bottom), 0))
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

        // Card 1. Each container is framed to its column rect, in the pane's own bottom-left
        // space -- no conversion: the view is unflipped and a layer's `geometryFlipped` is
        // false. `contentsScale` before `frame`, so the layer never rasterizes at the wrong
        // scale. The column index is the model's, which is the locked P0/P1/E order, and
        // card 2 makes the identical `columnRect` call (D-18).
        let columns = model?.columns.count ?? 0
        laidOutColumns = columns
        let residencyPlot = residencyPlotRect(frames[0])
        for (index, chart) in residencyCharts.enumerated() {
            chart.contentsScale = scale
            chart.frame = index < columns ? columnRect(index, of: columns, in: residencyPlot) : .zero
        }
        layoutColumnText(card: "residency", in: frames[0], plot: residencyPlot, columns: columns,
                         scale: scale)

        // Card 2: the identical `columnRect` call against card 2's plot rect, so a cluster
        // occupies the same x-range in both cards (D-18).
        let statesPlot = statesPlotRect(frames[1])
        for (index, histogram) in histograms.enumerated() {
            histogram.contentsScale = scale
            histogram.frame = index < columns ? columnRect(index, of: columns, in: statesPlot) : .zero
        }
        layoutColumnText(card: "states", in: frames[1], plot: statesPlot, columns: columns,
                         scale: scale)

        // Card 3: full inner width; the five W labels at 0/25/50/75/100 % of the plot, the top
        // one under the edge for the same reason cards 1 and 2's is (the headline band is there).
        let powerPlot = powerPlotRect(frames[2])
        powerChart.contentsScale = scale
        powerChart.frame = powerPlot
        for index in 0..<5 {
            guard let label = textLayers["power.axis.\(index)"] else { continue }
            label.contentsScale = scale
            let y = powerPlot.minY + powerPlot.height * CGFloat(index) / 4
            label.frame = CGRect(x: powerPlot.minX, y: index == 4 ? y - 12 : y + 1, width: 36, height: 11)
        }
        CATransaction.commit()

        // The paths are built in each container's own space, so a new frame is a new path.
        applyChartLayers()
    }

    /// Per column: the caption between the title line and the plot (13 + 2, 12 pt tall), the
    /// unavailable body centred in the column, and card 1's three MHz labels at the column's
    /// right edge. The left percent labels sit on the leftmost column, `layoutAxisLabels`'
    /// arithmetic. Columns beyond the model's are framed to `.zero`.
    private func layoutColumnText(card: String, in cardFrame: CGRect, plot: CGRect,
                                  columns: Int, scale: CGFloat) {
        let inner = cardFrame.insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        for index in 0..<Self.columnCount {
            let column = index < columns ? columnRect(index, of: columns, in: plot) : .zero
            if let caption = textLayers["\(card).caption.\(index)"] {
                caption.contentsScale = scale
                caption.frame = column == .zero ? .zero
                    : CGRect(x: column.minX, y: inner.maxY - 27, width: column.width, height: 12)
            }
            if let unavailable = textLayers["\(card).column.unavailable.\(index)"] {
                unavailable.contentsScale = scale
                unavailable.frame = column == .zero ? .zero
                    : CGRect(x: column.minX, y: column.midY - 7, width: column.width, height: 14)
            }
            if card == "residency" {
                // 48 pt, not the plan's 30: `4.51 GHz` at 9 pt is ≈44 pt and truncated at 30.
                let ys = [column.minY, column.midY, column.maxY - 11]
                for (tick, y) in ys.enumerated() {
                    guard let label = textLayers["residency.mhz.\(index).\(tick)"] else { continue }
                    label.contentsScale = scale
                    label.frame = column == .zero ? .zero
                        : CGRect(x: column.maxX - 48, y: y, width: 48, height: 11)
                }
            }
        }
        let first = columns > 0 ? columnRect(0, of: columns, in: plot) : .zero
        for value in CardMetrics.percentGridlines {
            guard let label = textLayers["\(card).axis.\(Int(value))"] else { continue }
            label.contentsScale = scale
            let y = first.minY + first.height * ChartAxis.percent.normalise(value)
            // `layoutAxisLabels`' arithmetic, except the top label sits **under** the edge:
            // above it is the caption (4.2's first screenshot had `100` drawn through `P0`).
            let labelY = value >= 100 ? y - 12 : y + 1
            label.frame = first == .zero ? .zero : CGRect(x: first.minX, y: labelY, width: 22, height: 11)
        }
    }

    // MARK: - Charts

    /// §6.5: the charts as parameters to their `ChartLayer`s at the current scroll offset.
    /// One transaction, actions disabled. Called when a plotted value changed (`apply(_:)`),
    /// when the scroll crossed a backing pixel (`tick()`), and on layout. §6.7's second
    /// number is counted here, where new pixels are actually produced.
    private func applyChartLayers() {
        guard let model else { return }
        counter.countDraw()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Card 1, per column: the cumulative bands then the average line **appended last** so
        // it strokes over them (D-14; `ChartLayer` draws slots in array order). A column that
        // is warming or unavailable has an empty `residencySeries` and no line, so `apply`
        // receives `[]` and clears every path, gridlines included -- §4.8's omitted plot
        // (finding F-9). The right axis is this column's own, never shared (D-14).
        for (index, chart) in residencyCharts.enumerated() where index < model.columns.count {
            let column = model.columns[index]
            let mhzTicks: [Double] = column.megahertzAxis.map { [0, $0.max / 2, $0.max] } ?? []
            chart.apply(series: column.residencySeries + (column.averageSeries.map { [$0] } ?? []),
                        gridlines: CardMetrics.percentGridlines,
                        axis: .percent,
                        rightGridlines: mhzTicks,
                        rightAxis: column.megahertzAxis,
                        scrollOffset: scrollOffset(for: chart.bounds, capacity: 120))
        }
        // Card 2, per column: the bins as bars, the same ramp as card 1's bands (one ramp
        // definition, two charts). An empty `bins` clears the plot, gridlines included.
        for (index, histogram) in histograms.enumerated() where index < model.columns.count {
            let column = model.columns[index]
            if histogram.accentToken != column.accentToken {
                histogram.applyTheme(theme, accentToken: column.accentToken)
            }
            histogram.apply(
                bars: column.bins.map {
                    HistogramLayer.Bar(heightFraction: $0.share, opacity: $0.opacity, label: $0.label)
                },
                gridlines: CardMetrics.percentGridlines
            )
        }
        // Card 3: the memory card's empty-series guard, but **not** its empty gridlines --
        // §14.1 gives this card five, at 0/25/50/75/100 % of the auto-scaled max, and
        // `ChartLayer` normalises gridline values through the axis it is handed, which here is
        // in watts. Raw percentages against a 60 W axis would pile up at the bottom.
        let watts = model.powerAxis
        powerChart.apply(series: watts == nil ? [] : model.powerSeries,
                         gridlines: watts.map { axis in [0, 25, 50, 75, 100].map { axis.max * $0 / 100 } } ?? [],
                         axis: watts ?? .percent,
                         scrollOffset: scrollOffset(for: powerChart.bounds, capacity: 60))
        CATransaction.commit()
    }

    /// Gate 12 renders into a 1× context; a layer rasterized at one scale and captured at
    /// another reads as a quarter-pixel phase difference along every stroke (phase-09). The
    /// charts are pinned to the context's own scale here, for the offscreen check only.
    func pinChartsToOffscreenScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for chart in residencyCharts { chart.contentsScale = 1 }
        for histogram in histograms { histogram.contentsScale = 1 }
        powerChart.contentsScale = 1
        CATransaction.commit()
        applyChartLayers()
    }

    /// §6.6 rule 4: the plot's x-offset advances continuously between samples and each
    /// plotted point keeps its measured value. `sampledAt == nil` pins the offset at 0 —
    /// gate 12's fixed fixture must not read the wall clock (finding F-8).
    private func scrollOffset(for plot: CGRect, capacity: Int) -> Double {
        guard let sampledAt else { return 0 }
        let fraction = Interpolation.fraction(now: ContinuousClock().now,
                                              sampledAt: sampledAt, interval: sampleInterval)
        let rect = PlotRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height)
        return ChartSeries.sampleWidth(in: rect, capacity: capacity) * fraction
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

    private var plotWidth: Double {
        Double(contentWidth - CardMetrics.cardPadding * 2)
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
        // pixel-identical to the frame already on screen is skipped (§6.7). The step is
        // card 1's: capacity 120, so the divisor is 119.
        if let sampledAt {
            let fraction = Interpolation.fraction(now: ContinuousClock().now,
                                                  sampledAt: sampledAt, interval: sampleInterval)
            let scale = Double(window?.backingScaleFactor ?? 2)
            let step = Int((fraction * plotWidth / Double(119) * scale).rounded(.down))
            if step != lastScrollStep {
                lastScrollStep = step
                applyChartLayers()
            }
        }

        // §6.7's counter closes a whole second and prints the harness's `fps` line itself —
        // which is what gives the Power & Freq-visible arm an `fps` number.
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

// MARK: - Gate 12's Power & Freq arm (§14.1, D-25; plan sub-step 5.1)

extension PowerFreqPaneView {
    private static let selfCheckWidth = 1172
    private static let selfCheckHeight = 778

    /// Renders one fixture offscreen at Summary's own self-check size. `sampledAt: nil`
    /// pins §6.6's scroll offset at 0 (finding F-8) — a fixed fixture must not read the wall
    /// clock. The context is part of the return value on purpose (`renderPaneOffscreen`'s
    /// comment).
    private static func renderSelfCheck(
        _ frames: SummaryFrames, themeStore: ThemeStore = .shared
    ) -> (view: PowerFreqPaneView, context: CGContext, scan: PixelScan)? {
        let width = selfCheckWidth, height = selfCheckHeight
        let view = PowerFreqPaneView(
            frame: NSRect(x: 0, y: 0, width: width, height: height), themeStore: themeStore
        )
        view.apply(PowerFreqModel.project(frames), sampledAt: nil, interval: SampleRate.hz2)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.pinChartsToOffscreenScale()
        guard let (context, scan) = renderPaneOffscreen(view, width: width, height: height)
        else { return nil }
        return (view, context, scan)
    }

    /// Eight assertions over four renders: chart pixels in all three cards and D-18's column
    /// alignment on the live fixture; §4.8's warming and whole-pane unavailable appearance;
    /// D-11's one column unavailable beside live neighbours. Every rect comes from the view's
    /// own geometry, so an assertion and the thing it asserts cannot drift apart. The
    /// warming and unavailable checks each pair a presence with absences, because an
    /// absence-only assertion passes on a blank render.
    static func paneSelfCheck() -> [PaneAssertion] {
        // `context` must keep its name so ARC keeps the bitmap `scan` points into alive.
        guard let (view, context, scan) = renderSelfCheck(selfCheckFramesPower()) else {
            return [PaneAssertion(name: "power-render", pass: false, detail: "no bitmap")]
        }
        if let path = ProcessInfo.processInfo.environment["GLOWTOP_SELFCHECK_PNG_POWER"] {
            writeSelfCheckPNG(context, to: path)
        }

        let theme = view.theme
        // Geometry is a pure function of the bounds, identical across the four renders.
        let cards = view.cardFrames()
        let residencyPlot = view.residencyPlotRect(cards[0])
        let statesPlot = view.statesPlotRect(cards[1])
        let powerPlot = view.powerPlotRect(cards[2])
        let p0Column = view.columnRect(0, of: 3, in: residencyPlot)
        let eColumn = view.columnRect(2, of: 3, in: residencyPlot)
        var results: [PaneAssertion] = []

        // 1 — card 1's P0 column has bands or a line in its accent.
        let p0Hits = scan.hits(in: p0Column, ofHex: theme.accentClock, tolerance: 60)
        results.append(PaneAssertion(
            name: "power-residency-p0-pixels", pass: p0Hits > 0, detail: "hits=\(p0Hits)"
        ))

        // 2 — the E column draws in a *different* accent, which a shared-accent bug fails.
        let eHits = scan.hits(in: eColumn, ofHex: theme.accentGPU, tolerance: 60)
        results.append(PaneAssertion(
            name: "power-residency-e-pixels", pass: eHits > 0, detail: "hits=\(eHits)"
        ))

        // 3 — card 2's P0 histogram has bars.
        let histogramHits = scan.hits(in: view.columnRect(0, of: 3, in: statesPlot),
                                      ofHex: theme.accentClock, tolerance: 60)
        results.append(PaneAssertion(
            name: "power-histogram-pixels", pass: histogramHits > 0, detail: "hits=\(histogramHits)"
        ))

        // 4 — D-18: each cluster occupies the same x-range in cards 1 and 2, as geometry.
        let columnXs = (0..<3).map { index in
            (residency: view.columnRect(index, of: 3, in: residencyPlot).minX,
             states: view.columnRect(index, of: 3, in: statesPlot).minX)
        }
        results.append(PaneAssertion(
            name: "power-columns-aligned",
            pass: columnXs.allSatisfy { abs($0.residency - $0.states) < 0.01 },
            detail: "x=" + columnXs.map { String(format: "%.1f", $0.residency) }.joined(separator: ",")
        ))

        // 5 — card 3's bottom band (CPU) and top band (DRAM) both present, so a stack that
        // collapsed to one layer fails.
        let cpuHits = scan.hits(in: powerPlot, ofHex: theme.accentCPU, tolerance: 60)
        let dramHits = scan.hits(in: powerPlot, ofHex: theme.accentMemory, tolerance: 60)
        results.append(PaneAssertion(
            name: "power-package-pixels", pass: cpuHits > 0 && dramHits > 0,
            detail: "cpu_hits=\(cpuHits) dram_hits=\(dramHits)"
        ))

        // 6 — §4.8's warming appearance. A warming frequency frame has no sample and so no
        // columns: cards 1 and 2 draw no captions at all, and the pane's one `···` is card
        // 3's headline. That presence, plus nothing plotted in card 1's P0 column or card 3.
        guard let (_, warmContext, warmScan) = renderSelfCheck(selfCheckFramesPower(state: .warming))
        else {
            results.append(PaneAssertion(name: "power-render-warming", pass: false, detail: "no bitmap"))
            _ = context
            return results
        }
        let powerInner = cards[2].insetBy(dx: CardMetrics.cardPadding, dy: CardMetrics.cardPadding)
        let headlineRect = CGRect(x: powerInner.minX, y: powerInner.maxY - 29,
                                  width: powerInner.width, height: 29)
        let warmHeadlineHits = warmScan.hits(in: headlineRect, ofHex: theme.textDisabled, tolerance: 24)
        let warmP0Hits = warmScan.hits(in: p0Column, ofHex: theme.accentClock, tolerance: 60)
        let warmCPUHits = warmScan.hits(in: powerPlot, ofHex: theme.accentCPU, tolerance: 60)
        results.append(PaneAssertion(
            name: "power-warming-appearance",
            pass: warmHeadlineHits > 0 && warmP0Hits == 0 && warmCPUHits == 0,
            detail: "headline_hits=\(warmHeadlineHits) p0_hits=\(warmP0Hits) cpu_hits=\(warmCPUHits)"
        ))

        // 7 — D-11: the E column alone unavailable, held by one assertion over one bitmap.
        guard let (_, columnContext, columnScan) = renderSelfCheck(selfCheckFramesPowerColumnUnavailable())
        else {
            results.append(PaneAssertion(name: "power-render-column-unavailable", pass: false, detail: "no bitmap"))
            _ = context
            _ = warmContext
            return results
        }
        let unavailableEHits = columnScan.hits(in: eColumn, ofHex: theme.accentGPU, tolerance: 60)
        let liveP0Hits = columnScan.hits(in: p0Column, ofHex: theme.accentClock, tolerance: 60)
        results.append(PaneAssertion(
            name: "power-column-unavailable-e",
            pass: unavailableEHits == 0 && liveP0Hits > 0,
            detail: "e_hits=\(unavailableEHits) p0_hits=\(liveP0Hits)"
        ))

        // 8 — PWR-05's offscreen half: `Unavailable on this Mac` on all three cards and no
        // accent anywhere on the pane.
        guard let (_, allContext, allScan) = renderSelfCheck(
            selfCheckFramesPower(state: .unavailable(reason: PrivateAPI.disabledReason))
        ) else {
            results.append(PaneAssertion(name: "power-render-unavailable", pass: false, detail: "no bitmap"))
            _ = context
            _ = warmContext
            _ = columnContext
            return results
        }
        let disabledHits = cards.map { allScan.hits(in: $0, ofHex: theme.textDisabled, tolerance: 24) }
        let accentHits = [theme.accentClock, theme.accentGPU, theme.accentCPU, theme.accentMemory]
            .map { allScan.hits(in: view.bounds, ofHex: $0, tolerance: 60) }
        results.append(PaneAssertion(
            name: "power-unavailable-all-cards",
            pass: disabledHits.allSatisfy { $0 > 0 } && accentHits.allSatisfy { $0 == 0 },
            detail: "disabled_hits=" + disabledHits.map(String.init).joined(separator: ",")
                + " accent_hits=" + accentHits.map(String.init).joined(separator: ",")
        ))

        _ = context
        _ = warmContext
        _ = columnContext
        _ = allContext
        return results
    }
}
