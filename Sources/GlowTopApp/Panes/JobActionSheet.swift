import AppKit
import GlowTopCore

/// SPEC.md §14.4's confirmation sheet, patterned on `KillSheet.swift` (D-02) rather than shared
/// with it: same `NSAlert` shape, same Cancel-added-first discipline with every `keyEquivalent`
/// set explicitly, same off-main call plus hop-back. This file computes no string of its own --
/// `JobActions.sheetText(for:verb:)` is the one place the sheet's words and the log's `result=`
/// can never disagree about what the action was.
@MainActor
final class JobActionSheet {
    private var actionTask: Task<Void, Never>?

    /// §14.4's sheet. Cancel returns immediately -- no call, no log line. Confirm runs the one
    /// verb function off the main actor (D-07: `JobActions.enable/disable/start/stop` block on
    /// their own 5 s poll) and hops back only if this sheet has not been asked to stand down.
    func confirm(_ job: LaunchdJob, verb: JobVerb, in window: NSWindow, onSettled: @escaping (JobOutcome) -> Void) {
        let alert = NSAlert()
        let (messageText, informativeText) = JobActions.sheetText(for: job, verb: verb)
        alert.messageText = messageText
        alert.informativeText = informativeText

        // D-11: Cancel added first, always. `Enable`/`Start` keep it non-default; `Disable`/
        // `Stop` make Cancel the default explicitly and the verb button destructive and
        // non-default -- both `keyEquivalent`s set on both branches, never left to AppKit's
        // own "first button added wins" rule (`KillSheet.swift:22-31`'s own reasoning).
        let cancel = alert.addButton(withTitle: "Cancel")
        let verbButton: NSButton
        switch verb {
        case .enable, .start:
            cancel.keyEquivalent = ""
            verbButton = alert.addButton(withTitle: verb.rawValue.capitalized)
            verbButton.keyEquivalent = "\r"
        case .disable, .stop:
            cancel.keyEquivalent = "\r"
            verbButton = alert.addButton(withTitle: verb.rawValue.capitalized)
            verbButton.hasDestructiveAction = true
            verbButton.keyEquivalent = ""
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            self.performAction(verb, job: job, in: window, onSettled: onSettled)
        }
    }

    /// §3.3-style discipline applied to a sheet: an in-flight call and poll that outlives its
    /// pane is a hop-back landing over whatever pane the user switched to. Called from
    /// `paneDidResignVisible()`. The verb function itself is left to run to completion --
    /// `JobActions`' own `defer`-adjacent log write cannot be interrupted from here, and should
    /// not be -- only the callback into this now-inactive pane is dropped.
    func cancelPendingPoll() {
        actionTask?.cancel()
        actionTask = nil
    }

    // MARK: - The one call site into 2.2, off the main actor

    private func performAction(_ verb: JobVerb, job: LaunchdJob, in window: NSWindow, onSettled: @escaping (JobOutcome) -> Void) {
        actionTask?.cancel()
        actionTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                switch verb {
                case .enable: return JobActions.enable(job)
                case .disable: return JobActions.disable(job)
                case .start: return JobActions.start(job)
                case .stop: return JobActions.stop(job)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.actionTask = nil
            onSettled(outcome)
            self.showFollowUp(for: outcome.result, in: window)
        }
    }

    /// §14.4's locked follow-up strings. `blockedGuardrail` shows nothing -- the disabled
    /// control already said why, and this path should be unreachable (`KillSheet.swift:83-89`'s
    /// own comment about an unreachable case). A successful result shows nothing either; the
    /// calling pane's own `refresh()` or poll is what the user sees change.
    private func showFollowUp(for result: JobResult, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch result {
        case .failed(3):
            alert.messageText = "Nothing was running under this label."
        case .failed(113):
            alert.messageText = "That job is not loaded."
        case .failedTimeout:
            alert.messageText = "KeepAlive is set — launchd will relaunch it. To keep it stopped, disable it in Startup Apps."
        case .failed(let code):
            alert.messageText = "launchctl exited \(code)."
        case .enabled, .disabled, .started, .stopped, .blockedGuardrail:
            return
        }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }
}
