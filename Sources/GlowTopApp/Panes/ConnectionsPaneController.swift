import AppKit
import Darwin
import GlowTopCore

/// SPEC.md §14.5's Connections pane: §8's table chrome reused verbatim (`TableChrome.swift`),
/// filled with §14.5's own six columns. 4.2 built the skeleton -- toolbar, columns, an empty
/// table; this file wires the poll loop, sort, search, the four D-28 states and the one
/// `Show Process` hand-off (D-14).
@MainActor
final class ConnectionsPaneController: NSViewController, PaneController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: MetricStore
    private let appState: AppState

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let cadenceLabel = NSTextField(labelWithString: "1 Hz")
    private let footerLabel = NSTextField(wrappingLabelWithString: "")
    /// D-28's empty-body / unavailable-body text, centred over the table, hidden while rows
    /// are showing. One label carries both strings -- they never appear at once.
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")

    private var pollTask: Task<Void, Never>?
    /// D-10's stale-frame guard: a frame sampled before this visit began is a leftover from a
    /// previous visit sitting in the store's slot (nothing re-samples between visits) and must
    /// not be shown as current.
    private var visibleSince: ContinuousClock.Instant?
    private var lastSample: ConnectionsSample?

    /// D-13's default: Process ascending.
    private var sortKey: ConnectionSortKey = .process
    private var ascending = true
    private var searchQuery = ""

    private var model = ConnectionsModel(rows: [], totalCount: 0, shownCount: 0, countText: "", footerText: "", emptyBodyText: "")
    /// D-13's identity: `(pid, fd)`, not row index -- `ConnectionsModel.selectionIndex(of:in:)`
    /// matches on this key after every re-sort or re-poll.
    private var selectedKey: String?

    /// The Process column's icon, resolved from the row's executable path and cached by path
    /// (discretion table) -- `pathCache` avoids repeating the `proc_pidpath` syscall for every
    /// row that shares a PID.
    private var pathCache: [Int32: String?] = [:]
    private var iconCache: [String: NSImage] = [:]

    private var theme: Theme { ThemeStore.shared.theme }

    init(store: MetricStore, state: AppState) {
        self.store = store
        self.appState = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    // §3.3. Declared in the type body, not an extension (F-7).

    /// Starts the poll loop against `store.connectionsFrame()` at the cadence CONN-05's
    /// reading set (1 Hz -- the warm median landed in the ≤ 25 ms band, `MetricStore.swift`'s
    /// `slowLoop()` comment). The store only samples sockets while this pane is `activePane`
    /// (F-4's gate, D-10), so this hook is also what turns sampling on.
    func paneDidBecomeVisible() {
        visibleSince = ContinuousClock().now
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let frame = await self.store.connectionsFrame()
                self.handle(frame)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func paneDidResignVisible() {
        pollTask?.cancel()
        pollTask = nil
        visibleSince = nil
    }

    // MARK: - View construction

    override func loadView() {
        let root = KeyCommandView()
        root.onCommandF = { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.searchField)
        }
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
        searchField.delegate = self

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .center
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        cadenceLabel.translatesAutoresizingMaskIntoConstraints = false
        cadenceLabel.alignment = .right
        cadenceLabel.font = .systemFont(ofSize: 11)
        cadenceLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        toolbar.addSubview(searchField)
        toolbar.addSubview(countLabel)
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

        let menu = NSMenu()
        menu.delegate = self
        // Every item's state is set by hand in `menuNeedsUpdate`. Left at its default, AppKit's
        // own validation pass runs afterwards and re-enables any item whose target responds to
        // its action -- which silently undid the guardrail's first layer in 1.1.0 (§14.9).
        menu.autoenablesItems = false
        let showItem = NSMenuItem(title: "Show Process", action: #selector(showProcessSelected), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        tableView.menu = menu

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.isHidden = true

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        root.addSubview(toolbar)
        root.addSubview(scrollView)
        root.addSubview(bodyLabel)
        root.addSubview(footerLabel)

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

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerLabel.topAnchor, constant: -8),

            bodyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            bodyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            bodyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            bodyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),

            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footerLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureColumns()
        restoreColumnWidths()
        observeColumnResize()
        updateSortIndicators()
        cadenceLabel.stringValue = "1 Hz"
        countLabel.stringValue = ""
        footerLabel.stringValue = ""

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    @objc private func handleThemeDidChange() {
        view.layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        countLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        cadenceLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        tableView.reloadData()
    }

    // MARK: - D-28's four states

    /// Discards a frame sampled before this visit began (D-10), then dispatches on
    /// `frame.state`: warming clears the table and shows `···`; unavailable clears it and
    /// shows §5.0.5's reason; live and stalled reproject the sample, stalled additionally
    /// dimming the whole table to 35 % rather than clearing it.
    private func handle(_ frame: MetricStore.Frame<ConnectionsSample>) {
        if let sampledAt = frame.sampledAt, let visibleSince, sampledAt < visibleSince { return }

        switch frame.state {
        case .warming:
            lastSample = nil
            tableView.alphaValue = 1
            bodyLabel.isHidden = true
            countLabel.stringValue = "···"
            footerLabel.stringValue = ""
            model = ConnectionsModel(rows: [], totalCount: 0, shownCount: 0, countText: "···", footerText: "", emptyBodyText: "")
            tableView.reloadData()

        case .unavailable(let reason):
            lastSample = nil
            tableView.alphaValue = 1
            countLabel.stringValue = Format.unknown
            footerLabel.stringValue = reason
            bodyLabel.stringValue = "Unavailable on this Mac"
            bodyLabel.textColor = NSColor(cgColor: theme.cgColor("textDisabled")) ?? .disabledControlTextColor
            bodyLabel.isHidden = false
            model = ConnectionsModel(rows: [], totalCount: 0, shownCount: 0, countText: Format.unknown, footerText: reason, emptyBodyText: "")
            tableView.reloadData()

        case .live, .stalled:
            tableView.alphaValue = frame.state == .stalled ? 0.35 : 1
            guard let sample = frame.current else { return }
            lastSample = sample
            reprojectAndRender()
        }
    }

    private func reprojectAndRender() {
        guard let sample = lastSample else { return }
        render(ConnectionsModel.project(sample, sort: sortKey, ascending: ascending, search: searchQuery))
    }

    // MARK: - §8.1 toolbar actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        reprojectAndRender()
    }

    // MARK: - D-14/F-11's one context action

    @objc private func showProcessSelected() {
        let row = tableView.clickedRow
        guard row >= 0, row < model.rows.count else { return }
        appState.pendingProcessPID = model.rows[row].pid
        appState.selectedPane = .processes
    }

    // MARK: - §14.5's six columns (UI-SPEC locked values)

    private struct ColumnSpec {
        let key: ConnectionSortKey
        let title: String
        let width: CGFloat
        let minWidth: CGFloat?
    }

    private static let columnSpecs: [ColumnSpec] = [
        ColumnSpec(key: .process, title: "Process", width: 200, minWidth: 160),
        ColumnSpec(key: .pid, title: "PID", width: 60, minWidth: nil),
        ColumnSpec(key: .proto, title: "Proto", width: 60, minWidth: nil),
        ColumnSpec(key: .local, title: "Local", width: 200, minWidth: 160),
        ColumnSpec(key: .remote, title: "Remote", width: 200, minWidth: 160),
        ColumnSpec(key: .state, title: "State", width: 110, minWidth: nil),
    ]

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
    }

    /// `PID`/`Proto`/`Local`/`Remote`/`State` are SF Mono (UI-SPEC); `Process` is SF Pro Text.
    private static func font(for key: ConnectionSortKey) -> NSFont {
        switch key {
        case .process: return .systemFont(ofSize: 11, weight: .regular)
        case .pid, .proto, .local, .remote, .state: return .monospacedSystemFont(ofSize: 11, weight: .regular)
        }
    }

    private static func alignment(for key: ConnectionSortKey) -> NSTextAlignment {
        switch key {
        case .pid: return .right
        case .process, .proto, .local, .remote, .state: return .left
        }
    }

    private static func text(for key: ConnectionSortKey, in detail: SocketRowDetail) -> String {
        switch key {
        case .process: return detail.processText
        case .pid: return detail.pidText
        case .proto: return detail.protoText
        case .local: return detail.localText
        case .remote: return detail.remoteText
        case .state: return detail.stateText
        }
    }

    /// D-04/discretion table: `proc_pidpath` resolved per PID and cached, never per row --
    /// rows sharing a PID (multiple sockets on one process) share the lookup.
    private static func resolvePath(pid: Int32) -> String? {
        let pathMax = 4 * Int(MAXPATHLEN)
        var buffer = [CChar](repeating: 0, count: pathMax)
        guard proc_pidpath(pid, &buffer, UInt32(pathMax)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private func icon(forPID pid: Int32) -> NSImage? {
        let path: String?
        if let cached = pathCache[pid] {
            path = cached
        } else {
            path = Self.resolvePath(pid: pid)
            pathCache[pid] = path
        }
        guard let path else { return nil }
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    private func cellView(for key: ConnectionSortKey) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return recycled
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.font = Self.font(for: key)
        label.alignment = Self.alignment(for: key)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label

        if key == .process {
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

    // MARK: - §14.5 column width persistence (own key, D-16)

    private static let columnsDefaultsKey = "connections.columns"

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

    // MARK: - Sort

    private func updateSortIndicators() {
        for column in tableView.tableColumns {
            guard let key = ConnectionSortKey(rawValue: column.identifier.rawValue) else { continue }
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

    // MARK: - Render: reload, restore scroll, reselect by (pid, fd)

    /// D-13's identity is `(pid, fd)`, never row index -- `ConnectionsModel.selectionIndex(of:in:)`
    /// finds the same socket again after a re-sort or the next poll's reorder. `reloadData()`,
    /// not `applyDiff` (discretion table): sockets do not reorder under a live sort at 1 Hz the
    /// way processes do.
    private func render(_ newModel: ConnectionsModel) {
        let selectedKeyBefore = selectedKey
        let scrollOrigin = scrollView.contentView.bounds.origin

        model = newModel
        countLabel.stringValue = model.countText
        footerLabel.stringValue = model.footerText

        if model.rows.isEmpty && !model.emptyBodyText.isEmpty {
            bodyLabel.stringValue = model.emptyBodyText
            bodyLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
            bodyLabel.isHidden = false
        } else {
            bodyLabel.isHidden = true
        }

        tableView.reloadData()

        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if let selectedKeyBefore, let index = ConnectionsModel.selectionIndex(of: selectedKeyBefore, in: model.rows) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            let rowRect = tableView.rect(ofRow: index)
            if !scrollView.documentVisibleRect.intersects(rowRect) {
                tableView.scrollRowToVisible(index)
            }
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    // MARK: - Gate 12's structural arm (5.1, D-31, override O-4)

    /// Five assertions over a controller built without a window: both new panes are
    /// `NSTableView`s, so their structure -- columns, row count, label strings -- is what
    /// correctness *is*, and `renderPaneOffscreen`'s `CALayer` pixel scan has nothing to do
    /// with AppKit's table drawing. `render(_:)` and `handle(_:)` are called directly,
    /// bypassing the store poll loop entirely.
    static func paneSelfCheck() -> [PaneAssertion] {
        let controller = ConnectionsPaneController(store: MetricStore(), state: AppState())
        controller.view.frame = CGRect(x: 0, y: 0, width: 1172, height: 778)
        controller.view.layoutSubtreeIfNeeded()
        var results: [PaneAssertion] = []

        let expectedColumns = ConnectionSortKey.allCases.map(\.rawValue).sorted()
        let actualColumns = controller.tableView.tableColumns.map(\.identifier.rawValue).sorted()
        results.append(PaneAssertion(
            name: "connections-columns-match-the-locked-set",
            pass: actualColumns == expectedColumns,
            detail: "columns=\(actualColumns.joined(separator: ","))"
        ))

        // No row is clicked in a windowless controller, so `Show Process` must read disabled --
        // and must still read disabled after AppKit's own validation pass (§14.9, 2026-09-21).
        if let menu = controller.tableView.menu {
            controller.menuNeedsUpdate(menu)
            menu.update()
            let live = menu.items.first?.isEnabled
            results.append(PaneAssertion(
                name: "connections-show-process-stays-disabled-after-appkit-validation",
                pass: live == false,
                detail: "enabled=\(live.map(String.init) ?? "nil")"
            ))
        }

        let liveRows = [
            SocketRowDetail(key: "1:0", pid: 1, processText: "launchd", pidText: "1", protoText: "TCP",
                            localText: "127.0.0.1:1000", remoteText: Format.unknown, stateText: "LISTEN"),
            SocketRowDetail(key: "2:0", pid: 2, processText: "sshd", pidText: "2", protoText: "TCP",
                            localText: "127.0.0.1:22", remoteText: "10.0.0.5:5000", stateText: "ESTABLISHED"),
            SocketRowDetail(key: "3:0", pid: 3, processText: "mDNSResponder", pidText: "3", protoText: "UDP",
                            localText: "*:5353", remoteText: Format.unknown, stateText: Format.unknown),
        ]
        let liveModel = ConnectionsModel(
            rows: liveRows, totalCount: 3, shownCount: 3,
            countText: "3 sockets · 3 processes · 3 shown",
            footerText: "3 of 3 processes inspected · sockets of the other 0 are not listed",
            emptyBodyText: ""
        )
        controller.render(liveModel)
        results.append(PaneAssertion(
            name: "connections-rows-render-live-fixture",
            pass: controller.numberOfRows(in: controller.tableView) == 3,
            detail: "rows=\(controller.numberOfRows(in: controller.tableView))"
        ))
        results.append(PaneAssertion(
            name: "connections-count-label-matches-the-model",
            pass: controller.countLabel.stringValue == liveModel.countText,
            detail: "label=\(controller.countLabel.stringValue)"
        ))

        let emptySample = ConnectionsSample(rows: [], pidCount: 608, inspectedPIDCount: 608, enumerationMilliseconds: 5)
        let emptyModel = ConnectionsModel.project(emptySample, sort: .process, ascending: true, search: "")
        controller.render(emptyModel)
        let expectedEmptyBody = "No open TCP or UDP sockets among the 608 processes this user can inspect"
        results.append(PaneAssertion(
            name: "connections-empty-body-appears-on-a-zero-row-fixture",
            pass: controller.bodyLabel.stringValue == expectedEmptyBody,
            detail: "body=\(controller.bodyLabel.stringValue)"
        ))

        controller.handle(MetricStore.Frame<ConnectionsSample>(
            previous: nil, current: nil, sampledAt: nil, interval: SampleRate.hz1,
            state: .unavailable(reason: "kernel call failed: proc_listallpids")
        ))
        let unavailableBody = controller.bodyLabel.stringValue
        results.append(PaneAssertion(
            name: "connections-unavailable-body-appears-and-differs-from-empty",
            pass: unavailableBody == "Unavailable on this Mac" && unavailableBody != expectedEmptyBody,
            detail: "body=\(unavailableBody)"
        ))

        return results
    }
}

// MARK: - NSTableViewDelegate

extension ConnectionsPaneController {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let key = ConnectionSortKey(rawValue: column.identifier.rawValue),
              row < model.rows.count else { return nil }
        let detail = model.rows[row]
        let cell = cellView(for: key)
        cell.textField?.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        cell.textField?.stringValue = Self.text(for: key, in: detail)
        if key == .process {
            cell.imageView?.image = icon(forPID: detail.pid)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("connectionRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? TableRowView) ?? TableRowView()
        rowView.identifier = identifier
        rowView.isEvenRow = row.isMultiple(of: 2)
        return rowView
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let key = ConnectionSortKey(rawValue: tableColumn.identifier.rawValue) else { return }
        if key == sortKey {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = true
        }
        updateSortIndicators()
        reprojectAndRender()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedKey = (row >= 0 && row < model.rows.count) ? model.rows[row].key : nil
    }
}

// MARK: - Context menu validation

extension ConnectionsPaneController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = tableView.clickedRow
        menu.items.first?.isEnabled = row >= 0 && row < model.rows.count
    }
}

// MARK: - Esc: clear the field and return focus to the table

extension ConnectionsPaneController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        searchField.stringValue = ""
        searchQuery = ""
        reprojectAndRender()
        view.window?.makeFirstResponder(tableView)
        return true
    }
}
