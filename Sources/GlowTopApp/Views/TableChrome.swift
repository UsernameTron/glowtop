import AppKit
import GlowTopCore

/// §3.5's ⌘F and ⌘⌫, bound here and nowhere else: `performKeyEquivalent` is called for a
/// modifier-flagged key press regardless of which view in this pane currently holds first
/// responder, which a plain `keyDown` override could not do. Plain ⌫ (§8.5 item 1's other
/// trigger) has no modifier and is instead caught by `ProcessesTableView.keyDown(with:)`,
/// which only fires while the table itself holds first responder -- exactly when a row can
/// be selected.
final class KeyCommandView: NSView {
    var onCommandF: (() -> Void)?
    var onCommandDelete: (() -> Void)?
    /// §8.6's ⌘I, opening the inspector for the selected row.
    var onCommandI: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "f":
            onCommandF?()
            return true
        case "i":
            onCommandI?()
            return true
        default:
            break
        }
        // keyCode 51 is the physical ⌫ key (`kVK_Delete`) regardless of keyboard layout --
        // the same check `ProcessesTableView.keyDown(with:)` uses for the unmodified key.
        if event.keyCode == 51 {
            onCommandDelete?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// §8.2's row chrome: alternating `processRowEven`/`processRowOdd` backgrounds, and a
/// `processRowSelected` fill with a 2 pt leading `accentCPU` bar in place of AppKit's system
/// selection highlight.
final class TableRowView: NSTableRowView {
    var isEvenRow = false

    override func drawBackground(in dirtyRect: NSRect) {
        let hex = isEvenRow ? SpecLiteralColor.processRowEven : SpecLiteralColor.processRowOdd
        (NSColor(cgColor: Theme.cgColor(hex: hex)) ?? .clear).setFill()
        dirtyRect.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        (NSColor(cgColor: Theme.cgColor(hex: SpecLiteralColor.processRowSelected)) ?? .clear).setFill()
        bounds.fill()
        (NSColor(cgColor: Theme.cgColor(hex: ThemeStore.shared.theme.accentCPU)) ?? .clear).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}
