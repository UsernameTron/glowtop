import AppKit
import GlowTopCore

/// SPEC.md §7.3's editor: every §7.2 token as a row (swatch + hex field), the two glow
/// numbers as their own rows, §7.5's inline contrast warning, ⌘Z and `Reset to preset`.
///
/// This pane owns **no theme state**. Every row reads `ThemeStore.shared.theme` and writes
/// back through `ThemeStore.shared.setToken`/`setGlow` — phase-04's container retains panes,
/// so a private copy here would drift from the live theme (and lose an edit) the moment the
/// pane is switched away and back.
///
/// Implements **neither** §3.3 visibility hook: the editor samples nothing, the same
/// exemption `SummaryPaneController`'s doc comment records for the opposite reason.
@MainActor
final class ColorsPaneController: NSViewController, PaneController {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let resetButton = NSButton(title: "Reset to preset", target: nil, action: nil)

    private var swatches: [String: NSView] = [:]
    private var hexFields: [String: NSTextField] = [:]
    private var warningLabels: [String: NSTextField] = [:]
    private var numericFields: [String: NSTextField] = [:]

    /// §7.5: checked for these four rows — the text-on-`background` pairs §7.5 names, not
    /// every token has a defined "on" surface to check against.
    private static let contrastCheckedTokens = ["textPrimary", "textSecondary", "textTertiary", "textDisabled"]

    override func loadView() {
        let root = ColorsKeyCommandView()
        root.onCommandZ = { ThemeStore.shared.undo() }
        root.wantsLayer = true
        root.layer?.backgroundColor = Theme.cgColor(hex: ThemeStore.shared.theme.background)

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.target = self
        resetButton.action = #selector(resetToPresetTapped)
        resetButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(resetButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for token in Theme.allTokenNames {
            let row = buildHexRow(token)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for (name, label) in [("glowOpacity", "glowOpacity"), ("glowRadius", "glowRadius")] {
            let row = buildNumericRow(name, label: label)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        scrollView.documentView = stack
        root.addSubview(toolbar)
        root.addSubview(scrollView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 40),

            resetButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            resetButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 12),
        ])

        view = root
        refreshAllRows()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeDidChange),
            name: ThemeStore.didChange, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func resetToPresetTapped() {
        ThemeStore.shared.resetToPreset()
    }

    @objc private func handleThemeDidChange() {
        view.layer?.backgroundColor = Theme.cgColor(hex: ThemeStore.shared.theme.background)
        refreshAllRows()
    }

    // MARK: - Rows

    private func buildHexRow(_ token: String) -> NSView {
        let row = NSView()
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderWidth = 1
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatches[token] = swatch

        let label = NSTextField(labelWithString: token)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: "")
        field.identifier = NSUserInterfaceItemIdentifier(token)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.wantsLayer = true
        field.translatesAutoresizingMaskIntoConstraints = false
        hexFields[token] = field

        row.addSubview(swatch)
        row.addSubview(label)
        row.addSubview(field)
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            swatch.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 18),
            swatch.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 140),

            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 90),
        ])

        // §7.5's inline warning, the four text-on-background rows only.
        if Self.contrastCheckedTokens.contains(token) {
            let warning = NSTextField(labelWithString: "")
            warning.font = .systemFont(ofSize: 10)
            warning.isHidden = true
            warning.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(warning)
            warningLabels[token] = warning
            NSLayoutConstraint.activate([
                warning.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 8),
                warning.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            ])
        }

        return row
    }

    private func buildNumericRow(_ name: String, label labelText: String) -> NSView {
        let row = NSView()
        row.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let label = NSTextField(labelWithString: labelText)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: "")
        field.identifier = NSUserInterfaceItemIdentifier(name)
        field.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        field.delegate = self
        field.target = self
        field.action = #selector(fieldCommitted(_:))
        field.wantsLayer = true
        field.translatesAutoresizingMaskIntoConstraints = false
        numericFields[name] = field

        row.addSubview(label)
        row.addSubview(field)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 26),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 140),

            field.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 90),
        ])
        return row
    }

    // MARK: - Live apply

    @objc private func fieldCommitted(_ sender: NSTextField) {
        commitIfValid(sender)
    }

    /// Commits on a **valid** value only — a 7-character hex or a non-negative number — and
    /// never on anything else. Called on every keystroke (`controlTextDidChange`) and again on
    /// Return (the field's `action`); the second call is a no-op once the first already
    /// committed the same text.
    private func commitIfValid(_ field: NSTextField) {
        guard let name = field.identifier?.rawValue else { return }
        let text = field.stringValue

        if Theme.allTokenNames.contains(name) {
            guard Theme.isValidHex(text) else {
                setInvalid(field, true)
                return
            }
            setInvalid(field, false)
            ThemeStore.shared.setToken(name, hex: text)
        } else {
            guard let value = Double(text), value >= 0 else {
                setInvalid(field, true)
                return
            }
            setInvalid(field, false)
            if name == "glowOpacity" {
                ThemeStore.shared.setGlow(opacity: value)
            } else if name == "glowRadius" {
                ThemeStore.shared.setGlow(radius: value)
            }
        }
    }

    /// §7.3: "no apply button" — invalid text is marked and changes nothing, never blocked
    /// and never rejected outright.
    private func setInvalid(_ field: NSTextField, _ invalid: Bool) {
        field.layer?.borderWidth = invalid ? 2 : 0
        field.layer?.borderColor = NSColor.systemRed.cgColor
    }

    /// Always overwrites every field's text, even one the user still has focused. A field's
    /// *own* commit only ever fires this via `didChange` once its text already equals the new
    /// value, so re-setting it there is a no-op; the case this exists for is a **different**
    /// source changing the token underneath a focused field -- ⌘Z, `Reset to preset`, or the
    /// Colors menu -- which must be visible immediately, not only after the field blurs. An
    /// invalid, not-yet-committed keystroke never reaches here at all: nothing posts
    /// `didChange` until `commitIfValid` accepts it.
    private func refreshAllRows() {
        let theme = ThemeStore.shared.theme
        for token in Theme.allTokenNames {
            let hex = theme[token] ?? "#FF00FF"
            swatches[token]?.layer?.backgroundColor = Theme.cgColor(hex: hex)
            swatches[token]?.layer?.borderColor = Theme.cgColor(hex: theme.cardBorder)
            if let field = hexFields[token] {
                field.stringValue = hex
                setInvalid(field, false)
            }
            if let warning = warningLabels[token] {
                if let ratio = Contrast.ratio(hex, theme.background), ratio < 4.5 {
                    warning.stringValue = String(format: "⚠ %.1f:1", ratio)
                    warning.isHidden = false
                } else {
                    warning.isHidden = true
                }
            }
        }
        if let field = numericFields["glowOpacity"] {
            field.stringValue = String(format: "%.2f", theme.glowOpacity)
            setInvalid(field, false)
        }
        if let field = numericFields["glowRadius"] {
            field.stringValue = String(format: "%.1f", theme.glowRadius)
            setInvalid(field, false)
        }
    }
}

extension ColorsPaneController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        commitIfValid(field)
    }
}

/// ⌘Z, the same pattern `ProcessesPaneController`'s `KeyCommandView` uses for its own keys.
private final class ColorsKeyCommandView: NSView {
    var onCommandZ: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
              event.charactersIgnoringModifiers?.lowercased() == "z"
        else { return super.performKeyEquivalent(with: event) }
        onCommandZ?()
        return true
    }
}
