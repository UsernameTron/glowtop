import AppKit
import GlowTopCore

/// SPEC.md §8.6, read-only in M01: a one-shot detail sheet over `ProcessesModel.inspector`'s
/// twelve pre-formatted values. This file draws strings; nothing here computes one (§7.1).
@MainActor
final class ProcessInspectorSheet {
    private struct Row { let label: String; let value: String }

    /// `model` is read once, at open -- §8.6 item 4: "a detail sheet, not a monitor," and a
    /// 1 Hz refresh under a modal nobody can interact with is cost with no reader.
    func present(name: String, model: ProcessInspectorModel, in window: NSWindow) {
        let rows: [Row] = [
            Row(label: "Path", value: model.pathText),
            Row(label: "Arguments", value: model.argumentsText),
            Row(label: "Parent", value: model.parentText),
            Row(label: "Started", value: model.startText),
            Row(label: "Elapsed", value: model.elapsedText),
            Row(label: "UID", value: model.uidText),
            Row(label: "User", value: model.userText),
            Row(label: "Threads", value: model.threadsText),
            Row(label: "Memory", value: model.memoryText),
            Row(label: "CPU time", value: model.cpuTimeText),
            Row(label: "Disk I/O", value: model.diskText),
            Row(label: "Architecture", value: model.architectureText),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for row in rows {
            let line = NSStackView()
            line.orientation = .horizontal
            line.alignment = .firstBaseline
            line.spacing = 6

            let label = NSTextField(labelWithString: "\(row.label):")
            label.font = .boldSystemFont(ofSize: 11)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 80).isActive = true

            let value = NSTextField(labelWithString: row.value)
            value.font = .systemFont(ofSize: 11)
            value.lineBreakMode = .byTruncatingMiddle
            value.maximumNumberOfLines = 1

            line.addArrangedSubview(label)
            line.addArrangedSubview(value)
            stack.addArrangedSubview(line)
        }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 0))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
        ])
        container.layoutSubtreeIfNeeded()

        let alert = NSAlert()
        alert.messageText = name
        alert.alertStyle = .informational
        alert.accessoryView = container
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
