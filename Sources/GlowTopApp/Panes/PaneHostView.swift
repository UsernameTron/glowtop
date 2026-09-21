import AppKit
import GlowTopCore

/// SPEC.md §3.3's container: constructs a pane on selection, releases the outgoing
/// controller when the selection changes (phase-08's RSS lever, §13.1.12), swaps which child
/// is installed, and calls the three visibility hooks. `show(_:)` is the **only** place a visibility hook is called and the only
/// place the store learns which pane is active — a second mechanism for one guarantee is a
/// second place for it to be wrong, the shape `MetricStore.pause()` already rejected in
/// phase-03.
///
/// It is also the one place the store is started (§6.3) and the one place it is told about
/// occlusion (§6.2). Both lived in `SummaryPaneController` until phase-06, and both were wrong
/// there for the same reason: a pane that has been switched away from has no window, so the
/// occlusion observer's guard could never pass and the store never dropped to 1 Hz behind a
/// minimized window unless Summary happened to be visible. Measured at 14.55 % of one core on
/// the Processes pane, against Summary-minimized's 2.40 % (M01 audit; phase-06's before-reading).
/// This view always has the window.
@MainActor
final class PaneHostView: NSView {
    private let store: MetricStore
    private let state: AppState
    private var controllers: [PaneID: any PaneController] = [:]
    private var current: PaneID?

    /// §6.2. Tracked from notifications only — never read from `occlusionState` directly; see
    /// `occlusionChanged(_:)`.
    private var isOccluded = false

    init(store: MetricStore, state: AppState) {
        self.store = store
        self.state = state
        super.init(frame: .zero)

        // §6.2. Only the notification is acted on; the initial state is never read.
        //
        // A window that has not been composited yet reports itself occluded, and acting on
        // that reading drops sampling to 1 Hz before §3.6's 400 ms first value lands. The
        // link then resumes on the first real notification a second later, so the only
        // symptom is a missed launch deadline that nothing measures.
        //
        // Target/selector rather than the block form: a block observer hands back a token
        // that has to be released in `deinit`, and a `deinit` on a `@MainActor` class cannot
        // touch a non-`Sendable` token under strict concurrency. The runtime clears a
        // target-based observer itself.
        //
        // `object: nil` and filter in the handler, not `object: window`: this view has no
        // window at `init`, so registering against one would pin `nil` forever and observe
        // nothing — green build, green tests, inert mechanism.
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: nil
        )

        // §6.3. The store runs for the app's lifetime and is started by the one object that
        // owns it — not as a side effect of `SummaryPaneController` being constructed, which
        // held only because `.summary` is the launch default. `start()` is idempotent.
        Task { await store.start() }

        // D-18's sampler-jitter instrument. A peer of GLOWTOP_LOG_GEOM/PROCROWS/COVER/MINIMIZE:
        // off unless its variable is set, never on in the harness, and it touches none of the
        // store's four loops -- it reads the public `cpuFrame()` accessor and prints one line per
        // observed change of `sampledAt`. Its own 500 Hz actor reads cost the same in both arms
        // of the A/B, which is why the arms are interleaved rather than compared to an absolute.
        if ProcessInfo.processInfo.environment["GLOWTOP_LOG_SAMPLE_CADENCE"] != nil {
            Task.detached(priority: .utility) { [store] in
                var last: ContinuousClock.Instant?
                while !Task.isCancelled {
                    if let now = await store.cpuFrame().sampledAt, now != last {
                        if let previous = last {
                            let ms = Double(previous.duration(to: now).components.attoseconds) / 1e15
                                + Double(previous.duration(to: now).components.seconds) * 1000
                            print(String(format: "samplecadence delta_ms=%.2f", ms)); fflush(stdout)
                        }
                        last = now
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// Waves 2-4 replace each non-Summary case as that pane's controller lands (2.3, 3.2,
    /// 4.1, 4.2, 4.3 each modify this factory). Until then, switching to one of those five
    /// panes constructs a real, correctly-retained controller with an empty view rather than
    /// hitting a missing switch case.
    private func make(_ pane: PaneID) -> any PaneController {
        switch pane {
        case .summary:
            return SummaryPaneController(store: store, state: state)
        case .performance:
            return PerformancePaneController(store: store, state: state)
        case .processes:
            return ProcessesPaneController(store: store, state: state)
        case .systemInfo:
            return SystemInfoPaneController(store: store, state: state)
        case .startupApps:
            return StartupAppsPaneController()
        case .users:
            return UsersPaneController()
        case .services:
            return ServicesPaneController(store: store, appState: state)
        case .power:
            return PowerFreqPaneController(store: store, state: state)
        case .colors:
            return ColorsPaneController()
        case .connections:
            return ConnectionsPaneController(store: store, state: state)
        case .installedApps:
            return InstalledAppsPaneController()
        case .diskSpace:
            return DiskSpacePaneController(state: state)
        }
    }

    func show(_ pane: PaneID) {
        guard pane != current else { return }

        let outgoing = current.flatMap { controllers[$0] }
        outgoing?.paneDidResignVisible()

        let incoming: any PaneController
        if let existing = controllers[pane] {
            incoming = existing
        } else {
            let built = make(pane)
            controllers[pane] = built
            incoming = built
        }

        outgoing?.view.removeFromSuperview()

        // Phase-08 lever 1 (2.1). §3.3 retained every controller for the app's lifetime; this
        // releases the outgoing one instead, and the pane is rebuilt on next selection.
        //
        // `removeFromSuperview()` above already frees the pane's *backing stores* — phase-08
        // measured `CoreAnimation` carrying only 21.00 MB of the walk's cost. What retention
        // holds is the *view hierarchy and its Auto Layout constraint graph*: a live-heap census
        // after visiting all seven panes reads 558,375 nodes / 69.5 MB against 108,111 / 20.4 MB
        // for Summary alone, and the classes are `_NSViewLayoutAux`, ~44,000 CoreAutoLayout
        // objects, `NSTextField`/`NSTableCellView` and 32.3 MB of small `non-object` blocks.
        //
        // §3.3's stated reason for retention is that switching back "is instant and does not
        // re-warm a provider's delta baseline (§5.0.3)". The second half is not served by this
        // dictionary: delta baselines live inside `MetricStore`, an actor owned by the app, and
        // no pane controller holds one — `ProcessesPaneController.lastSample` and
        // `ServicesPaneController.allRows` are caches of store *output*. Releasing a controller
        // cannot re-warm a baseline it never had. What is traded is the first half only.
        if let previous = current, previous != pane {
            controllers[previous] = nil
        }

        let childView = incoming.view
        childView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(childView)
        NSLayoutConstraint.activate([
            childView.topAnchor.constraint(equalTo: topAnchor),
            childView.bottomAnchor.constraint(equalTo: bottomAnchor),
            childView.leadingAnchor.constraint(equalTo: leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        incoming.paneDidBecomeVisible()
        // The host's tracked state, not a fresh read of `occlusionState`. Without this,
        // minimizing on one pane and switching to another hands the new pane a stale `false`,
        // which is the seam this phase closes, rebuilt through the door it just opened.
        incoming.paneDidChangeOcclusion(isOccluded)
        current = pane
        // Phase-10: which pane a measurement round actually ran. Matches neither pattern
        // `scripts/overhead-harness.sh` parses (`^fps` and `window on screen`), so it is
        // invisible to the instrument and greppable by the reader.
        print("pane: \(pane.rawValue)")
        fflush(stdout)

        Task { await store.setActivePane(pane) }
    }

    /// Window notifications are posted on the main thread, which is this class's actor.
    @objc private func occlusionChanged(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == self.window else { return }
        isOccluded = !window.occlusionState.contains(.visible)
        Task { await store.setOccluded(isOccluded) }
        current.flatMap { controllers[$0] }?.paneDidChangeOcclusion(isOccluded)
    }
}

