import AppKit
import GlowTopCore

/// SPEC.md §9's System Info pane. §9.3's cadence, implemented literally: static rows are read
/// once on first visibility and again on wake from sleep; live rows are read at 1 Hz, and
/// only while this pane is visible (§3.3's locked "sample only while visible" decision).
///
/// `SystemInfoReader` does every formatting decision; this file only starts/stops the timer,
/// fetches the two live inputs the reader needs from the store, and hands the result to
/// `InfoListController` to draw (§7.1's boundary).
@MainActor
final class SystemInfoPaneController: NSViewController, PaneController {
    private let store: MetricStore
    private let state: AppState
    private let scrollView = NSScrollView()
    private let listView = InfoListController(frame: .zero)

    private var reader = SystemInfoReader()
    private var staticRows: SystemInfo.StaticRows?
    private var liveRows: SystemInfo.Live?
    private var liveTimer: Timer?

    init(store: MetricStore, state: AppState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        listView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = listView
        NSLayoutConstraint.activate([
            listView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            listView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Observed for the controller's whole lifetime, not just while visible: a machine
        // that sleeps while another pane is on screen must not show pre-sleep values when
        // the user comes back here (§9.3, and this sub-step's own recorded failure shape).
        NotificationCenter.default.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        // §7.3's live theme edits. `InfoListController.render(cards:)` tears down and rebuilds
        // every card, and each reads `ThemeStore.shared.theme` fresh, so re-rendering *is* the
        // full repaint — which is why this is one observer and not a recolour pass. Every other
        // pane already has it; this one was missed.
        NotificationCenter.default.addObserver(
            self, selector: #selector(render), name: ThemeStore.didChange, object: nil
        )
    }

    // MARK: - §3.3's visibility hooks

    func paneDidBecomeVisible() {
        if staticRows == nil {
            refreshStatic()
        }
        startLiveTimer()
    }

    func paneDidResignVisible() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    @objc private func didWake() {
        refreshStatic()
    }

    private func refreshStatic() {
        staticRows = SystemInfoReader.staticRows()
        render()
    }

    // MARK: - §9.3's 1 Hz live rows

    private func startLiveTimer() {
        guard liveTimer == nil else { return }
        refreshLive()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
    }

    private func refreshLive() {
        Task { [weak self] in
            guard let self else { return }
            let memoryFrame = await self.store.memoryFrame()
            let health = await self.store.health()
            // Memory is passed through even while it is still warming: the three memory rows
            // then read `—` and every other row renders, rather than the pane showing nothing
            // at all because one of its inputs is not ready yet.
            let live = self.reader.liveRows(memory: memoryFrame.current, health: health,
                                            frameRate: self.state.summaryFrameRate)
            self.liveRows = live
            self.render()
        }
    }

    // MARK: - §9.1's four cards

    @objc private func render() {
        guard let staticRows else { return }
        // §9.2 lists Uptime inside the Software card even though it is a live row; spliced
        // in at its spec-given position (macOS version, Build, Kernel, **Uptime**, Boot
        // volume, Computer name) rather than carried as a sixth static row that never updates.
        var software = staticRows.software
        software.insert(liveRows?.uptime ?? SystemInfo.Row(label: "Uptime", value: Format.unknown, isMonospaced: true), at: 3)

        listView.render(cards: [
            (title: "Hardware", rows: staticRows.hardware),
            (title: "Software", rows: software),
            (title: "Memory and storage", rows: liveRows?.memoryAndStorage ?? []),
            (title: "GlowTop", rows: liveRows?.glowTop ?? []),
        ])
    }
}
