import GlowTopCore
import SwiftUI

/// SPEC.md §3.1-3.3 and §4.7: the window, the sidebar, the detail area, the status bar.
///
/// SwiftUI owns exactly this much — the split view, the rows, the chrome. Everything inside
/// the detail area is one AppKit view (§6.5, §6.9), and nothing SwiftUI observes changes more
/// than once a second.
struct ShellView: View {
    let store: MetricStore
    @Bindable var state: AppState

    private var theme: Theme { ThemeStore.shared.theme }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 260, max: 260)
                // §3.2: the sidebar is fixed, not collapsible, in M01. SwiftUI adds a
                // collapse toggle to the title bar by default, and a control that hides a
                // sidebar the spec calls fixed is a feature nobody specified.
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // §3.1's `titlebarAppearsTransparent = true`, by the lever SwiftUI honours: the
        // `Window` scene re-asserts the AppKit bit after any direct set — from the launch
        // pass and from `viewDidMoveToWindow` both — while this modifier makes SwiftUI set
        // the bit itself (the gate-9 geometry line reads titlebarTransparent=true).
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background(theme.color("background"))
    }

    // MARK: - §3.2 sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(SidebarRow.all.enumerated()), id: \.offset) { _, row in
                    switch row {
                    case .pane(let pane, let title, let symbol, let comingIn):
                        SidebarRowView(
                            theme: theme, title: title, symbol: symbol,
                            selected: state.selectedPane == pane && comingIn == nil,
                            comingIn: comingIn
                        ) {
                            state.selectedPane = pane
                        }
                    case .disabled(let title, let symbol, let comingIn):
                        SidebarRowView(theme: theme, title: title, symbol: symbol,
                                       selected: false, comingIn: comingIn, action: {})
                    case .proHeader:
                        Text("PRO")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(theme.color("textDisabled"))
                            .padding(.leading, 12)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                    case .divider:
                        Rectangle()
                            .fill(theme.color("cardBorder"))
                            .frame(height: 1)
                            .padding(.vertical, 8)
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(theme.color("sidebarBackground"))
        .overlay(alignment: .trailing) {
            // §3.2's literal #1E1E26 — one hex digit from cardBorder's #1E1E28 and not it.
            Rectangle()
                .fill(Color(hex: SpecLiteralColor.sidebarRule))
                .frame(width: 1)
        }
    }

    // MARK: - §3.3 detail area + §4.7 status bar

    private var detail: some View {
        VStack(spacing: 0) {
            PaneHostRepresentable(store: store, state: state)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            statusBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("background"))
    }

    private var statusBar: some View {
        HStack(spacing: 0) {
            Text(state.statusLeading)
                .font(.system(size: 11))
                .foregroundStyle(theme.color(state.statusPhraseToken))
                .help(state.statusTooltip)
            Spacer()
            Text(state.clock)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.color("textSecondary"))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(theme.color("sidebarBackground"))
        .overlay(alignment: .top) {
            Rectangle().fill(theme.color("cardBorder")).frame(height: 1)
        }
    }
}

/// Bridges §3.3's AppKit pane container into the SwiftUI detail area. `updateNSView` is one
/// line: SwiftUI owns the shell, and everything about which pane is visible and what happens
/// when it changes belongs to `PaneHostView.show(_:)`, not to this representable.
private struct PaneHostRepresentable: NSViewRepresentable {
    let store: MetricStore
    let state: AppState

    func makeNSView(context: Context) -> PaneHostView {
        PaneHostView(store: store, state: state)
    }

    func updateNSView(_ view: PaneHostView, context: Context) {
        view.show(state.selectedPane)
    }
}

/// One §3.2 row. A disabled row is deliberately not a `NavigationLink` that refuses to
/// navigate: §3.2 asks for 40 % opacity and a tooltip, and a control that looks live and does
/// nothing is a worse lie than one that visibly is not a control.
private struct SidebarRowView: View {
    let theme: Theme
    let title: String
    let symbol: String
    let selected: Bool
    let comingIn: String?
    let action: () -> Void

    @State private var hovering = false

    private var disabled: Bool { comingIn != nil }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(selected ? theme.color("accentCPU") : .clear)
                .frame(width: 3)
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 20)
                .padding(.leading, 9)
            Text(title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .padding(.leading, 12)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? theme.color("textPrimary") : Color(hex: "#9A9AA8"))
        .frame(height: 32)
        .background(background)
        .opacity(disabled ? 0.4 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 && !disabled }
        .onTapGesture { if !disabled { action() } }
        // §3.2 as amended for 1.1.1. Two things were wrong with this tooltip. It printed promises
        // that had lapsed ("Coming in M02", "Coming in phase 05"); and it had never once
        // appeared, because an `.allowsHitTesting(!disabled)` sat here and a view that refuses
        // hit testing gets no tooltip either. The hover and the tap above already guard on
        // `disabled`, so the row stays inert without it -- read live, 2026-09-21.
        .help(disabled ? "Not in this version" : "")
    }

    private var background: Color {
        if selected { return Color(hex: "#1C1C26") }
        if hovering { return Color(hex: "#16161D") }
        return .clear
    }
}
