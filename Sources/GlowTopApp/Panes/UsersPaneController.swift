import AppKit
import GlowTopCore

/// SPEC.md §11's Users pane: two read-only tables, Accounts and Sessions, each in one §4.2
/// card. `UsersReader` does every read, filter and format decision (§7.1); this file only
/// starts/stops §11.2's two timers and draws what it is handed.
@MainActor
final class UsersPaneController: NSViewController, PaneController {
    private var accounts: [AccountRow] = []
    private var sessions: [SessionRow] = []
    private var sessionsTimer: Timer?

    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let accountsTable = NSTableView()
    private let sessionsTable = NSTableView()
    private var cardContainers: [NSView] = []
    private var cardTitleLabels: [NSTextField] = []
    private var theme: Theme { ThemeStore.shared.theme }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let accountsCard = card(title: "Accounts", table: accountsTable)
        let sessionsCard = card(title: "Sessions", table: sessionsTable)
        stack.addArrangedSubview(accountsCard)
        accountsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(sessionsCard)
        sessionsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 16),
        ])

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureAccountsColumns()
        configureSessionsColumns()
        accountsTable.dataSource = self
        accountsTable.delegate = self
        sessionsTable.dataSource = self
        sessionsTable.delegate = self

        let menu = NSMenu()
        menu.delegate = self
        // Every item's state is set by hand in `menuNeedsUpdate`. Left at its default, AppKit's
        // own validation pass runs afterwards and re-enables any item whose target responds to
        // its action -- which silently undid the guardrail's first layer in 1.1.0 (§14.9).
        menu.autoenablesItems = false
        let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(revealHomeDirectory), keyEquivalent: "")
        revealItem.target = self
        menu.addItem(revealItem)
        accountsTable.menu = menu

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    /// §7.3's live-apply. The two cards' chrome and titles, then both tables via
    /// `reloadData()` -- `makeCellView`'s recycled path re-colours on every call, same fix as
    /// `StartupAppsPaneController`'s and `ServicesPaneController`'s twins.
    @objc private func handleThemeDidChange() {
        for container in cardContainers {
            container.layer?.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
            container.layer?.borderColor = Theme.cgColor(hex: theme.cardBorder)
        }
        for label in cardTitleLabels {
            label.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        }
        accountsTable.reloadData()
        sessionsTable.reloadData()
    }

    // MARK: - §11.2's cadence: Accounts once, Sessions at 0.2 Hz while visible

    func paneDidBecomeVisible() {
        if accounts.isEmpty {
            accounts = UsersReader.readAccounts()
            accountsTable.reloadData()
        }
        refreshSessions()
        sessionsTimer?.invalidate()
        sessionsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshSessions() }
        }
    }

    func paneDidResignVisible() {
        sessionsTimer?.invalidate()
        sessionsTimer = nil
    }

    private func refreshSessions() {
        sessions = UsersReader.readSessions()
        sessionsTable.reloadData()
    }

    // MARK: - §11.2's read-only escape hatch

    @objc private func revealHomeDirectory() {
        let row = accountsTable.clickedRow
        guard row >= 0, row < accounts.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: accounts[row].homeDirectory)])
    }

    // MARK: - Card chrome (§4.2's table)

    private func card(title: String, table: NSTableView) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
        container.layer?.borderColor = Theme.cgColor(hex: theme.cardBorder)
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 10
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        table.rowHeight = 20
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.translatesAutoresizingMaskIntoConstraints = false
        table.headerView = NSTableHeaderView()

        container.addSubview(titleLabel)
        container.addSubview(table)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            table.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            table.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            table.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            table.heightAnchor.constraint(equalToConstant: 160),
        ])
        cardContainers.append(container)
        cardTitleLabels.append(titleLabel)
        return container
    }

    // MARK: - Columns

    private static let accountColumns = ["name", "fullName", "uid", "group", "homeDirectory", "shell", "admin"]
    private static let accountTitles = ["Name", "Full name", "UID", "Group", "Home", "Shell", "Admin"]
    private static let sessionColumns = ["user", "kind", "line", "host", "elapsed"]
    private static let sessionTitles = ["User", "Type", "Line", "Host", "Elapsed"]

    private func configureAccountsColumns() {
        for (key, title) in zip(Self.accountColumns, Self.accountTitles) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = key == "homeDirectory" ? 200 : 100
            accountsTable.addTableColumn(column)
        }
    }

    private func configureSessionsColumns() {
        for (key, title) in zip(Self.sessionColumns, Self.sessionTitles) {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
            column.title = title
            column.width = key == "host" ? 140 : 100
            sessionsTable.addTableColumn(column)
        }
    }

    private func accountText(_ key: String, _ row: AccountRow) -> String {
        switch key {
        case "name": return row.name
        case "fullName": return row.fullName
        case "uid": return String(row.uid)
        case "group": return row.group
        case "homeDirectory": return row.homeDirectory
        case "shell": return row.shell
        case "admin": return row.admin ? "✓" : Format.unknown
        default: return ""
        }
    }

    private func sessionText(_ key: String, _ row: SessionRow) -> String {
        switch key {
        case "user": return row.user
        case "kind": return row.kind.rawValue
        case "line": return row.line
        case "host": return row.host.isEmpty ? Format.unknown : row.host
        case "elapsed": return row.elapsedText
        default: return ""
        }
    }

    private func makeCellView(in table: NSTableView, identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        if let recycled = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            return recycled
        }
        let cell = NSTableCellView()
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
        return cell
    }
}

extension UsersPaneController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === accountsTable ? accounts.count : sessions.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let cell = makeCellView(in: tableView, identifier: column.identifier)
        let key = column.identifier.rawValue
        // Set on every call, not only at creation -- a recycled cell must pick up a theme
        // change too. The "kind" column's remote-session styling below overrides this.
        cell.textField?.textColor = NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor

        if tableView === accountsTable {
            guard row < accounts.count else { return nil }
            cell.textField?.stringValue = accountText(key, accounts[row])
        } else {
            guard row < sessions.count else { return nil }
            let session = sessions[row]
            cell.textField?.stringValue = sessionText(key, session)
            // §11.1: an unexpected remote session is what this section occasionally exists
            // to surface -- its Type cell renders in the warning token rather than the
            // normal text color, decided here (from the row's own data), not chosen in the
            // cell's drawing code (§7.1).
            if key == "kind" {
                cell.textField?.textColor = session.kind == .remote
                    ? NSColor(cgColor: theme.cgColor("warning")) ?? .systemYellow
                    : NSColor(cgColor: theme.cgColor("textPrimary")) ?? .labelColor
            }
        }
        return cell
    }
}

extension UsersPaneController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.items.forEach { $0.isEnabled = accountsTable.clickedRow >= 0 }
    }
}
