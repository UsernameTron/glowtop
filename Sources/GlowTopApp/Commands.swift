import GlowTopCore
import SwiftUI

/// SPEC.md §3.4's menu bar and the half of §3.5 that belongs in menus.
///
/// `Space` and `⌘R` are deliberately **not** here — they are bound on the pane view. §3.5
/// says `Space`'s collision with a focused text field is correct and expected, and that only
/// holds if the binding is view-local; a `.commands` entry would swallow the space bar
/// everywhere in phase-04's search field.
struct GlowTopCommands: Commands {
    @Bindable var state: AppState

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            // No Settings scene exists in M01, so the item is present and disabled and ⌘,
            // is unbound. A shortcut that opens nothing is worse than no shortcut.
            Button("Settings…") {}.disabled(true)
        }

        CommandGroup(replacing: .help) {
            Button("GlowTop Help") {}.disabled(true)
        }

        // `.sidebar` places these inside AppKit's own View menu (§3.4's table) rather than
        // appending a second menu titled "View" beside it — the prior declaration here did
        // exactly that, and the duplicate was phase-03's last carried item.
        CommandGroup(replacing: .sidebar) {
            Button("Summary") { state.selectedPane = .summary }
                .keyboardShortcut("1", modifiers: .command)

            Button("Performance") { state.selectedPane = .performance }
                .keyboardShortcut("2", modifiers: .command)
            Button("Processes") { state.selectedPane = .processes }
                .keyboardShortcut("3", modifiers: .command)
            Button("System Info") { state.selectedPane = .systemInfo }
                .keyboardShortcut("4", modifiers: .command)
            Button("Startup apps") { state.selectedPane = .startupApps }
                .keyboardShortcut("5", modifiers: .command)
            Button("Users") { state.selectedPane = .users }
                .keyboardShortcut("6", modifiers: .command)
            Button("Services") { state.selectedPane = .services }
                .keyboardShortcut("7", modifiers: .command)
            Button("Power & Freq") { state.selectedPane = .power }
                .keyboardShortcut("8", modifiers: .command)
            Button("Connections") { state.selectedPane = .connections }
                .keyboardShortcut("9", modifiers: .command)
            Button("Installed Apps") { state.selectedPane = .installedApps }
                .keyboardShortcut("0", modifiers: .command)
            Button("Disk Space") {
                if state.selectedPane == .diskSpace {
                    state.diskSpaceSelectHomeRoot?()
                } else {
                    state.selectedPane = .diskSpace
                }
            }
            .keyboardShortcut("d", modifiers: .command)

            Divider()

            Button(state.showFPSOverlay ? "Hide FPS Counter" : "Show FPS Counter") {
                state.showFPSOverlay.toggle()
            }
            .keyboardShortcut("f", modifiers: [.shift, .command])

            // §4.10. No key equivalent on purpose: gate 12 asserts the View menu's letter
            // shortcuts are exactly ⌘D and ⇧⌘F, and a display preference does not need one.
            Button(state.displayMode == .simple ? "Use Technical Labels" : "Use Simple Labels") {
                state.displayMode = state.displayMode == .simple ? .technical : .simple
            }
        }

        CommandMenu("Colors") {
            // §7.4's three presets, live (3.2). `Edit Colors…` selects §7.3's editor (3.3).
            Button(presetTitle("Neon")) { ThemeStore.shared.select(preset: "Neon") }
            Button(presetTitle("Classic Green")) { ThemeStore.shared.select(preset: "Classic Green") }
            Button(presetTitle("Amber Retro")) { ThemeStore.shared.select(preset: "Amber Retro") }
            Divider()
            Button("Edit Colors…") { state.selectedPane = .colors }
        }
    }

    private func presetTitle(_ name: String) -> String {
        ThemeStore.shared.presetName == name ? "✓ \(name)" : name
    }
}
