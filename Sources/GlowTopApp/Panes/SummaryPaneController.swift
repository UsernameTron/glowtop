import AppKit
import GlowTopCore

/// Hosts the Summary pane and drives it from the store.
///
/// SwiftUI is **not** in the sample path: this Task polls the actor and writes layer
/// properties directly, so a new sample never invalidates a view and never re-evaluates the
/// view graph. This is the shape §13.1.6 measured from a 2.71 % floor to 1.07 %.
///
/// Summary's *providers* are exempt from §3.3's suspension — this controller never asks the
/// store to stop anything, and that exemption is why §4.7's status bar keeps a live reading
/// from every pane. Its own projection loop is **not** exempt: hidden or occluded it drops to
/// 1 Hz and skips the view writes, and the three hooks below are how it learns which.
@MainActor
final class SummaryPaneController: NSViewController, PaneController {
    private let store: MetricStore
    private let state: AppState
    private var task: Task<Void, Never>?
    private var paneView: SummaryPaneView!

    /// §3.3. Whether this pane is the one installed in `PaneHostView`. Written by the host's
    /// visibility hooks. Since phase-08 the host releases a switched-away Summary instead of
    /// retaining it, so in steady state `paneView.isOccluded` is the gate that fires; this one
    /// only bridges the ticks between `show`/resign and deallocation.
    private var isVisible = false

    init(store: MetricStore, state: AppState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// §6.2. `PaneHostView` owns the observer — it always has a window, and this view does not
    /// once another pane is installed. `isOccluded`'s `didSet` pauses the display link.
    func paneDidChangeOcclusion(_ occluded: Bool) {
        paneView?.isOccluded = occluded
    }

    // §3.3. Declared in the type body, not an extension: an extension method would not
    // satisfy the protocol witness through `any PaneController`, the default no-op would win,
    // and this pane would believe itself permanently hidden — one frame, then frozen.
    func paneDidBecomeVisible() { isVisible = true }
    func paneDidResignVisible() { isVisible = false }

    /// Only Summary has a fixed-height pane (§8.1's table and §9.1's list scroll themselves),
    /// so the `ScrollView` wrapper phase-03 put in `ShellView` lives here and nowhere else.
    override func loadView() {
        let paneView = SummaryPaneView(frame: .zero)
        self.paneView = paneView
        view = Self.makeScrollView(hosting: paneView)
    }

    /// The scroll view `loadView()` installs, as a factory so gate 12 can lay it out at a
    /// taller-than-content size without starting a sample loop (1.1.3).
    static func makeScrollView(hosting paneView: SummaryPaneView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        // An `NSClipView` reports its document view's flippedness, and `SummaryPaneView` is
        // unflipped (its layers are laid out bottom-left), so the stock clip view parked a
        // shorter-than-viewport pane at the BOTTOM and opened a taller-than-viewport one
        // scrolled to its bottom. A flipped clip view pins it to the top in both cases; the
        // pane's own coordinate system is untouched (1.1.3).
        let clipView = TopPinnedClipView()
        clipView.drawsBackground = false
        scrollView.contentView = clipView

        paneView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = paneView
        NSLayoutConstraint.activate([
            paneView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            paneView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            paneView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            paneView.heightAnchor.constraint(equalToConstant: SummaryPaneView.Metrics.paneHeight),
        ])
        return scrollView
    }

    /// Gate 12 (1.1.3): in a window taller than the pane, the content must sit at the TOP of
    /// the detail area. Until 1.1.3 it sat at the bottom with a dead band above it, because an
    /// `NSClipView` takes its flippedness from its document view and this pane's is unflipped.
    static func paneSelfCheck() -> [PaneAssertion] {
        let paneView = SummaryPaneView(frame: .zero)
        let scrollView = makeScrollView(hosting: paneView)
        let tall = SummaryPaneView.Metrics.paneHeight + 300
        scrollView.frame = CGRect(x: 0, y: 0, width: 1172, height: tall)
        scrollView.layoutSubtreeIfNeeded()
        scrollView.tile()
        let inScroll = paneView.convert(paneView.bounds, to: scrollView)
        let gapAbove = scrollView.isFlipped ? inScroll.minY : scrollView.bounds.height - inScroll.maxY
        return [PaneAssertion(
            name: "summary-content-pins-to-the-top-of-a-taller-window",
            pass: abs(gapAbove) < 1,
            detail: String(format: "gapAbove=%.1f paneHeight=%.0f viewport=%.0f", gapAbove, inScroll.height, tall)
        )]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        start()
    }

    private func start() {
        guard task == nil else { return }
        let store = store
        let state = state
        let paneView = paneView!

        paneView.onKey = { [weak paneView] action in
            switch action {
            case .pause:
                state.paused.toggle()
                paneView?.isPaused = state.paused
                let paused = state.paused
                Task {
                    if paused { await store.pause() } else { await store.resume() }
                }
            case .forceSample:
                Task { await store.forceSample() }
            case .toggleFPS:
                state.showFPSOverlay.toggle()
                paneView?.showFPSOverlay = state.showFPSOverlay
            }
        }

        task = Task { [weak paneView] in
            var tick = 0
            // §4.10: the last projection's verdicts, handed back so the rules' deadband has
            // something to hold on to. Dropped whenever the mode is Technical.
            var verdicts: SummaryVerdicts?
            while !Task.isCancelled {
                // 100 ms always, with a divisor when hidden — never a longer sleep. The loop
                // reads its state *before* it sleeps, so a 1 s sleep would leave the pane
                // frozen for up to a second after it is shown or uncovered;
                // `MetricStore.samplingDivisor`'s comment rejects the same shape for the same
                // reason, and the line this replaces had exactly that bug.
                try? await Task.sleep(for: .milliseconds(100))
                guard let paneView else { return }
                tick += 1

                // §3.3 / §6.2. Hidden or occluded, nine ticks in ten do nothing.
                let hidden = !isVisible || paneView.isOccluded
                if hidden && tick % 10 != 0 { continue }

                // One hop. Five separate frame accessors would be 50 actor entries a
                // second where one does, and the cost lands on gate 9 where it is
                // indistinguishable from drawing cost.
                let frames = await store.summaryFrames()
                var model = SummaryModel.project(frames, paused: state.paused)
                if state.displayMode == .simple {
                    (model, verdicts) = model.simplified(frames: frames, previous: verdicts)
                } else {
                    verdicts = nil
                }

                // §3.3: projecting is cheap and §4.7's status bar needs it from every pane, so
                // it stays unconditional. Writing layers to a view with no window is the waste
                // (M01 audit, integration seam 2) and that is what this gate removes.
                if isVisible {
                    paneView.apply(model, sampledAt: frames.cpu.sampledAt,
                                    interval: frames.cpu.interval,
                                    processSampledAt: frames.processes.sampledAt)
                    paneView.applyPerCoreCaptions(model.perCore)

                    // ponytail: `updateNSView` is one line now (§3.3's pane-host factory), so
                    // it no longer re-pushes `state.showFPSOverlay` into the view on every
                    // SwiftUI render the way `SummaryPaneHost` did. Polled here instead, on
                    // the loop this pane already runs — a Commands-menu toggle lands within
                    // one tick.
                    paneView.showFPSOverlay = state.showFPSOverlay
                }

                // §6.5 and §6.9: nothing SwiftUI observes updates faster than 1 Hz. Ticks 10,
                // 20, … in every state, so §4.7's clock and health phrase stay at 1 Hz on the
                // panes where they are actually on screen.
                if tick % 10 == 0 {
                    state.statusLeading = model.status.leading
                    state.statusPhraseToken = model.status.phraseToken
                    state.statusTooltip = model.status.tooltip
                    state.clock = Self.clockText()
                    // §9.2. Republished every second while Summary is installed. When the host
                    // releases this controller the last value stays put and its own timestamp
                    // makes the age climb, which is what System Info's row is meant to show.
                    state.summaryFrameRate = paneView.frameRate
                }
            }
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func clockText() -> String { clockFormatter.string(from: Date()) }

    deinit {
        task?.cancel()
    }
}

/// See `SummaryPaneController.makeScrollView(hosting:)`.
private final class TopPinnedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
