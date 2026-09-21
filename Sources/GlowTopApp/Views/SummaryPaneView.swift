import AppKit
import GlowTopCore
import QuartzCore

/// The Summary pane. SPEC.md §4.
///
/// One `NSView` owns the whole content area: §4.1's grid in points, every `CALayer`, every
/// `CGPath`, the display link and §6.7's counter. Eleven child views would be eleven backing
/// stores, eleven `draw(_:)` calls, and eleven places for the identical-frame skip to be
/// decided; card chrome is `backgroundColor` + `borderWidth` + `cornerRadius`, which the
/// compositor does for free.
///
/// The eight `chartLayers` (Views/ChartLayer.swift) are the chart plot areas, one per plot
/// rect, and sit above the card chrome. Everything else is layers too. The view itself draws
/// nothing: drawn into the root layer, the charts sit beneath ten opaque chrome sublayers and
/// are composited away — `draws` read 10/s on a pane with no visible chart.
@MainActor
final class SummaryPaneView: NSView {
    // MARK: - §4.1 geometry

    /// §4.1's constants live in `CardMetrics` (Views/CardChrome.swift) as of phase-10.
    typealias Metrics = CardMetrics

    // MARK: - State

    /// Defaults to `.shared` (production) but is swappable via the `themeStore:` initializer
    /// so gate 12's theme-switch self-check can render against an isolated store instead of
    /// mutating the real `UserDefaults` domain (`ThemeStore.shared`'s own doc comment).
    private var themeStore: ThemeStore = .shared
    private var theme: Theme { themeStore.theme }
    private var model: SummaryModel?
    private var lastPlottedSignature: Int = 0
    private var lastScrollStep: Int = -1
    private var sampledAt: ContinuousClock.Instant?
    private var sampleInterval: Duration = SampleRate.hz10

    /// §6.8 and §6.2. Both stop the display link; neither stops the store from this view.
    var isPaused = false { didSet { updateLinkState() } }
    var isOccluded = false { didSet { updateLinkState() } }

    var onKey: ((KeyAction) -> Void)?
    enum KeyAction { case pause, forceSample, toggleFPS }

    var showFPSOverlay = false { didSet { fpsLayer.isHidden = !showFPSOverlay } }

    // MARK: - Layers

    private var cardLayers: [CALayer] = []
    /// Eight `ChartLayer`s, one per plot rect: CPU, memory, tile 0…5. Constructed here with
    /// their series and colours as parameters (RENDER-05); Phase 10's pane constructs its own.
    private var chartLayers: [ChartLayer] = []
    /// Printed at launch. Phase-09's spike proved its two arms were a pair by this marker; it
    /// stays because it costs one line and names the renderer a log came from.
    static let chartPathName = "ca"
    private var meters: [MeterLayer] = []
    private var perCoreMeters: [MeterLayer] = []
    private var perCoreCaptions: [CATextLayer] = []
    private var memoryMeter: MeterLayer?
    private var textLayers: [String: CATextLayer] = [:]
    private let fpsLayer = CATextLayer()
    private var processRows: ProcessRowsLayer?
    /// §5.5.3: the card refreshes at 1 Hz, so it is gated on the sample's own timestamp
    /// changing rather than on the 10 Hz tick.
    private var lastProcessSampledAt: ContinuousClock.Instant?
    private var builtCoreCount = 0

    // MARK: - §6.7 counter

    private var link: CADisplayLink?
    /// §6.7's two numbers, counted in `FrameRateCounter` (Views/FrameRateCounter.swift).
    private let counter = FrameRateCounter()
    /// §9.2's Frame rate row: the counter's last whole-second reading and its instant.
    var frameRate: (fps: Double, at: Date)? { counter.frameRate }
    private let logFPS = ProcessInfo.processInfo.environment["GLOWTOP_LOG_FPS"] != nil
    private let logGeometry = ProcessInfo.processInfo.environment["GLOWTOP_LOG_GEOM"] != nil
    private var loggedGeometry = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// §4.10: one plain sentence per card, shown on hover in Simple mode. Keyed like
    /// `textLayers`; empty in Technical. Registered over `cardFrames()` in `layout()` and again
    /// whenever the set changes (`PowerFreqPaneView`'s `addToolTip(_:owner:userData:)` pattern).
    private var explanations: [String: String] = [:] {
        didSet { if explanations != oldValue { needsLayout = true } }
    }
    private var tooltipOwners: [NSString] = []
    private static let cardKeys = ["meters", "cpu", "processes", "memory",
                                   "tile.0", "tile.1", "tile.2", "tile.3", "tile.4", "tile.5"]

    /// The horizontal band the verdict takes out of the footer's line: the word's own measured
    /// width plus §4.10's gap, or nothing at all when there is no verdict (Technical mode, and
    /// any card that is not live).
    private func verdictLayerWidth(_ key: String) -> CGFloat {
        guard let text = textLayers["\(key).verdict"]?.string as? String, !text.isEmpty else { return 0 }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + Metrics.verdictGap
    }

    private func registerExplanations() {
        removeAllToolTips()
        tooltipOwners = []
        for (key, frame) in zip(Self.cardKeys, cardFrames()) {
            guard let text = explanations[key], !text.isEmpty else { continue }
            let owner = text as NSString
            tooltipOwners.append(owner)
            _ = addToolTip(frame, owner: owner, userData: nil)
        }
    }

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

    /// Gate 12's self-check entry point: renders against `themeStore` instead of `.shared`, so
    /// a theme switch can be exercised without writing to the real `UserDefaults` domain.
    convenience init(frame frameRect: NSRect, themeStore: ThemeStore) {
        self.init(frame: frameRect)
        self.themeStore = themeStore
        applyThemeChange()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Data

    func apply(_ model: SummaryModel, sampledAt: ContinuousClock.Instant?, interval: Duration,
               processSampledAt: ContinuousClock.Instant?) {
        self.model = model
        self.sampledAt = sampledAt
        self.sampleInterval = interval

        // §4.3.3: 1 Hz, deliberately slower than the meters. A list that reshuffles ten
        // times a second is unreadable, and rewriting twelve rows at 10 Hz would also undo
        // §6.9's set-on-change rule nine times out of ten.
        if processSampledAt != lastProcessSampledAt {
            lastProcessSampledAt = processSampledAt
            processRows?.apply(model.processRows)
        }

        if model.perCore.count != builtCoreCount {
            buildPerCoreStrip(count: model.perCore.count)
            needsLayout = true
        }

        applyMeters(model)
        applyText(model)
        applyRightAxis(model)

        // A chart redraws when a plotted value changed, not on every tick.
        let signature = plotSignature(model)
        if signature != lastPlottedSignature {
            lastPlottedSignature = signature
            applyChartLayers()
        }
    }

    private func plotSignature(_ model: SummaryModel) -> Int {
        var hasher = Hasher()
        hasher.combine(model.cpuOverview.series.first?.values.last)
        hasher.combine(model.cpuOverview.series.last?.values.last)
        hasher.combine(model.memory.series.first?.values.last)
        for tile in model.tiles { hasher.combine(tile.series.first?.values.last) }
        return hasher.finalize()
    }

    /// §4.4: the right-hand axis labels and `drawCharts(_:in:)`'s `rightGridlines` argument
    /// are both driven from this one condition -- two independent switches is how a chart
    /// ends up with an axis and no line, or a line with no axis.
    private func applyRightAxis(_ model: SummaryModel) {
        let present = model.cpuOverview.rightAxis != nil
        for value in SummaryModel.cpuRightGridlines {
            setText("cpu.rightAxis.\(Int(value))", present ? "\(Int(value))" : "")
        }
    }

    private func applyMeters(_ model: SummaryModel) {
        for (index, meterModel) in model.meters.enumerated() where index < meters.count {
            meters[index].set(fraction: meterModel.fraction, state: meterModel.state,
                              over: sampleInterval)
        }
        for (index, coreModel) in model.perCore.enumerated() where index < perCoreMeters.count {
            perCoreMeters[index].set(fraction: coreModel.fraction, state: coreModel.state,
                                     over: sampleInterval)
        }
        memoryMeter?.set(fraction: model.memoryMeter.fraction, state: model.memoryMeter.state,
                         over: sampleInterval)
    }

    // MARK: - Text

    /// §6.9: a `CATextLayer` per label whose string is set **only when it changes**, so text
    /// left the per-frame path for the same reason the meters did.
    private func setText(_ key: String, _ value: String, token: String? = nil,
                         opacity: Float = 1) {
        CardChrome.setText(textLayers[key], value, token: token, opacity: opacity, theme: theme)
    }

    private func applyText(_ model: SummaryModel) {
        for (index, meter) in model.meters.enumerated() {
            setText("meter.\(index).label", meter.label,
                    token: meter.state == .live ? meter.colorToken : "textDisabled")
            // §4.10: captions and titles are the model's, so Simple and Technical are one code
            // path with two sets of words. `setText` writes only on change.
            setText("meter.\(index).caption", meter.caption, token: "textTertiary")
        }

        explanations["meters"] = model.cpuOverview.explanation.isEmpty ? "" : SimpleLabels.explanations[0]
        applyCard("cpu", model.cpuOverview)
        applyCard("memory", model.memory)
        applyCard("processes", model.processes)
        for (index, tile) in model.tiles.enumerated() {
            applyCard("tile.\(index)", tile)
        }
    }

    private func applyCard(_ key: String, _ card: CardModel) {
        // §4.3.3: the process count is a header-right caption in `#6E6E7E`, not an accent.
        CardChrome.applyCardText(
            card, headline: textLayers["\(key).headline"], footer: textLayers["\(key).footer"],
            unavailable: textLayers["\(key).unavailable"], theme: theme,
            headlineToken: key == "processes" ? "textTertiary" : nil
        )
        setText("\(key).title", card.title, token: "textSecondary")
        // §4.10's verdict: bottom-trailing, on the footer's line. Never the card's accent, and
        // empty in Technical mode and on any card that is not live.
        // The word is written on the render path; its width changes the footer's frame, which is
        // a layout concern. Deadbanded verdicts change rarely, so this asks for a layout pass
        // only when the string actually moves.
        let verdictLayer = textLayers["\(key).verdict"]
        let newVerdict = card.verdict?.text ?? ""
        if (verdictLayer?.string as? String) != newVerdict { needsLayout = true }
        setText("\(key).verdict", newVerdict, token: card.verdict?.colorToken ?? "textSecondary")
        explanations[key] = card.explanation
    }

    // MARK: - Theme

    /// The four §4.3.1 meters' tokens, in `meters`' build order (CPU, Clock, Temp, GPU).
    private static let meterAccentTokens = ["accentCPU", "accentClock", "accentThermal", "accentGPU"]
    /// The nine cards that carry a title label — `meters` has none (§4.3.1's comment in
    /// `buildStaticLayers()`).
    private static let titledCardKeys = [
        "cpu", "processes", "memory", "tile.0", "tile.1", "tile.2", "tile.3", "tile.4", "tile.5",
    ]

    @objc private func handleThemeDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === themeStore else { return }
        applyThemeChange()
    }

    /// §7.3's live-apply, this view's half: every already-built layer's colour is re-derived
    /// from the new theme. Order matters — the shared cache (`MeterLayer`'s texture cache) is
    /// cleared **before** anything downstream reads it again, or a meter reads back its own
    /// stale image under the new key (this sub-step's own recorded failure shape: the charts
    /// repaint and the meters silently stay in the old palette).
    private func applyThemeChange() {
        layer?.backgroundColor = Theme.cgColor(hex: theme.background)

        for chrome in cardLayers {
            chrome.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
            chrome.borderColor = Theme.cgColor(hex: theme.cardBorder)
        }

        let titleColor = Theme.cgColor(hex: theme.textSecondary)
        for key in Self.titledCardKeys {
            textLayers["\(key).title"]?.foregroundColor = titleColor
        }
        let captionColor = Theme.cgColor(hex: theme.textTertiary)
        for index in 0..<meters.count {
            textLayers["meter.\(index).caption"]?.foregroundColor = captionColor
        }
        let disabledColor = Theme.cgColor(hex: theme.textDisabled)
        for value in CardMetrics.percentGridlines {
            textLayers["cpu.axis.\(Int(value))"]?.foregroundColor = disabledColor
        }
        for value in SummaryModel.cpuRightGridlines {
            textLayers["cpu.rightAxis.\(Int(value))"]?.foregroundColor = disabledColor
        }
        fpsLayer.foregroundColor = disabledColor

        // Data-dependent text (card headlines/footers, meter labels) re-derives its token from
        // the current model through the same call that set it the first time — no second,
        // separately-maintained mapping of key to token.
        if let model {
            applyText(model)
        }

        // The shared cache, cleared before anything reads it again.
        MeterLayer.invalidateTextureCache()

        for (index, meter) in meters.enumerated() where index < Self.meterAccentTokens.count {
            let hex = theme[Self.meterAccentTokens[index]] ?? theme.accentCPU
            meter.updateTheme(accentHex: hex, theme: theme)
        }
        for meter in perCoreMeters {
            meter.updateTheme(accentHex: theme.accentCPU, theme: theme)
        }
        memoryMeter?.updateTheme(accentHex: theme.accentMemory, theme: theme)

        processRows?.updateTheme(theme)

        for chart in chartLayers { chart.applyTheme(theme, colors: themeStore.colors) }
    }

    // MARK: - Static layer construction

    private func buildStaticLayers() {
        guard let root = layer else { return }

        // §4.1's order: row 1, row 2, then the six tiles. `accent` is a §7.2 token name —
        // `addText` resolves tokens, and a hex string handed to it resolves to the
        // fallback colour with an error logged per card.
        let cards: [(key: String, accent: String, title: String)] = [
            ("meters", "accentCPU", ""),
            ("cpu", "accentCPU", "CPU OVERVIEW"),
            ("processes", "accentCPU", "TOP CPU PROCESSES"),
            ("memory", "accentMemory", "MEMORY UTILIZATION"),
            ("tile.0", "accentDisk", "DISKS"), ("tile.1", "accentNetwork", "NETWORK"),
            ("tile.2", "accentEnergy", "ENERGY"), ("tile.3", "accentGPU", "GPU 0"),
            ("tile.4", "accentNPU", "NPU 0"), ("tile.5", "accentThermal", "THERMALS"),
        ]

        // Sublayer order is z-order, and `CALayer.render(in:)` — gate 12's instrument —
        // honours only that order, not `zPosition`. So: every chrome, then the charts, then
        // every mark and label, in three passes rather than one interleaved one.
        for _ in cards {
            let chrome = CardChrome.makeCardLayer(theme: theme)
            root.addSublayer(chrome)
            cardLayers.append(chrome)
        }

        // §6.5: the charts, one container per plot rect, above the chrome and below the
        // marks. Capacities in `applyChartLayers`' order: §4.4 and §4.5 plot 600, §4.6's
        // tiles 240.
        for capacity in [600, 600, 240, 240, 240, 240, 240, 240] {
            let chart = ChartLayer(capacity: capacity)
            chart.applyTheme(theme, colors: themeStore.colors)
            root.addSublayer(chart)
            chartLayers.append(chart)
        }

        // §4.3.1 gives the meters card no title, headline or footer, so it gets no text
        // layers: a headline nothing ever writes keeps its `···` forever.
        for card in cards where card.key != "meters" {
            addText("\(card.key).title", card.title, size: 11, weight: .semibold,
                    token: "textSecondary", alignment: .left, tracking: 0.66)
            // §4.3.3: the process count is a 10 pt header-right caption, not a headline.
            let count = card.key == "processes"
            addText("\(card.key).headline", "···", size: count ? 10 : 24,
                    weight: count ? .regular : .medium,
                    token: count ? "textTertiary" : card.accent, alignment: .right,
                    monospacedDigits: true)
            addText("\(card.key).footer", "", size: 10, weight: .regular,
                    token: "textTertiary", alignment: .left)
            addText("\(card.key).unavailable", "", size: 11, weight: .regular,
                    token: "textDisabled", alignment: .center)
            addText("\(card.key).verdict", "", size: 10, weight: .semibold,
                    token: "textSecondary", alignment: .right)
        }

        // §4.3.1's four meters and their labels/captions.
        let meterSpecs: [(String, String)] = [
            (theme.accentCPU, "CPU"), (theme.accentClock, "CLOCK"),
            (theme.accentThermal, "TEMP"), (theme.accentGPU, "GPU"),
        ]
        for (index, spec) in meterSpecs.enumerated() {
            let meter = MeterLayer(geometry: .verticalMeter, accentHex: spec.0, theme: theme)
            meter.addTo(root)
            meters.append(meter)
            addText("meter.\(index).label", "—", size: 12, weight: .medium,
                    token: "textDisabled", alignment: .center, monospacedDigits: true)
            addText("meter.\(index).caption", spec.1, size: 9, weight: .regular,
                    token: "textTertiary", alignment: .center)
        }

        memoryMeter = MeterLayer(geometry: .memoryMeter, accentHex: theme.accentMemory,
                                 theme: theme)
        memoryMeter?.addTo(root)

        processRows = ProcessRowsLayer(root: root, theme: theme)

        // §4.4's left axis labels (`CardMetrics.percentGridlines` carries the rule).
        for value in CardMetrics.percentGridlines {
            addText("cpu.axis.\(Int(value))", "\(Int(value))", size: 9, weight: .regular,
                    token: "textDisabled", alignment: .right)
        }

        // §4.4's right-hand axis labels, created once and blank until the temperature series
        // is present. Driven by `string`, not `isHidden`: a `CATextLayer` created hidden and
        // later unhidden never gets its content rasterized by the offscreen render path gate
        // 12 uses, since nothing ever drives its display cycle -- `setText`'s change-driven
        // `string` update is what every other label in this view already relies on for that.
        for value in SummaryModel.cpuRightGridlines {
            addText("cpu.rightAxis.\(Int(value))", "", size: 9, weight: .regular,
                    token: "textDisabled", alignment: .right)
        }

        fpsLayer.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        fpsLayer.fontSize = 10
        fpsLayer.foregroundColor = Theme.cgColor(hex: theme.textDisabled)
        fpsLayer.alignmentMode = .right
        fpsLayer.isHidden = true
        fpsLayer.actions = ["contents": NSNull()]
        root.addSublayer(fpsLayer)
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

    private func buildPerCoreStrip(count: Int) {
        for meter in perCoreMeters {
            meter.unlit.removeFromSuperlayer()
            meter.lit.removeFromSuperlayer()
        }
        for caption in perCoreCaptions { caption.removeFromSuperlayer() }
        perCoreMeters = []
        perCoreCaptions = []
        builtCoreCount = count
        guard let root = layer, count > 0 else { return }

        let width = perCoreStripWidth(count: count)
        for _ in 0..<count {
            let meter = MeterLayer(geometry: .perCoreStrip(width: width),
                                   accentHex: theme.accentCPU, theme: theme)
            meter.addTo(root)
            meter.updateScale(window?.backingScaleFactor ?? 2)
            perCoreMeters.append(meter)

            // §4.3.2's cluster captions. P `#7A7A88`, E `#57575F` — §4.3.2 literals with no
            // §7.2 token, so they stay call-site constants naming their section.
            let caption = CATextLayer()
            caption.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            caption.fontSize = 9
            caption.alignmentMode = .center
            caption.contentsScale = window?.backingScaleFactor ?? 2
            caption.actions = ["contents": NSNull()]
            root.addSublayer(caption)
            perCoreCaptions.append(caption)
        }
    }

    private func perCoreStripWidth(count: Int) -> CGFloat {
        let (_, cpuWidth, _) = Metrics.row1Widths(contentWidth: contentWidth)
        let inner = cpuWidth - Metrics.cardPadding * 2
        guard count > 0 else { return inner }
        return (inner - CGFloat(count - 1) * 2) / CGFloat(count)
    }

    private var contentWidth: CGFloat { bounds.width - Metrics.outerPadding * 2 }

    // MARK: - Layout

    override func layout() {
        super.layout()
        layoutCards()
        registerExplanations()
        if logGeometry, !loggedGeometry, bounds.width > 1 {
            loggedGeometry = true
            let (a, b, c) = Metrics.row1Widths(contentWidth: contentWidth)
            let inWindow = convert(bounds, to: nil)
            print(String(
                format: "pane bounds=%.1fx%.1f inWindow=%.1f,%.1f content=%.1f row1=%.1f/%.1f/%.1f tiles=%.1f rows=260/150/150/150",
                bounds.width, bounds.height, inWindow.minX, inWindow.maxY, contentWidth, a, b, c,
                Metrics.tileWidth(contentWidth: contentWidth)
            ))
            fflush(stdout)
        }
    }

    /// Every card's frame in the pane's bottom-left origin space, in §4.1's order.
    func cardFrames() -> [CGRect] {
        let content = contentWidth
        let (metersW, cpuW, procW) = Metrics.row1Widths(contentWidth: content)
        let tileW = Metrics.tileWidth(contentWidth: content)
        let x0 = Metrics.outerPadding
        // Bottom-left origin: row 1 is the topmost row, so its y is the highest.
        let row4Y = Metrics.outerPadding
        let row3Y = row4Y + Metrics.tileRowHeight + Metrics.gap
        let row2Y = row3Y + Metrics.tileRowHeight + Metrics.gap
        let row1Y = row2Y + Metrics.tileRowHeight + Metrics.gap

        var frames: [CGRect] = [
            CGRect(x: x0, y: row1Y, width: metersW, height: Metrics.row1Height),
            CGRect(x: x0 + metersW + Metrics.gap, y: row1Y, width: cpuW, height: Metrics.row1Height),
            CGRect(x: x0 + metersW + cpuW + Metrics.gap * 2, y: row1Y, width: procW,
                   height: Metrics.row1Height),
            CGRect(x: x0, y: row2Y, width: content, height: Metrics.tileRowHeight),
        ]
        for index in 0..<6 {
            let row = index < 3 ? row3Y : row4Y
            let column = CGFloat(index % 3)
            frames.append(CGRect(x: x0 + column * (tileW + Metrics.gap), y: row,
                                 width: tileW, height: Metrics.tileRowHeight))
        }
        return frames
    }

    private func layoutCards() {
        guard bounds.width > 1 else { return }
        let frames = cardFrames()
        let scale = window?.backingScaleFactor ?? 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Each container is framed to its plot rect, in the pane's own bottom-left space.
        // No conversion: the view is unflipped and a layer's `geometryFlipped` is false.
        let plots = [cpuPlotRect(frames[1]), memoryPlotRect(frames[3])]
            + (0..<6).map { tilePlotRect(frames[4 + $0]) }
        for (chart, plot) in zip(chartLayers, plots) {
            chart.contentsScale = scale
            chart.frame = plot
        }
        for (index, frame) in frames.enumerated() where index < cardLayers.count {
            cardLayers[index].frame = frame
        }

        let keys = ["meters", "cpu", "processes", "memory",
                    "tile.0", "tile.1", "tile.2", "tile.3", "tile.4", "tile.5"]
        for (index, key) in keys.enumerated() where index < frames.count {
            layoutCardText(key, in: frames[index], scale: scale)
        }

        processRows?.layout(in: frames[2], scale: scale)
        layoutAxisLabels(in: frames[1], scale: scale)
        layoutMeters(in: frames[0], scale: scale)
        layoutPerCore(in: frames[1], scale: scale)
        layoutMemoryMeter(in: frames[3], scale: scale)

        // 4.2: bottom-right of the CPU Overview card's plot area, not the pane's top-right --
        // the top-right placement began overlapping the process card's title line once
        // phase-03's G6 removed the dead band above it.
        let cpuPlot = cpuPlotRect(frames[1])
        fpsLayer.contentsScale = scale
        fpsLayer.frame = CGRect(x: cpuPlot.maxX - 160 - 4, y: cpuPlot.minY + 4,
                                width: 160, height: 14)
        CATransaction.commit()

        // The paths are built in each container's own space, so a new frame is a new path.
        applyChartLayers()
    }

    /// §4.3.2: the chart fills the height remaining between the per-core strip's captions
    /// and the footer.
    func cpuPlotRect(_ cardFrame: CGRect) -> CGRect {
        let inner = cardFrame.insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let stripBottom = inner.maxY - 29 - 6 - 6 - 12
        let top = stripBottom - 6
        let bottom = inner.minY + 16
        return CGRect(x: inner.minX, y: bottom, width: inner.width,
                      height: max(top - bottom, 0))
    }

    /// §4.5: the timeline fills the width remaining to the right of the 260 pt meter,
    /// 90 pt tall.
    func memoryPlotRect(_ cardFrame: CGRect) -> CGRect {
        let inner = cardFrame.insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let meterWidth: CGFloat = 260
        let x = inner.minX + meterWidth + Metrics.gap
        return CGRect(x: x, y: inner.minY + 16, width: max(inner.maxX - x, 0), height: 90)
    }

    /// §4.6's tiles: between the headline and the footer.
    func tilePlotRect(_ cardFrame: CGRect) -> CGRect {
        let inner = cardFrame.insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let top = inner.maxY - 31
        let bottom = inner.minY + 16
        return CGRect(x: inner.minX, y: bottom, width: inner.width,
                      height: max(top - bottom, 0))
    }

    private func layoutCardText(_ key: String, in frame: CGRect, scale: CGFloat) {
        let inner = frame.insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        if let title = textLayers["\(key).title"] {
            title.contentsScale = scale
            title.frame = CGRect(x: inner.minX, y: inner.maxY - 13, width: inner.width, height: 13)
        }
        if let headline = textLayers["\(key).headline"] {
            headline.contentsScale = scale
            // §4.3.3: the process count shares the title line.
            let height: CGFloat = key == "processes" ? 13 : 29
            headline.frame = CGRect(x: inner.minX, y: inner.maxY - height,
                                    width: inner.width, height: height)
        }
        // §4.10's verdict shares the footer's line, so the footer gives up exactly the width
        // the verdict word needs and no more: a fixed reservation would truncate footers that
        // fit today (at §3.1's minimum window the Simple disks footer already fills its layer).
        let verdictWidth = verdictLayerWidth(key)
        if let footer = textLayers["\(key).footer"] {
            footer.contentsScale = scale
            footer.frame = CGRect(x: inner.minX, y: inner.minY,
                                  width: max(inner.width - verdictWidth, 0), height: 12)
        }
        if let verdict = textLayers["\(key).verdict"] {
            verdict.contentsScale = scale
            verdict.frame = CGRect(x: inner.maxX - max(verdictWidth - Metrics.verdictGap, 0),
                                   y: inner.minY,
                                   width: max(verdictWidth - Metrics.verdictGap, 0), height: 12)
        }
        if let unavailable = textLayers["\(key).unavailable"] {
            unavailable.contentsScale = scale
            unavailable.frame = CGRect(x: inner.minX, y: inner.midY - 7,
                                       width: inner.width, height: 14)
        }
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
        // §4.4's right-hand axis. Positioned whether or not it is currently hidden --
        // `isHidden` is the only thing `applyRightAxis(_:)` toggles.
        for value in SummaryModel.cpuRightGridlines {
            guard let label = textLayers["cpu.rightAxis.\(Int(value))"] else { continue }
            label.contentsScale = scale
            let y = plot.minY + plot.height * ChartAxis.celsius.normalise(value)
            label.frame = CGRect(x: plot.maxX - 22, y: y + 1, width: 22, height: 11)
        }
    }

    /// §4.3.1: four meters side by side, each with a label 8 pt below and a caption 2 pt
    /// below that.
    private func layoutMeters(in frame: CGRect, scale: CGFloat) {
        let inner = frame.insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let meterWidth: CGFloat = 22
        let spacing = (inner.width - meterWidth * 4) / 3

        let baseY = inner.minY + 30

        for (index, meter) in meters.enumerated() {
            let x = inner.minX + CGFloat(index) * (meterWidth + spacing)
            meter.updateScale(scale)
            meter.layout(origin: CGPoint(x: x, y: baseY))

            if let label = textLayers["meter.\(index).label"] {
                label.contentsScale = scale
                label.frame = CGRect(x: x - spacing / 2, y: baseY - 8 - 15,
                                     width: meterWidth + spacing, height: 15)
            }
            if let caption = textLayers["meter.\(index).caption"] {
                caption.contentsScale = scale
                caption.frame = CGRect(x: x - spacing / 2, y: baseY - 8 - 15 - 2 - 11,
                                       width: meterWidth + spacing, height: 11)
            }
        }

    }

    /// §4.3.2's strip, directly under the headline.
    private func layoutPerCore(in frame: CGRect, scale: CGFloat) {
        guard !perCoreMeters.isEmpty else { return }
        let inner = frame.insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let width = perCoreStripWidth(count: perCoreMeters.count)
        let stripY = inner.maxY - 29 - 6 - 6

        for (index, meter) in perCoreMeters.enumerated() {
            let x = inner.minX + CGFloat(index) * (width + 2)
            meter.updateScale(scale)
            meter.layout(origin: CGPoint(x: x, y: stripY))

            let caption = perCoreCaptions[index]
            caption.contentsScale = scale
            caption.frame = CGRect(x: x, y: stripY - 12, width: width, height: 11)
        }
    }

    private func layoutMemoryMeter(in frame: CGRect, scale: CGFloat) {
        guard let memoryMeter else { return }
        let inner = frame.insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        memoryMeter.updateScale(scale)
        memoryMeter.layout(origin: CGPoint(x: inner.minX, y: inner.minY + 24))
    }

    /// §4.3.2's per-core captions carry the P/E split, so they are applied with the model.
    func applyPerCoreCaptions(_ models: [MeterModel]) {
        for (index, model) in models.enumerated() where index < perCoreCaptions.count {
            let caption = perCoreCaptions[index]
            if (caption.string as? String) != model.caption { caption.string = model.caption }
            let hex = model.caption == "P" || model.caption == "F"
                ? SpecLiteralColor.clusterCaptionP : SpecLiteralColor.clusterCaptionE
            caption.foregroundColor = Theme.cgColor(hex: hex)
        }
    }

    /// A window dragged from a 2× panel to a 1× external otherwise keeps 2× text (soft) and
    /// 2× textures (half size).
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        MeterLayer.invalidateTextureCache()
        // A scale change invalidates everything: `layoutCards()` re-frames, re-scales and
        // re-applies all eight charts; there is no partial answer to it.
        needsLayout = true
    }

    // MARK: - Display link and §6.7's two numbers

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
        // The counter window has to start over with the link (`FrameRateCounter.reset()`
        // carries phase-07's reason).
        counter.reset()
        let newLink = displayLink(target: self, selector: #selector(tick))
        newLink.add(to: .main, forMode: .common)
        link = newLink
    }

    @objc private func tick() {
        // §6.6 rule 4: the plot's x-offset advances continuously between samples. Redraw
        // only when that offset crosses a whole backing pixel — a tick whose output would be
        // pixel-identical to the frame already on screen is skipped (§6.7).
        //
        // At ~478 pt of plot for 600 samples the scroll is 0.80 pt per sample. On a 2× panel
        // that is 1.6 px and this fires twice an interval; on a 1× panel it is 0.8 px and it
        // never fires at all, which is correct — between samples there is genuinely nothing
        // new to draw, and the redraw comes from `apply(_:)` when a plotted value changes.
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

        // §6.7's counter closes a whole second and prints the harness's `fps` line itself.
        guard counter.tick(window: window, logFPS: logFPS) else { return }
        if showFPSOverlay {
            fpsLayer.string = String(format: "fps %.1f · draws %.1f", counter.fps, counter.draws)
        }
    }

    private var plotWidth: Double {
        let (_, cpuW, _) = Metrics.row1Widths(contentWidth: contentWidth)
        return Double(cpuW - Metrics.cardPadding * 2)
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

    // MARK: - Charts

    /// §6.5: the eight charts, as parameters to eight `ChartLayer`s, at the current scroll
    /// offset. One transaction, actions disabled. Called when a plotted value changed
    /// (`apply(_:)`), when the scroll crossed a backing pixel (`tick()`), and on layout.
    ///
    /// §6.7's second number is counted here, where new pixels are actually produced. Counting
    /// it in `tick()` instead reported only the scroll-driven redraws and missed every
    /// data-driven one, which read as `draws 0.0` on a pane that was updating fine. §6.7's
    /// warning is about calling this number *fps* — reported as `draws` beside a
    /// separately-counted `fps`, it is the quantity §6.7 asks for.
    private func applyChartLayers() {
        guard let model, chartLayers.count == 8 else { return }
        counter.countDraw()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let cpu = chartLayers[0]
        cpu.apply(series: model.cpuOverview.series, gridlines: CardMetrics.percentGridlines, axis: .percent,
                  rightGridlines: SummaryModel.cpuRightGridlines,
                  rightAxis: model.cpuOverview.rightAxis,
                  scrollOffset: scrollOffset(for: cpu.bounds, capacity: 600))

        // §4.5's timeline. The four layers arrive already cumulative from `SummaryModel`, so
        // the layer fills the band between adjacent paths; free memory is the unfilled
        // remainder to the top of the plot by construction, not a fifth layer. Swap is the
        // fifth descriptor and is deliberately *not* stacked — §4.5 calls it an event worth
        // noticing rather than a fraction to blend in. Without an axis nothing is drawn; an
        // empty series is that, in parameters.
        let memory = chartLayers[1]
        memory.apply(series: model.memory.axis == nil ? [] : model.memory.series,
                     gridlines: [], axis: model.memory.axis ?? .percent,
                     scrollOffset: scrollOffset(for: memory.bounds, capacity: 600))

        // §4.6's six tiles through one routine. An unavailable tile has an empty `series`
        // and draws **nothing** — no gridlines, no empty plot. §4.8 says the plot area is
        // omitted entirely, and a tile with axes and no line is indistinguishable from a live
        // tile reading zero on a quiet machine, which is the confusion §4.8 exists to prevent.
        for (index, tile) in model.tiles.enumerated() where index < 6 {
            let chart = chartLayers[2 + index]
            chart.apply(series: tile.series, gridlines: [], axis: tile.axis ?? .percent,
                        scrollOffset: scrollOffset(for: chart.bounds, capacity: 240))
        }
        CATransaction.commit()
    }

    /// Gate 12 renders into a 1× context. Windowless, `layoutCards()` gives every chart layer
    /// its 2× default; a `CAShapeLayer` rasterizes straight into the context at whatever
    /// scale it carries, and phase-09's spike found that a layer rasterized at one scale and
    /// captured at another reads as a quarter-pixel phase difference along every stroke. The
    /// charts are pinned to the context's own scale here, for the offscreen check only;
    /// nothing on screen goes through this.
    func pinChartsToOffscreenScale() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for chart in chartLayers { chart.contentsScale = 1 }
        CATransaction.commit()
        applyChartLayers()
    }

    /// §6.6 rule 4: the plot's x-offset advances continuously between samples and each
    /// plotted point keeps its measured value. Interpolating the *values* would flatten the
    /// single-sample spikes the chart exists to show.
    private func scrollOffset(for plot: CGRect, capacity: Int) -> Double {
        guard let sampledAt else { return 0 }
        let fraction = Interpolation.fraction(now: ContinuousClock().now,
                                              sampledAt: sampledAt, interval: sampleInterval)
        let rect = PlotRect(x: plot.minX, y: plot.minY, width: plot.width, height: plot.height)
        return ChartSeries.sampleWidth(in: rect, capacity: capacity) * fraction
    }
}

// MARK: - Gate 12's pane arm (§5.10; plan sub-step 4.2)

extension SummaryPaneView {
    private static let selfCheckWidth = 1172
    private static let selfCheckHeight = 778

    /// Renders one fixture offscreen and returns the view (laid out), the backing context,
    /// and a pixel scanner over the result, shared by both of gate 12's fixtures. The bitmap
    /// half is `renderPaneOffscreen` (Views/PaneSelfCheck.swift), whose doc comment says why
    /// the context is part of the return value.
    private static func renderSelfCheck(
        _ frames: SummaryFrames, themeStore: ThemeStore = .shared, mode: DisplayMode = .technical
    ) -> (view: SummaryPaneView, context: CGContext, scan: PixelScan)? {
        let width = selfCheckWidth, height = selfCheckHeight
        let view = SummaryPaneView(
            frame: NSRect(x: 0, y: 0, width: width, height: height), themeStore: themeStore
        )
        var model = SummaryModel.project(frames)
        if mode == .simple { model = model.simplified(frames: frames, previous: nil).0 }
        let now = ContinuousClock().now
        // `sampledAt: nil` pins §6.6's scroll offset at 0. With a real instant the paths are
        // built `now - sampledAt` into the sample interval, which is whenever this fixture
        // happened to reach the renderer -- and phase-09's two chart paths reach it at
        // different moments, so the "fixed" fixture drifted a quarter pixel between them.
        view.apply(model, sampledAt: nil, interval: SampleRate.hz10, processSampledAt: now)
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.pinChartsToOffscreenScale()

        guard let (context, scan) = renderPaneOffscreen(view, width: width, height: height)
        else { return nil }
        return (view, context, scan)
    }

    /// Renders the whole pane offscreen over §5.10's construction — five providers live with
    /// known values, five not built — and asserts §4.8 against the **pixels**, which is the
    /// part of §5.10 no unit test reaches. Five assertions; the fifth (chart pixels inside
    /// the CPU plot) exists because every check in this project passed while every chart
    /// rendered beneath the card chrome (phase-03's gap record, G1) — §13.7.1's shape.
    ///
    /// A sixth and seventh assertion (3.3) run over a second fixture with all ten providers
    /// live: an absence-only suite passes on a blank render, so proving the right axis and
    /// the four private tiles *appear* needs its own fixture, the same reasoning phase-03
    /// applied one level down when it added assertion 3 for the CPU meter and headline.
    /// An eighth (phase-05, 4.2) re-renders with the FPS overlay on and checks the process card's
    /// title survives.
    static func paneSelfCheck() -> [PaneAssertion] {
        // `context` is never read again below, but the binding must keep its name -- never
        // `_` -- so ARC keeps it (and the bitmap `scan` points into) alive for the rest of
        // this function. See `renderSelfCheck(_:)`'s doc comment.
        guard let (view, context, scan) = renderSelfCheck(selfCheckFrames()) else {
            return [PaneAssertion(name: "render", pass: false, detail: "no bitmap")]
        }

        // Phase-09's parity instrument A: the first fixture's bitmap, dumped **here** -- before
        // assertion 8 turns the FPS overlay on and re-renders into this same context. A dump
        // taken after it carries the overlay inside the CPU plot rect the diff is computed over.
        if let path = ProcessInfo.processInfo.environment["GLOWTOP_SELFCHECK_PNG"] {
            writeSelfCheckPNG(context, to: path)
        }

        let theme = view.theme
        let cards = view.cardFrames()
        var results: [PaneAssertion] = []

        // 1 — §4.8: a not-built tile contains no pixel of its own accent. An Energy tile
        // drawing a yellow trace fails here.
        let tileAccents = [(6, theme.accentEnergy), (7, theme.accentGPU),
                           (8, theme.accentNPU), (9, theme.accentThermal)]
        let tileHits = tileAccents.map { index, accent in
            scan.hits(in: cards[index].insetBy(dx: 2, dy: 2), ofHex: accent, tolerance: 24)
        }
        results.append(PaneAssertion(
            name: "unavailable-tiles", pass: tileHits.allSatisfy { $0 == 0 },
            detail: "accent_hits=\(tileHits.map(String.init).joined(separator: "/"))"
        ))

        // 2 — §4.8: the Clock, Temp and GPU meter columns show nothing above the unlit
        // 4 % opacity. A meter whose `fraction` defaulted to 1.0 fails here.
        let inner0 = cards[0].insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let meterWidth: CGFloat = 22
        let spacing = (inner0.width - meterWidth * 4) / 3
        func meterRect(_ index: Int) -> CGRect {
            CGRect(x: inner0.minX + CGFloat(index) * (meterWidth + spacing),
                   y: inner0.minY + 30, width: meterWidth,
                   height: MeterGeometry.verticalMeter.size.height)
        }
        let meterAccents = [(1, theme.accentClock), (2, theme.accentThermal),
                            (3, theme.accentGPU)]
        let meterHits = meterAccents.map { index, accent in
            scan.hits(in: meterRect(index), ofHex: accent, tolerance: 24)
        }
        results.append(PaneAssertion(
            name: "unavailable-meters", pass: meterHits.allSatisfy { $0 == 0 },
            detail: "accent_hits=\(meterHits.map(String.init).joined(separator: "/"))"
        ))

        // 3 — the live marks are actually there. An absence-only suite passes on an
        // all-black render, which is what makes negative pixel tests worthless alone.
        let cpuMeterHits = scan.hits(in: meterRect(0), ofHex: theme.accentCPU, tolerance: 24)
        let inner1 = cards[1].insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let headlineRect = CGRect(x: inner1.minX, y: inner1.maxY - 29,
                                  width: inner1.width, height: 29)
        let headlineHits = scan.hits(in: headlineRect, ofHex: theme.accentCPU, tolerance: 24)
        results.append(PaneAssertion(
            name: "cpu-live-marks", pass: cpuMeterHits > 0 && headlineHits > 0,
            detail: "meter_hits=\(cpuMeterHits) headline_hits=\(headlineHits)"
        ))

        // 4 — §4.4: the omitted right axis leaves no textDisabled pixels along the plot's
        // right edge. (The left axis labels sit at the plot's left edge; the footer, whose
        // grey is within a stone's throw of textDisabled, is below the plot.)
        let plot = view.cpuPlotRect(cards[1])
        let rightStrip = CGRect(x: plot.maxX - 22, y: plot.minY, width: 22,
                                height: plot.height)
        let axisHits = scan.hits(in: rightStrip, ofHex: theme.textDisabled, tolerance: 12)
        results.append(PaneAssertion(
            name: "right-axis-omitted", pass: axisHits == 0, detail: "hits=\(axisHits)"
        ))

        // 5 — the chart itself has pixels inside the CPU plot (phase-03's gap record G1's
        // regression catch: charts drawn beneath the chrome leave this at zero).
        let chartHits = scan.hits(in: plot, ofHex: theme.accentCPU, tolerance: 60)
        // Phase-09's parity check A3 needs the same count for the other seven plot rects, each
        // against its own card's accent, so every rect has a before count from the before tree.
        // Diagnostic detail only -- the assertion is still the CPU plot's.
        let memoryHits = scan.hits(in: view.memoryPlotRect(cards[3]), ofHex: theme.accentMemory,
                                   tolerance: 60)
        let tileAccentHexes = [theme.accentDisk, theme.accentNetwork, theme.accentEnergy,
                               theme.accentGPU, theme.accentNPU, theme.accentThermal]
        let tilePlotHits = tileAccentHexes.enumerated().map { index, hex in
            scan.hits(in: view.tilePlotRect(cards[4 + index]), ofHex: hex, tolerance: 60)
        }
        results.append(PaneAssertion(
            name: "cpu-chart-pixels", pass: chartHits > 0,
            detail: "hits=\(chartHits) memory_hits=\(memoryHits) "
                + "tile_hits=\(tilePlotHits.map(String.init).joined(separator: "/"))"
        ))

        // 6 and 7 (3.3) — the same two rectangles (assertion 4's `rightStrip` and assertion
        // 1's four tile rects), now over the second fixture where all ten providers are
        // live, proving the right axis and the four private tiles *appear* rather than
        // merely proving they can be made to disappear.
        guard let (liveView, liveContext, liveScan) = renderSelfCheck(selfCheckFramesPrivateLive()) else {
            results.append(PaneAssertion(name: "render-private-live", pass: false, detail: "no bitmap"))
            return results
        }
        let liveCards = liveView.cardFrames()
        let livePlot = liveView.cpuPlotRect(liveCards[1])
        let liveRightStrip = CGRect(x: livePlot.maxX - 22, y: livePlot.minY, width: 22,
                                    height: livePlot.height)
        // Tolerance 48, not assertion 4's 12: a 9 pt digit has no fully-opaque interior pixel
        // at this size against `cardBackground`, so every rendered pixel is a partial
        // antialiased blend toward `textDisabled` rather than the solid colour itself.
        // Measured empirically -- 30 finds nothing here, 40 finds the first hits.
        let liveAxisHits = liveScan.hits(in: liveRightStrip, ofHex: theme.textDisabled, tolerance: 48)
        results.append(PaneAssertion(
            name: "right-axis-present", pass: liveAxisHits > 0, detail: "hits=\(liveAxisHits)"
        ))

        let liveTileAccents = [(6, theme.accentEnergy), (7, theme.accentGPU),
                               (8, theme.accentNPU), (9, theme.accentThermal)]
        let liveTileHits = liveTileAccents.map { index, accent in
            liveScan.hits(in: liveCards[index].insetBy(dx: 2, dy: 2), ofHex: accent, tolerance: 24)
        }
        results.append(PaneAssertion(
            name: "private-tiles-live", pass: liveTileHits.allSatisfy { $0 > 0 },
            detail: "accent_hits=\(liveTileHits.map(String.init).joined(separator: "/"))"
        ))

        // 8 (4.2) — the FPS overlay moved off the process card's title line and into the CPU
        // card's plot rect (phase-03's G6 regression: the top-right placement began
        // overlapping "Top CPU processes"'s title once G6 removed the dead band). Turning the
        // overlay on and re-rendering must leave the process card's own title text intact.
        view.showFPSOverlay = true
        view.layer?.render(in: context)
        let processesInner = cards[2].insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let processesTitleRect = CGRect(x: processesInner.minX, y: processesInner.maxY - 13,
                                        width: processesInner.width, height: 13)
        let processesTitleHits = scan.hits(in: processesTitleRect, ofHex: theme.textSecondary, tolerance: 48)
        results.append(PaneAssertion(
            name: "fps-overlay-title-clear", pass: processesTitleHits > 0,
            detail: "hits=\(processesTitleHits)"
        ))

        // Neither context is read again, but both must stay retained (bound to a real name,
        // not `_`) for as long as their scan is used above -- see `renderSelfCheck(_:)`.
        // 9, 10 -- §4.10 (1.2). The Temperature tile's verdict word must reach the pixels, and
        // in the pressure's own colour: a `.serious` fixture paints `statusDegraded` in that
        // tile's verdict rect. A verdict that never reached a layer, or one drawn in
        // `textSecondary` whatever the level, fails here.
        if let (hotView, hotContext, hotScan) = renderSelfCheck(
            selfCheckFramesPrivateLive(thermalPressure: .serious), mode: .simple
        ) {
            let hotCards = hotView.cardFrames()
            let inner = hotCards[9].insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
            let verdictRect = CGRect(x: inner.maxX - 120, y: inner.minY, width: 120, height: 12)
            let warned = hotScan.hits(in: verdictRect, ofHex: hotView.theme.statusDegraded, tolerance: 24)
            results.append(PaneAssertion(
                name: "simple-verdict-is-drawn-in-the-pressure-colour",
                pass: warned > 0, detail: "statusDegraded_hits=\(warned)"
            ))
            _ = hotContext
        }

        // §4.8 holds in Simple mode too: a tile that is not live carries no verdict, so the
        // four not-built tiles of the base fixture stay free of verdict pixels.
        if let (coldView, coldContext, coldScan) = renderSelfCheck(selfCheckFrames(), mode: .simple) {
            let coldCards = coldView.cardFrames()
            let hits = [6, 7, 8, 9].map { index -> Int in
                let cardInner = coldCards[index].insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
                let rect = CGRect(x: cardInner.maxX - 120, y: cardInner.minY, width: 120, height: 12)
                return coldScan.hits(in: rect, ofHex: coldView.theme.textSecondary, tolerance: 24)
            }
            results.append(PaneAssertion(
                name: "simple-unavailable-tiles-carry-no-verdict",
                pass: hits.allSatisfy { $0 == 0 },
                detail: "verdict_hits=\(hits.map(String.init).joined(separator: "/"))"
            ))
            _ = coldContext
        }

        _ = context
        _ = liveContext
        return results
    }

    /// 3.2's addition: proves `ThemeStore`'s live switch reaches rendered pixels, not just a
    /// `MeterLayer` constructed with an explicit theme (every other assertion in this file
    /// already gets that for free). Renders against an **isolated** `ThemeStore` backed by
    /// `MemoryDefaults`, so the check never touches the real, persisted `theme.presetName`
    /// the running app reads on its own next launch -- and never hands `cfprefsd` a domain to
    /// write. The previous on-disk scratch suite leaked one empty plist per run under
    /// `~/Library/Preferences/`: the daemon's write-back of the emptied domain landed after
    /// the in-process delete, a race no ordering of `synchronize()` and `removeItem` could win.
    static func themeSwitchSelfCheck() -> PaneAssertion {
        guard let scratchDefaults = MemoryDefaults(suiteName: "com.glowtop.selfcheck.theme") else {
            return PaneAssertion(name: "theme-switch", pass: false, detail: "no scratch defaults")
        }

        let store = ThemeStore(defaults: scratchDefaults)
        store.select(preset: "Classic Green")

        guard let (view, context, scan) = renderSelfCheck(selfCheckFrames(), themeStore: store) else {
            return PaneAssertion(name: "theme-switch", pass: false, detail: "no bitmap")
        }
        let cards = view.cardFrames()
        let inner0 = cards[0].insetBy(dx: Metrics.cardPadding, dy: Metrics.cardPadding)
        let meterWidth: CGFloat = 22
        let cpuMeterRect = CGRect(x: inner0.minX, y: inner0.minY + 30, width: meterWidth,
                                  height: MeterGeometry.verticalMeter.size.height)

        // The CPU meter's lit pixels must read Classic Green's accent and not the shipped
        // default's -- proving the switch reached the rendered pixel, not merely the model.
        // The comparison hex is §7.2's shipped-default `accentCPU` written literally rather
        // than through the preset constant, which this file's "one owner" grep check (3.2's
        // Expected block) bans outside `ThemeStore.swift`.
        let classicGreenHits = scan.hits(in: cpuMeterRect, ofHex: Theme.classicGreen.accentCPU, tolerance: 24)
        let neonHits = scan.hits(in: cpuMeterRect, ofHex: "#39FF14", tolerance: 24)
        _ = context
        return PaneAssertion(
            name: "theme-switch",
            pass: classicGreenHits > 0 && neonHits == 0,
            detail: "switch=classicGreen accent_hits=\(classicGreenHits)/\(neonHits)"
        )
    }
}

/// ponytail: dictionary-backed `UserDefaults` for the theme self-check. Overrides exactly the
/// six methods `ThemeStore` calls, so no read or write ever reaches `cfprefsd` and there is no
/// plist to leak. The suite name only names the fallback domain for a method this does not
/// override -- a fixed, visible one, never the app's own.
private final class MemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { storage[key] }
    override func string(forKey key: String) -> String? { storage[key] as? String }
    override func data(forKey key: String) -> Data? { storage[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { storage[key] = value }
    override func set(_ value: Int, forKey key: String) { storage[key] = value }
    override func removeObject(forKey key: String) { storage[key] = nil }
}
