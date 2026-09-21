import AppKit
import GlowTopCore

/// SPEC.md §10's Startup Apps pane. `LaunchdReader` does every read and every formatting
/// decision (§7.1); this file starts/stops the re-read timer, sorts and filters the projected
/// rows, draws them, and offers `Reveal in Finder` plus §14.4's guarded `Enable`/`Disable`
/// through `JobActionSheet`.
@MainActor
final class StartupAppsPaneController: NSViewController, PaneController {
    private struct Row {
        let label: String
        let type: String
        let program: String
        let runAtLoad: String
        let keepAlive: String
        let path: String
        let enabled: String
    }

    private var inventory = LaunchdInventory(jobs: [], footerNotes: [])
    /// D-05's footer note when the override store is unreadable -- travels with the tuple
    /// `LaunchdOverrides.read()` returns; the reader itself generates no footer text (2.1).
    private var overrideNote: String?
    private var rows: [Row] = []
    private var searchQuery = ""
    private var refreshTimer: Timer?
    private let jobActionSheet = JobActionSheet()

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let footerLabel = NSTextField(labelWithString: "")
    private var theme: Theme { ThemeStore.shared.theme }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.cgColor(hex: theme.background)

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

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.maximumNumberOfLines = 0

        root.addSubview(toolbar)
        root.addSubview(scrollView)
        root.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

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
        let enableItem = NSMenuItem(title: "Enable", action: #selector(enableSelected), keyEquivalent: "")
        enableItem.target = self
        menu.addItem(enableItem)
        let disableItem = NSMenuItem(title: "Disable", action: #selector(disableSelected), keyEquivalent: "")
        disableItem.target = self
        menu.addItem(disableItem)
        tableView.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    /// §7.3's live-apply: the chrome set once in `loadView()` and the row colour baked into
    /// each recycled cell both need a push — `reloadData()` alone repaints only because
    /// `tableView(_:viewFor:row:)` now re-sets colour on every call, not only at creation.
    @objc private func handleThemeDidChange() {
        view.layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        tableView.reloadData()
    }

    // MARK: - §3.3's visibility hooks

    /// Reads once on first visibility, then re-reads at 0.2 Hz -- plist directories change
    /// rarely, and 5 s is well inside "live" for a source that is not on any hot path.
    func paneDidBecomeVisible() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func paneDidResignVisible() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        jobActionSheet.cancelPendingPoll()
    }

    private func refresh() {
        let (overrides, note) = LaunchdOverrides.read()
        inventory = LaunchdReader.read(overrides: overrides)
        overrideNote = note
        project()
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        project()
    }

    /// §10.2: sorted by Type then Name. Search filters on Name, Program and Path -- §10.2's
    /// own three fields, distinct from §8.4's Name/Path/PID.
    private func project() {
        let query = searchQuery.lowercased()
        let filtered = query.isEmpty ? inventory.jobs : inventory.jobs.filter {
            $0.label.lowercased().contains(query) ||
            $0.program.lowercased().contains(query) ||
            $0.path.lowercased().contains(query)
        }
        let sorted = filtered.sorted {
            $0.type != $1.type ? $0.type < $1.type : $0.label < $1.label
        }
        rows = sorted.map { job in
            Row(
                label: job.label,
                type: job.type,
                program: job.program.isEmpty ? Format.unknown : job.program,
                runAtLoad: job.runAtLoad.map { $0 ? "Yes" : "No" } ?? Format.unknown,
                keepAlive: job.keepAlive ?? Format.unknown,
                path: job.path,
                enabled: job.enabled == true ? "✓" : Format.unknown
            )
        }
        footerLabel.stringValue = footerText()
        tableView.reloadData()
    }

    /// §10.1's fixed sentence, 4.2's outcome-B disclosure (§10.4: a missing source names
    /// itself on the footer rather than the table quietly covering less than it claims to),
    /// plus §10.4's per-directory notes.
    private func footerText() -> String {
        var lines = ["Legacy login items are not listed."]
        if case .unavailable = LoginItemsReader.read() {
            lines.append("Login items are not listed: macOS gives apps no supported way to read them.")
        }
        lines.append(contentsOf: inventory.footerNotes)
        if let overrideNote {
            lines.append(overrideNote)
        }
        return lines.joined(separator: "  ")
    }

    // MARK: - §10.3's read-only context action

    @objc private func revealSelected() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: rows[row].path)])
    }

    // MARK: - §14.4's write actions (D-06)

    @objc private func enableSelected() { performJobAction(.enable) }
    @objc private func disableSelected() { performJobAction(.disable) }

    /// D-03's second guardrail layer: `menuNeedsUpdate` already disabled the control for
    /// anything but `.actionable`, but a disabled control is not a guarantee, so this re-checks
    /// before the sheet ever opens. The job is resolved by **label**, never by index -- `rows`
    /// is a search-filtered projection (F-4), so a row's position here can outrun its position
    /// in `inventory.jobs`.
    private func performJobAction(_ verb: JobVerb) {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count,
              let job = inventory.jobs.first(where: { $0.label == rows[row].label }),
              JobActions.actionability(of: job) == .actionable,
              let window = view.window
        else { return }
        jobActionSheet.confirm(job, verb: verb, in: window) { [weak self] _ in
            // D-06: Startup re-reads immediately rather than waiting for the 5 s poll timer.
            self?.refresh()
        }
    }

    // MARK: - Columns

    private struct ColumnSpec {
        let key: String
        let title: String
        let width: CGFloat
    }

    private static let columnSpecs: [ColumnSpec] = [
        ColumnSpec(key: "enabled", title: "Enabled", width: 60),
        ColumnSpec(key: "name", title: "Name", width: 220),
        ColumnSpec(key: "type", title: "Type", width: 140),
        ColumnSpec(key: "program", title: "Program", width: 220),
        ColumnSpec(key: "runAtLoad", title: "Run at load", width: 90),
        ColumnSpec(key: "keepAlive", title: "Keep alive", width: 160),
        ColumnSpec(key: "path", title: "Path", width: 240),
    ]

    private func configureColumns() {
        for spec in Self.columnSpecs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key))
            column.title = spec.title
            column.width = spec.width
            tableView.addTableColumn(column)
        }
    }

    private func text(for key: String, in row: Row) -> String {
        switch key {
        case "enabled": return row.enabled
        case "name": return row.label
        case "type": return row.type
        case "program": return row.program
        case "runAtLoad": return row.runAtLoad
        case "keepAlive": return row.keepAlive
        case "path": return row.path
        default: return ""
        }
    }
}

extension StartupAppsPaneController: NSTableViewDataSource, NSTableViewDelegate {
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
        // Set on every call, not only at creation -- a recycled cell must pick up a theme
        // change too, and `reloadData()` after one is what drives this.
        cell.textField?.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        cell.textField?.stringValue = text(for: identifier.rawValue, in: rows[row])
        return cell
    }
}

extension StartupAppsPaneController: NSMenuDelegate {
    /// Layer 1's per-row state for `Enable`/`Disable`, factored out of `menuNeedsUpdate` so
    /// `paneSelfCheck()` can exercise the same logic against a fixture row keyed by an explicit
    /// index -- `tableView.clickedRow` has no public setter (4.2, hand-off from wave 3).
    private func jobActionState(forRow row: Int) -> (isEnabled: Bool, tooltip: String?) {
        guard row >= 0, row < rows.count,
              let job = inventory.jobs.first(where: { $0.label == rows[row].label })
        else { return (false, nil) }
        switch JobActions.actionability(of: job) {
        case .actionable: return (true, nil)
        case .readOnly(let tooltip): return (false, tooltip)
        case .denied: return (false, "This job cannot be changed.")
        }
    }

    /// Layer 1 of D-03's two-layer guardrail. `Reveal in Finder`'s enablement is unchanged;
    /// `Enable`/`Disable` follow `JobActions.actionability(of:)` -- `.actionable` enabled with no
    /// tooltip, `.readOnly` disabled with §14.4's own tooltip, `.denied` disabled with the
    /// deny-list's generic one.
    func menuNeedsUpdate(_ menu: NSMenu) {
        applyMenuState(to: menu, forRow: tableView.clickedRow)
    }

    /// `menuNeedsUpdate`'s body keyed by an explicit row, so `paneSelfCheck()` can drive the real
    /// menu items -- `tableView.clickedRow` has no public setter.
    private func applyMenuState(to menu: NSMenu, forRow row: Int) {
        let state = jobActionState(forRow: row)
        for item in menu.items {
            switch item.action {
            case #selector(enableSelected), #selector(disableSelected):
                item.isEnabled = state.isEnabled
                item.toolTip = state.tooltip
            default:
                item.isEnabled = row >= 0
            }
        }
    }

    // MARK: - Gate 12's structural arm (4.2, hand-off from wave 3)

    /// Three assertions over a controller built without a window, every fixture synthetic --
    /// never a live `LaunchdReader.read()`, which would make the assertion depend on this
    /// Mac's own `~/Library/LaunchAgents` (`InstalledAppsPaneController`'s own reasoning, O-4).
    static func paneSelfCheck() -> [PaneAssertion] {
        let controller = StartupAppsPaneController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1172, height: 778)
        controller.view.layoutSubtreeIfNeeded()
        var results: [PaneAssertion] = []

        let menuTitles = controller.tableView.menu?.items.map(\.title) ?? []
        results.append(PaneAssertion(
            name: "startupapps-menu-carries-enable-and-disable",
            pass: menuTitles == ["Reveal in Finder", "Enable", "Disable"],
            detail: "items=\(menuTitles.joined(separator: ","))"
        ))

        func fixtureJob(type: String) -> LaunchdJob {
            LaunchdJob(
                label: "com.example.phase14-fixture", type: type, program: "/usr/bin/fixture",
                runAtLoad: false, keepAlive: nil,
                path: "/Library/LaunchDaemons/com.example.phase14-fixture.plist",
                enabled: true, programArguments: []
            )
        }
        func loadFixture(_ job: LaunchdJob) {
            controller.inventory = LaunchdInventory(jobs: [job], footerNotes: [])
            controller.rows = [Row(
                label: job.label, type: job.type, program: job.program, runAtLoad: "No",
                keepAlive: Format.unknown, path: job.path, enabled: "✓"
            )]
        }

        loadFixture(fixtureJob(type: "Launch Daemon"))
        let daemonState = controller.jobActionState(forRow: 0)
        results.append(PaneAssertion(
            name: "startupapps-launch-daemon-items-are-disabled",
            pass: daemonState.isEnabled == false && daemonState.tooltip
                == "Read-only — this job runs as root in the system domain, and GlowTop never asks for root.",
            detail: "isEnabled=\(daemonState.isEnabled) tooltip=\(daemonState.tooltip ?? "nil")"
        ))

        loadFixture(fixtureJob(type: "Launch Agent (system)"))
        let systemAgentState = controller.jobActionState(forRow: 0)
        results.append(PaneAssertion(
            name: "startupapps-system-agent-items-are-disabled",
            pass: systemAgentState.isEnabled == false && systemAgentState.tooltip
                == "Read-only — installed for every user by a package; only jobs in your own ~/Library/LaunchAgents can be changed here.",
            detail: "isEnabled=\(systemAgentState.isEnabled) tooltip=\(systemAgentState.tooltip ?? "nil")"
        ))

        // The live control, not the computed state. AppKit runs its own validation pass
        // (`NSMenu.update()`) after `menuNeedsUpdate` on every real right-click, and with
        // `autoenablesItems` left at its default it re-enabled both items on every read-only
        // row. Found 2026-09-21 by hovering the real menu in the notarized 1.1.0 build -- the
        // assertions above read `jobActionState`, which was right all along (§14.9).
        loadFixture(fixtureJob(type: "Launch Daemon"))
        if let menu = controller.tableView.menu {
            controller.applyMenuState(to: menu, forRow: 0)
            menu.update()
            let live = menu.items.filter { $0.title == "Enable" || $0.title == "Disable" }.map(\.isEnabled)
            results.append(PaneAssertion(
                name: "startupapps-launch-daemon-items-stay-disabled-after-appkit-validation",
                pass: live == [false, false],
                detail: "enabled=\(live)"
            ))
        }

        return results
    }
}
