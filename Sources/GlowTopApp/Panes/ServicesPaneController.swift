import AppKit
import GlowTopCore

/// SPEC.md §12's Services pane: §12.1's configured-jobs inventory, never `launchctl` stdout.
/// `ServicesModel` decides every status and every sort (§7.1); this file draws rows, offers
/// §12.3's two read-only actions (`Reveal in Finder`, `Show Process`) and §14.4's guarded
/// `Start`/`Stop` through `JobActionSheet`.
@MainActor
final class ServicesPaneController: NSViewController, PaneController {
    private let store: MetricStore
    private let appState: AppState

    /// The unfiltered correlated set, refreshed by the 1 Hz poll. `rows` is a projection of it,
    /// so a keystroke can re-filter without waiting for the next poll — `StartupAppsPaneController`'s
    /// shape, which this pane was missing.
    private var allRows: [ServiceRow] = []
    private var rows: [ServiceRow] = []
    /// F-3/O-5: `ServiceRow` carries no `RunAtLoad`/`KeepAlive`, which §14.4's sheet body and
    /// D-11's `Stop` line both need. Retained here, by label, rather than adding a field to
    /// `ServiceRow` -- `ServicesModel.correlate` and `ServiceRow` stay untouched (CONTEXT).
    private var jobsByLabel: [String: LaunchdJob] = [:]
    private var searchQuery = ""
    private var pollTask: Task<Void, Never>?
    private let jobActionSheet = JobActionSheet()

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "Services — configured jobs")
    private var theme: Theme { ThemeStore.shared.theme }

    init(store: MetricStore, appState: AppState) {
        self.store = store
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.cgColor(hex: theme.background)

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        toolbar.addSubview(searchField)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        // §12.1's permanent footer, always visible -- not a tooltip.
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        footerLabel.stringValue = """
        Configured jobs from launchd plist directories. Jobs registered at runtime, jobs in domains this user cannot read, and system jobs without an on-disk plist are not listed. Running state is inferred by matching against the process table.
        """

        root.addSubview(titleLabel)
        root.addSubview(toolbar)
        root.addSubview(scrollView)
        root.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            toolbar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),

            searchField.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 240),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),

            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureColumns()

        let menu = NSMenu()
        menu.delegate = self
        // Every item's state is set by hand in `menuNeedsUpdate`. Left at its default, AppKit's
        // own validation pass runs afterwards and re-enables any item whose target responds to
        // its action -- which silently undid the guardrail's first layer in 1.1.0 (§14.9).
        menu.autoenablesItems = false
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealSelected), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)
        let showItem = NSMenuItem(title: "Show Process", action: #selector(showProcessSelected), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let startItem = NSMenuItem(title: "Start", action: #selector(startSelected), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)
        let stopItem = NSMenuItem(title: "Stop", action: #selector(stopSelected), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)
        tableView.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    /// §7.3's live-apply. See `StartupAppsPaneController`'s twin for why `reloadData()` alone
    /// is enough once the cell-colouring path stops skipping recycled cells.
    @objc private func handleThemeDidChange() {
        view.layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        titleLabel.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        tableView.reloadData()
    }

    // MARK: - §3.3's visibility hooks

    /// Re-reads and re-correlates at 1 Hz -- the same cadence as the process snapshot the
    /// correlation is against; anything faster would re-derive the same answer.
    func paneDidBecomeVisible() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let frame = await self.store.processFrame()
                self.refresh(processes: frame.current?.rows ?? [])
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func paneDidResignVisible() {
        pollTask?.cancel()
        pollTask = nil
        jobActionSheet.cancelPendingPoll()
    }

    private func refresh(processes: [ProcessRow]) {
        let jobs = LaunchdReader.read().jobs
        allRows = ServicesModel.correlate(jobs: jobs, processes: processes)
        // `uniquingKeysWith:` rather than `uniqueKeysWithValues:` -- three source directories
        // (§10.1) can in principle name the same label twice, and a crash on a malformed real
        // system is worse than keeping the first match.
        jobsByLabel = Dictionary(jobs.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        project()
    }

    /// Reads `allRows` and only `allRows`. Filtering `rows` in place would apply the query to
    /// already-filtered output, and a second keystroke would empty the list for good.
    private func project() {
        let query = searchQuery.lowercased()
        rows = query.isEmpty ? allRows : allRows.filter {
            $0.label.lowercased().contains(query) || $0.program.lowercased().contains(query)
        }
        tableView.reloadData()
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        project()
    }

    // MARK: - §12.3's two read-only actions

    @objc private func revealSelected() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rows[row].path)])
    }

    /// The only cross-pane call in the phase: switches to Processes with the matched PID
    /// selected.
    @objc private func showProcessSelected() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, let pid = rows[row].pid else { return }
        appState.pendingProcessPID = pid
        appState.selectedPane = .processes
    }

    // MARK: - §14.4's write actions (D-06). D-10: `Stop` is offered on every actionable row,
    // never gated on `Status`, which is process correlation and reads `Unknown` for real
    // running jobs.

    @objc private func startSelected() { performJobAction(.start) }
    @objc private func stopSelected() { performJobAction(.stop) }

    /// D-03's second guardrail layer, resolved through `jobsByLabel` (O-5) rather than by index.
    private func performJobAction(_ verb: JobVerb) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count,
              let job = jobsByLabel[rows[row].label],
              JobActions.actionability(of: job) == .actionable,
              let window = view.window
        else { return }
        // D-06: no `refresh()` here -- the 1 Hz poll already running for this pane picks up
        // the change on its own next tick.
        jobActionSheet.confirm(job, verb: verb, in: window) { _ in }
    }

    // MARK: - Columns

    private static let columnKeys = ["status", "label", "type", "program", "pid", "cpu", "memory"]
    private static let columnTitles = ["Status", "Label", "Type", "Program", "PID", "CPU", "Memory"]

    private func configureColumns() {
        for (key, title) in zip(Self.columnKeys, Self.columnTitles) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = key == "program" ? 240 : (key == "label" ? 200 : 80)
            tableView.addTableColumn(column)
        }
    }

    private static let statusGlyph: [ServiceRow.Status: String] = [.running: "●", .configured: "◌", .unknown: "○"]

    private func text(_ key: String, _ row: ServiceRow) -> String {
        switch key {
        case "status": return "\(Self.statusGlyph[row.status] ?? "") \(row.status.rawValue)"
        case "label": return row.label
        case "type": return row.type
        case "program": return row.program
        case "pid": return row.pid.map(String.init) ?? Format.unknown
        case "cpu": return row.cpuText
        case "memory": return row.memoryText
        default: return ""
        }
    }
}

extension ServicesPaneController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let identifier = column.identifier
        let cell: NSTableCellView
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = recycled
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        cell.textField?.stringValue = text(identifier.rawValue, rows[row])
        return cell
    }
}

extension ServicesPaneController: NSMenuDelegate {
    /// Layer 1's per-row state for `Start`/`Stop`, factored out of `menuNeedsUpdate` so
    /// `paneSelfCheck()` can exercise the same logic against a fixture row keyed by an explicit
    /// index -- `tableView.clickedRow` has no public setter (4.2, hand-off from wave 3).
    private func jobActionState(forRow row: Int) -> (isEnabled: Bool, tooltip: String?) {
        guard row >= 0, row < rows.count, let job = jobsByLabel[rows[row].label] else {
            return (false, nil)
        }
        switch JobActions.actionability(of: job) {
        case .actionable: return (true, nil)
        case .readOnly(let tooltip): return (false, tooltip)
        case .denied: return (false, "This job cannot be changed.")
        }
    }

    /// Layer 1 of D-03's two-layer guardrail. `Reveal in Finder`/`Show Process` enablement is
    /// unchanged; `Start`/`Stop` follow `JobActions.actionability(of:)`, resolved through
    /// `jobsByLabel`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        applyMenuState(to: menu, forRow: tableView.clickedRow)
    }

    /// `menuNeedsUpdate`'s body keyed by an explicit row, so `paneSelfCheck()` can drive the real
    /// menu items -- `tableView.clickedRow` has no public setter.
    private func applyMenuState(to menu: NSMenu, forRow row: Int) {
        let state = jobActionState(forRow: row)
        for item in menu.items {
            switch item.action {
            case #selector(startSelected), #selector(stopSelected):
                item.isEnabled = state.isEnabled
                item.toolTip = state.tooltip
            case #selector(showProcessSelected):
                item.isEnabled = row >= 0 && row < rows.count && rows[row].pid != nil
            default:
                item.isEnabled = row >= 0
            }
        }
    }

    // MARK: - Gate 12's structural arm (4.2, hand-off from wave 3)

    /// Three assertions over a controller built without a window (F-11's construction shape),
    /// every fixture synthetic -- never a live `LaunchdReader.read()`.
    static func paneSelfCheck() -> [PaneAssertion] {
        let controller = ServicesPaneController(store: MetricStore(), appState: AppState())
        controller.view.frame = CGRect(x: 0, y: 0, width: 1172, height: 778)
        controller.view.layoutSubtreeIfNeeded()
        var results: [PaneAssertion] = []

        let menuTitles = controller.tableView.menu?.items.map(\.title) ?? []
        results.append(PaneAssertion(
            name: "services-menu-carries-start-and-stop",
            pass: menuTitles == ["Reveal in Finder", "Show Process", "Start", "Stop"],
            detail: "items=\(menuTitles.joined(separator: ","))"
        ))

        func fixtureRow(label: String) -> ServiceRow {
            ServiceRow(
                label: label, type: "Launch Agent", program: "/usr/bin/fixture",
                path: "/Users/fixture/Library/LaunchAgents/\(label).plist",
                status: .configured, pid: nil, cpuText: Format.unknown, memoryText: Format.unknown
            )
        }
        func fixtureJob(label: String) -> LaunchdJob {
            LaunchdJob(
                label: label, type: "Launch Agent", program: "/usr/bin/fixture",
                runAtLoad: false, keepAlive: nil,
                path: "/Users/fixture/Library/LaunchAgents/\(label).plist",
                enabled: true, programArguments: []
            )
        }
        func loadFixture(label: String) {
            controller.rows = [fixtureRow(label: label)]
            controller.jobsByLabel = [label: fixtureJob(label: label)]
        }

        // D-12's deny-list, live-unreachable second layer: a `com.apple.*` user-agent row is
        // still guardrail-denied even though its domain (`Launch Agent`) is itself actionable.
        loadFixture(label: "com.apple.phase14-fixture")
        let appleState = controller.jobActionState(forRow: 0)
        results.append(PaneAssertion(
            name: "services-apple-label-items-are-disabled",
            pass: appleState.isEnabled == false,
            detail: "isEnabled=\(appleState.isEnabled) tooltip=\(appleState.tooltip ?? "nil")"
        ))

        // The live control after AppKit's own validation pass -- see the same assertion in
        // `StartupAppsPaneController.paneSelfCheck()` for what it caught (§14.9, 2026-09-21).
        if let menu = controller.tableView.menu {
            controller.applyMenuState(to: menu, forRow: 0)
            menu.update()
            let live = menu.items.filter { $0.title == "Start" || $0.title == "Stop" }.map(\.isEnabled)
            results.append(PaneAssertion(
                name: "services-apple-label-items-stay-disabled-after-appkit-validation",
                pass: live == [false, false],
                detail: "enabled=\(live)"
            ))
        }

        // Catches a deny-list mistakenly written as a `com.glowtop.` prefix (D-12's own worry) --
        // this exact throwaway label must stay actionable.
        loadFixture(label: "com.glowtop.phase14-test")
        let testLabelState = controller.jobActionState(forRow: 0)
        results.append(PaneAssertion(
            name: "services-glowtop-test-label-stays-actionable",
            pass: testLabelState.isEnabled == true,
            detail: "isEnabled=\(testLabelState.isEnabled)"
        ))

        return results
    }
}
