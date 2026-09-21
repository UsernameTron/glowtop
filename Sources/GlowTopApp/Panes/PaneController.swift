import AppKit

/// SPEC.md §3.3's two visibility hooks, and §6.2's occlusion hook. `PaneHostView` is the only
/// caller of all three — a second call site is a second place for the guarantee to be wrong.
///
/// Default no-op implementations below: a pane that samples nothing (a static reader pane, or
/// Summary, which §3.3 exempts outright) implements only what it needs.
@MainActor
protocol PaneController: NSViewController {
    func paneDidBecomeVisible()
    func paneDidResignVisible()

    /// §6.2. The window this pane is in became fully occluded or minimized, or stopped being.
    /// The host tracks the state and forwards it to whichever pane is current, including on a
    /// pane switch — a pane installed while the window is covered starts at the right rate.
    func paneDidChangeOcclusion(_ occluded: Bool)
}

extension PaneController {
    func paneDidBecomeVisible() {}
    func paneDidResignVisible() {}
    func paneDidChangeOcclusion(_ occluded: Bool) {}
}
