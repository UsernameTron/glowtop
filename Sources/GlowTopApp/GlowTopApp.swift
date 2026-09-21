import GlowTopCore
import QuartzCore
import SwiftUI

@main
struct GlowTopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    /// One store for the app's lifetime. SPEC.md §3.3 releases a pane when the user switches
    /// away and rebuilds it on return; delta baselines live in this store, so they survive it.
    @State private var store = MetricStore()
    @State private var state = AppState()

    var body: some Scene {
        // `Window`, not `WindowGroup`: §3.1 specifies one window and no tabs, and
        // `WindowGroup` gives ⌘N a second one.
        Window("GlowTop", id: "main") {
            ShellView(store: store, state: state)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1440, height: 900)
        .commands { GlowTopCommands(state: state) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Phase-09: which chart path this process installed, so a paired reading is a grep
        // and not an assumption. Matches neither pattern the overhead harness parses.
        print("charts: \(SummaryPaneView.chartPathName)")
        fflush(stdout)

        // SPEC.md §3.1: forced dark; the whole palette is luminous marks on near-black.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        // §3.4: unbundled, the first menu reads the executable's name ("GlowTopApp"). The
        // fix that matters is CFBundleName in 5.1's packaged Info.plist; this is the runtime
        // attempt for an unbundled run, which SwiftUI's `Window` scene may re-assert after
        // (4.2's outcome B, the same shape §3.1 records for `titlebarAppearsTransparent`).
        if let appMenuItem = NSApp.mainMenu?.items.first {
            appMenuItem.title = "GlowTop"
            appMenuItem.submenu?.title = "GlowTop"
        }

        if ProcessInfo.processInfo.environment["GLOWTOP_SELFCHECK"] != nil {
            runSelfCheck()
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // §3.1: the window remembers where it was.
        DispatchQueue.main.async {
            NSApp.windows.first?.setFrameAutosaveName("GlowTopMainWindow")
        }

        // Measurement hooks (SPEC.md §13.1.5). These pin the variables the overhead
        // harness has to hold constant -- which display, what geometry, whether the
        // window is composited at all. They do nothing unless their variable is set.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.applyMeasurementHooks()
        }
    }

    private var coverWindow: NSWindow?

    private func applyMeasurementHooks() {
        let environment = ProcessInfo.processInfo.environment
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }

        // Same display and same geometry across arms, or the arms are not comparable.
        // GLOWTOP_WINDOW_SIZE=WxH is the surface-area arm (SPEC.md §13.1.7): the bars
        // stay the same size and count, only the window surface changes.
        if let index = environment["GLOWTOP_SCREEN"].flatMap(Int.init),
           NSScreen.screens.indices.contains(index) {
            let screen = NSScreen.screens[index]
            let frame = screen.visibleFrame
            let dims = environment["GLOWTOP_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) }
            let size = dims?.count == 2 ? CGSize(width: dims![0], height: dims![1]) : CGSize(width: 900, height: 400)
            window.minSize = .zero
            window.contentMinSize = .zero
            window.setFrame(
                NSRect(x: frame.minX + 80, y: frame.minY + 80, width: size.width, height: size.height),
                display: true
            )
        }

        if environment["GLOWTOP_MINIMIZE"] != nil {
            window.miniaturize(nil)
        }

        // An opaque window covering the bars entirely. macOS then stops compositing the
        // window underneath, so the app keeps sampling and animating while nothing is
        // drawn -- which is the point of the control.
        if environment["GLOWTOP_COVER"] != nil {
            let cover = NSWindow(
                contentRect: window.frame.insetBy(dx: -40, dy: -40),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            cover.backgroundColor = .black
            cover.isOpaque = true
            cover.level = .floating
            cover.orderFrontRegardless()
            coverWindow = cover
        }

        if let screen = window.screen {
            // Surface properties are printed because any one of them makes WindowServer
            // blend the whole window every frame regardless of what is inside it.
            let scale = screen.backingScaleFactor
            print("window on screen refresh=\(screen.maximumFramesPerSecond) "
                  + "frame=\(Int(window.frame.width))x\(Int(window.frame.height)) "
                  + "occluded=\(!window.occlusionState.contains(.visible)) "
                  + "backing=\(Int(screen.frame.width * scale))x\(Int(screen.frame.height * scale))px "
                  + "opaque=\(window.isOpaque) shadow=\(window.hasShadow) "
                  + "bgAlpha=\(window.backgroundColor.alphaComponent) "
                  + "titlebarTransparent=\(window.titlebarAppearsTransparent) "
                  + "fullSizeContent=\(window.styleMask.contains(.fullSizeContentView)) "
                  + "contentLayerOpaque=\(window.contentView?.layer?.isOpaque ?? false) "
                  // Phase-09's instrument B: `screencapture -l` takes this CGWindowID. Appended to
                  // a line the harness passes through verbatim (`-v geom=`) and never parses.
                  + "windowNumber=\(window.windowNumber)")
            fflush(stdout)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Verifies that a `contentsRect` crop reveals the bottom of a vertical meter and the
    /// leading edge of a horizontal one, against rendered pixels rather than by reasoning.
    /// SPEC.md §6.5, gate 12 (§13.7.12).
    ///
    /// Both axes, eight assertions. The horizontal crop is a second platform convention, not
    /// a consequence of the first: transliterating the vertical case fills the memory meter
    /// and all fourteen per-core strips from the wrong end, which is identical at 50 % and
    /// symmetric enough elsewhere to survive a glance.
    @MainActor private func runSelfCheck() {
        let theme = ThemeStore.shared.theme
        var failures = 0

        for axis in [MeterAxis.vertical, .horizontal] {
            let name = axis == .vertical ? "vertical" : "horizontal"
            for value in [0.25, 0.5, 0.75, 1.0] {
                guard let result = MeterLayer.selfCheck(value: value, axis: axis, theme: theme) else {
                    print("selfcheck axis=\(name) value=\(value) FAIL — no lit pixels found")
                    failures += 1
                    continue
                }
                // One segment plus its gap, plus slack for the glow's soft edge bleeding
                // past both ends of the lit run.
                let slack: CGFloat = 8
                // Length AND origin. Length alone passes on a meter filled from the wrong
                // end, which is what breaking this check deliberately established.
                let ok = abs(result.expected - result.measured) <= slack
                    && abs(result.origin) <= slack
                print(String(
                    format: "selfcheck axis=%@ value=%.2f expected_lit=%.1f measured=%.1f origin=%.1f %@",
                    name, value, result.expected, result.measured, result.origin,
                    ok ? "PASS" : "FAIL"
                ))
                if !ok { failures += 1 }
            }
        }

        // The pane arm (§5.10, plan 4.2): the whole Summary pane rendered offscreen, §4.8
        // asserted against pixels. Eight assertions since phase-05 (4.2); the count is part of
        // gate 3's check.
        // Phase-10 (5.1): two panes, the pane's name in the line. No script parses it.
        // Phase-11 (5.1): a third. A pane absent from this array passes silently (F-2).
        // Phase-12 (5.1): a fourth and fifth -- structural arms (O-4), not pixel arms.
        // Phase-13 (5.1): a sixth -- `TreemapLayout`'s output, not a controller (D-26, O-6).
        // Phase-14 (4.2): a seventh and eighth -- structural arms, same shape as phase-12's.
        // 1.1.1 (2026-09-21): a ninth -- Processes, for §8.5's first guardrail layer (§14.9).
        for (pane, assertions) in [("summary", SummaryPaneView.paneSelfCheck()),
                                   ("performance", PerformancePaneView.paneSelfCheck()),
                                   ("power", PowerFreqPaneView.paneSelfCheck()),
                                   ("connections", ConnectionsPaneController.paneSelfCheck()),
                                   ("installedApps", InstalledAppsPaneController.paneSelfCheck()),
                                   ("diskSpace", DiskSpacePaneController.paneSelfCheck()),
                                   ("startupApps", StartupAppsPaneController.paneSelfCheck()),
                                   ("services", ServicesPaneController.paneSelfCheck()),
                                   ("processes", ProcessesPaneController.paneSelfCheck()),
                                   ("summaryScroll", SummaryPaneController.paneSelfCheck())] {
            for assertion in assertions {
                print("selfcheck pane \(pane) \(assertion.name) \(assertion.detail) "
                      + (assertion.pass ? "PASS" : "FAIL"))
                if !assertion.pass { failures += 1 }
            }
        }

        // 3.2: proves `ThemeStore`'s live switch reaches rendered pixels, against an isolated
        // store so the real `UserDefaults` domain is never touched.
        let themeAssertion = SummaryPaneView.themeSwitchSelfCheck()
        print("selfcheck theme \(themeAssertion.detail) " + (themeAssertion.pass ? "PASS" : "FAIL"))
        if !themeAssertion.pass { failures += 1 }

        // 1.2: the duplicate View menu fix, asserted against the actual menu bar rather than
        // against the diff — a menu renamed to dodge the first assertion still fails §3.4's
        // table, which is what the reviewer checks (phase-04 plan, sub-step 1.2's Failure note).
        let viewMenus = NSApp.mainMenu?.items.filter { $0.title == "View" } ?? []
        let viewMenuOK = viewMenus.count == 1
        print("selfcheck menu view-menu-count=\(viewMenus.count) \(viewMenuOK ? "PASS" : "FAIL")")
        if !viewMenuOK { failures += 1 }

        let shortcuts = (viewMenus.first?.submenu?.items ?? [])
            .map(\.keyEquivalent)
            .filter { $0.count == 1 && $0.first!.isNumber }
            .sorted()
        let shortcutsOK = Set(shortcuts) == ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]
        print("selfcheck menu shortcuts=\(shortcuts.joined(separator: ",")) "
              + (shortcutsOK ? "PASS" : "FAIL"))
        if !shortcutsOK { failures += 1 }

        // D-04: the block above filters key equivalents to digits before comparing, so a letter
        // shortcut is invisible to it -- binding ⌘D would pass gate 12 silently, which is exactly
        // the shape F-2 records one level up ("a pane absent from the array passes silently").
        let letterShortcuts = (viewMenus.first?.submenu?.items ?? [])
            .map(\.keyEquivalent)
            .filter { $0.count == 1 && !$0.first!.isNumber }
            .sorted()
        let letterShortcutsOK = letterShortcuts == ["d", "f"]
        print("selfcheck menu letter-shortcuts=\(letterShortcuts.joined(separator: ",")) "
              + (letterShortcutsOK ? "PASS" : "FAIL"))
        if !letterShortcutsOK { failures += 1 }

        // 4.2: the app-menu name, checked against the live menu bar itself.
        let appMenuTitle = NSApp.mainMenu?.items.first?.title ?? "?"
        let appMenuTitleOK = appMenuTitle == "GlowTop"
        print("selfcheck menu app-menu-title=\(appMenuTitle) " + (appMenuTitleOK ? "PASS" : "FAIL"))
        if !appMenuTitleOK { failures += 1 }

        print(failures == 0 ? "selfcheck: PASS" : "selfcheck: \(failures) FAILED")
        fflush(stdout)
        if failures > 0 { exit(1) }
    }
}
