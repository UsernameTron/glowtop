import GlowTopCore
import SwiftUI

/// The only thing SwiftUI observes.
///
/// Nothing here is written more than once a second except `paused` and `showFPSOverlay`,
/// which are user actions. SPEC.md §13.1.6 measured SwiftUI out of the sample path and took
/// the app's idle floor from 2.71 % to 1.07 %; a field written at 10 Hz would re-run the view
/// graph ten times a second and put it straight back.
@MainActor
@Observable
final class AppState {
    /// Defaults to Summary. `GLOWTOP_PANE=<PaneID rawValue>` selects a different pane at
    /// launch — a measurement hook in the `GLOWTOP_SCREEN`/`GLOWTOP_WINDOW_SIZE` family
    /// (§13.1.5), read once, because `scripts/overhead-harness.sh` cannot select a pane and
    /// driving one with `osascript` inside a measurement window starves the reading
    /// (the project's lessons log, 2026-09-01).
    var selectedPane: PaneID = ProcessInfo.processInfo.environment["GLOWTOP_PANE"]
        .flatMap(PaneID.init(rawValue:)) ?? .summary

    /// §6.8. The pane view owns the key binding; this is what it toggles.
    var paused = false

    /// §4.10: Simple (the default) or Technical. Persisted under `display.mode` beside §7.4's
    /// theme keys. `GLOWTOP_DISPLAY_MODE` overrides it for one launch without writing it back —
    /// a measurement hook in `GLOWTOP_PANE`'s family, so a harness or a gate can pin the mode.
    var displayMode: DisplayMode = {
        if let pinned = ProcessInfo.processInfo.environment["GLOWTOP_DISPLAY_MODE"] {
            return DisplayMode.parse(pinned)
        }
        return DisplayMode.parse(UserDefaults.standard.string(forKey: DisplayMode.storageKey))
    }() {
        didSet {
            guard displayMode != oldValue else { return }
            UserDefaults.standard.set(displayMode.rawValue, forKey: DisplayMode.storageKey)
        }
    }

    /// §6.7: off by default in release, on in debug.
    var showFPSOverlay: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// §4.7's leading string, whole. Written once a second by the coordinator.
    var statusLeading = "···"
    /// A `Theme` token name — §4.7's health phrase carries a colour.
    var statusPhraseToken = "textSecondary"
    /// One line per unavailable provider (§5.0.5), shown on hover.
    var statusTooltip = ""

    /// §4.7's trailing wall clock, `HH:mm:ss`.
    var clock = ""

    /// §9.2's Frame rate row: Summary's §6.7 counter with the instant it was computed. Written
    /// once a second by `SummaryPaneController`'s 1 Hz block while Summary is installed; once
    /// the host releases that controller the last value stays put and its timestamp makes the
    /// age climb. No SwiftUI body reads it, so the 1 Hz write costs no view-graph pass.
    var summaryFrameRate: (fps: Double, at: Date)?

    /// §12.3's Show Process: the PID Services asks Processes to select. Parked here rather than
    /// handed over directly because the Processes controller may not exist yet — `PaneHostView`
    /// constructs panes lazily, and `show(_:)` runs on SwiftUI's next pass after `selectedPane`
    /// is written. Consumed and cleared by `ProcessesPaneController.paneDidBecomeVisible()`.
    /// A user action, not a rate — this write is not on any loop.
    var pendingProcessPID: Int32?

    /// Set by the pane view once it has a window, so ⌘R and Space reach the store without
    /// SwiftUI holding the store itself.
    var forceSample: (() -> Void)?

    /// §14.6's ⌘D overload. The menu item selects the pane on the first press and asks it to
    /// take `~` as the root on a second press while it is already selected.
    /// `PaneHostView.show(_:)` early-returns on a repeat selection (`guard pane != current`),
    /// so the second press cannot reach the controller through `selectedPane` at all -- the
    /// same reason `forceSample` above exists. Set by `DiskSpacePaneController` in
    /// `viewDidLoad`, cleared in `deinit`.
    var diskSpaceSelectHomeRoot: (() -> Void)?
}

/// §3.2's sidebar rows. Twelve panes are selectable; `Benchmarks` and `Settings` are the two
/// disabled rows. A non-nil `comingIn` marks a row disabled and records where the work
/// sits; since 1.1.1 the tooltip reads `Not in this version` and no longer prints it (§3.2).
enum SidebarRow: Hashable {
    case pane(PaneID, title: String, symbol: String, comingIn: String?)
    case proHeader
    case divider
    case disabled(title: String, symbol: String, comingIn: String)

    /// §3.2's order, checked against the reference build. The `PRO` block is Power & Freq,
    /// Connections, Installed Apps, Disk Space, Benchmarks — §3.2's canonical paragraph, not
    /// the order of its SF Symbol sentence, which lists Benchmarks before Installed Apps and
    /// which §3.2 itself records as having been wrong once.
    ///
    /// **Performance was ruled M02's on 2026-08-27 (§3.2) and restored on 2026-09-02
    /// (phase-10).** It sat in the `PRO` block, disabled, for as long as §14.10 did not
    /// exist. §14.10 now specifies it, so the row is back in second position — the seat
    /// ⌘2's number matches — and the `PRO` block holds the five panes still unbuilt.
    ///
    /// **Power & Freq shipped 2026-09-03 (phase-11)** and is the first `PRO` row to lose its
    /// disabled state. It keeps its seat at the head of the block -- §3.2's order is the
    /// reference layout's and does not change because a row became selectable -- and takes
    /// ⌘8 (§3.4). §14.1 specifies it.
    ///
    /// **Connections and Installed Apps shipped 2026-09-04 (phase-12)** and flip in place,
    /// second and third in the block, keeping their seats (D-01); ⌘9 and ⌘0 (§3.4/§3.5). §14.5
    /// and §14.3 specify them. Two `PRO` rows remain unbuilt.
    ///
    /// **Disk Space shipped 2026-09-08 (phase-13)** and flips in place, fourth in the block,
    /// keeping its seat (D-01); ⌘D, the first pane bound to a letter rather than a digit
    /// (D-02). §14.6 specifies it. `Benchmarks` alone remains.
    static let all: [SidebarRow] = [
        .pane(.summary, title: "Summary", symbol: "square.grid.2x2", comingIn: nil),
        .pane(.performance, title: "Performance", symbol: "waveform.path.ecg", comingIn: nil),
        .pane(.processes, title: "Processes", symbol: "list.bullet.rectangle", comingIn: nil),
        .pane(.systemInfo, title: "System Info", symbol: "desktopcomputer", comingIn: nil),
        .pane(.startupApps, title: "Startup apps", symbol: "power", comingIn: nil),
        .pane(.users, title: "Users", symbol: "person.2", comingIn: nil),
        .pane(.services, title: "Services", symbol: "gearshape.2", comingIn: nil),
        .proHeader,
        .pane(.power, title: "Power & Freq", symbol: "bolt", comingIn: nil),
        .pane(.connections, title: "Connections", symbol: "network", comingIn: nil),
        .pane(.installedApps, title: "Installed Apps", symbol: "app.badge", comingIn: nil),
        .pane(.diskSpace, title: "Disk Space", symbol: "internaldrive", comingIn: nil),
        .disabled(title: "Benchmarks", symbol: "speedometer", comingIn: "backlog 999.1"),
        .divider,
        .disabled(title: "Settings", symbol: "slider.horizontal.3", comingIn: "unscheduled"),
        .pane(.colors, title: "Colors", symbol: "paintpalette", comingIn: nil),
    ]
}
