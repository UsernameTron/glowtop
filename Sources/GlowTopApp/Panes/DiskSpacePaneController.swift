import AppKit
import GlowTopCore
import QuartzCore

/// SPEC.md §14.6's pane (4.1's shell). The **reader-pane idiom** (`InstalledAppsPaneController`'s
/// shape) -- a `KeyCommandView` root, `NSTextField` labels, a `ThemeStore.didChange` observer --
/// per the UI-SPEC's own resolution of the one architectural question CONTEXT left implicit: the
/// Storage card needs `NSPathControl`/`NSProgressIndicator`/`NSButton`, controls a pure `CALayer`
/// scene cannot host.
///
/// Pane-owned (D-08): this initializer takes no metrics-sampling actor at all -- neither half of
/// §14.6's reader (the one-shot volume read, the detached directory walk) samples on its loops.
/// The volume bars draw from `DiskSpaceReader.volumes()` on first visibility (D-08's one-shot).
/// The treemap canvas is wired for real in this sub-step (4.3): `enter(_:)` is both "cancel
/// whatever is running" and "start the next walk" -- descend, ascend and a breadcrumb click are
/// the same operation, because every transition re-walks (D-09, no retained ancestor level).
@MainActor
final class DiskSpacePaneController: NSViewController, PaneController {
    private let state: AppState

    // MARK: - The scan (D-17), the current level, and D-09's "no retained ancestor" state

    private var scanTask: Task<Void, Never>?
    /// Read from the detached scan's background thread inside `isCancelled`
    /// (`InstalledAppsPaneController`'s own reason: it cannot be `@MainActor`-isolated).
    nonisolated(unsafe) private var cancelled = false
    private var root: URL?
    /// The volume the bar shows -- §14.6's "direct pick": clicking the bar makes it the root.
    private var shownVolume: VolumeInfo?
    private var volumesCardView = NSView()
    /// The authoritative result of the level currently on screen -- `nil` while a walk is still
    /// in flight (the canvas draws from `finishedChildren` instead, D-17's incremental promise).
    private var level: LevelResult?
    /// Accumulated one child at a time from `progress`, so a rectangle appears the moment its
    /// size lands (§14.6) -- discarded and rebuilt on every `enter(_:)` (D-09).
    private var finishedChildren: [DirectoryChild] = []
    /// Incremented on every `enter(_:)` -- the only thing guaranteed to change even when the
    /// same directory is re-entered twice in a row (⌘D's own overload), which a `URL`
    /// comparison alone cannot tell apart from the walk it superseded.
    private var scanGeneration = 0

    // MARK: - Volumes card

    private let volumesTitleLabel = NSTextField(labelWithString: "VOLUMES")
    private let volumeNameLabel = NSTextField(labelWithString: "")
    private let volumeNumbersLabel = NSTextField(labelWithString: "")
    /// The volume capacity bar's own `CALayer` -- `MeterLayer` reused unmodified per the
    /// discretion table's own instruction (D-07's continuous crop).
    private let volumeMeterView = VolumeMeterView(
        accentHex: ThemeStore.shared.theme.accentDisk, theme: ThemeStore.shared.theme)
    private let volumeClauseLabel = NSTextField(labelWithString: "")

    // MARK: - Storage card

    private let breadcrumb = NSPathControl()
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    /// The `TreemapLayer` canvas -- a hard-coded fixture level in this sub-step; 4.3 wires the
    /// real scan and removes it.
    private let canvasView = TreemapCanvasView(theme: ThemeStore.shared.theme)
    /// D-23's "no root chosen" / "root unavailable" bodies -- centred over the canvas, which
    /// hides while this shows (States: only one of the two occupies that space at a time).
    private let bodyLabel = NSTextField(labelWithString: "")
    private let readoutLabel = NSTextField(labelWithString: "")
    private let disclosureLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")

    private var cardContainers: [NSView] = []

    private var theme: Theme { ThemeStore.shared.theme }

    init(state: AppState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - §3.3's visibility hooks (declared in the type body, not an extension -- F-13).

    /// D-08's one-shot volume read, taken on first visibility -- never a `MetricStore` slot.
    /// **No walk starts here** (D-10): the pane opens on the volume bars, "no root chosen,"
    /// and waits for ⌘D's second press or a direct pick.
    func paneDidBecomeVisible() {
        applyVolumes(DiskSpaceReader.volumes())
        updateStorageState()
        view.window?.makeFirstResponder(canvasView)
    }

    /// The load-bearing cancel (F-6): this fires deterministically, before the controller is
    /// released, while `deinit` waits on ARC. `deinit` below is the backstop, not the primary.
    func paneDidResignVisible() {
        cancelled = true
        scanTask?.cancel()
    }
    func paneDidChangeOcclusion(_ occluded: Bool) {}

    /// `readable == false` never reaches this pane as a `VolumeInfo` at all -- the volumes list
    /// is either the boot volume or empty (D-23's "Volumes, empty", not reachable on a booted
    /// Mac). An empty result leaves the row blank rather than crash on `.first`.
    private func applyVolumes(_ volumes: [VolumeInfo]) {
        shownVolume = volumes.first
        guard let volume = volumes.first else {
            volumeNameLabel.stringValue = ""
            volumeNumbersLabel.stringValue = ""
            volumeMeterView.set(fraction: nil, state: .unavailable(reason: "No browsable volumes"))
            volumeClauseLabel.isHidden = true
            return
        }
        volumeNameLabel.stringValue = volume.name
        volumeNumbersLabel.stringValue = DiskSpaceModel.volumeRowText(volume)
        let fraction = volume.capacityBytes > 0
            ? Double(volume.usedBytes) / Double(volume.capacityBytes) : 0
        volumeMeterView.set(fraction: fraction, state: .live)
        if let clause = DiskSpaceModel.purgeableClause(volume) {
            volumeClauseLabel.stringValue = clause
            volumeClauseLabel.isHidden = false
        } else {
            volumeClauseLabel.isHidden = true
        }
    }

    /// §14.6's direct pick (1.1.3).
    /// The body text has always read "Select a volume or press ⌘D again…", and until 1.1.3 the
    /// first half was a promise nothing kept: `enter(_:)` was reachable only from ⌘D's second
    /// press and from navigation inside an existing walk. A whole-volume walk is the expensive
    /// one (§14.6's cost note), which is why `enter(_:)`'s pre-scan line names it before it runs
    /// and `Stop` is on screen throughout.
    @objc private func volumeBarClicked() {
        guard let volume = shownVolume else { return }
        enter(URL(fileURLWithPath: volume.path))
    }

    // MARK: - D-09/D-13/D-17: the scan and every navigation transition

    /// Every transition re-walks (UI-SPEC's locked value): descend, ascend and a breadcrumb
    /// click are the same operation, because D-09 retains only the current level's totals, not
    /// a stack of ancestors. This is both "cancel whatever is running" and "start the next
    /// walk" -- `InstalledAppsPaneController.startScan()`'s shape, with the level semantics
    /// folded in.
    private func enter(_ url: URL) {
        scanTask?.cancel(); cancelled = true
        cancelled = false
        // A URL is not enough to tell two scans apart: re-entering the *same* directory twice
        // in quick succession (⌘D's own overload, pressed twice) gives both calls an identical
        // `url`, so a stale first task's late callbacks would still pass a `url == root` check
        // and double every child into `finishedChildren` (caught live -- the treemap drew each
        // directory twice). A monotonic generation is the only thing that actually changes on
        // every `enter(_:)`, same-URL re-entry included.
        scanGeneration += 1
        let generation = scanGeneration
        root = url
        level = nil
        finishedChildren = []
        breadcrumb.url = url
        canvasView.set(children: [], resetSelection: true)
        showPreScanAnnouncement(for: url)
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let result = DiskSpaceReader.children(
                of: url,
                progress: { done, total, child in
                    Task { @MainActor in self?.appendFinished(child, done: done, total: total, generation: generation) }
                },
                // `Task.isCancelled` is what makes `scanTask?.cancel()` real. `enter(_:)` sets
                // `cancelled` and clears it on the next line, so a superseded walk never saw the
                // flag and ran to completion behind the new one -- cheap for a home folder,
                // minutes of disk reads once 1.1.3 made a whole volume one click away. The reader
                // runs synchronously on this detached task, so the task's own cancellation is
                // visible here; the flag still serves `Stop` and leaving the pane.
                isCancelled: { [weak self] in Task.isCancelled || (self?.cancelled ?? true) }
            )
            // D-18's teardown proof (5.2): unconditional, `pane:`'s idiom, and -- unlike a print
            // inside `handle(_:generation:)` below -- NOT gated on `self` still being alive. The
            // scenario this proves (a pane switched away mid-walk) is exactly the scenario in
            // which `self` may already be nil by the time the walk notices cancellation, so the
            // marker has to live in this closure's own un-weak-captured scope.
            if result.cancelled {
                print("diskspace: scan cancelled at \(result.sizedCount) of \(result.totalCount)")
                fflush(stdout)
            }
            await MainActor.run { [weak self] in self?.handle(result, generation: generation) }
        }
        updateStorageState()
    }

    /// "Says what it is about to do before it does it" (§14.6): a cheap, non-recursive listing
    /// of `url` itself gives the count without doing any of the expensive recursive sizing --
    /// that only starts once `scanTask` above is assigned.
    private func showPreScanAnnouncement(for url: URL) {
        let total = (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0
        let rootLabel = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        progressLabel.stringValue = DiskSpaceModel.preScanAnnouncement(count: total, rootLabel: rootLabel)
        progressIndicator.maxValue = Double(max(total, 1))
        progressIndicator.doubleValue = 0
    }

    /// One child, the moment its size lands (§14.6) -- `generation` pins this callback to the
    /// walk that produced it, so a superseded scan's late-arriving progress (including one
    /// re-entering the very same directory) is discarded rather than mixed into the level now
    /// on screen.
    private func appendFinished(_ child: DirectoryChild, done: Int, total: Int, generation: Int) {
        guard generation == scanGeneration, let root else { return }
        finishedChildren.append(child)
        progressIndicator.maxValue = Double(max(total, 1))
        progressIndicator.doubleValue = Double(done)
        progressLabel.stringValue = DiskSpaceModel.progressText(done: done, total: total, name: child.name)
        let partial = LevelResult(
            rootPath: root.path, children: finishedChildren, sizedCount: finishedChildren.count,
            totalCount: total, cancelled: false, rootUnavailableReason: nil,
            millisecondsElapsed: 0, unreadableCount: 0
        )
        canvasView.set(children: DiskSpaceModel.project(partial), resetSelection: false)
        updateReadoutAndDisclosure()
    }

    /// The finished (or cancelled) walk's authoritative result -- same staleness guard as
    /// `appendFinished` above.
    private func handle(_ result: LevelResult, generation: Int) {
        guard generation == scanGeneration else { return }
        level = result
        scanTask = nil
        canvasView.set(children: DiskSpaceModel.project(result), resetSelection: false)
        updateStorageState()
    }

    @objc private func stopButtonClicked() {
        cancelled = true
    }

    @objc private func breadcrumbClicked(_ sender: NSPathControl) {
        guard let url = sender.clickedPathItem?.url else { return }
        enter(url)
    }

    private func descendIntoSelection() {
        guard let child = directoryChild(for: canvasView.selectedCell),
              child.readable, child.isDirectory, !child.path.isEmpty
        else { return }
        enter(URL(fileURLWithPath: child.path))
    }

    /// Stops at `/` (`deletingLastPathComponent()` is a no-op there) -- D-13's own wording.
    private func ascend() {
        guard let root else { return }
        let parent = root.deletingLastPathComponent()
        guard parent.path != root.path else { return }
        enter(parent)
    }

    /// Maps a drawn cell back to the reader's own `DirectoryChild` by name -- unique within
    /// one directory listing. The aggregate cell (`aggregatedCount > 0`) has no backing child
    /// at all (`TreemapLayout` synthesises it); this builds one for display only -- entries
    /// stands in for the count of items folded into it, apparent stays unknown since the
    /// model never sums it for the aggregate.
    private func directoryChild(for cell: TreemapCell?) -> DirectoryChild? {
        guard let cell else { return nil }
        if cell.aggregatedCount > 0 {
            return DirectoryChild(
                name: cell.name, path: "", isDirectory: false, readable: true,
                allocatedBytes: cell.bytes, apparentBytes: nil, entries: cell.aggregatedCount
            )
        }
        return finishedChildren.first { $0.name == cell.name }
    }

    // MARK: - D-23's states (five render branches; "Locked child present" is not a sixth --
    // `TreemapLayout` already carves that cell automatically (D-20, wired in 4.2), and its
    // footer note is `DiskSpaceModel.footerText`'s existing `unreadableCount` clause, already
    // folded into whichever branch below is active).

    private func updateStorageState() {
        let isSizing = scanTask != nil
        progressIndicator.isHidden = !isSizing
        progressLabel.isHidden = !isSizing
        stopButton.isHidden = !isSizing

        if root == nil {
            bodyLabel.stringValue = DiskSpaceModel.noRootBodyText
            bodyLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
            bodyLabel.isHidden = false
            canvasView.isHidden = true
            footerLabel.stringValue = ""
        } else if let reason = level?.rootUnavailableReason {
            bodyLabel.stringValue = DiskSpaceModel.unavailableBodyText
            bodyLabel.textColor = NSColor(cgColor: theme.cgColor("textDisabled")) ?? .disabledControlTextColor
            bodyLabel.isHidden = false
            canvasView.isHidden = true
            footerLabel.stringValue = reason
        } else {
            bodyLabel.isHidden = true
            canvasView.isHidden = false
            footerLabel.stringValue = level.map(DiskSpaceModel.footerText) ?? ""
            // A hidden view cannot hold first responder -- `paneDidBecomeVisible()`'s own
            // attempt lands while this canvas is still hidden behind the "no root chosen"
            // body, so D-13's keyboard navigation needs its own claim the moment the canvas
            // actually has content to navigate.
            if view.window?.firstResponder !== canvasView {
                view.window?.makeFirstResponder(canvasView)
            }
        }
        updateReadoutAndDisclosure()
    }

    private func updateReadoutAndDisclosure() {
        guard root != nil, level?.rootUnavailableReason == nil,
              let child = directoryChild(for: canvasView.selectedCell)
        else {
            readoutLabel.stringValue = ""
            disclosureLabel.stringValue = ""
            return
        }
        readoutLabel.stringValue = DiskSpaceModel.readoutText(for: child)
        disclosureLabel.stringValue = DiskSpaceModel.disclosureText(for: child) ?? ""
    }

    // MARK: - View construction

    override func loadView() {
        let root = KeyCommandView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.cgColor(hex: theme.background)

        let volumesCard = makeCardContainer()
        volumesCardView = volumesCard
        volumesCard.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(volumeBarClicked))
        )
        volumesCard.toolTip = "Click to size this volume — reads every file on it, which takes minutes."
        let storageCard = makeCardContainer()
        root.addSubview(volumesCard)
        root.addSubview(storageCard)

        buildVolumesCard(volumesCard)
        buildStorageCard(storageCard)

        NSLayoutConstraint.activate([
            volumesCard.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            volumesCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            volumesCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            storageCard.topAnchor.constraint(equalTo: volumesCard.bottomAnchor, constant: 12),
            storageCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            storageCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            storageCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // §14.6's ⌘D overload, second press: `PaneHostView.show(_:)` early-returns on a repeat
        // selection (F-6), so `Commands.swift`'s button calls this closure instead of setting
        // `state.selectedPane` again.
        state.diskSpaceSelectHomeRoot = { [weak self] in
            self?.enter(FileManager.default.homeDirectoryForCurrentUser)
        }

        breadcrumb.target = self
        breadcrumb.action = #selector(breadcrumbClicked(_:))
        stopButton.target = self
        stopButton.action = #selector(stopButtonClicked)

        canvasView.onDescend = { [weak self] in self?.descendIntoSelection() }
        canvasView.onAscend = { [weak self] in self?.ascend() }
        canvasView.onSelectionChanged = { [weak self] in self?.updateReadoutAndDisclosure() }
        // Item handed forward from 4.2: the tooltip now carries the same string as the node
        // readout line, not just name-and-bytes, now that real `DirectoryChild` data flows.
        canvasView.tooltipText = { [weak self] cell in
            guard let self, let child = self.directoryChild(for: cell) else {
                return "\(cell.name) — \(cell.bytes.map(Format.bytes) ?? Format.unknown)"
            }
            return DiskSpaceModel.readoutText(for: child)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    deinit {
        // `paneDidResignVisible()` is the load-bearing cancel (F-6); this is the backstop --
        // both `Task` and the flag below are `Sendable`, safe to touch directly from a
        // nonisolated `deinit`.
        cancelled = true
        scanTask?.cancel()
        // `deinit` runs nonisolated even on a `@MainActor` class (PaneHostView's own comment
        // on this, one door over); `state` is a distinct MainActor-isolated object, so the
        // clear is handed to the actor rather than written directly.
        let state = state
        Task { @MainActor in state.diskSpaceSelectHomeRoot = nil }
    }

    @objc private func handleThemeDidChange() {
        for container in cardContainers {
            container.layer?.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
            container.layer?.borderColor = Theme.cgColor(hex: theme.cardBorder)
        }
        volumesTitleLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        volumeNameLabel.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        volumeNumbersLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        volumeClauseLabel.textColor = NSColor(cgColor: theme.cgColor("textTertiary")) ?? .tertiaryLabelColor
        progressLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        bodyLabel.textColor = NSColor(cgColor: theme.cgColor(root == nil ? "textSecondary" : "textDisabled"))
            ?? .secondaryLabelColor
        readoutLabel.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        disclosureLabel.textColor = NSColor(cgColor: theme.cgColor("textTertiary")) ?? .tertiaryLabelColor
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        view.layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        volumeMeterView.applyTheme(accentHex: theme.accentDisk, theme: theme)
        canvasView.applyTheme(theme)
    }

    // MARK: - §4.2's card chrome, `UsersPaneController.card(title:table:)`'s own construction

    private func makeCardContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
        container.layer?.borderColor = Theme.cgColor(hex: theme.cardBorder)
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 10
        cardContainers.append(container)
        return container
    }

    /// One row, structurally: this Mac reports exactly one browsable volume (D-05/D-06).
    /// Every label starts empty and the clause stays hidden -- 4.2 fills them from
    /// `DiskSpaceReader.volumes()` and `DiskSpaceModel`.
    private func buildVolumesCard(_ card: NSView) {
        volumesTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        volumesTitleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        volumesTitleLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        volumeNameLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeNameLabel.font = .systemFont(ofSize: 11)
        volumeNameLabel.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor

        volumeNumbersLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeNumbersLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        volumeNumbersLabel.alignment = .right
        volumeNumbersLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        volumeMeterView.translatesAutoresizingMaskIntoConstraints = false

        volumeClauseLabel.translatesAutoresizingMaskIntoConstraints = false
        volumeClauseLabel.font = .systemFont(ofSize: 10)
        volumeClauseLabel.textColor = NSColor(cgColor: theme.cgColor("textTertiary")) ?? .tertiaryLabelColor
        // D-07: shown only when the purgeable gap exceeds 1 GB -- 4.2 decides that per volume.
        volumeClauseLabel.isHidden = true

        card.addSubview(volumesTitleLabel)
        card.addSubview(volumeNameLabel)
        card.addSubview(volumeNumbersLabel)
        card.addSubview(volumeMeterView)
        card.addSubview(volumeClauseLabel)

        NSLayoutConstraint.activate([
            volumesTitleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            volumesTitleLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            volumesTitleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            volumeNameLabel.topAnchor.constraint(equalTo: volumesTitleLabel.bottomAnchor, constant: 8),
            volumeNameLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),

            volumeNumbersLabel.centerYAnchor.constraint(equalTo: volumeNameLabel.centerYAnchor),
            volumeNumbersLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: volumeNameLabel.trailingAnchor, constant: 8
            ),
            volumeNumbersLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            // §4.9's locked meter geometry (`MeterGeometry.perCoreStrip`): 6 pt thick.
            volumeMeterView.topAnchor.constraint(equalTo: volumeNameLabel.bottomAnchor, constant: 4),
            volumeMeterView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            volumeMeterView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            volumeMeterView.heightAnchor.constraint(equalToConstant: 6),

            volumeClauseLabel.topAnchor.constraint(equalTo: volumeMeterView.bottomAnchor, constant: 4),
            volumeClauseLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            volumeClauseLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            volumeClauseLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    /// The 44 pt toolbar (breadcrumb leading, progress/Stop cluster trailing, all three hidden),
    /// the canvas 4.2 draws into, and the three stacked footer lines -- all empty (D-23's "no
    /// root chosen" state; 4.3 wires the six states).
    private func buildStorageCard(_ card: NSView) {
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        breadcrumb.translatesAutoresizingMaskIntoConstraints = false
        breadcrumb.pathStyle = .standard
        breadcrumb.isEditable = false
        breadcrumb.backgroundColor = .clear

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.isHidden = true

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        progressLabel.isHidden = true

        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.isHidden = true

        toolbar.addSubview(breadcrumb)
        toolbar.addSubview(progressIndicator)
        toolbar.addSubview(progressLabel)
        toolbar.addSubview(stopButton)

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.wantsLayer = true

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        bodyLabel.isHidden = true

        readoutLabel.translatesAutoresizingMaskIntoConstraints = false
        readoutLabel.font = .systemFont(ofSize: 11)
        readoutLabel.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        readoutLabel.lineBreakMode = .byTruncatingTail

        disclosureLabel.translatesAutoresizingMaskIntoConstraints = false
        disclosureLabel.font = .systemFont(ofSize: 10)
        disclosureLabel.textColor = NSColor(cgColor: theme.cgColor("textTertiary")) ?? .tertiaryLabelColor
        disclosureLabel.lineBreakMode = .byTruncatingTail

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        footerLabel.lineBreakMode = .byTruncatingTail

        card.addSubview(toolbar)
        card.addSubview(canvasView)
        card.addSubview(bodyLabel)
        card.addSubview(readoutLabel)
        card.addSubview(disclosureLabel)
        card.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: card.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            breadcrumb.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            breadcrumb.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            breadcrumb.trailingAnchor.constraint(lessThanOrEqualTo: stopButton.leadingAnchor, constant: -12),

            stopButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            stopButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            progressLabel.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -12),
            progressLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            // UI-SPEC's locked 120 pt `.small` progress bar.
            progressIndicator.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -8),
            progressIndicator.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 120),

            canvasView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvasView.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: readoutLabel.topAnchor, constant: -8),

            bodyLabel.centerXAnchor.constraint(equalTo: canvasView.centerXAnchor),
            bodyLabel.centerYAnchor.constraint(equalTo: canvasView.centerYAnchor),
            bodyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: canvasView.leadingAnchor, constant: 24),
            bodyLabel.trailingAnchor.constraint(lessThanOrEqualTo: canvasView.trailingAnchor, constant: -24),

            readoutLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            readoutLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            disclosureLabel.topAnchor.constraint(equalTo: readoutLabel.bottomAnchor, constant: 8),
            disclosureLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            disclosureLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),

            footerLabel.topAnchor.constraint(equalTo: disclosureLabel.bottomAnchor, constant: 8),
            footerLabel.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])
    }

    // MARK: - Gate 12's structural arm (5.1, D-26, override O-6)

    /// Five assertions on `TreemapLayout`'s output alone. Unlike every other pane's arm, this
    /// one needs no window and no controller instance -- `TreemapLayout` is a pure function and
    /// D-26/O-6 is that the correctness of a treemap lives there, not in pixels. 2.1's ten unit
    /// tests already cover the function in isolation, so this fixture asserts the *composition*
    /// a real level produces: five distinct large readable directories, one that refuses
    /// enumeration, and four small enough to aggregate.
    static func paneSelfCheck() -> [PaneAssertion] {
        var pickAssertions: [PaneAssertion] = []
        do {
            // 1.1.3: the pane's own body text says "Select a volume", and until 1.1.3 nothing on
            // the volume bar was clickable -- ⌘D's second press was the only way to start a walk.
            // Asserted against the live view: the card must carry a click recognizer, and the
            // handler must make the shown volume the root.
            let controller = DiskSpacePaneController(state: AppState())
            controller.view.frame = CGRect(x: 0, y: 0, width: 1172, height: 778)
            controller.view.layoutSubtreeIfNeeded()
            // A path that does not exist: `enter(_:)` still makes it the root (what is asserted),
            // while the reader fails its first directory read and returns at once -- no walk, no
            // I/O, and no `scan cancelled` line racing the verdict on stdout.
            let fixturePath = "/var/empty/glowtop-selfcheck-fixture-does-not-exist"
            controller.applyVolumes([VolumeInfo(
                name: "Fixture HD", path: fixturePath, capacityBytes: 1_000, freeBytes: 400,
                importantUsageFreeBytes: nil, isRemovable: false, isInternal: true, isRootFileSystem: false
            )])
            let clickable = controller.volumesCardView.gestureRecognizers.contains { $0 is NSClickGestureRecognizer }
            pickAssertions.append(PaneAssertion(
                name: "diskspace-volume-bar-is-clickable", pass: clickable,
                detail: "recognizers=\(controller.volumesCardView.gestureRecognizers.count)"
            ))
            controller.volumeBarClicked()
            let picked = controller.root?.path
            controller.paneDidResignVisible()   // cancels the fixture walk
            pickAssertions.append(PaneAssertion(
                name: "diskspace-volume-pick-makes-it-the-root",
                pass: picked.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                    == URL(fileURLWithPath: fixturePath).standardizedFileURL.path,
                detail: "root=\(picked ?? "nil")"
            ))
        }

        let rect = TreemapRect(x: 0, y: 0, width: 1140, height: 738)
        let lockedCell = TreemapSize(width: 60, height: 32)
        let minimumCell = TreemapSize(width: 8, height: 8)

        let fixture: [TreemapChild] = [
            TreemapChild(name: "Alpha", bytes: 500_000_000),
            TreemapChild(name: "Beta", bytes: 400_000_000),
            TreemapChild(name: "Gamma", bytes: 300_000_000),
            TreemapChild(name: "Delta", bytes: 200_000_000),
            TreemapChild(name: "Epsilon", bytes: 100_000_000),
            TreemapChild(name: "Locked", bytes: nil),
            TreemapChild(name: "tiny1", bytes: 100),
            TreemapChild(name: "tiny2", bytes: 90),
            TreemapChild(name: "tiny3", bytes: 80),
            TreemapChild(name: "tiny4", bytes: 70),
        ]
        let cells = TreemapLayout.layout(fixture, in: rect, lockedCell: lockedCell, minimumCell: minimumCell)
        var results: [PaneAssertion] = []

        results.append(PaneAssertion(
            name: "diskspace-layout-cell-count-matches-the-fixture",
            pass: cells.count == 7,
            detail: "cells=\(cells.count)"
        ))

        // Area conservation is squarify's own guarantee, checked here against the readable-only
        // half of the same fixture (no `Locked` child) so it is never conflated with the 60x32
        // carve-out's own assertion below: a partially filled locked row legitimately reserves
        // more band than it draws, which is the carve-out's property, not an area bug.
        let readableFixture = fixture.filter { $0.bytes != nil }
        let readableCells = TreemapLayout.layout(
            readableFixture, in: rect, lockedCell: lockedCell, minimumCell: minimumCell)
        let totalArea = readableCells.reduce(0.0) { $0 + $1.rect.area }
        let areaFraction = abs(totalArea - rect.area) / rect.area
        results.append(PaneAssertion(
            name: "diskspace-layout-total-area-within-half-a-percent",
            pass: areaFraction <= 0.005,
            detail: String(format: "total=%.1f container=%.1f diff=%.3f%%", totalArea, rect.area, areaFraction * 100)
        ))

        var overlapArea = 0.0
        for i in 0..<cells.count {
            for j in (i + 1)..<cells.count {
                overlapArea += Self.overlap(cells[i].rect, cells[j].rect)
            }
        }
        results.append(PaneAssertion(
            name: "diskspace-layout-no-pairwise-overlap",
            pass: overlapArea == 0,
            detail: "overlap=\(overlapArea)"
        ))

        let readable = cells.filter { $0.bytes != nil && $0.aggregatedCount == 0 }
        let readableBytes = readable.map { $0.bytes! }
        let isDescending = readableBytes == readableBytes.sorted(by: >)
        let maxReadableArea = readable.map { $0.rect.area }.max() ?? -1
        let firstIsLargest = readable.first?.rect.area == maxReadableArea
        results.append(PaneAssertion(
            name: "diskspace-layout-largest-child-is-first-and-largest-by-area",
            pass: isDescending && firstIsLargest,
            detail: "bytes=\(readableBytes) firstArea=\(readable.first?.rect.area ?? -1) maxArea=\(maxReadableArea)"
        ))

        let locked = cells.first { $0.bytes == nil }
        let lockedSizeOK = locked?.rect.width == 60 && locked?.rect.height == 32
        results.append(PaneAssertion(
            name: "diskspace-layout-locked-cell-is-fixed-size-and-carries-no-bytes",
            pass: locked != nil && lockedSizeOK && locked?.bytes == nil,
            detail: "rect=\(locked.map { "\($0.rect.width)x\($0.rect.height)" } ?? "nil") bytes=\(locked?.bytes.map(String.init) ?? "nil")"
        ))

        return results + pickAssertions
    }

    private static func overlap(_ a: TreemapRect, _ b: TreemapRect) -> Double {
        let x0 = max(a.x, b.x), y0 = max(a.y, b.y)
        let x1 = min(a.x + a.width, b.x + b.width), y1 = min(a.y + a.height, b.y + b.height)
        return max(0, x1 - x0) * max(0, y1 - y0)
    }
}

/// Hosts the volume capacity bar's single `MeterLayer` -- already exactly "a lit fraction of a
/// track" (D-07), so this view exists only to give it a `CALayer` parent inside the reader-pane
/// idiom's Auto Layout tree, and to rebuild it when its width changes (`MeterGeometry`'s width
/// is baked in at construction, `PerformancePaneView.buildGrid`'s own reason for rebuilding on a
/// cell-width change). `MeterLayer.swift` itself is untouched.
@MainActor
private final class VolumeMeterView: NSView {
    private var meter: MeterLayer?
    private var accentHex: String
    private var theme: Theme
    private var fraction: Double?
    private var state: CardState = .warming
    private var builtWidth: CGFloat = -1

    init(accentHex: String, theme: Theme) {
        self.accentHex = accentHex
        self.theme = theme
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { false }

    func set(fraction: Double?, state: CardState) {
        self.fraction = fraction
        self.state = state
        meter?.set(fraction: fraction, state: state, over: .zero)
    }

    func applyTheme(accentHex: String, theme: Theme) {
        self.accentHex = accentHex
        self.theme = theme
        meter?.updateTheme(accentHex: accentHex, theme: theme)
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, let root = layer else { return }
        if meter == nil || abs(bounds.width - builtWidth) > 0.5 {
            builtWidth = bounds.width
            meter?.unlit.removeFromSuperlayer()
            meter?.lit.removeFromSuperlayer()
            let newMeter = MeterLayer(geometry: .perCoreStrip(width: bounds.width),
                                      accentHex: accentHex, theme: theme)
            newMeter.addTo(root)
            meter = newMeter
            meter?.set(fraction: fraction, state: state, over: .zero)
        }
        let scale = window?.backingScaleFactor ?? 2
        meter?.updateScale(scale)
        meter?.layout(origin: .zero)
    }
}

/// Hosts the `TreemapLayer` canvas, D-13's keyboard-first navigation, and the selection state
/// the pane controller reads to build the node readout. Re-invokes the pure
/// `TreemapLayout.layout(...)` on every resize -- no re-walk, the byte totals haven't changed
/// (UI-SPEC's "nothing scrolls" paragraph) -- and keeps every rectangle's tooltip current,
/// `PowerFreqPaneView.layout()`'s own `removeAllToolTips()`-then-rebuild idiom (that file is in
/// the untouched list; this is its own copy, since `addToolTipRect` is a view API a bare
/// `CALayer` cannot call).
@MainActor
private final class TreemapCanvasView: NSView {
    let treemapLayer: TreemapLayer
    private var children: [TreemapChild] = []
    private(set) var cells: [TreemapCell] = []
    private var tooltipOwners: [NSString] = []

    /// Tracked by **name**, not array index: a relayout re-sorts by bytes on every progressive
    /// update while a scan is in flight, so an index into `cells` from one layout does not name
    /// the same rectangle in the next. `autoSelectLargest` is UI-SPEC's default (the largest
    /// cell, re-picked on every relayout) and holds until the user actually moves the selection.
    private var selectedName: String?
    private var autoSelectLargest = true

    var onDescend: (() -> Void)?
    var onAscend: (() -> Void)?
    var onSelectionChanged: (() -> Void)?
    /// Set by the controller once real node data flows (4.3) -- the same string the node
    /// readout line shows for every cell, down to the aggregate and the `Locked` one (UI-SPEC),
    /// so a label too small to render is only ever deferred to a hover, never withheld. Falls
    /// back to the bare name/bytes pair only if unset.
    var tooltipText: ((TreemapCell) -> String)?

    init(theme: Theme) {
        treemapLayer = TreemapLayer(theme: theme)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(treemapLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    var selectedCell: TreemapCell? {
        guard let index = currentSelectedIndex, cells.indices.contains(index) else { return nil }
        return cells[index]
    }

    /// `resetSelection` is `true` only on entering a fresh level (`enter(_:)`): the largest
    /// cell becomes the default again and stays the default through every progressive update
    /// until the user actually moves the selection.
    func set(children: [TreemapChild], resetSelection: Bool) {
        self.children = children
        if resetSelection {
            selectedName = nil
            autoSelectLargest = true
        }
        relayout()
    }

    func applyTheme(_ theme: Theme) {
        treemapLayer.applyTheme(theme)
    }

    override func layout() {
        super.layout()
        treemapLayer.frame = bounds
        relayout()
    }

    private func relayout() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let rect = TreemapRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        cells = TreemapLayout.layout(children, in: rect,
                                     lockedCell: TreemapLayer.lockedCellSize,
                                     minimumCell: TreemapLayer.minimumCell)
        treemapLayer.apply(cells: cells, selected: currentSelectedIndex, hovered: nil)
        updateTooltips()
    }

    private var currentSelectedIndex: Int? {
        if !autoSelectLargest, let selectedName, let index = cells.firstIndex(where: { $0.name == selectedName }) {
            return index
        }
        return largestReadableIndex
    }

    /// UI-SPEC: on entering a level the largest rectangle is selected by default.
    private var largestReadableIndex: Int? {
        cells.indices
            .filter { cells[$0].bytes != nil }
            .max { (cells[$0].bytes ?? 0) < (cells[$1].bytes ?? 0) }
    }

    // MARK: - D-13's keyboard-first navigation. `TreemapLayout.neighbour(of:in:direction:)`
    // decides; nothing here re-implements the nearest-centre rule, it only dispatches.

    private static let keyCodeReturn: UInt16 = 36
    private static let keyCodeDelete: UInt16 = 51
    private static let keyCodeLeft: UInt16 = 123
    private static let keyCodeRight: UInt16 = 124
    private static let keyCodeDown: UInt16 = 125
    private static let keyCodeUp: UInt16 = 126

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case Self.keyCodeLeft: moveSelection(.left)
        case Self.keyCodeRight: moveSelection(.right)
        case Self.keyCodeUp: moveSelection(.up)
        case Self.keyCodeDown: moveSelection(.down)
        case Self.keyCodeReturn: onDescend?()
        case Self.keyCodeDelete: onAscend?()
        default: super.keyDown(with: event)
        }
    }

    private func moveSelection(_ direction: TreemapDirection) {
        guard let current = currentSelectedIndex,
              let next = TreemapLayout.neighbour(of: current, in: cells, direction: direction)
        else { return }
        selectedName = cells[next].name
        autoSelectLargest = false
        treemapLayer.apply(cells: cells, selected: next, hovered: nil)
        onSelectionChanged?()
    }

    /// The obvious gesture (UI-SPEC) -- ungated (D-13): no acceptance check in this phase
    /// depends on a synthesized click.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = cells.firstIndex(where: {
            CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height).contains(point)
        }) else { return }
        selectedName = cells[index].name
        autoSelectLargest = false
        treemapLayer.apply(cells: cells, selected: index, hovered: nil)
        onSelectionChanged?()
        onDescend?()
    }

    private func updateTooltips() {
        removeAllToolTips()
        tooltipOwners = cells.map { cell in
            (tooltipText?(cell) ?? "\(cell.name) — \(cell.bytes.map(Format.bytes) ?? Format.unknown)") as NSString
        }
        for (cell, owner) in zip(cells, tooltipOwners) {
            let rect = CGRect(x: cell.rect.x, y: cell.rect.y, width: cell.rect.width, height: cell.rect.height)
            _ = addToolTip(rect, owner: owner, userData: nil)
        }
    }
}
