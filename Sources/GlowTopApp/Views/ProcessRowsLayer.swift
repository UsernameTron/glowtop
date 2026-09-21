import AppKit
import GlowTopCore
import QuartzCore

/// §4.3.3's twelve rows.
///
/// **Rows are keyed by PID, not by index.** Keyed by index, every reorder reassigns every
/// string and animates nothing meaningful: the card still shows the right twelve processes in
/// the right order, and §4.3.3's 250 ms movement — which exists so the eye can follow a row
/// that moves rather than losing it — is replaced by twelve simultaneous relabels. Keyed by
/// PID, a row that moves is the *same* layers animating to a new position, and only the
/// strings that actually changed are written (§6.9).
@MainActor
final class ProcessRowsLayer {
    /// §4.3.3's column widths, in points.
    private enum Columns {
        static let pid: CGFloat = 44
        static let cpu: CGFloat = 52
        static let gpu: CGFloat = 44
        static let memory: CGFloat = 64
        static let rowHeight: CGFloat = 15
        static let count = 12
    }

    private struct Row {
        let pid = CATextLayer()
        let name = CATextLayer()
        let cpu = CATextLayer()
        let gpu = CATextLayer()
        let memory = CATextLayer()

        var all: [CATextLayer] { [pid, name, cpu, gpu, memory] }
    }

    private let root: CALayer
    private var theme: Theme
    private var rows: [Int32: Row] = [:]
    private var frame: CGRect = .zero
    private var scale: CGFloat = 2

    /// Instrument, not a feature: `GLOWTOP_LOG_PROCROWS` reports what the reorder actually
    /// did, so "keyed by PID" is a checkable claim rather than an assertion in a comment.
    private let logRows = ProcessInfo.processInfo.environment["GLOWTOP_LOG_PROCROWS"] != nil
    private var lastLog = Date()
    private var movesSinceLog = 0
    private var animatedSinceLog = 0
    private var stringsSinceLog = 0

    init(root: CALayer, theme: Theme) {
        self.root = root
        self.theme = theme
    }

    func layout(in cardFrame: CGRect, scale: CGFloat) {
        self.frame = cardFrame
        self.scale = scale
        relayoutExistingRows()
    }

    /// Re-colours every already-built row's five columns. `makeRow()` only colours a row at
    /// creation, and rows are reused across `apply(_:)` calls once their PID exists — without
    /// this, a theme change repaints only the *new* rows the next reorder happens to create.
    func updateTheme(_ newTheme: Theme) {
        theme = newTheme
        for row in rows.values {
            row.pid.foregroundColor = Theme.cgColor(hex: theme.textTertiary)
            row.name.foregroundColor = Theme.cgColor(hex: SpecLiteralColor.processName)
            row.cpu.foregroundColor = Theme.cgColor(hex: theme.accentCPU)
            row.gpu.foregroundColor = Theme.cgColor(hex: theme.accentGPU)
            row.memory.foregroundColor = Theme.cgColor(hex: theme.accentMemory)
        }
    }

    /// §5.5.3's 1 Hz. The coordinator polls at 10 Hz, so the caller gates on the sample's
    /// timestamp changing rather than on the tick.
    func apply(_ models: [ProcessRowModel]) {
        let wanted = Set(models.map(\.pid))

        for (pid, row) in rows where !wanted.contains(pid) {
            for layer in row.all { layer.removeFromSuperlayer() }
            rows[pid] = nil
        }

        for (index, model) in models.prefix(Columns.count).enumerated() {
            let existing = rows[model.pid]
            let row = existing ?? makeRow()
            if existing == nil { rows[model.pid] = row }

            let changed = write(row, model)
            stringsSinceLog += changed

            let target = rowFrames(at: index)
            if existing == nil {
                // A new PID appears already at its position: animating it in from nowhere
                // would read as a row that moved.
                place(row, at: target, animated: false)
            } else if row.pid.frame.origin.y != target.pid.origin.y {
                movesSinceLog += 1
                animatedSinceLog += 1
                place(row, at: target, animated: true)
            }
        }

        logIfDue(models)
    }

    // MARK: - Rows

    private func makeRow() -> Row {
        let row = Row()
        configure(row.pid, size: 10, mono: true, align: .right, hex: theme.textTertiary)
        configure(row.name, size: 10, mono: false, align: .left, hex: SpecLiteralColor.processName)
        configure(row.cpu, size: 10, mono: true, align: .right, hex: theme.accentCPU)
        configure(row.gpu, size: 10, mono: true, align: .right, hex: theme.accentGPU)
        configure(row.memory, size: 10, mono: true, align: .right, hex: theme.accentMemory)
        for layer in row.all { root.addSublayer(layer) }
        return row
    }

    private func configure(_ layer: CATextLayer, size: CGFloat, mono: Bool,
                           align: CATextLayerAlignmentMode, hex: String) {
        layer.font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            : NSFont.systemFont(ofSize: size, weight: .regular)
        layer.fontSize = size
        layer.alignmentMode = align
        layer.foregroundColor = Theme.cgColor(hex: hex)
        layer.contentsScale = scale
        // §4.3.3: the Name column truncates with a middle ellipsis.
        layer.truncationMode = mono ? .none : .middle
        // Only `frame` animates in the 250 ms reorder: a string that crossfades while its
        // row slides shows two values in one cell.
        layer.actions = ["contents": NSNull()]
    }

    /// Returns how many strings actually changed. §6.9: a `CATextLayer`'s string is assigned
    /// only when it differs, so a steady machine writes a handful per second, not sixty.
    private func write(_ row: Row, _ model: ProcessRowModel) -> Int {
        var changed = 0
        func set(_ layer: CATextLayer, _ value: String) {
            guard (layer.string as? String) != value else { return }
            layer.string = value
            changed += 1
        }
        set(row.pid, model.pidText)
        set(row.name, model.name)
        set(row.cpu, model.cpu)
        set(row.gpu, model.gpu)
        set(row.memory, model.memory)
        return changed
    }

    private struct RowFrames {
        let pid: CGRect
        let name: CGRect
        let cpu: CGRect
        let gpu: CGRect
        let memory: CGRect
    }

    /// §4.3.3's columns: PID · Name (flexible) · CPU · GPU · Memory.
    private func rowFrames(at index: Int) -> RowFrames {
        let inner = frame.insetBy(dx: SummaryPaneView.Metrics.cardPadding,
                                  dy: SummaryPaneView.Metrics.cardPadding)
        // Rows run downward from just under the header, in a bottom-left origin space.
        let top = inner.maxY - 30
        let y = top - CGFloat(index + 1) * Columns.rowHeight

        let nameWidth = inner.width - Columns.pid - Columns.cpu - Columns.gpu - Columns.memory
        var x = inner.minX
        let pid = CGRect(x: x, y: y, width: Columns.pid, height: Columns.rowHeight)
        x += Columns.pid
        let name = CGRect(x: x + 4, y: y, width: max(nameWidth - 4, 0), height: Columns.rowHeight)
        x += nameWidth
        let cpu = CGRect(x: x, y: y, width: Columns.cpu, height: Columns.rowHeight)
        x += Columns.cpu
        let gpu = CGRect(x: x, y: y, width: Columns.gpu, height: Columns.rowHeight)
        x += Columns.gpu
        let memory = CGRect(x: x, y: y, width: Columns.memory, height: Columns.rowHeight)
        return RowFrames(pid: pid, name: name, cpu: cpu, gpu: gpu, memory: memory)
    }

    private func place(_ row: Row, at frames: RowFrames, animated: Bool) {
        let targets = [frames.pid, frames.name, frames.cpu, frames.gpu, frames.memory]

        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated {
            // §4.3.3: 250 ms, ease-in-out. The compositor does the movement (§6.5); the app
            // sets one property per layer.
            CATransaction.setAnimationDuration(0.25)
            CATransaction.setAnimationTimingFunction(
                CAMediaTimingFunction(name: .easeInEaseOut)
            )
        }
        for (layer, target) in zip(row.all, targets) {
            layer.contentsScale = scale
            layer.frame = target
        }
        CATransaction.commit()
    }

    private func relayoutExistingRows() {
        guard !rows.isEmpty else { return }
        // On a resize every row is repositioned without animation: a window drag is not a
        // reorder and animating it would smear the whole card.
        let ordered = rows.values.enumerated()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, row) in ordered {
            let target = rowFrames(at: index)
            for (layer, frame) in zip(row.all, [target.pid, target.name, target.cpu,
                                                target.gpu, target.memory]) {
                layer.contentsScale = scale
                layer.frame = frame
            }
        }
        CATransaction.commit()
    }

    private func logIfDue(_ models: [ProcessRowModel]) {
        guard logRows, Date().timeIntervalSince(lastLog) >= 1 else { return }
        lastLog = Date()
        let pids = models.prefix(Columns.count).map { String($0.pid) }.joined(separator: ",")
        print("procrows pids=[\(pids)] moves=\(movesSinceLog) animated=\(animatedSinceLog) "
              + "dur=0.250 strings=\(stringsSinceLog)")
        fflush(stdout)
        movesSinceLog = 0
        animatedSinceLog = 0
        stringsSinceLog = 0
    }
}
