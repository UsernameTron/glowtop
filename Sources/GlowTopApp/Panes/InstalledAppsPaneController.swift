import AppKit
import GlowTopCore

/// SPEC.md §14.3's Installed Apps pane: §8's table chrome reused verbatim
/// (`TableChrome.swift`), filled with §14.3's own six columns. Pane-owned (D-18): no metrics
/// store dependency, not even in its initializer. D-23's lifecycle: a cancellable
/// `Task.detached` scan starts once on first visibility, `Rescan`/`Stop Scan` share one
/// button, and switching away cancels the in-flight scan rather than letting it run on
/// behind a released controller.
@MainActor
final class InstalledAppsPaneController: NSViewController, PaneController, NSTableViewDataSource, NSTableViewDelegate {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let rescanButton = NSButton(title: "Rescan", target: nil, action: nil)
    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")

    private var theme: Theme { ThemeStore.shared.theme }

    private var scanTask: Task<Void, Never>?
    /// Read from the detached scan's background thread inside `isCancelled`, so it cannot be
    /// `@MainActor`-isolated like the rest of this controller's state. Only ever transitions
    /// false -> true; a stale read costs at most one more bundle's walk before the next
    /// 512-file check inside `InstalledAppsReader.allocatedSize(of:)` observes it.
    nonisolated(unsafe) private var cancelled = false
    private var lastScan: InstalledAppsScan?

    /// D-25's default: Size descending.
    private var sortKey: InstalledAppSortKey = .size
    private var ascending = false
    private var searchQuery = ""
    /// §8.7's identity shape, keyed on bundle path rather than row index (D-25).
    private var selectedPath: String?

    private var model = InstalledAppsModel(rows: [], shownCount: 0, countText: "", footerNotes: [])

    /// §14.3's icon, cached by path -- a bundle's path cannot change mid-scan.
    private var iconCache: [String: NSImage] = [:]

    // MARK: - §3.3's visibility hooks (declared in the type body, not an extension -- F-7)

    func paneDidBecomeVisible() {
        // D-23: auto-start once, not on every revisit.
        guard scanTask == nil, lastScan == nil else { return }
        startScan()
    }

    func paneDidResignVisible() {
        cancelled = true
    }

    deinit {
        cancelled = true
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

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.alignment = .center
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.isHidden = true

        rescanButton.translatesAutoresizingMaskIntoConstraints = false
        rescanButton.bezelStyle = .rounded
        rescanButton.controlSize = .small
        rescanButton.target = self
        rescanButton.action = #selector(rescanButtonClicked)

        toolbar.addSubview(searchField)
        toolbar.addSubview(countLabel)
        toolbar.addSubview(progressIndicator)
        toolbar.addSubview(progressLabel)
        toolbar.addSubview(rescanButton)

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

        bodyLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyLabel.alignment = .center
        bodyLabel.font = .systemFont(ofSize: 11)
        bodyLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        bodyLabel.stringValue = "No applications in /Applications or ~/Applications"
        bodyLabel.isHidden = true

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.font = .systemFont(ofSize: 10)
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        footerLabel.lineBreakMode = .byWordWrapping
        footerLabel.maximumNumberOfLines = 0

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

            rescanButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            rescanButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            progressLabel.trailingAnchor.constraint(equalTo: rescanButton.leadingAnchor, constant: -12),
            progressLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            // §UI-SPEC's locked 120 pt `.small` progress bar.
            progressIndicator.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -8),
            progressIndicator.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 120),

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
        countLabel.stringValue = ""

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    @objc private func handleThemeDidChange() {
        view.layer?.backgroundColor = Theme.cgColor(hex: theme.background)
        countLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        progressLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        bodyLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        footerLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        tableView.reloadData()
    }

    // MARK: - D-23's scan lifecycle

    private func startScan() {
        cancelled = false
        rescanButton.title = "Stop Scan"
        progressIndicator.isHidden = false
        progressIndicator.doubleValue = 0
        progressLabel.stringValue = ""
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let scan = InstalledAppsReader.scan(
                progress: { done, total in
                    Task { @MainActor in self?.updateProgress(done, total) }
                },
                isCancelled: { [weak self] in self?.cancelled ?? true }
            )
            await MainActor.run { [weak self] in self?.handle(scan) }
        }
    }

    @objc private func rescanButtonClicked() {
        if scanTask != nil {
            cancelled = true
        } else {
            startScan()
        }
    }

    private func updateProgress(_ done: Int, _ total: Int) {
        progressIndicator.maxValue = Double(total)
        progressIndicator.doubleValue = Double(done)
        progressLabel.stringValue = "Scanning \(done) of \(total)…"
    }

    /// The simpler of the two shapes the plan left open: rows appear all at once, at
    /// completion or cancellation, with the progress bar as the only mid-scan feedback. Taken
    /// because nothing in 5.1's structural gate-12 arm needs an incremental row to assert
    /// against -- it reads the finished table, the same way `PaneSelfCheck` reads every other
    /// pane's structure post-render.
    private func handle(_ scan: InstalledAppsScan) {
        lastScan = scan
        scanTask = nil
        rescanButton.title = "Rescan"
        progressIndicator.isHidden = true
        progressLabel.stringValue = ""
        reprojectAndRender()
    }

    private func reprojectAndRender() {
        guard let lastScan else { return }
        render(InstalledAppsModel.project(lastScan, sort: sortKey, ascending: ascending, search: searchQuery))
    }

    // MARK: - Toolbar actions

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        searchQuery = sender.stringValue
        reprojectAndRender()
    }

    // MARK: - §14.3's six columns (UI-SPEC locked values)

    private struct ColumnSpec {
        let key: InstalledAppSortKey
        let title: String
        let width: CGFloat
        let minWidth: CGFloat?
    }

    private static let columnSpecs: [ColumnSpec] = [
        ColumnSpec(key: .name, title: "Name", width: 220, minWidth: 180),
        ColumnSpec(key: .version, title: "Version", width: 90, minWidth: nil),
        ColumnSpec(key: .bundleID, title: "Bundle ID", width: 220, minWidth: 200),
        ColumnSpec(key: .size, title: "Size", width: 90, minWidth: nil),
        ColumnSpec(key: .signing, title: "Signing", width: 220, minWidth: 200),
        ColumnSpec(key: .arch, title: "Architectures", width: 110, minWidth: nil),
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
        updateSortIndicators()
    }

    private static func font(for key: InstalledAppSortKey) -> NSFont {
        switch key {
        case .version, .size, .arch:
            return .monospacedSystemFont(ofSize: 11, weight: .regular)
        case .name, .bundleID, .signing:
            return .systemFont(ofSize: 11, weight: .regular)
        }
    }

    private static func alignment(for key: InstalledAppSortKey) -> NSTextAlignment {
        key == .size ? .right : .left
    }

    private static func text(for key: InstalledAppSortKey, in detail: InstalledAppDetail) -> String {
        switch key {
        case .name: return detail.nameText
        case .version: return detail.versionText
        case .bundleID: return detail.bundleIDText
        case .size: return detail.sizeText
        case .signing: return detail.signingText
        case .arch: return detail.archText
        }
    }

    /// §14.3's icon: `NSWorkspace.shared.icon(forFile:)`, cached by path -- `ProcessesPaneController`'s
    /// same three lines (the discretion table's choice).
    private func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = icon
        return icon
    }

    private func cellView(for key: InstalledAppSortKey) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(key.rawValue)
        if let recycled = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return recycled
        }

        let cell = NSTableCellView()
        cell.identifier = identifier

        let label = NSTextField(labelWithString: "")
        label.font = Self.font(for: key)
        label.alignment = Self.alignment(for: key)
        // Signing truncates its tail (UI-SPEC locked value -- long certificate summaries);
        // the other flexible text columns follow the same rule rather than clipping mid-word.
        label.lineBreakMode = key == .version || key == .size || key == .arch ? .byClipping : .byTruncatingTail
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

    // MARK: - Sort

    private func updateSortIndicators() {
        for column in tableView.tableColumns {
            guard let key = InstalledAppSortKey(rawValue: column.identifier.rawValue) else { continue }
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

    // MARK: - Render: reload, restore scroll, reselect by bundle path

    /// `reloadData()`, not `applyDiff` -- a one-shot scan's rows do not reorder under a live
    /// poll the way Processes' do (the same reasoning Connections' discretion entry gives).
    private func render(_ newModel: InstalledAppsModel) {
        let selectedPathBefore = selectedPath
        let scrollOrigin = scrollView.contentView.bounds.origin

        model = newModel
        countLabel.stringValue = model.countText
        footerLabel.stringValue = model.footerNotes.joined(separator: "  ")

        // D-29's empty state: a genuine zero-bundle scan, not merely a search with no matches,
        // and not a scan a footer note already explains (unreadable root / cancelled / partial).
        if (lastScan?.apps.isEmpty ?? false) && model.footerNotes.isEmpty {
            bodyLabel.isHidden = false
        } else {
            bodyLabel.isHidden = true
        }

        tableView.reloadData()

        scrollView.contentView.scroll(to: scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        if let selectedPathBefore, let index = model.rows.firstIndex(where: { $0.path == selectedPathBefore }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: - NSTableViewDataSource / NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int {
        model.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, let key = InstalledAppSortKey(rawValue: column.identifier.rawValue),
              row < model.rows.count else { return nil }
        let detail = model.rows[row]
        let cell = cellView(for: key)
        cell.textField?.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
        cell.textField?.stringValue = Self.text(for: key, in: detail)
        if key == .name {
            cell.imageView?.image = icon(for: detail.path)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("installedAppsRow")
        let rowView = (tableView.makeView(withIdentifier: identifier, owner: self) as? TableRowView) ?? TableRowView()
        rowView.identifier = identifier
        rowView.isEvenRow = row.isMultiple(of: 2)
        return rowView
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let key = InstalledAppSortKey(rawValue: tableColumn.identifier.rawValue) else { return }
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
        selectedPath = (row >= 0 && row < model.rows.count) ? model.rows[row].path : nil
    }

    // MARK: - Gate 12's structural arm (5.1, D-31, override O-4)

    /// Five assertions over a controller built without a window -- `ConnectionsPaneController`'s
    /// own arm, same reasoning (override O-4). `render(_:)` is called directly; `lastScan` stays
    /// `nil` throughout since nothing here goes through `handle(_:)`, which only affects the
    /// empty-body state this arm does not assert.
    static func paneSelfCheck() -> [PaneAssertion] {
        let controller = InstalledAppsPaneController()
        controller.view.frame = CGRect(x: 0, y: 0, width: 1172, height: 778)
        controller.view.layoutSubtreeIfNeeded()
        var results: [PaneAssertion] = []

        let expectedColumns = InstalledAppSortKey.allCases.map(\.rawValue).sorted()
        let actualColumns = controller.tableView.tableColumns.map(\.identifier.rawValue).sorted()
        results.append(PaneAssertion(
            name: "installedapps-columns-match-the-locked-set",
            pass: actualColumns == expectedColumns,
            detail: "columns=\(actualColumns.joined(separator: ","))"
        ))

        func fixtureApp(name: String, bundleID: String?, isUnparseable: Bool = false) -> InstalledApp {
            InstalledApp(bundlePath: "/Applications/\(name).app", name: name, version: "1.0",
                        bundleIdentifier: bundleID, allocatedBytes: 1024, signingIdentity: "Ad-hoc",
                        architectures: ["arm64"], isUnparseable: isUnparseable)
        }

        let threeApps = [
            fixtureApp(name: "Alpha", bundleID: "com.example.alpha"),
            fixtureApp(name: "Beta", bundleID: "com.example.beta"),
            fixtureApp(name: "Gamma", bundleID: "com.example.gamma"),
        ]
        let liveScan = InstalledAppsScan(apps: threeApps, scannedCount: 3, totalCount: 3, cancelled: false,
                                         unreadableRoots: [], millisecondsElapsed: 10)
        let liveModel = InstalledAppsModel.project(liveScan, sort: .size, ascending: false, search: "")
        controller.render(liveModel)
        results.append(PaneAssertion(
            name: "installedapps-rows-render-live-fixture",
            pass: controller.numberOfRows(in: controller.tableView) == 3,
            detail: "rows=\(controller.numberOfRows(in: controller.tableView))"
        ))
        results.append(PaneAssertion(
            name: "installedapps-count-label-matches-the-model",
            pass: controller.countLabel.stringValue == liveModel.countText,
            detail: "label=\(controller.countLabel.stringValue)"
        ))

        let unparseableScan = InstalledAppsScan(
            apps: [fixtureApp(name: "Broken", bundleID: "Unparseable", isUnparseable: true)],
            scannedCount: 1, totalCount: 1, cancelled: false, unreadableRoots: [], millisecondsElapsed: 1
        )
        let unparseableModel = InstalledAppsModel.project(unparseableScan, sort: .size, ascending: false, search: "")
        controller.render(unparseableModel)
        let bundleIDColumn = controller.tableView.tableColumn(
            withIdentifier: NSUserInterfaceItemIdentifier(InstalledAppSortKey.bundleID.rawValue)
        )
        let bundleIDCell = controller.tableView(
            controller.tableView, viewFor: bundleIDColumn, row: 0
        ) as? NSTableCellView
        let bundleIDText = bundleIDCell?.textField?.stringValue ?? "nil"
        results.append(PaneAssertion(
            name: "installedapps-unparseable-appears-in-the-bundle-id-cell",
            pass: bundleIDText == "Unparseable",
            detail: "bundleID=\(bundleIDText)"
        ))

        let cancelledScan = InstalledAppsScan(apps: threeApps, scannedCount: 2, totalCount: 5, cancelled: true,
                                              unreadableRoots: [], millisecondsElapsed: 1)
        let cancelledModel = InstalledAppsModel.project(cancelledScan, sort: .size, ascending: false, search: "")
        controller.render(cancelledModel)
        results.append(PaneAssertion(
            name: "installedapps-cancelled-scan-footer-note",
            pass: controller.footerLabel.stringValue == "Scan stopped at 2 of 5 bundles.",
            detail: "footer=\(controller.footerLabel.stringValue)"
        ))

        return results
    }
}
