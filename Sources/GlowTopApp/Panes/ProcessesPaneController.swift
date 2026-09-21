import AppKit
import GlowTopCore

/// SPEC.md §8's Processes pane: §8.1's toolbar, §8.2's eight-column table, §8.3's stable
/// header-click sort, §8.7's PID-keyed selection and preserved scroll. Reuses `MetricStore`'s
/// existing 1 Hz process stream (the locked discretion-table decision) -- no second cadence,
/// no second enumeration.
///
/// `ProcessesModel.project(...)` does every filter/sort/format decision; this file only draws
/// the strings it is handed and reacts to clicks (§7.1's boundary).
@MainActor
final class ProcessesPaneController: NSViewController, PaneController {
    private let store: MetricStore
    private let state: AppState
    private var pollTask: Task<Void, Never>?
    /// The last sample fetched from the store, re-projected immediately on a search or sort
    /// change rather than waiting up to a second for the next poll tick.
    private var lastSample: ProcessSample?

    private let tableView = ProcessesTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let cadenceLabel = NSTextField(labelWithString: "1 Hz")
    /// §8.5 item 1's toolbar trigger. Disabled with no row selected and for PID 0/1 (§8.5's
    /// guardrail) -- the second layer; `ProcessActions.guardrail` is the first, and the one
    /// that logs.
    private let quitButton = NSButton(title: "Quit Process", target: nil, action: nil)
    private let killSheet = KillSheet()
    private let inspectorSheet = ProcessInspectorSheet()

    /// §8.3's default: CPU % descending.
    private var sortKey: ProcessSortKey = .cpu
    private var ascending = false
    private var searchQuery = ""

    private var model = ProcessesModel(rows: [], totalCount: 0, shownCount: 0, countText: "")
    /// §8.7: the identity selection is keyed on, tracked independently of row index so a
    /// re-sort can find the same process again after the table reorders under it.
    private var selectedPID: Int32?

    /// §8.2's icons, cached by path: a live PID's path cannot change, so the icon cannot
    /// either -- §5.5.4's argument for the name cache, applied here.
    private var iconCache: [String: NSImage] = [:]

    private var theme: Theme { ThemeStore.shared.theme }

    init(store: MetricStore, state: AppState) {
        self.store = store
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // MARK: - View construction

    override func loadView() {
        let root = KeyCommandView()
        root.onCommandF = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.searchField)
        }
        root.onCommandDelete = { [weak self] in self?.attemptQuitSelected() }
        root.onCommandI = { [weak self] in self?.showInspectorForSelection() }
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.cgColor(hex: theme.background)

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search"
        // Fires on every keystroke rather than only on Return -- §8.4: "it does not stop the
        // table from updating," which only holds if the field reports text as it is typed.
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.delegate = self

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .center
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        cadenceLabel.translatesAutoresizingMaskIntoConstraints = false
        cadenceLabel.alignment = .right
        cadenceLabel.font = .systemFont(ofSize: 11)
        cadenceLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        quitButton.translatesAutoresizingMaskIntoConstraints = false
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.target = self
        quitButton.action = #selector(quitButtonClicked)
        quitButton.isEnabled = false
        quitButton.toolTip = "Select a process to quit it"

        toolbar.addSubview(searchField)
        toolbar.addSubview(countLabel)
        toolbar.addSubview(quitButton)
        toolbar.addSubview(cadenceLabel)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.documentView = tableView

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.headerView = NSTableHeaderView()

        root.addSubview(toolbar)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // §8.1's 44 pt toolbar.
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            searchField.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            searchField.widthAnchor.constraint(equalToConstant: 240),

            countLabel.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            countLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            cadenceLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            cadenceLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            quitButton.trailingAnchor.constraint(equalTo: cadenceLabel.leadingAnchor, constant: -12),
            quitButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureColumns()
        restoreColumnWidths()
        observeColumnResize()
        cadenceLabel.stringValue = "1 Hz"
        countLabel.stringValue = model.countText

        // §8.5 item 1's ⌫ trigger (⌘⌫ is `KeyCommandView.onCommandDelete`, set in `loadView()`).
        tableView.onDelete = { [weak self] in self?.attemptQuitSelected() }

        // §8.6: double-click or ⌘I opens the read-only inspector.
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked)

        let menu = NSMenu()
        menu.delegate = self
        // Every item's state is set by hand in `menuNeedsUpdate`. Left at its default, AppKit's
        // own validation pass runs afterwards and re-enables any item whose target responds to
        // its action -- which silently undid the guardrail's first layer in 1.1.0 (§14.9).
        menu.autoenablesItems = false
        let quitItem = NSMenuItem(title: "Quit Process", action: #selector(contextQuitProcess(_:)), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)
        tableView.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    /// §7.3's live-apply. `ProcessRowView`'s own `drawSelection(in:)` already reads
    /// `ThemeStore.shared` fresh on every draw, so `reloadData()` (which redraws rows) covers
    /// it; the cell-colouring path re-colours on every call, same fix as the other panes'.
    @objc private func handleThemeDidChange() {
        view.layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        countLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        cadenceLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        tableView.reloadData()
    }

    // MARK: - §3.3's visibility hooks

    /// Starts a 1 Hz poll of the store's existing process stream. The provider itself keeps
    /// sampling regardless (§3.3 exempts it), so what starts and stops here is the
    /// projection, the diff and the redraw -- the cost that actually exists.
    func paneDidBecomeVisible() {
        // §12.3's hand-off. The parked PID becomes §8.7's selection identity, and `render(_:)`
        // selects and scrolls to it exactly as it does after a re-sort — on the first frame that
        // has rows, whether that is the cached model or the first awaited sample. §8.4's filter is
        // cleared the way Esc clears it: a row promised by another pane must not arrive hidden.
        //
        // Above the `pollTask` guard deliberately: on a repeat visit the guard returns early, and
        // a PID consumed below it would stay parked and fire on some unrelated later visit.
        if let pid = state.pendingProcessPID {
            state.pendingProcessPID = nil
            selectedPID = pid
            searchField.stringValue = ""
            searchQuery = ""
            // Re-project rather than re-render: `model` is the last *filtered* projection, so
            // redrawing it would keep the rows the cleared filter just removed. On a first
            // visit `lastSample` is nil and this returns early — the selection then lands with
            // the first frame, which is an actor hop away, not a 1 s wait.
            reprojectAndRender()
        }
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let frame = await self.store.processFrame()
                self.handle(frame)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func paneDidResignVisible() {
        pollTask?.cancel()
        pollTask = nil
        // §8.5 item 5's poll must not outlive this pane -- a 5 s timer that fires after the
        // user has switched away would open a sheet over whatever pane they are looking at.
        killSheet.cancelPendingPoll()
    }

    private func handle(_ frame: MetricStore.Frame<ProcessSample>) {
        guard let sample = frame.current else { return }
        lastSample = sample
        reprojectAndRender()
    }

    private func reprojectAndRender() {
        guard let sample = lastSample else { return }
        render(ProcessesModel.project(sample, sort: sortKey, ascending: ascending, search: searchQuery))
    }

    // MARK: - §8.1 toolbar actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        reprojectAndRender()
    }

    // MARK: - §8.6's read-only inspector

    @objc private func tableViewDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < model.rows.count else { return }
        showInspector(for: model.rows[row])
    }

    private func showInspectorForSelection() {
        guard let pid = selectedPID, let row = model.rows.first(where: { $0.pid == pid }) else { return }
        showInspector(for: row)
    }

    /// One-shot: `ProcessesModel.inspector(for:in:)` reads live syscalls exactly once, here,
    /// against `lastSample` -- never on a timer under the sheet (§8.6 item 4).
    private func showInspector(for detail: ProcessRowDetail) {
        guard let window = view.window, let sample = lastSample,
              let row = sample.rows.first(where: { $0.pid == detail.pid }) else { return }
        let inspectorModel = ProcessesModel.inspector(for: row, in: sample)
        inspectorSheet.present(name: detail.name, model: inspectorModel, in: window)
    }

    // MARK: - §8.5's kill flow

    @objc private func quitButtonClicked() {
        attemptQuitSelected()
    }

    @objc private func contextQuitProcess(_ sender: NSMenuItem) {
        let row = tableView.clickedRow
        guard row >= 0, row < model.rows.count else { return }
        presentKillSheet(for: model.rows[row])
    }

    private func attemptQuitSelected() {
        guard let pid = selectedPID, let row = model.rows.first(where: { $0.pid == pid }) else { return }
        presentKillSheet(for: row)
    }

    private func presentKillSheet(for row: ProcessRowDetail) {
        // The second guardrail layer: the toolbar item and context menu item are already
        // disabled for PID 0/1, but a disabled control is not a guarantee -- 1.3's
        // `ProcessActions.guardrail` inside `attempt(...)` is the one that actually blocks
        // and logs, and this re-check is what keeps the sheet itself from ever opening for
        // an unkillable PID in the first place.
        guard let window = view.window, !ProcessActions.guardrail(pid: row.pid) else { return }
        killSheet.confirmQuit(row, in: window) { [weak self] pid in
            self?.removeRowImmediately(pid: pid)
        }
    }

    /// §8.5 item 6: `ESRCH` "closes the sheet silently and removes the row" -- patches the
    /// cached sample so the row disappears immediately rather than waiting up to a second for
    /// the pane's own 1 Hz poll to notice the PID is gone.
    private func removeRowImmediately(pid: Int32) {
        guard let sample = lastSample, sample.rows.contains(where: { $0.pid == pid }) else { return }
        let filteredRows = sample.rows.filter { $0.pid != pid }
        lastSample = ProcessSample(
            rows: filteredRows,
            totalCount: max(0, sample.totalCount - 1),
            inspectableCount: max(0, sample.inspectableCount - 1),
            enumerationMilliseconds: sample.enumerationMilliseconds
        )
        reprojectAndRender()
    }

    /// Enabled only with a selected row that is not PID 0/1 (§8.5's guardrail, the second
    /// layer). Re-evaluated on every selection change and every refresh, since a refresh can
    /// remove the selected row out from under the button.
    private func updateQuitButtonState() {
        guard let pid = selectedPID, let row = model.rows.first(where: { $0.pid == pid }) else {
            quitButton.isEnabled = false
            quitButton.toolTip = "Select a process to quit it"
            return
        }
        if ProcessActions.guardrail(pid: row.pid) {
            quitButton.isEnabled = false
            quitButton.toolTip = "This process cannot be quit."
        } else {
            quitButton.isEnabled = true
            quitButton.toolTip = nil
        }
    }

    // MARK: - §8.2 columns

    private struct ColumnSpec {
        let key: ProcessSortKey
        let title: String
        let width: CGFloat
        let minWidth: CGFloat?
    }

    private static let columnSpecs: [ColumnSpec] = [
        ColumnSpec(key: .pid, title: "PID", width: 60, minWidth: nil),
        ColumnSpec(key: .name, title: "Name", width: 220, minWidth: 180),
        ColumnSpec(key: .cpu, title: "CPU %", width: 70, minWidth: nil),
        ColumnSpec(key: .memory, title: "Memory", width: 90, minWidth: nil),
        ColumnSpec(key: .threads, title: "Threads", width: 60, minWidth: nil),
        ColumnSpec(key: .user, title: "User", width: 110, minWidth: nil),
        ColumnSpec(key: .energy, title: "Energy", width: 70, minWidth: nil),
        ColumnSpec(key: .path, title: "Path", width: 240, minWidth: 200),
    ]

    /// §4.10: Simple mode's column titles. Widths, identifiers, sort keys and cell contents are
    /// the same in both modes -- only the header words change.
    private static let simpleTitles: [String: String] = [
        // "Processor %" does not fit §8.2's 70 pt CPU column once the sort chevron takes its
        // share, and a truncated header reads worse than a technical one. "CPU use" fits.
        "PID": "ID", "CPU %": "CPU use", "Energy": "Battery use", "Path": "Location",
    ]

    /// Called from `render(_:)` once a second; writes a header only when its word changes.
    private func applyColumnTitles() {
        let simple = state.displayMode == .simple
        // Keyed by identifier, never by position: §8.2's columns are user-reorderable, so a
        // zip over `tableColumns` would retitle the wrong header after a drag.
        for spec in Self.columnSpecs {
            let id = NSUserInterfaceItemIdentifier(spec.key.rawValue)
            guard let index = tableView.tableColumns.firstIndex(where: { $0.identifier == id }) else { continue }
            let column = tableView.tableColumns[index]
            let title = simple ? (Self.simpleTitles[spec.title] ?? spec.title) : spec.title
            if column.title != title { column.title = title }
        }
    }

    private func configureColumns() {
        for spec in Self.columnSpecs {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.key.rawValue))
            column.title = spec.title
            column.width = spec.width
            if let minWidth = spec.minWidth {
                column.minWidth = minWidth
                column.resizingMask = [.userResizingMask, .autoresizingMask]
            } else {
                column.resizingMask = .userResizingMask
            }
            tableView.addTableColumn(column)
        }
        updateSortIndicators()
    }

    private static func font(for key: ProcessSortKey) -> NSFont {
        switch key {
        case .pid, .cpu, .memory, .threads, .energy:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .name, .user, .path:
            return .systemFont(ofSize: 11, weight: .regular)
        }
    }

    private static func alignment(for key: ProcessSortKey) -> NSTextAlignment {
        switch key {
        case .pid, .cpu, .memory, .threads, .energy: return .right
        case .name, .user, .path: return .left
        }
    }

    private static func text(for key: ProcessSortKey, in detail: ProcessRowDetail) -> String {
        switch key {
        case .pid: return detail.pidText
        case .name: return detail.name
        case .cpu: return detail.cpuText
        case .memory: return detail.memoryText
        case .threads: return detail.threadsText
        case .user: return detail.userText
        case .energy: return detail.energyText
        case .path: return detail.pathText
        }
    }

    /// §8.2's icon: `NSWorkspace.shared.icon(forFile:)`, resolved only for rows this method is
    /// actually called for -- `tableView(_:viewFor:row:)` is only invoked for visible rows,
    /// which is what keeps this to a handful of lookups rather than one per process.
    private func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    private func cellView(for key: ProcessSortKey) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return recycled
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.font = Self.font(for: key)
        label.alignment = Self.alignment(for: key)
        // §8.2: the Name column truncates with a middle ellipsis, the Path column with a
        // head ellipsis -- the same convention §4.3.3's `ProcessRowsLayer` uses.
        label.lineBreakMode = key == .path ? .byTruncatingHead : (key == .name ? .byTruncatingMiddle : .byClipping)
        label.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        if key == .name {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            cell.addSubview(imageView)
            cell.imageView = imageView
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        return cell
    }

    // MARK: - §8.2 column width persistence

    private static let columnsDefaultsKey = "processes.columns"

    private func restoreColumnWidths() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.columnsDefaultsKey) as? [String: Double] else { return }
        for column in tableView.tableColumns {
            if let width = saved[column.identifier.rawValue] {
                column.width = CGFloat(width)
            }
        }
    }

    private func observeColumnResize() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(columnDidResize),
            name: NSTableView.columnDidResizeNotification, object: tableView
        )
    }

    @objc private func columnDidResize(_ notification: Notification) {
        var widths: [String: Double] = [:]
        for column in tableView.tableColumns {
            widths[column.identifier.rawValue] = Double(column.width)
        }
        UserDefaults.standard.set(widths, forKey: Self.columnsDefaultsKey)
    }

    // MARK: - §8.3 sort

    private func updateSortIndicators() {
        for column in tableView.tableColumns {
            guard let key = ProcessSortKey(rawValue: column.identifier.rawValue) else { continue }
            guard key == sortKey else {
                tableView.setIndicatorImage(nil, in: column)
                continue
            }
            let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .regular)
            let image = NSImage(
                systemSymbolName: ascending ? "chevron.up" : "chevron.down", accessibilityDescription: nil
            )?.withSymbolConfiguration(config)
            image?.isTemplate = true
            tableView.setIndicatorImage(image, in: column)
            tableView.highlightedTableColumn = column
        }
    }

    // MARK: - §8.7 render: diff, reselect, restore scroll

    /// Renders a new projection against the currently-displayed one. §8.7's contract, in
    /// order: capture identity and scroll before touching anything, update the structure with
    /// an animated diff (never `reloadData()`, which would destroy both), restore the scroll
    /// origin, then reselect by PID -- scrolling the row into view only if it moved off
    /// screen, and clearing the selection without moving the scroll if the PID is gone.
    private func render(_ newModel: ProcessesModel) {
        applyColumnTitles()
        let previousPIDs = model.rows.map(\.pid)
        let selectedPIDBefore = selectedPID
        let scrollOrigin = scrollView.contentView.bounds.origin

        model = newModel
        countLabel.stringValue = model.countText

        if previousPIDs.isEmpty {
            // Nothing to preserve on first population (or after the table was emptied), so
            // a plain reload is correct rather than an animated insert of hundreds of rows.
            tableView.reloadData()
        } else {
            let currentPIDs = model.rows.map(\.pid)
            applyDiff(previous: previousPIDs, current: currentPIDs)
            if !model.rows.isEmpty {
                tableView.reloadData(
                    forRowIndexes: IndexSet(model.rows.indices),
                    columnIndexes: IndexSet(0..<tableView.tableColumns.count)
                )
            }
        }

        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if let selectedPIDBefore, let index = ProcessesModel.selectionIndex(of: selectedPIDBefore, in: model.rows) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let rowRect = tableView.rect(ofRow: index)
            if !scrollView.documentVisibleRect.intersects(rowRect) {
                tableView.scrollRowToVisible(index)
            }
        } else {
            tableView.deselectAll(nil)
        }
        updateQuitButtonState()
    }

    /// §8.3: diffs the previous and current PID order and drives `insertRows`/`removeRows`/
    /// `moveRow` inside one 250 ms animated update, so a process exiting fades out rather than
    /// leaving a silent gap and a process entering fades in at its sorted position.
    private func applyDiff(previous: [Int32], current: [Int32]) {
        let previousSet = Set(previous)
        let currentSet = Set(current)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            tableView.beginUpdates()

            let removed = IndexSet(previous.enumerated().compactMap { currentSet.contains($0.element) ? nil : $0.offset })
            if !removed.isEmpty {
                tableView.removeRows(at: removed, withAnimation: .effectFade)
            }

            var interim = previous.filter { currentSet.contains($0) }

            let inserted = IndexSet(current.enumerated().compactMap { previousSet.contains($0.element) ? nil : $0.offset })
            if !inserted.isEmpty {
                tableView.insertRows(at: inserted, withAnimation: .effectFade)
                for index in inserted.sorted() {
                    interim.insert(current[index], at: min(index, interim.count))
                }
            }

            // Every PID both sides share is now present in `interim`, possibly in the wrong
            // relative order; walk the target order left to right and move whatever is out
            // of place. Not the minimal edit sequence, but every move is a real, animated
            // `NSTableRowView` reposition and a no-op costs nothing (§8.3's cost is measured
            // in 5.1, not tuned here).
            for targetIndex in current.indices {
                let pid = current[targetIndex]
                guard let sourceIndex = interim.firstIndex(of: pid), sourceIndex != targetIndex else { continue }
                tableView.moveRow(at: sourceIndex, to: targetIndex)
                interim.remove(at: sourceIndex)
                interim.insert(pid, at: targetIndex)
            }

            tableView.endUpdates()
        }
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ProcessesPaneController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        model.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let key = ProcessSortKey(rawValue: column.identifier.rawValue),
              row < model.rows.count else { return nil }
        let detail = model.rows[row]
        let cell = cellView(for: key)
        // Set on every call, not only at creation -- `cellView(for:)` returns a recycled cell
        // early, and a recycled cell must pick up a theme change too.
        cell.textField?.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        cell.textField?.stringValue = Self.text(for: key, in: detail)
        if key == .name {
            cell.imageView?.image = detail.path.map(icon(for:))
        }
        return cell
    }

    /// §8.2's alternating row backgrounds and selected-row fill, drawn by a custom row view
    /// rather than `usesAlternatingRowBackgroundColors` -- the tokens are §7.2/spec-literal
    /// hex, not AppKit's system alternating colors, and the selected row also needs the 2 pt
    /// leading accent bar §8.2 asks for.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("processRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? TableRowView) ?? TableRowView()
        rowView.identifier = identifier
        rowView.isEvenRow = row.isMultiple(of: 2)
        return rowView
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let key = ProcessSortKey(rawValue: tableColumn.identifier.rawValue) else { return }
        if key == sortKey {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = true
        }
        updateSortIndicators()
        reprojectAndRender()
    }

    /// §8.7's identity, kept current on every user-driven selection change (this fires for
    /// `render(_:)`'s own programmatic `selectRowIndexes`/`deselectAll` too, harmlessly).
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedPID = (row >= 0 && row < model.rows.count) ? model.rows[row].pid : nil
        updateQuitButtonState()
    }
}

// MARK: - Context menu validation (§8.5's second guardrail layer)

extension ProcessesPaneController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        applyMenuState(to: menu, forRow: tableView.clickedRow)
    }

    /// `menuNeedsUpdate`'s body keyed by an explicit row, so `paneSelfCheck()` can drive the real
    /// menu item -- `tableView.clickedRow` has no public setter.
    private func applyMenuState(to menu: NSMenu, forRow row: Int) {
        guard row >= 0, row < model.rows.count, !ProcessActions.guardrail(pid: model.rows[row].pid) else {
            menu.items.first?.isEnabled = false
            return
        }
        menu.items.first?.isEnabled = true
    }

    // MARK: - Gate 12's structural arm (added 2026-09-21, §14.9)

    /// §8.5's first guardrail layer, asserted against the live `NSMenuItem` after AppKit's own
    /// validation pass rather than against the value this controller computed. `Quit Process`
    /// read enabled on `launchd` in the notarized 1.1.0 build for exactly that reason; the
    /// second layer (`ProcessActions.attempt`'s `blocked-guardrail`) held, so nothing could be
    /// killed, but the control the spec calls disabled was live.
    static func paneSelfCheck() -> [PaneAssertion] {
        let controller = ProcessesPaneController(store: MetricStore(), state: AppState())
        controller.view.frame = CGRect(x: 0, y: 0, width: 1172, height: 778)
        controller.view.layoutSubtreeIfNeeded()

        func fixtureRow(pid: Int32, name: String) -> ProcessRowDetail {
            ProcessRowDetail(
                pid: pid, uid: pid == 1 ? 0 : 501, path: "/usr/bin/fixture", pidText: "\(pid)",
                name: name, cpuText: "0.0%", memoryText: "1 MB", threadsText: "1",
                userText: pid == 1 ? "root" : "fixture", energyText: Format.unknown,
                pathText: "/usr/bin/fixture"
            )
        }
        controller.model = ProcessesModel(
            rows: [fixtureRow(pid: 1, name: "launchd"), fixtureRow(pid: 4242, name: "fixture")],
            totalCount: 2, shownCount: 2, countText: ""
        )
        guard let menu = controller.tableView.menu else {
            return [PaneAssertion(name: "processes-context-menu-exists", pass: false, detail: "menu=nil")]
        }

        controller.applyMenuState(to: menu, forRow: 0)
        menu.update()
        let launchd = menu.items.first?.isEnabled
        controller.applyMenuState(to: menu, forRow: 1)
        menu.update()
        let ordinary = menu.items.first?.isEnabled

        return [
            PaneAssertion(
                name: "processes-quit-item-stays-disabled-for-launchd-after-appkit-validation",
                pass: launchd == false,
                detail: "enabled=\(launchd.map(String.init) ?? "nil")"
            ),
            PaneAssertion(
                name: "processes-quit-item-is-enabled-for-an-ordinary-process",
                pass: ordinary == true,
                detail: "enabled=\(ordinary.map(String.init) ?? "nil")"
            ),
        ]
    }
}

// MARK: - §8.4's Esc: clear the field and return focus to the table

extension ProcessesPaneController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        searchField.stringValue = ""
        searchQuery = ""
        reprojectAndRender()
        view.window?.makeFirstResponder(tableView)
        return true
    }
}

/// §8.5 item 1's ⌫ trigger. A plain `NSTableView` has no delete-key behaviour of its own to
/// override, so this is the minimal subclass that lets the pane catch it while a row is
/// selected and the table holds first responder.
private final class ProcessesTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        guard event.specialKey == .delete || event.keyCode == 51 else {
            super.keyDown(with: event)
            return
        }
        onDelete?()
    }
}
