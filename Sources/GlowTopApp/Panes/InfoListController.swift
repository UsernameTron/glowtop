import AppKit
import GlowTopCore

/// §9.1's grouped-card list: a title and label/value rows per card, 22 pt row height, no
/// charts and no animation -- the only things on this pane that change are a handful of
/// strings, so a full rebuild on every render is simpler than diffing rows nobody watches
/// move (§8.3's diff exists because rows there reorder under sort; nothing here reorders).
///
/// §10, §11 and §12's panes are tables and do not use this type.
@MainActor
final class InfoListController: NSView {
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func render(cards: [(title: String, rows: [SystemInfo.Row])]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for card in cards {
            let cardView = InfoCardView(title: card.title, rows: card.rows)
            cardView.translatesAutoresizingMaskIntoConstraints = false
            // Activated only after `addArrangedSubview` -- a constraint between two views
            // with no common ancestor yet throws (this sub-step's own recorded crash).
            stack.addArrangedSubview(cardView)
            cardView.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
}

/// One §4.2 card: title, then one 22 pt row per label/value pair. Same chrome constants as
/// `SummaryPaneView`'s cards (§4.2's own table) -- background, 1 pt border, 10 pt corner
/// radius, 12 pt inner padding.
private final class InfoCardView: NSView {
    // §7.3's live-apply: `InfoListController.render(cards:)` rebuilds every `InfoCardView`
    // from scratch, so a fresh read here is enough -- the pane's own 1 Hz live timer (or its
    // next `paneDidBecomeVisible()`) is what re-runs `render(cards:)`, no separate observer.
    private var theme: Theme { ThemeStore.shared.theme }
    /// Keeps the row's `Copy` action alive for the row view's lifetime -- an `NSMenuItem`
    /// does not retain its target.
    private var copyTargets: [CopyItem] = []

    init(title: String, rows: [SystemInfo.Row]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.cgColor(hex: theme.cardBackground)
        layer?.borderColor = Theme.cgColor(hex: theme.cardBorder)
        layer?.borderWidth = 1
        layer?.cornerRadius = 10

        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        for row in rows {
            let rowView = makeRowView(row)
            rowsStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        addSubview(titleLabel)
        addSubview(rowsStack)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            rowsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            rowsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rowsStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rowsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// §9.1: label leading in `textSecondary`, value trailing in `textPrimary` (or the row's
    /// own colour token -- memory pressure's only), SF Mono when the row says so.
    private func makeRowView(_ row: SystemInfo.Row) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let label = NSTextField(labelWithString: row.label)
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor(cgColor: theme.cgColor("textSecondary")) ?? .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let value = NSTextField(labelWithString: row.value)
        value.font = row.isMonospaced ? .monospacedSystemFont(ofSize: 11, weight: .regular) : .systemFont(ofSize: 11)
        value.alignment = .right
        value.lineBreakMode = .byTruncatingMiddle
        value.textColor = NSColor(cgColor: theme.cgColor(row.colorToken ?? "textPrimary")) ?? .labelColor
        value.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(value)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            value.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            value.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])

        // §9.2: the serial number and hardware UUID are shown but are never one click from
        // the clipboard -- a screenshot of this pane is a common way to leak them. A
        // right-click -> Copy exists on these two rows and nothing else; neither label has a
        // click target, so a plain click does nothing. "Make every row copyable" is the
        // obvious polish this rule refuses.
        if row.label == "Serial number" || row.label == "Hardware UUID" {
            let target = CopyItem(value: row.value)
            copyTargets.append(target)
            let menu = NSMenu()
            let item = NSMenuItem(title: "Copy", action: #selector(CopyItem.copy(_:)), keyEquivalent: "")
            item.target = target
            menu.addItem(item)
            container.menu = menu
        }

        return container
    }
}

private final class CopyItem: NSObject {
    let value: String
    init(value: String) { self.value = value }

    @objc func copy(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
