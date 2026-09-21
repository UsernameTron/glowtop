import AppKit
import Darwin
import GlowTopCore

/// SPEC.md §8.5's kill flow, copied rather than paraphrased: the sheet text, the button
/// order, the 5 s poll and the errno paths are all §8.5's own. Every attempt logs through
/// `ProcessActions` (1.3) inside `attempt(pid:name:uid:signal:)`; this file writes nothing to
/// the log itself and never calls `kill(2)` to signal a process outside that one call.
@MainActor
final class KillSheet {
    private var pollTask: Task<Void, Never>?

    /// §8.5 item 2's confirmation sheet, always, with no "don't ask again" option. `onGone`
    /// is called the moment `ESRCH` is observed on this row's PID -- item 6's "closes the
    /// sheet silently and removes the row," done here rather than waiting up to a second for
    /// the pane's own poll to notice.
    func confirmQuit(_ row: ProcessRowDetail, in window: NSWindow, onGone: @escaping (Int32) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Quit \(row.name)?"
        alert.informativeText = informativeText(for: row)

        // §8.5's order -- Cancel, Force Quit, Quit -- with `Quit` added **last** so AppKit's
        // "first button added is the default" rule cannot make Force Quit the default by
        // accident. Both defaults are set explicitly regardless, so the order only matters
        // for on-screen left-to-right placement.
        alert.addButton(withTitle: "Cancel")
        let forceQuit = alert.addButton(withTitle: "Force Quit")
        forceQuit.hasDestructiveAction = true
        forceQuit.keyEquivalent = ""
        let quit = alert.addButton(withTitle: "Quit")
        quit.keyEquivalent = "\r"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertSecondButtonReturn:
                // Force Quit: SIGKILL cannot be caught, so there is nothing to poll for.
                self.send(.kill, to: row, in: window, onGone: onGone)
            case .alertThirdButtonReturn:
                self.send(.term, to: row, in: window, onGone: onGone)
                self.startPoll(on: row, in: window, onGone: onGone)
            default:
                // Cancel, or the sheet dismissed some other way: not an attempt, no log line.
                return
            }
        }
    }

    /// §8.5 item 5's second sheet: still alive 5 s after SIGTERM.
    private func offerForceQuit(for row: ProcessRowDetail, in window: NSWindow, onGone: @escaping (Int32) -> Void) {
        let alert = NSAlert()
        alert.messageText = "\(row.name) has not quit"
        alert.informativeText = "PID \(row.pidText) is still running 5 seconds after SIGTERM."
        let forceQuit = alert.addButton(withTitle: "Force Quit")
        forceQuit.hasDestructiveAction = true
        forceQuit.keyEquivalent = ""
        let leaveIt = alert.addButton(withTitle: "Leave it")
        leaveIt.keyEquivalent = "\r"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.send(.kill, to: row, in: window, onGone: onGone)
        }
    }

    /// §3.3-style discipline applied to a sheet: a poll that outlives its pane is a sheet
    /// that can open over a different one. Called from `paneDidResignVisible()`.
    func cancelPendingPoll() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - The one call site into 1.3

    private func send(_ signal: KillSignal, to row: ProcessRowDetail, in window: NSWindow, onGone: @escaping (Int32) -> Void) {
        let uid = row.uid ?? 0
        let result = ProcessActions.attempt(pid: row.pid, name: row.name, uid: uid, signal: signal)
        switch result {
        case .esrch:
            onGone(row.pid)
        case .eperm:
            showFailure(ProcessActions.userMessage(for: result) ?? "", in: window)
        case .ok, .blockedGuardrail, .failed:
            // `.blockedGuardrail` should be unreachable here -- the pane's second guardrail
            // layer (the disabled control) and `presentKillSheet`'s own re-check both sit in
            // front of this call. `.failed` has no §8.5 message defined; §8.5 names only
            // EPERM and ESRCH, and inventing a string for an unnamed errno is not this file's
            // call to make.
            break
        }
    }

    // MARK: - §8.5 item 5's poll

    /// `kill(pid, 0)` every 500 ms for 5 s, on a cancellable `Task` rather than a blocking
    /// sleep -- a synchronous wait on the main thread would freeze every display link and the
    /// clock for five seconds after every SIGTERM. `Task { }` from this `@MainActor` type
    /// inherits its isolation, the same shape `MetricStore`'s sample loops and
    /// `SummaryPaneController`'s poll already use, rather than `Timer`'s `@Sendable` callback.
    private func startPoll(on row: ProcessRowDetail, in window: NSWindow, onGone: @escaping (Int32) -> Void) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var elapsed: TimeInterval = 0
            while elapsed < 5.0 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                elapsed += 0.5
                guard Self.processExists(row.pid) else {
                    self.pollTask = nil
                    onGone(row.pid)
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.pollTask = nil
            self.offerForceQuit(for: row, in: window, onGone: onGone)
        }
    }

    /// `kill(pid, 0)` sends no signal; it only tests whether the PID exists and whether this
    /// process may signal it. `ESRCH` means gone; any other outcome (success, or `EPERM` for
    /// a PID that exists but is owned by someone else) means still alive.
    private static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func showFailure(_ message: String, in window: NSWindow) {
        guard !message.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// §8.5 item 2, exactly: `PID 48213 · 4.2% CPU · 1.8 GB memory · user jappleseed`, with
    /// §4.9's percent form (no space before `%`) rather than §8.5's own example, which 5.2
    /// amends -- the discretion table's resolution. `—` for any field the row does not have,
    /// same as every other column (§4.9).
    private func informativeText(for row: ProcessRowDetail) -> String {
        var lines = ["PID \(row.pidText) · \(row.cpuText) CPU · \(row.memoryText) memory · user \(row.userText)"]
        lines.append("This sends SIGTERM. The process may lose unsaved work.")
        if row.uid == 0 {
            lines.append("This is a system process. Quitting it may destabilize macOS.")
        }
        return lines.joined(separator: "\n\n")
    }
}
