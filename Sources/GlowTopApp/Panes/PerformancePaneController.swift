import AppKit
import GlowTopCore

/// Hosts §14.10's Performance pane and drives it from the store.
///
/// Mirrors `SummaryPaneController` — the same 100 ms loop, the same one-hop
/// `summaryFrames()`, the same `isVisible` gate on layer writes — and differs in four
/// deliberate ways: the view is installed directly (the pane fills, it does not scroll —
/// §14.10, D-04); the projection is `PerformanceModel.project`; it writes nothing SwiftUI
/// observes (§4.7's status bar stays Summary's, like every other non-Summary pane); and
/// ⇧⌘F is ignored because this pane has no FPS overlay.
///
/// It asks the store to sample nothing of its own: §3.3 exempts Summary's providers from
/// suspension, and every number this pane draws comes from those providers.
@MainActor
final class PerformancePaneController: NSViewController, PaneController {
    private let store: MetricStore
    private let state: AppState
    private var task: Task<Void, Never>?
    private var paneView: PerformancePaneView!

    /// §3.3. Whether this pane is the one installed in `PaneHostView`. Written by the host's
    /// visibility hooks; `paneView.isOccluded` is the gate that fires in steady state.
    private var isVisible = false

    init(store: MetricStore, state: AppState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// §6.2. `isOccluded`'s `didSet` pauses the pane's display link.
    func paneDidChangeOcclusion(_ occluded: Bool) {
        paneView?.isOccluded = occluded
    }

    // §3.3. Declared in the type body, not an extension — an extension method would not
    // satisfy the protocol witness through `any PaneController` and the default no-op would
    // win (`SummaryPaneController`'s own comment records the failure: one frame, then frozen).
    func paneDidBecomeVisible() { isVisible = true }
    func paneDidResignVisible() { isVisible = false }

    /// No `NSScrollView`: §14.10 says the pane fills the detail area and does not scroll, so
    /// the host's four edge constraints size the view directly.
    override func loadView() {
        let paneView = PerformancePaneView(frame: .zero)
        paneView.translatesAutoresizingMaskIntoConstraints = true
        self.paneView = paneView
        view = paneView
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

        // §3.5's Space and ⌘R are global, not Summary's; ⇧⌘F is not handled here because
        // this pane draws no overlay (§6.7's counter still prints to stdout).
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
            }
        }

        task = Task { [weak paneView] in
            var tick = 0
            while !Task.isCancelled {
                // 100 ms always, with a divisor when hidden — never a longer sleep
                // (`SummaryPaneController`'s reason).
                try? await Task.sleep(for: .milliseconds(100))
                guard let paneView else { return }
                tick += 1

                // §3.3 / §6.2. Hidden or occluded, nine ticks in ten do nothing.
                let hidden = !isVisible || paneView.isOccluded
                if hidden && tick % 10 != 0 { continue }

                // One hop, the same one Summary takes.
                let frames = await store.summaryFrames()
                let model = PerformanceModel.project(frames, paused: state.paused, mode: state.displayMode)

                if isVisible {
                    paneView.apply(model, sampledAt: frames.cpu.sampledAt,
                                   interval: frames.cpu.interval)
                }
            }
        }
    }

    deinit {
        task?.cancel()
    }
}
