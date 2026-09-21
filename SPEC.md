# GlowTop — Specification v1

**Status:** Specification of the shipped product — GlowTop 1.2.0 (2026-09-21). Living document: amendments are dated inline and logged in §14.9.
**First written:** 2026-08-25 · **Last amended:** 2026-09-21
**Target platform:** macOS 14+ (developed on macOS 26.6.1, build 25G76; 1.1.2 verified on 26.6.2, build 25G83), Apple Silicon
**Toolchain:** Swift 6 (first built on 6.3.3; 1.1.2 verified on Xcode 27.0 / Swift 6.4 — full Xcode is required, not the Command Line Tools alone), SwiftPM (`swift-tools-version` 5.10), no third-party dependencies
**Reference layout:** the TMOG Summary pane, described in the phase-01 plan, §1.2
**Planning records:** phase plans, CONTEXT files, `STATE.md`, `ROADMAP.md`, `MILESTONES.md` and `REQUIREMENTS.md` are cited here by name for provenance; they are the project's planning records, kept in a private archive, not in the public tree.

This document is the contract. Every feature that ships must trace to a section here (see §14.8, Traceability). Where this document and an implementation disagree, this document is wrong until it is edited — code does not silently redefine the spec.

A note on how to read the numbers: every threshold in this document is a number, not an adjective. "Fast" and "smooth" are not acceptance criteria; "58–60 fps measured over 60 seconds" is. Where a number is a guess that has not yet been measured on real hardware, it is marked **(provisional)** and the phase that will replace it with a measurement is named.

---

## 1 Purpose & non-goals

### 1.1 What GlowTop is

GlowTop is a native macOS desktop application that displays the live state of the machine it runs on: processor load per logical core, memory pressure and composition, disk throughput, network throughput, energy draw, GPU and Neural Engine activity, thermal state, and the full process table. It presents this on a dark, neon-accented dashboard whose meters and charts animate continuously at the display's refresh rate rather than stepping once per second.

It is a personal tool. The primary user is its owner, who keeps it open on a second display all day in place of Activity Monitor. It is not a product, has no users to onboard, no telemetry, no accounts, and no network surface at all.

### 1.2 Why it exists

Activity Monitor answers "what is my machine doing" slowly and coarsely: a 1–5 second refresh, no per-core detail without opening a separate window, no thermal or Neural Engine visibility, and a visual design that makes trends hard to see at a glance. `htop` in a terminal is faster but text-only and blind to GPU, energy, and thermal data. Third-party monitors exist but are closed, subscription-priced, or bundle features their owner did not ask for.

The specific trigger is a published account of TMOG — a system monitor built by feeding a 107-page written specification to Claude Code, which produced a working native app in about 4.5 hours. TMOG is closed-source, Swift and AppKit, and cannot ship on the Mac App Store because the sandbox blocks the process list. GlowTop replicates the *method*, not the code: a written specification precedes any implementation, native APIs are used directly, and the result is owned end to end and extensible by its owner.

### 1.3 What GlowTop must get right

In priority order. When a trade-off arises, the higher item wins.

1. **Correct numbers.** A monitor that displays a plausible-looking wrong number is worse than no monitor. Every provider is cross-checked against a system tool (`top`, `ps`, `vm_stat`, `netstat`, `sysctl`, `ioreg`) before it ships.
2. **Never crash.** Hardware sensors are inconsistent across Macs and macOS versions. A missing sensor renders `—` in its tile. It never throws, never traps, never takes the app down.
3. **Continuous motion.** Meters animate at the display refresh rate. Motion is what makes a spike visible in peripheral vision; a stepping meter is a table with extra steps.
4. **Negligible cost.** A monitor that consumes measurable resources corrupts its own measurement and is not worth keeping open. The budget is §13.
5. **Legibility at a glance.** Reading the dashboard from two feet away, without focusing, must convey whether the machine is idle, busy, or in trouble.

### 1.4 Non-goals

These are excluded deliberately. Each entry states why, so the exclusion is not silently revisited.

| Non-goal | Reason |
|---|---|
| Windows or Linux builds | Every metric source in §5 is a macOS kernel or IOKit interface. A cross-platform build means a second data layer for a single user who owns one Mac. |
| Mac App Store distribution | The App Store requires sandboxing. The sandbox blocks `proc_listallpids`, blocks reading other processes' resource usage, and blocks process termination. The Processes pane (§8) is the app's second reason to exist; sandboxing removes it. |
| Any web technology in the UI (Electron, Tauri, React) | §6 requires drawing 14–24 animated meters plus two streaming charts every display frame inside §13.1's app-process budget (first written as under 3 % of one core, before any measurement; ruled to ≤ 35 % on 2026-08-28, §13.1.11). A browser engine adds its own cost before drawing anything. |
| Remote or multi-machine monitoring | No network surface at all (§2.5). Monitoring another machine means a wire protocol, an agent, and an authentication story — all of which are larger than the app. |
| Historical persistence / a metrics database | The dashboard's memory is its ring buffers: 60 seconds of history in RAM (§6.4). Nothing is written to disk. Long-term history is a different product. |
| Alerting, thresholds, notifications | The tool is watched, not consulted. There is nobody to page. |
| Configurable dashboards / drag-to-rearrange tiles | The layout in §4 is the layout. Making it configurable adds a persistence format, a layout engine, and an editing mode for one user who wants one arrangement. |
| Copying TMOG's binary, assets, wordmark, or name | Not ours. GlowTop is an independent implementation from a written specification. |
| `sudo`, root helpers, privileged daemons | Everything in §5 is readable unprivileged. `powermetrics` would give better energy data but requires root, which is a disqualifying cost for a always-open desktop app. |

### 1.5 Scope of this document

Sections 1–13 specify M01 and M02 behavior in implementable detail. Section 14 began as a low-resolution outline of M02's "Pro" panes; each subsection that shipped has since been expanded in place to the same detail (§14.2 and §14.7 remain outlines). Section 14.8 maps every feature to its section and its phase.

---

## 2 Platform & constraints

### 2.1 Operating system

**Minimum: macOS 14.0 (Sonoma).** Developed on macOS 26.6.1 (build 25G76); 1.1.2 verified on 26.6.2 (build 25G83).

macOS 14 is the floor for three reasons:

1. `NSView.displayLink(target:selector:)` — the display-link API used in §6.2 — is macOS 14+. On macOS 13 the fallback is `CVDisplayLink`, which is deprecated in 15 and carries a threading model the app does not otherwise need.
2. Swift 6 language mode with strict concurrency checking requires a recent toolchain and interacts badly with older SDKs.
3. The owner's machine runs macOS 26. Supporting 13 means testing on 13, and there is no machine to test on.

If the app is ever run on macOS 13, it does not launch — `LSMinimumSystemVersion` is set to `14.0`, and the failure is a clear Finder dialog rather than a crash.

### 2.2 Architecture

**Apple Silicon (`arm64`) only.** Two hard dependencies:

- The performance/efficiency core split (§5.1.4) is read from `hw.perflevel0.logicalcpu` and `hw.perflevel1.logicalcpu`. These keys do not exist on Intel.
- The GPU, Neural Engine, and thermal providers (§5.6, §5.6.4, §5.8) read Apple Silicon SoC-specific IOKit subsystems. On Intel they would return `.unavailable` for every tile, leaving three empty tiles and an app that mostly does not work.

The binary is built `arm64` only. There is no Rosetta path and no universal binary in M01–M03.

Verified reference machine: 14 logical cores — 10 performance (`hw.perflevel0.logicalcpu`), 4 efficiency (`hw.perflevel1.logicalcpu`). The UI must not assume 14; core count is read at runtime and the layout adapts (§4.3.1).

### 2.3 Sandboxing and entitlements

**The app is not sandboxed.** This is a deliberate, irreversible product decision, and it is the reason App Store distribution is a non-goal (§1.4).

Specifically, the sandbox blocks:

- `proc_listallpids` — returns only the calling process. The Processes pane (§8) would list one row.
- `proc_pid_rusage` / `proc_pidinfo` for other processes — no CPU or memory per process.
- `kill(2)` against processes outside the sandbox — the kill action (§8.5) fails with `EPERM`.

Entitlements in M01: none required. The app requests no TCC-protected resources — no camera, microphone, contacts, calendar, Photos, or Full Disk Access. It reads no user documents. Notably, the metrics in §5 are all available to an ordinary unprivileged process with no entitlement and no user consent prompt.

**Hardened Runtime** is enabled from M03 (a notarization requirement) — the installed signed bundle reads `flags=0x10000(runtime)`, and `codesign -d --entitlements -` prints no entitlement beyond the `Executable=` line. None of the metric sources require disabling library validation or JIT: phase-16's 2.1 opened the signed bundle without §13.7's flag and read every private tile (GPU, Energy/NPU, Thermals, Frequency) live, with `log show`'s `library validation` line count at 0 — §14.11 states why (the two `dlopen` targets are Apple platform binaries in the dyld shared cache, which library validation admits by construction) and phase-16 is where that argument was proved live rather than assumed.

### 2.4 Privileges

The app runs as the logged-in user. It never calls `sudo`, never installs a privileged helper tool, never registers a `launchd` daemon, and never runs `powermetrics` (which requires root).

The consequence is a specific, accepted degradation: package power in watts (§5.6.3) is read from IOReport's energy counters rather than from `powermetrics`, which means it is a computed rate over an interval rather than a vendor-blessed instantaneous figure. §5.6.3 specifies the arithmetic and marks the confidence level.

### 2.5 Network

**Zero network access at any point.** No update check, no telemetry, no crash reporting, no remote configuration, no font or asset download. The app makes no outbound connection and opens no listening socket.

This is testable and is a shipping gate: with the app running for 10 minutes, `lsof -nP -i -a -p $(pgrep -x GlowTopApp)` must return no rows (§13.7.7).

### 2.6 Dependencies

**Zero third-party packages.** `Package.swift` declares an empty `dependencies` array, and that emptiness is itself a gate (§13.7.6).

First-party frameworks used: Foundation, SwiftUI, AppKit, CoreGraphics, QuartzCore, IOKit, Darwin (mach, sysctl, libproc), OSLog, Security (§14.3), Observation, UniformTypeIdentifiers, ImageIO (gate 12's capture), and — in `glowtop-probe` only, as §13.6's load generators — Metal and Vision; Collections is *not* used (it is a package, not a framework).

Swift Charts is explicitly rejected for the streaming charts (§6.6) — its redraw path is not reliably frame-locked for data that changes every frame, and the CPU overlay chart (§4.4) is exactly that. Custom `CGPath` drawing is used instead.

Rationale for zero dependencies: the audit surface is the whole point of a system monitor that reads kernel state. A dependency graph means reading someone else's code before trusting the numbers, and it means a build that can break without any local change.

### 2.7 Build system

**SwiftPM only.** `swift build` is the canonical build. No `.xcodeproj` or `.xcworkspace` is committed; both are in `.gitignore`.

Targets:

| Target | Type | Contents | May import |
|---|---|---|---|
| `GlowTopCore` | library | Metric providers, `Snapshot` types, `MetricStore`, `RingBuffer` | Foundation, Darwin, IOKit, OSLog, Security |
| `GlowTopApp` | executable | SwiftUI shell, AppKit views, theme, all panes | everything, plus `GlowTopCore` |
| `glowtop-probe` | executable | CLI that prints provider samples as JSON | Foundation, `GlowTopCore`, and — for §13.6's load generators only — Metal, Vision and CoreGraphics |
| `GlowTopCoreTests` | test | Provider unit tests | XCTest, `GlowTopCore` |

The layering rule is enforced and is a build gate: **`GlowTopCore` must not import AppKit or SwiftUI.** A provider that needs a UI type has been designed wrong. This is what allows `glowtop-probe` and the test suite to exercise every provider with no window and no run loop.

Build settings: `swift-tools-version: 5.10`, `platforms: [.macOS(.v14)]`, strict concurrency checking enabled, and **zero warnings** — a warning is a build failure for the purpose of the phase gate (§13.7.1).

### 2.8 Distribution

M01–M02: ad-hoc signed (`codesign -s -`), built locally, copied to `~/Applications`. Gatekeeper will warn on any other machine; that is acceptable because there is no other machine.

M03: Developer ID signing, notarization, stapling, DMG — specified in §14.11. The constraint on M01–M02 stands: nothing may depend on being unsigned or on a disabled Hardened Runtime, and M03 changes nothing in `Sources/`.

**As built (phase-16).** `scripts/package-app.sh` selects the identity from `GLOWTOP_SIGN_IDENTITY`; unset, it signs exactly as it has since phase-05 (the paragraph above), so every gate instrument's control is unchanged. Set to `Developer ID Application: Christopher Connor (G7FX8CR43U)`, it adds `--options runtime --timestamp`, asserts the four §14.11 signature facts, submits a `ditto` zip through the `glowtop-notary` keychain profile, staples the ticket, and installs the notarized bundle. `Info.plist` read `1.1.0` / `2` at that build; it has been bumped per release since (`1.2.0` / `6` as of 2026-09-21).

**The bundle, as built (phase-05).** `scripts/package-app.sh` assembles `GlowTop.app` at
`Contents/MacOS/GlowTopApp`, `Contents/Resources/GlowTop.icns`, `Contents/Info.plist` and
`Contents/PkgInfo`, then `codesign --force --sign - --identifier com.glowtop.GlowTop` and
installs to the literal path `~/Applications/GlowTop.app`. `CFBundleIdentifier` is
`com.glowtop.GlowTop` — the same domain §7.4's three theme keys and §8.2's
`processes.columns` key already write `UserDefaults` under, so changing it here would orphan
both. `CFBundleExecutable` stays `GlowTopApp` rather than `GlowTop`: five gate instruments
(`pgrep -x GlowTopApp`, `scripts/overhead-harness.sh`, gate 7's `lsof`, gate 10's RSS reads,
§9.2's own-RSS row) grep that name, and `CFBundleName`/`CFBundleDisplayName` (both `GlowTop`)
are the fields the menu bar and Finder actually read for display. Verification, run after
every package:

```
codesign --verify --strict --verbose=2 ~/Applications/GlowTop.app
# → valid on disk, satisfies its Designated Requirement
codesign -dv ~/Applications/GlowTop.app 2>&1 | grep 'Identifier='
# → Identifier=com.glowtop.GlowTop
```

Signed with a Developer ID identity, two more checks hold:

```
spctl --assess -vv --type execute ~/Applications/GlowTop.app
# → accepted, source=Notarized Developer ID
xcrun stapler validate ~/Applications/GlowTop.app
# → The validate action worked!
```

### 2.9 Reference hardware

| Property | Value |
|---|---|
| macOS | 26.6.1 (25G76) at first build; 26.6.2 (25G83) as of 1.1.2 |
| Architecture | arm64 |
| Logical cores | 14 |
| Performance cores | 10 |
| Efficiency cores | 4 |
| Physical memory | 48 GB (`hw.memsize` = 51539607552) — the 128 GB in §4.5's example values comes from the TMOG reference screenshot, not from this machine |
| Swift | 6.3.3 at first build; 6.4 (Xcode 27.0) as of 1.1.2 |

Every provisional number in this document assumes this machine. Numbers that would differ materially on a smaller Mac (an 8-core MacBook Air) are called out where they occur.

---

## 3 Window & navigation model

### 3.1 Window

A single main window. No document model, no tabs, no multiple windows in M01.

| Property | Value |
|---|---|
| Default size | 1440 × 900 points |
| Minimum size | 1100 × 700 points |
| Maximum size | unbounded (resizable, full-screen capable) |
| Title | `GlowTop` |
| Title bar | Standard, `titlebarAppearsTransparent = true`, `titleVisibility = .visible`. The bit is SwiftUI's: a direct AppKit set from the launch pass or `viewDidMoveToWindow` is re-asserted to `false` by the `Window` scene, while `.toolbarBackground(.hidden, for: .windowToolbar)` makes SwiftUI set it `true` itself (observed in the gate-9 geometry line). Set it through the modifier, never directly (phase-03). |
| Appearance | Forced dark (`NSApp.appearance = NSAppearance(named: .darkAqua)`) regardless of the system setting |
| Restoration | Frame saved under autosave name `GlowTopMainWindow`; sidebar selection saved in `UserDefaults` key `nav.selectedPane` |
| Closing behavior | Closing the window quits the app (`applicationShouldTerminateAfterLastWindowClosed` returns `true`) |

Below 1100 points wide, the tile grid (§4.3) cannot hold three columns without tiles becoming illegible; the minimum size enforces this rather than degrading.

The app is forced dark because the entire palette (§7) is built for luminous marks on a near-black ground. A light mode is a second palette, a second set of contrast decisions, and a second thing to test, for a tool used on a dark desktop.

### 3.2 Sidebar

A `NavigationSplitView` sidebar, 260 points wide, fixed (not collapsible in M01), background `#0E0E13`, separated from the detail area by a 1-point `#1E1E26` rule. *Measured 2026-09-02 (phase-10): the code requests 260 pt (`navigationSplitViewColumnWidth`), but the rendered sidebar measures ≈148 pt, so at the 1440 pt default the content width is 1260 pt rather than the 1148 §4.1 derives. §4's ≈ card widths are the 260 pt design figures; the percentages and gap rule are what the layout actually applies (§14.10).*

Items, in order:

```
  Summary                 (default selection)
  Performance
  Processes
  System Info
  Startup apps
  Users
  Services
  ─────── PRO ───────
  Power & Freq            (M02)
  Connections             (M02)
  Installed Apps          (M02)
  Disk Space              (M02)
  Benchmarks              (M02)
  ───────────────────
  Settings                (GlowTop's own — not in the reference sidebar)
  Colors                  (GlowTop's own — not in the reference sidebar)
```

Row specification:

| Property | Value |
|---|---|
| Row height | 32 points |
| Font | SF Pro Text 13 pt regular; selected row 13 pt medium |
| Icon | SF Symbol, 16 pt, 12 points from the leading edge; label 12 points after the icon |
| Idle text | `#9A9AA8` |
| Hover | background `#16161D` |
| Selected | background `#1C1C26`, text `#F2F2F7`, and a 3-point-wide accent bar on the leading edge in the current accent color |
| Section header (`PRO`) | SF Pro Text 10 pt semibold, tracking +0.08 em, color `#5A5A68`, 16 points above and 6 below |

The `PRO` section is not a paywall — GlowTop has no payment anything. It is a shipping boundary: those five panes are M02. In M01 they are visible but disabled (40 % opacity, not selectable, tooltip "Coming in M02"). Showing them disabled rather than hiding them keeps the sidebar's shape stable across milestones, and the reference layout has them. *Amended 2026-09-03 (phase-11):* `Power & Freq` is the first of the five to ship — it keeps its seat at the head of the block, loses its disabled state and its "Coming in M02" tooltip, and takes ⌘8 (§3.4); §14.1 specifies it, and the four rows below it stay disabled. *Amended 2026-09-04 (phase-12):* `Connections` and `Installed Apps` lose their disabled state and their "Coming in M02" tooltip, keeping their seats second and third in the block; §14.5 and §14.3 specify them, and `Disk Space` and `Benchmarks` stay disabled. *Amended 2026-09-08 (phase-13):* `Disk Space` loses its disabled state and its tooltip, keeping its seat fourth in the block; §14.6 specifies it, and `Benchmarks` alone stays disabled. *Amended 2026-09-21 (1.1.1):* the two rows still disabled, `Benchmarks` and `Settings`, carry the tooltip `Not in this version`. "Coming in M02" outlived M02 on `Benchmarks` when Connor's 2026-09-08 ruling moved it to backlog 999.1, and `Settings` read "Coming in phase 05" for a pane no section of this document specifies — two promises that had already lapsed. Neither had ever reached a user's screen, as it turned out: the row carried `.allowsHitTesting(false)`, and a SwiftUI view that refuses hit testing shows no `.help` tooltip, so this paragraph's tooltip had been specified, implemented and invisible since M01. The modifier is gone — the row's hover and tap handlers already guard on its disabled state — and the tooltip was read live on 2026-09-21, with a click on either row still doing nothing.

The item order above is the reference layout's, checked against it rather than assumed:
Power & Freq, Connections, Installed Apps, Disk Space, Benchmarks. An earlier version of
this list put Benchmarks second and omitted Connections entirely (§14.5).

**Ruled 2026-08-27: the Performance pane is M02's.** It used to sit second in the sidebar,
hold ⌘2 in §3.4's View menu, and appear in the SF Symbol table below — with nothing in this
document saying what it contained. §13 is the performance *budget*, not this pane, so the
pane was navigable, shortcut-bound, and unspecified: the same defect class §14.8's table
exists to prevent, one level up — a feature in the UI with no section behind it. Rather than
write M01 scope for it under gate pressure, it moves into the `PRO` block above, disabled
with the same "Coming in M02" tooltip the other five carry. §3.4's View menu drops it and
⌘2 stays reserved and unbound, so the eventual pane drops in without a renumbering pass.
M01 closes with no navigable-but-unspecified pane, and §14.8's table carries a row for it
naming M02. *Restored 2026-09-02 (phase-10):* the pane is specified in §14.10 and built, so the row leaves the `PRO` block and returns to second position — the seat it held before the ruling, and the one ⌘2's number matches — while §14.8's row and this section now both point at a section that exists.

SF Symbol per row: Summary `square.grid.2x2`, Performance `waveform.path.ecg`, Processes `list.bullet.rectangle`, System Info `desktopcomputer`, Startup apps `power`, Users `person.2`, Services `gearshape.2`, Power & Freq `bolt`, Connections `network`, Benchmarks `speedometer`, Installed Apps `app.badge`, Disk Space `internaldrive`, Settings `slider.horizontal.3`, Colors `paintpalette`.

### 3.3 Detail area

The selected sidebar item fills the detail area. Background `#0B0B0F` (§7.2). Panes are constructed on selection and **released when the user switches away** — phase-08's one kept RSS lever (§13.1.12, −49.60 MB on the seven-pane arm); switching back rebuilds the pane. Summary's providers live in `MetricStore`, which the host owns for the app's lifetime, so a rebuilt Summary does not re-warm a delta baseline (§5.0.3). A reader pane's own sort, search and selection start fresh on each visit; §8.3 and §8.4 do not require them to persist. *(Until 2026-09-01 this paragraph said panes were retained — the code had done the opposite since phase-08, recorded in §13.1.12 and §14.8 but not here.)*

Each pane owns its refresh cadence (§5) but **only the visible pane's providers sample.** Switching away from a pane suspends its providers within one sample interval; switching back resumes them and marks the first sample `.warming` (§5.0.3). The Summary pane is the exception: its providers keep sampling while any pane is visible, because the status bar (§4.7) reads from them and because Summary is the pane the user returns to.

A pane is also told when the **window's** occlusion changes (§6.2), so it may suspend its own timers behind a minimized or fully occluded window rather than continuing to sample for pixels nobody can see. In M01 only Summary acts on this; the hook takes a no-op default everywhere else, so a pane that has nothing to suspend says nothing.

### 3.4 Menu bar

| Menu | Items |
|---|---|
| GlowTop | About GlowTop, Settings… (present but disabled — no Settings scene exists; ⌘, is unbound), Services, Hide (⌘H), Hide Others (⌥⌘H), Quit (⌘Q) |
| View | Summary (⌘1), Performance (⌘2), Processes (⌘3), System Info (⌘4), Startup apps (⌘5), Users (⌘6), Services (⌘7), Power & Freq (⌘8), Connections (⌘9), Installed Apps (⌘0), Disk Space (⌘D), separator, Show/Hide FPS Counter (⇧⌘F), Use Simple/Technical Labels (§4.10, no key equivalent) |
| Colors | Neon (default), Classic Green, Amber Retro (a ✓ marks the active preset), separator, Edit Colors… |
| Window | standard |
| Help | GlowTop Help (present but disabled — not in this version) |

**The Performance item is in the View menu as of phase-10** and takes the ⌘2 that §3.2's 2026-08-27 ruling kept reserved for it; §14.10 specifies the pane it opens. **The Power & Freq item joins the View menu as of phase-11** at ⌘8, the first number past M01's seven; §14.1 specifies the pane it opens. **The Connections and Installed Apps items join the View menu as of phase-12**, at ⌘9 and ⌘0 — the ninth and tenth positions, and the last two digit keys available; §14.5 and §14.3 specify the panes they open. **The Disk Space item joins as of phase-13**, and it is the first pane item bound to a letter rather than a digit: the ten digits were spent at ⌘0, ⌘D is otherwise unbound in this app, and a pane that cannot be reached by a keystroke cannot be driven at all in this project's test environment, where key equivalents are the one input mechanism that has stayed reliable. §14.6 specifies the pane it opens.

There is no menu-bar (status-bar) extra in M01. A menu-bar mini mode is listed in §14.7.

### 3.5 Keyboard

| Key | Action |
|---|---|
| ⌘1 … ⌘9, ⌘0 | Select the corresponding pane |
| ⌘D | Select the Disk Space pane (§14.6). The digit keys ran out at ⌘0; this is the first pane bound to a letter, and a Benchmarks pane, if backlog 999.1 is ever built, faces the same question |
| ⇧⌘F | Toggle the FPS counter overlay (§6.7) |
| ⌘F | Focus the search field (Processes, Connections and Installed Apps panes) |
| ⌘R | Force an immediate sample of the visible pane's providers. Delta providers discard their baseline and re-warm (§5.0.3), so the first post-⌘R value arrives one sample interval later — §6.3 holds providers as task locals inside their loops, and forcing a sample restarts the loop. |
| ⌫ / ⌘⌫ | With a process row selected in the Processes pane, open the kill confirmation (§8.5) |
| Space | Pause / resume all sampling (the dashboard freezes; §6.8) |
| Esc | Dismiss the active sheet or confirmation |
| ⌘, | Unbound — no Settings scene exists in this version (§3.4) |

`Space` as a global pause is worth the collision risk with a focused text field: pausing is how you read a spike that just happened before it scrolls away. When a text field has focus, `Space` types a space and the pause is unavailable — that is correct and expected.

### 3.6 Launch behavior

1. The window appears within **1200 ms** of the app icon being clicked, with its layout drawn and every tile showing `—` or a warming state. It does not wait for data.
2. First real values appear within **400 ms** of the window (two sample intervals: one to establish a delta baseline, one to produce a delta).
3. Charts fill left-to-right as history accumulates; the CPU overlay chart (§4.4) reaches full width after 60 seconds.

An app that shows a spinner while it warms up is worse than one that shows its structure immediately with empty meters.

---

## 4 Summary pane layout

The Summary pane is the reason the app exists. It is a fixed four-row grid inside a scroll view; if the window is shorter than the content, the pane scrolls vertically, and nothing reflows or hides. *Amended 2026-09-21 (1.1.3):* the pane pins to the **top** of the detail area. Until 1.1.3 a window taller than the 778 pt content showed the cards at the bottom under a dead band, and a window shorter than it opened scrolled to the bottom: `NSClipView` takes its flippedness from its document view, and this pane's is unflipped. The scroll view now uses a flipped clip view; the pane's own bottom-left layer geometry is unchanged, and gate 12 asserts a 0 pt gap above the pane in a 1078 pt viewport (it read 300 pt before the fix).

### 4.1 Grid

| Property | Value |
|---|---|
| Outer padding | 16 points on all sides |
| Inter-card gap | 12 points, horizontal and vertical |
| Row heights | Row 1: 260 pt · Row 2: 150 pt · Row 3: 150 pt · Row 4: 150 pt |
| Total content height | 16 + 260 + 150 + 150 + 150 + (3 × 12) + 16 = 778 pt for the pane; + 32 (status bar) = 810 pt for the detail area. An earlier revision printed the sum of these same terms as 878, and a pane sized to the printed number carried 68 pt of dead space at its top (phase-03). |
| Column model | Row 1 is three cards at 22 % / 45 % / 33 % of content width; rows 2–4 divide content width evenly (row 2: one full-width card; rows 3 and 4: three equal cards) |

At the 1440-point default width, content width is 1440 − 260 (sidebar) − 32 (padding) = 1148 points. (As built the sidebar measures ≈148 pt and the content width is 1260 — §3.2's 2026-09-02 note; the arithmetic below is unchanged in form.) The 22 / 45 / 33 percentages apply to the content width **after** the two 12-point gaps are removed, so cards plus gaps sum exactly to the content width — 247.3 / 505.8 / 370.9 at the default. §4.3.1–§4.3.3's ≈ 253 / 517 / 379 are the ungapped percentages and stay as approximations; laid out literally they overflow the content width by 25 points and clip the process card (phase-03).

### 4.2 Card chrome

Every card in every pane shares one appearance:

| Property | Value |
|---|---|
| Background | `#101017` |
| Border | 1 pt, `#1E1E28` |
| Corner radius | 10 pt |
| Inner padding | 12 pt |
| Title | SF Pro Text 11 pt semibold, tracking +0.06 em, uppercase, color `#8A8A99`, top-leading |
| Headline value | SF Pro Display 24 pt medium, tabular figures, color = the card's accent |
| Footer | SF Pro Text 10 pt regular, color `#6E6E7E`, bottom-leading |
| Shadow | none (cards are flat; glow belongs to the marks, not the containers) |

**Tabular figures are mandatory on every number that changes.** Proportional digits make a value jitter horizontally as it updates, which reads as instability in a tool whose job is to look stable.

### 4.3 Row 1 — meters, CPU overview, top processes

#### 4.3.1 Four vertical segmented meters (card 1, ≈253 pt)

Four meters side by side, each with a value label beneath:

| Meter | Accent | Value shown | Label beneath | Source |
|---|---|---|---|---|
| CPU | green `#39FF14` | total utilization, 1 decimal | `15.8%` | §5.1 |
| Clock | red `#FF3B30` | frequency state | `Auto` | §5.9 |
| Temp | orange `#FF9F0A` (`accentThermal`, §7.2) | hottest die sensor, 1 decimal | `37.5 °C` | §5.8 |
| GPU | blue `#0A84FF` | GPU utilization, 1 decimal | `18.0%` | §5.6 |

Each meter is a vertical stack of segments:

| Property | Value |
|---|---|
| Segment count | 40 |
| Segment height | 3 pt |
| Segment gap | 1 pt |
| Meter height | 40 × 3 + 39 × 1 = 159 pt |
| Meter width | 22 pt |
| Lit segment | accent color at 100 % opacity, plus glow (§6.5) |
| Unlit segment | accent color at 8 % opacity, no glow |
| Fill rule | `litCount = round(value × 40)`, clamped 0…40; fills from the bottom |
| Label | SF Pro Text 12 pt medium tabular, accent color, centered, 8 pt below the meter |
| Caption | SF Pro Text 9 pt, `#6E6E7E`, centered, 2 pt below the label (`CPU`, `CLOCK`, `TEMP`, `GPU`) |

The "Clock" meter is the one that does not map cleanly to a percentage. Its fill is the current average P-core frequency as a fraction of the SoC's maximum P-core frequency (§5.9), and its label shows `Auto` because macOS does not expose a user-settable governor. If frequency data is unavailable (§5.9.3), the meter shows all segments unlit and the label reads `—`.

#### 4.3.2 CPU Overview card (card 2, ≈517 pt)

| Element | Specification |
|---|---|
| Title | `CPU OVERVIEW` |
| Headline | Total CPU %, SF Pro Display 24 pt medium, green, top-trailing, e.g. `15.8%` |
| Per-core strip | A row of `N` horizontal mini-meters (one per logical core) directly under the headline, height 6 pt each, 2 pt gap, full card width, green, lit fraction = that core's utilization. With 14 cores at 517 pt, each is ≈ 34 pt wide. Above 32 cores the strip switches to 2 rows. Each meter carries a `P` or `E` cluster caption (§5.1.4), SF Mono 9 pt, `#7A7A88` for P and `#57575F` for E. |
| Chart | The overlay chart described in §4.4, filling the remaining height (≈150 pt) |
| Footer | `14 logical processors · Speed Apple managed` |

The per-core strip is what makes a single pinned core visible. A total that reads 7 % while one core sits at 100 % is the most common interesting state on a 14-core machine, and a single aggregate number hides it completely.

#### 4.3.3 Top CPU processes card (card 3, ≈379 pt)

| Element | Specification |
|---|---|
| Title | `TOP CPU PROCESSES` |
| Header right | Total process count, e.g. `1138 total`, SF Pro Text 10 pt, `#6E6E7E` |
| Rows | 12, fixed. Sorted by CPU % descending. |
| Row height | 15 pt |
| Columns | PID (44 pt, trailing, `#6E6E7E`) · Name (flexible, leading, `#D8D8E0`, truncated with a middle ellipsis) · CPU (52 pt, trailing, green, 1 decimal) · GPU (44 pt, trailing, blue, 1 decimal, §5.6.7) · Memory (64 pt, trailing, magenta, §4.9 formatting) |
| Font | SF Mono 10 pt for all numeric columns; SF Pro Text 10 pt for Name |
| Refresh | 1 Hz (§5.5.3) — deliberately slower than the meters |
| Row reordering | When the sort order changes, rows animate to their new position over 250 ms with ease-in-out |

Process rows update at 1 Hz, not 10 Hz, for two reasons: enumerating ~840 processes costs real time (§5.5.4), and a top-process list that reshuffles ten times a second is unreadable. The 250 ms reorder animation exists so the eye can follow a row that moves rather than losing it.

The GPU column reads a real percentage (§5.6.7) for every PID GlowTop can inspect. It reads `—` only for the ~40 % of PIDs that refuse unprivileged inspection outright (§5.5.1) — the same set whose CPU and memory columns are also unavailable — not as a general fallback for the column as a whole.

Clicking a row selects it; double-clicking switches to the Processes pane with that PID selected and scrolled into view. *Not built as of v1.1.2:* the card's rows are not interactive. The cross-pane hand-off this sentence describes exists only as Services' and Connections' Show Process (§12.3, §14.5); wiring it to this card is carried, unscheduled.

### 4.4 CPU overlay chart

A time-series chart inside the CPU Overview card with three simultaneous series on two y-axes.

| Property | Value |
|---|---|
| Window | 60 seconds |
| Samples | 600 (10 Hz × 60 s), one per ring-buffer slot (§6.4) |
| Left y-axis | 0–100 %, gridlines at 0/25/50/75/100 |
| Right y-axis | 0–110 °C, gridlines at 0/55/110 |
| X-axis | Time, newest at the right edge; no tick labels (the window is always 60 s and labeling it is noise) |
| Gridlines | 1 pt, `#1A1A22`; axis labels SF Pro Text 9 pt `#5A5A68` |
| Scroll behavior | The plot shifts left by one sample width every 100 ms; the shift is interpolated per frame so motion is continuous, not stepped |

Series:

| Series | Axis | Color | Line width | Fill |
|---|---|---|---|---|
| Utilization | left (%) | green `#39FF14` | 1.5 pt | gradient from 22 % → 0 % opacity beneath the line |
| Temperature | right (°C) | orange `#FF9F0A` | 1.5 pt | none |
| Kernel (system) time | left (%) | red `#FF453B` | 1.0 pt | none |

Drawing rules: each series is a single `CGPath` built once per frame from the ring buffer, stroked with `lineJoin = .round` and `lineCap = .round`. No per-point markers, no anti-aliasing tricks beyond CoreGraphics defaults. When a series is unavailable (temperature on a machine with no readable sensor), its line and its axis are omitted entirely — no flat line at zero, which would read as a real measurement of zero.

The kernel series is included because the gap between total and kernel time is diagnostically the most useful thing on the chart: a machine at 60 % total with 45 % in the kernel is doing something very different from one at 60 % in user space.

### 4.5 Row 2 — Memory Utilization

A single full-width card (≈1148 pt).

| Element | Specification |
|---|---|
| Title | `MEMORY UTILIZATION` |
| Headline | `66.3 GB resident / 128 GB`, SF Pro Display 24 pt medium, magenta `#FF2D95` — the word is "resident", never "used" (§5.2.3) |
| Segmented meter | Horizontal, on the left, 260 pt wide × 22 pt tall, 40 segments of 5 pt with 1.5 pt gaps, magenta, lit fraction = resident / total |
| Timeline | Fills the remaining width (≈860 pt) × 90 pt tall: a 60-second stacked area chart of memory composition |
| Footer | `Reclaimable 18.4 GB · Free 43.3 GB · Swap 0 B` |

Timeline series, stacked bottom to top, each a filled area with no stroke:

| Layer | Color | Opacity |
|---|---|---|
| Wired | `#FF2D95` | 90 % |
| Active | `#FF2D95` | 60 % |
| Compressed | `#C724B1` | 55 % |
| Cached / inactive | `#7A2A6E` | 40 % |

Free memory is the unfilled remainder to the top of the plot. Swap is not stacked — it is drawn as a separate 1 pt line in `#FF453B` scaled to the same axis, because swap is an event worth noticing, not a fraction to blend in.

"Resident" in the headline is defined in §5.2.3 and is GlowTop's own quantity, computed from named `vm_statistics64` fields. It is deliberately not Activity Monitor's "Memory Used"; the two will differ and that is expected, not a defect.

### 4.6 Rows 3 and 4 — six tiles

Six equal cards, three per row, ≈375 pt each at default width, 150 pt tall.

#### 4.6.1 Disks (row 3, position 1) — green `#39FF14`

| Element | Value |
|---|---|
| Title | `DISKS` |
| Headline | Combined throughput, e.g. `R 12.4 · W 3.1 MB/s` |
| Chart | 60-second dual-line: read (solid, green), write (dashed 3-2, green at 60 %) |
| Footer | Device count and busy percentage, e.g. `2 devices · 4.0% busy`. §5.3 sums every `IOBlockStorageDriver` on the machine and its payload is deliberately flat with a `deviceCount`, so naming one volume beside a multi-device total would be wrong rather than merely absent — and the `statfs("/")` read a volume name needs is excluded by §5.3 (phase-03). |

#### 4.6.2 Network (row 3, position 2) — blue `#0A84FF`

| Element | Value |
|---|---|
| Title | `NETWORK` |
| Headline | `R 148.2 · S 22.6 KB/s` |
| Chart | 60-second dual-line: received (solid, blue), sent (dashed, blue at 60 %) |
| Footer | Primary interface and its address, e.g. `en0 · 192.168.1.42` |

Units auto-scale per §4.9. The headline is the only place in the app where two numbers share one line, and the `R`/`S` prefixes carry the distinction because a legend would not fit.

#### 4.6.3 Energy (row 3, position 3) — yellow `#FFD60A`

| Element | Value |
|---|---|
| Title | `ENERGY` |
| Headline | Package power, e.g. `8.4 W` |
| Chart | 60-second single line, yellow, with a 20 % gradient fill |
| Footer | `Thermals nominal · AC Power` (thermal state from §5.8.4, power source from §5.7.2) |

#### 4.6.4 GPU 0 (row 4, position 1) — blue `#0A84FF`

| Element | Value |
|---|---|
| Title | `GPU 0` |
| Headline | Utilization, e.g. `18.0%` |
| Chart | 60-second single line with gradient fill |
| Footer | Chip name and core count, e.g. `Apple M4 Pro · 20 cores` |

#### 4.6.5 NPU 0 (row 4, position 2) — red `#FF453B` — headline only, no chart

| Element | Value |
|---|---|
| Title | `NPU 0` |
| Headline | Utilization, e.g. `0.0%`, or `—` when unreadable |
| Chart | **None.** This tile plots nothing, in either row 4 position — the only one of the six §4.6 tiles with no history line. |
| Footer | `Apple Neural Engine · 16 cores` |

The Neural Engine is the least reliably readable subsystem on the dashboard (§5.6.4). It is on the Summary pane anyway because when it *is* active — during a local model inference — that is exactly the moment the owner wants to see it, and a tile that reads `—` honestly is still better than no tile.

This tile is **headline-only by design, not by omission.** §5.6.4's path 2 derives utilization from power drawn over a **provisional** 8 W ceiling, and phase-03.1's own record calls the resulting number the least trustworthy on the dashboard. A plotted 60-second history invites the reader to trust its *shape* the way the CPU or GPU chart's shape can be trusted — reading a derived ratio's trend as if it were a measured one — which this tile's own honesty (`—` when unreadable) would then be undercutting. §6.4's ring-buffer table carries no ANE-utilization buffer to match: there is no history to plot, so there is nothing to buffer.

#### 4.6.6 Thermals (row 4, position 3) — orange `#FF9F0A`

| Element | Value |
|---|---|
| Title | `THERMALS` |
| Headline | Hottest sensor, e.g. `37.5 °C` |
| Chart | 60-second multi-line: up to 4 sensors, orange at 100 / 75 / 55 / 40 % opacity, hottest at full |
| Footer | `Nominal thermal pressure` (from §5.8.4) |

### 4.7 Status bar

A 32-point strip across the bottom of the detail area, background `#0E0E13`, top border 1 pt `#1E1E28`.

| Position | Content | Font |
|---|---|---|
| Leading | `Native providers healthy · 1138 processes · Generation 4218` | SF Pro Text 11 pt, `#8A8A99` |
| Trailing | Wall clock, `HH:mm:ss`, updating every second | SF Mono 11 pt, `#8A8A99` |

"Generation" is the monotonically increasing sample-loop counter (§6.3). It is on screen because it is the cheapest possible liveness indicator: if the generation number stops advancing, the sample loop has died, and no amount of smoothly interpolating meters would reveal that — they would simply hold their last value and look fine.

The health phrase changes with provider state:

| Condition | Text | Color |
|---|---|---|
| All providers returning data | `Native providers healthy` | `#8A8A99` |
| 1–2 providers `.unavailable` | `2 providers unavailable` | `#FFD60A` |
| 3+ providers `.unavailable` | `5 providers unavailable` | `statusDegraded` (`#FF9F0A`) |
| Sample loop stalled > 2 s | `Sampling stalled` | `#FF453B` |

The third row's color is the `statusDegraded` token (§7.2, added phase-05) rather than a
second read of `accentThermal` — the two happen to carry the same value in every shipped
preset, but only the token, not the Thermals accent, is what this row draws.

Hovering the health phrase shows a tooltip naming each unavailable provider and its reason (§5.0.5).

### 4.8 Empty, warming, and unavailable states

Three distinct states, three distinct appearances. Confusing them is how a monitor lies.

| State | Meaning | Meter | Headline | Chart |
|---|---|---|---|---|
| **Warming** | Provider is alive; a delta needs two samples and only one exists | All segments unlit | `···` in `#5A5A68` | empty plot area, gridlines only |
| **Unavailable** | Provider cannot read this hardware on this machine/OS | All segments unlit at 4 % opacity | `—` in `#5A5A68` | plot area omitted entirely; card shows a centered `Unavailable on this Mac` in 11 pt `#5A5A68` |
| **Stalled** | Provider has not produced a sample in > 2 s | Segments hold last value at 35 % opacity | last value at 35 % opacity | last data, dimmed to 35 % |

A stalled provider dims rather than blanks so the last known value stays readable while being visibly stale. Blanking would destroy information; showing it at full strength would be a lie.

### 4.9 Number formatting

One set of rules, applied everywhere, so that no two panes format the same quantity differently.

| Quantity | Rule | Examples |
|---|---|---|
| Percentage | 1 decimal, always, with `%` and no space | `0.0%`, `7.3%`, `100.0%` |
| Bytes (size) | Base-1024, 1 decimal at GB and above, 0 decimals below; a trailing `.0` is dropped | `512 KB`, `18.4 GB`, `128 GB` |
| Byte rate | Base-1024, auto-scaled to keep 1–999 in the mantissa, 1 decimal; `B/s` carries none, a fractional byte not being a thing | `948 B/s`, `12.4 MB/s` |
| Temperature | 1 decimal, `°C` with a non-breaking space | `37.5 °C` |
| Power | 1 decimal, `W` with a space | `8.4 W` |
| Frequency | 0 decimals in MHz below 1000, 2 decimals in GHz at or above | `600 MHz`, `4.05 GHz` |
| Duration | `1d 4h`, `4h 12m`, `12m 30s`, `30.4s` | |
| Count | Grouped with thin spaces above 9999 | `1138`, `12 400` |
| Unknown | `—` (em dash), color `#5A5A68` | |

Byte units are base-1024 with `KB`/`MB`/`GB` labels — matching Activity Monitor's historical presentation rather than the SI-correct `KiB`. This is a deliberate wrongness, chosen so numbers match the other tool on the same screen; it is noted here so it is not "fixed" later by accident.

Two of the rules above were tightened in phase-02 because the rule text and its own examples disagreed, and the implementation had to pick one. `128 GB` cannot come from "1 decimal at GB and above" without dropping the trailing zero, and `948 B/s` cannot come from "1 decimal" at all. Both examples were right and both rules were underspecified. Implemented in `Sources/GlowTopCore/Formatting.swift`, one test per row (§13.5 item 7).

The rules are implemented with explicit string math rather than `NumberFormatter`, and that is deliberate: `NumberFormatter` is locale-sensitive, and a monitor that renders `18,4 GB` on one machine and `18.4 GB` on another has two presentations of one number. Every rule here is locale-independent.

### 4.10 Display mode — Simple and Technical (1.2)

**Simple is the default; Technical is §4 as specified above, word for word.** Simple changes what
the dashboard is *called*, never what it reads: `SummaryModel.simplified(frames:previous:)` takes
the Technical projection and returns a copy with different strings, so every value, series, axis
and §4.8 state is identical in both modes by construction, and a unit test asserts that equality
field by field. Toggled from `View › Use Simple Labels` / `Use Technical Labels`, with **no key
equivalent** (§3.5's letter shortcuts stay exactly ⌘D and ⇧⌘F). Persisted in `UserDefaults` under
`display.mode`; `GLOWTOP_DISPLAY_MODE=simple|technical` pins it for one launch without writing it
back, the hook `GLOWTOP_PANE` already establishes for measurement.

**The words.** Technical on the left, Simple on the right:

| Technical | Simple |
|---|---|
| `CPU OVERVIEW` | `PROCESSOR` |
| `TOP CPU PROCESSES` | `BUSIEST APPS` |
| `MEMORY UTILIZATION`, `20 GB resident / 48 GB` | `MEMORY`, `20 GB of 48 GB in use` |
| `Reclaimable … · Free … · Swap …` | `Can be freed … · Free … · Spilled to disk …` |
| `ENERGY` · `GPU 0` · `NPU 0` · `THERMALS` | `POWER DRAW` · `GRAPHICS` · `AI CHIP` · `TEMPERATURE` |
| meters `CPU` `CLOCK` `TEMP` `GPU` | `CPU` `SPEED` `TEMP` `GRAPHICS` |
| `R 148.2 · S 22.6 KB/s` (network) | `↓ 148.2 · ↑ 22.6 KB/s`; the footer keeps the interface and address |
| `14 logical processors · Speed Apple managed` | `10 fast cores · 4 efficient cores` |
| Disks footer `2 devices · 4.0% busy` | `R reading · W writing · 2 drives` |
| Energy footer `Thermals nominal · AC Power` | `Plugged in` / `Running on battery` / `Power source unknown` |
| Thermals footer `Nominal thermal pressure` | `Cooling is keeping up` · `Warming up — still at full speed` · `macOS is slowing things down to cool off` · `macOS is slowing down sharply to cool off` |
| cluster captions `P` / `E` (§14.10's grid) | `Fast` / `Efficient` |
| §14.10's titles | `EACH PROCESSOR CORE` · `PROCESSOR, LAST MINUTE` · `MEMORY, LAST MINUTE` |
| §8.2's `PID`, `CPU %`, `Energy`, `Path` | `ID`, `CPU use`, `Battery use`, `Location` (`CPU use`, not `Processor %`: §8.2's 70 pt column truncates the longer word once the sort chevron takes its share) |
| `Native providers healthy · 1138 processes · Generation 4218` | one sentence, below |

§8.2's columns are user-reorderable, so the retitling is keyed by column identifier, never by
position.

**The verdict.** One word per Summary card, bottom-trailing on the footer's line, 10 pt semibold.
`Normal` is `textSecondary`; anything else takes `warning`, `statusDegraded` or `critical` by
level. **Never the card's accent** — §4.8's rule that a not-built tile contains no pixel of its own
accent is asserted against pixels, and a verdict is commentary on a reading, not part of one. A
card that is not live carries **no verdict at all**: warming, unavailable and stalled look exactly
as §4.8 specifies in both modes.

Where macOS publishes its own judgement, that judgement is used rather than a threshold of ours:

| Card | Source | Rule |
|---|---|---|
| Processor | `CPUSample.total`, mean of the last 10 s of §6.4's buffer | < 60 % `Normal` · 60–85 % `Busy` · ≥ 85 % `Very busy` |
| Memory | `kern.memorystatus_vm_pressure_level` (§5.2.3) | 1 `Normal` · 2 `Getting full` · 4 `Low on memory`; unreadable → §5.2.3's own pressure fraction at 60 % / 80 % |
| Temperature | `ThermalPressure` (§5.8.4) | nominal `Normal` · fair `Warm` · serious `Hot` · critical `Critical` |
| Disks, Graphics, AI chip | utilization, 10 s mean | < 70 % `Normal` · else `Busy` |
| Network | byte rate | `Active` / `Idle` — never a warning: no byte rate is unhealthy |
| Power draw | — | **no verdict.** Watts are not good or bad; the heat they cause is, and Temperature already says so |

**The windows are seconds, not sample counts.** §6.2 divides every provider's rate by ten behind
an occluded window, so a fixed count would average a hundred seconds of history and call it ten —
a finished build still reading `Very busy` a minute later. `SummaryFrames` carries the active
divisor and each window is derived from its provider's rate, so "the last 10 s" is 10 s of wall
clock in both states. The AI chip's mean comes from §6.4's ANE **watts** buffer over §5.6.4's
provisional ceiling — the same path-2 arithmetic the sample itself used — because §6.4 carries no
ANE-utilization buffer; when §5.6.4's reading is `nil` the tile keeps its `—` and takes **no
verdict**, since a live frame is not the same thing as a live reading.

Thresholds carry a **5-point deadband**: a level is entered at its threshold and left only 5 points
below it, so a load hovering at 60 % does not flip the word every second. The previous verdict is
the caller's state, handed back into the next projection; projection itself stays pure.

**The sentence** replaces §4.7's leading string in Simple mode. §4.7's three "do not trust the
screen" conditions keep their precedence and their colour — `Paused — press Space to resume.`,
`Readings have stopped updating — press ⌘R.`, `N readings are unavailable on this Mac.` — and only
when everything is sampling does the sentence describe the Mac: `Your Mac is running normally.`,
or the worst verdict's own sentence, e.g. `Your Mac is hot and is slowing itself down to cool off.`
A busy processor names the program responsible when one program holds more than half the load
(`Google Chrome is using most of the processor.`), because that is the reader's next question.

**The verdict shares the footer's line and takes only the width its word measures**, so a footer
that fits today is not truncated to make room. §4.6.3's and §4.6.6's footers stay unconditional in
Simple mode, as they are in Technical, in their own plain wording: a real thermal state has to survive §13.7.3's
blackout, and it does so in both modes.

**Hover explanations.** One plain sentence per Summary card, registered over `cardFrames()` with
`NSView.addToolTip(_:owner:userData:)` — §14.1's own pattern — and empty in Technical.

**Expert panes are not rewritten.** §14.1, §14.5 and §12 are expert surfaces by nature; Simple mode
does not paraphrase their contents.

---

## 5 Metric providers

### 5.0 The provider contract

#### 5.0.1 Protocol

Every provider conforms to one protocol in `GlowTopCore`:

- `var id: ProviderID` — a stable identifier used for the status bar and probe CLI.
- `var nominalInterval: Duration` — the sample interval the provider wants (§5.0.2).
- `mutating func sample() -> Snapshot` — produce one reading.

`Snapshot` is an enum with three cases: `.value(payload, timestamp)`, `.warming`, and `.unavailable(reason)`. There is no `throws` anywhere in the protocol. This is not laziness about error handling — it is the mechanism that makes §1.3's "never crash" structural rather than aspirational. A provider that cannot read its hardware returns `.unavailable(reason)` and the reason string reaches the status-bar tooltip (§4.7).

Payload types are `Sendable` value types. Providers hold their own delta state and are owned by exactly one task (§6.3) (§6.3), so they need no internal locking.

#### 5.0.2 Sample rates

| Provider | Interval | Rate | Why |
|---|---|---|---|
| CPU (§5.1) | 100 ms | 10 Hz | Drives the fastest-moving meters; `host_processor_info` is cheap |
| Memory (§5.2) | 100 ms | 10 Hz | Cheap; feeds the memory timeline |
| Disk (§5.3) | 250 ms | 4 Hz | IOKit registry iteration costs more than a mach call |
| Network (§5.4) | 250 ms | 4 Hz | `getifaddrs` allocates and walks a list |
| Process table (§5.5) | 1000 ms | 1 Hz | ~840 processes × 3 syscalls each; see §5.5.4 |
| GPU (§5.6) | 500 ms | 2 Hz | IOReport subscription sampling |
| Energy (§5.7) | 1000 ms | 1 Hz | Energy counters are cumulative; a longer window is more stable |
| Thermals (§5.8) | 1000 ms | 1 Hz | Die temperatures move slowly; faster sampling only adds noise |
| Frequency (§5.9) | 500 ms | 2 Hz | Feeds the Clock meter |
| System info (§9) | once at launch + on wake | — | Static |

**No provider samples at 60 Hz.** Rendering interpolates (§6.2); syscalls do not.

#### 5.0.3 Delta providers and warming

CPU, disk, network, energy, and per-process CPU are all cumulative counters. Utilization is a delta over an interval, which means:

1. The first `sample()` after start (or after resume, or after wake) stores a baseline and returns `.warming`.
2. The second returns `.value`.
3. If the interval since the previous sample is under **50 ms**, the provider returns the previous value unchanged rather than dividing by a near-zero denominator. This is the specific failure mode that makes a CPU meter read 0 % or 900 % at random.
4. If the interval since the previous sample exceeds **5 seconds** (sleep, suspension, debugger pause), the baseline is discarded and the provider returns `.warming` again. A "utilization" computed across a sleep is meaningless.

#### 5.0.4 Counter wrap

`host_processor_info` tick counters are `natural_t` (32-bit unsigned) and do wrap — on a busy core, roughly every 497 days of accumulated tick time, but in practice on any counter reset. Every delta computation clamps: if `current < previous` for an unsigned counter, the provider treats the delta as 0 for that field and returns `.warming` for that sample rather than producing a huge or negative utilization.

#### 5.0.5 Unavailability reasons

`.unavailable(reason)` carries a short human string that reaches the status-bar tooltip and the probe CLI. The vocabulary is fixed — a closed list, so a provider needing a new reason adds it here rather than inventing one at the call site. `"composition does not sum"` joined the list in phase-02, having been in use by §5.2.3 since phase-01 without ever appearing here: `"no matching IOService"`, `"IOReport subscription failed"`, `"key not present"`, `"unsupported on this Mac"`, `"permission denied"`, `"kernel call failed: <kern_return_t>"`, `"composition does not sum"` (§5.2.3), `"provider not built"` (phase-03: carried by §5.6–§5.9's marks while the pane ships ahead of its private providers; retired in phase-03.1 with no call sites remaining, as predicted), `"private APIs disabled"` (phase-03.1: §13.7.3's force-unavailable flag, carried by every provider in §5.6–§5.9 and nothing else — the operator turned them off, so the tooltip does not blame the hardware).

This list itself had drifted from the code that is supposed to implement it: `Sources/GlowTopCore/MetricProvider.swift`'s doc comment named `"no readable sensor"`, a string this section has never contained, and omitted `"no matching IOService"`, `"key not present"` and `"kernel call failed: <kern_return_t>"`, which it does. Corrected in phase-03.1's first sub-step (1.1) — a closed vocabulary living in two places that disagree is not closed.

#### 5.0.6 API risk classification

Every API in this section is tagged:

- **public** — documented, in a public SDK header, with a stable contract. Safe.
- **private** — real, widely used, and not in any public header. It can change or vanish in any macOS update without notice. Every private-API call site is wrapped so that failure produces `.unavailable`, never a crash, and the app must remain fully usable with every private-API provider returning `.unavailable`.
- **uncertain** — the interface is public but the *meaning* of the value, its units, or its availability on a given Mac is not documented and has been inferred. The number may be right and may be misleading; the tile carries a tooltip saying how it was derived.

This tagging is a gate, not a courtesy: a provider whose tag is missing does not ship (§13.7.2).

### 5.1 CPU provider

#### 5.1.1 Data source — **public**

`host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount)` from `<mach/mach_host.h>`. Public, documented, stable since NeXTSTEP, and the same source Activity Monitor's numbers ultimately derive from.

Returns an array of `CPU_STATE_MAX` (4) `natural_t` tick counters per logical CPU, indexed `info[CPU_STATE_MAX * core + state]` where state is one of `CPU_STATE_USER`, `CPU_STATE_SYSTEM`, `CPU_STATE_IDLE`, `CPU_STATE_NICE`.

The returned buffer is vm-allocated and **must** be released with `vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))`. The size argument is `infoCount × stride`, not `count × stride` — using `count` leaks on every sample and eventually faults.

#### 5.1.2 Arithmetic

For each logical core *i*, with Δ meaning current minus previous:

```
busy_i  = Δuser_i + Δsystem_i + Δnice_i
total_i = busy_i + Δidle_i
util_i  = total_i > 0 ? busy_i / total_i : previous util_i
```

Aggregate utilization is `Σ busy_i / Σ total_i` across all cores — a tick-weighted mean, **not** the arithmetic mean of the per-core percentages. On a machine with asymmetric P and E cores these differ measurably, and the tick-weighted figure is the one that matches `top`.

User, system, and idle shares for the overlay chart (§4.4) are computed the same way against the same denominator, so they sum to 1.0.

#### 5.1.3 Payload

| Field | Type | Meaning |
|---|---|---|
| `perCore` | `[Double]` | Utilization 0.0–1.0, length = `hw.logicalcpu`, index order as returned by the kernel |
| `total` | `Double` | Tick-weighted aggregate, 0.0–1.0 |
| `user`, `system`, `idle`, `nice` | `Double` | Aggregate shares, 0.0–1.0, summing to 1.0 ± 0.001 |
| `logicalCount` | `Int` | From `sysctl hw.logicalcpu` |
| `performanceCores`, `efficiencyCores` | `Int` | From `hw.perflevel0.logicalcpu` / `hw.perflevel1.logicalcpu` |
| `timestamp` | `ContinuousClock.Instant` | When the sample was taken |

#### 5.1.4 Core topology — **public**

`sysctlbyname("hw.logicalcpu")`, `"hw.physicalcpu"`, `"hw.perflevel0.logicalcpu"` (performance), `"hw.perflevel1.logicalcpu"` (efficiency). Read once at launch and cached. The `perflevel` keys exist only on Apple Silicon; on failure the provider reports all cores as performance cores and marks the split `uncertain` — it does not fail.

Kernel index order is P cores first, then E cores, on every Apple Silicon Mac observed. The reference machine reports 14 logical cores as 10 performance + 4 efficiency.

**Every per-core mark is labeled with its cluster.** Fourteen identical bars, four of which are efficiency cores, misreports load: an E core at 100 % and a P core at 100 % are not the same event, and a viewer who cannot tell them apart reads the wrong thing. The per-core strip (§4.3.2) and the phase-01 spike bars therefore carry a `P` or `E` caption under each mark, derived from the index against `performanceCores`, dimmer for E.

The layout must not *depend* on P-then-E ordering for correctness — the caption is computed from the counts, so a machine that interleaved clusters would mislabel rather than crash, and the fix would be to read the cluster per core rather than infer it. Visual *grouping* (separating the clusters with a gap and a cluster-level aggregate) remains M02 (§14.1); labeling is M01 because it is what stops the misreport.

#### 5.1.5 Accuracy gate

`glowtop-probe cpu` total must agree with `top -l 2 -n 0 | grep 'CPU usage'` (user + sys) within **±10 percentage points** over 5 consecutive samples. The tolerance is wide because the two tools sample different intervals at different moments; a tighter bound would fail on noise. A systematic disagreement — the probe consistently double or half — is a stride or denominator bug, not noise.

`perCore.count` must equal `sysctl -n hw.logicalcpu` exactly. On the reference machine, 14.

### 5.2 Memory provider

#### 5.2.1 Data source — **public**

`host_statistics64(mach_host_self(), HOST_VM_INFO64, &stats, &count)` returning `vm_statistics64_data_t`. Public and documented. Page size from `host_page_size` (16384 bytes on Apple Silicon — read it, do not hardcode it).

Total physical memory from `sysctlbyname("hw.memsize")` — **public**, `UInt64` bytes.

#### 5.2.2 Fields used

| `vm_statistics64` field | Meaning |
|---|---|
| `active_count` | Recently used, backed pages |
| `inactive_count` | Not recently used, reclaimable |
| `wire_count` | Kernel-locked, not reclaimable |
| `compressor_page_count` | Pages held by the compressor |
| `free_count` | Unallocated |
| `speculative_count` | Read-ahead, reclaimable |
| `purgeable_count` | Purgeable — an overlay on the active/inactive/speculative queues; reported, never summed |
| `external_page_count` | File-backed (the cached figure) |

All are page counts; multiply by page size for bytes.

#### 5.2.3 Composition — **public**

*Amended 2026-09-21 (1.2):* the sample also carries `kern.memorystatus_vm_pressure_level` (1 normal, 2 warning, 4 critical) — a **public** sysctl, the kernel's own memory-pressure verdict, read for §4.10's Simple-mode verdict only. No figure in §4.5 derives from it, and `nil` when the sysctl is unreadable.

GlowTop does not reconstruct Activity Monitor's "Memory Used". That formula is undocumented, and a value defined by matching a black box goes wrong on someone else's Mac or at the next point release without anything here having changed. GlowTop's memory figures are defined only from the `vm_statistics64` fields in §5.2.2, which are public and mean what the kernel says they mean.

The composition is summed in exactly **one** function in `MemoryProvider`, and that function carries the field names in a comment so the definition and the arithmetic cannot drift apart:

```
resident    = (active + wired + compressor) × pageSize   // vm_statistics64: active_count, wire_count, compressor_page_count
reclaimable = (inactive + speculative) × pageSize
free        = (free_count − speculative_count) × pageSize   // free_count includes speculative pages
total       = sysctl hw.memsize
```

`resident + reclaimable + free` is checked against `total` and must agree within one page-size rounding per term; a larger gap means a field was double-counted and the provider returns `.unavailable("composition does not sum")` rather than displaying a number it cannot justify.

`hw.memsize` counts a firmware carve-out (about 0.69 GiB on the reference machine) that `vm_statistics64` never reports, so the sum lands under `total` by that margin on every sample; the check is one-sided by design.

**The UI names what the number is.** The Memory card headline reads `66.3 GB resident / 128 GB` and the footer reads `Reclaimable 18.4 GB · Free 43.3 GB · Swap 0 B` (§4.5). It does not use the word "used", because "used" is Activity Monitor's word for a quantity GlowTop is not computing. The card's tooltip states the formula above verbatim.

Comparison against Activity Monitor is **an observation, not a test.** The two numbers are expected to differ, the difference is recorded once in the phase-02 notes as a fact about this machine at that moment, and no gate anywhere asserts a tolerance between them (§13.6).

Swap comes from `sysctlbyname("vm.swapusage")` returning `xsw_usage` — **public** — fields `xsu_total`, `xsu_used`, `xsu_avail`.

Memory pressure is computed as `(wired + compressor) / total` and bucketed: green < 0.60, yellow 0.60–0.80, red > 0.80. These thresholds are **provisional** and are GlowTop's own, not a reproduction of the macOS pressure indicator; the tooltip says so.

#### 5.2.4 Verification

`glowtop-probe memory` total must equal `sysctl -n hw.memsize` exactly, and its free, active, wired, and compressed page counts must be within 5 % of the corresponding `vm_stat` lines sampled at the same moment — `vm_stat` reads the same `host_statistics64` fields, so this is a check of GlowTop's arithmetic, not of another tool's definition. The memory probe ships in phase-01 alongside the CPU probe so this cross-check happens at the same gate (§13.6).

### 5.3 Disk provider

#### 5.3.1 Data source — **public** (interface) / **uncertain** (semantics)

IOKit registry: match `IOBlockStorageDriver` services via `IOServiceMatching("IOBlockStorageDriver")` and `IOServiceGetMatchingServices`, then read the `Statistics` dictionary from each with `IORegistryEntryCreateCFProperty`. The IOKit calls are public and documented. The `Statistics` dictionary keys are conventional and widely used but their exact semantics are not formally specified — hence **uncertain**.

Keys read (`kIOBlockStorageDriverStatistics*` constants):

| Key | Meaning |
|---|---|
| `Bytes (Read)` | Cumulative bytes read |
| `Bytes (Write)` | Cumulative bytes written |
| `Operations (Read)` | Cumulative read operations |
| `Operations (Write)` | Cumulative write operations |
| `Total Time (Read)` | Cumulative nanoseconds spent in reads |
| `Total Time (Write)` | Cumulative nanoseconds spent in writes |

#### 5.3.2 Arithmetic

Rates are `Δbytes / Δseconds` per device, summed across devices for the headline. Busy percentage is `(ΔreadTime + ΔwriteTime) / Δinterval`, clamped to 0–100 % — a device servicing overlapping requests can exceed 100 % of wall time, and clamping is the honest presentation at this resolution.

Every matched service is released with `IOObjectRelease`, and the iterator too. IOKit object leaks in a process that samples 4 times a second are not survivable over an 8-hour session.

#### 5.3.3 Fallback

No matching services → `.unavailable("no matching IOService")`. Statistics dictionary present but missing a key → that field is zero and the rest of the payload is still produced; a missing `Total Time` costs the busy percentage, not the throughput numbers.

#### 5.3.4 Verification

Write a 1 GB file with `dd if=/dev/zero of=/tmp/glowtop-test bs=1m count=1024` and confirm the write rate tracks within 20 % of `dd`'s reported throughput, then delete the file. The tolerance is loose because the page cache decouples the write syscall from the block-device write.

### 5.4 Network provider

#### 5.4.1 Data source — **public**

`getifaddrs(3)` walking the returned list for entries with `ifa_addr->sa_family == AF_LINK`, whose `ifa_data` is an `if_data` struct. Public, documented, POSIX-adjacent, stable.

| `if_data` field | Meaning |
|---|---|
| `ifi_ibytes` | Cumulative bytes in |
| `ifi_obytes` | Cumulative bytes out |
| `ifi_ipackets`, `ifi_opackets` | Cumulative packets |
| `ifi_ierrors`, `ifi_oerrors` | Cumulative errors |

`freeifaddrs` is called on every path out of the function, including error paths.

#### 5.4.2 Interface selection

Rates are summed across all non-loopback interfaces (skip `lo0`, skip interfaces whose `ifi_ibytes` and `ifi_obytes` are both zero since boot). The footer names the *primary* interface: the one with the default route, read from `sysctl net.route` — or, more simply and equally correctly for the display, the non-loopback interface with the highest cumulative byte total. GlowTop uses the latter; it is tagged **uncertain** as a heuristic, and it is right on any machine with one active network path.

The interface's IPv4 address comes from the same `getifaddrs` walk, matching `AF_INET` entries by interface name.

#### 5.4.3 Counter wrap

`if_data` counters are 32-bit on some interface types and do wrap at high throughput — at 1 Gb/s, a 32-bit byte counter wraps in about 34 seconds. The §5.0.4 clamp rule handles it: a decrease produces one `.warming` sample rather than a nonsense spike.

#### 5.4.4 Verification

`glowtop-probe network` cumulative byte totals must be within 1 % of `netstat -ib` for the same interface sampled at the same moment.

### 5.5 Process table provider

#### 5.5.1 Data source — **public** (with caveats)

`libproc`, declared in `<libproc.h>`:

- `proc_listallpids(nil, 0)` → count; then `proc_listallpids(buffer, size)` → PIDs.
- `proc_pidpath(pid, buffer, size)` → executable path.
- `proc_name(pid, buffer, size)` → short name (16-char truncated; use the last path component of `proc_pidpath` when it is available and fall back to `proc_name`).
- `proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)` → `proc_taskinfo` with `pti_total_user`, `pti_total_system` (mach absolute time), `pti_resident_size`, `pti_virtual_size`, `pti_threadnum`.
- `proc_pid_rusage(pid, RUSAGE_INFO_V4, &info)` → `rusage_info_v4` with `ri_pkg_idle_wkups`, `ri_diskio_bytesread`, `ri_diskio_byteswritten`, and on Apple Silicon `ri_energy_nj`.

These are public headers shipped in the SDK, but `libproc` is documented thinly and its behavior for processes the caller cannot inspect is: return a nonzero error and leave the buffer untouched. Every call's return value is checked; a failing PID is skipped, not defaulted to zero.

**`proc_listallpids` returns a PID count, not a byte count**, in both its sizing form and its
filling form. This is the opposite of the convention most `proc_*` sizing calls follow, and
getting it wrong is silent: sizing the buffer as `returned / MemoryLayout<Int32>.size` makes
it four times too small, and the enumeration then covers a quarter of the machine — 202
processes where `ps -A` counts 851 — while every individual row remains correct. Nothing
errors, and the total simply reads low. Caught in phase-02 only because the §5.5.5 count
cross-check exists.

**About 40 % of PIDs cannot be inspected by an unprivileged process.** On the reference
machine 335 of 839 PIDs return `EPERM` from `proc_pidinfo`: they belong to root or to another
user. `kernel_task` (PID 0) refuses outright. So the process table shows every PID in its
count but can only report CPU, memory, and thread data for the subset this user owns — and
the omitted set includes `WindowServer`, the process §13.1.5 spent a milestone measuring.
This is not a defect to fix; reading another user's task info requires privilege GlowTop does
not have and will not ask for (CLAUDE.md: no root, no `sudo`). It is recorded because a table
silently covering 60 % of the machine looks exactly like a quiet machine, which is why
`ProcessSample` reports `totalCount` and `inspectableCount` as separate numbers and §4.3.3's
header must not imply the rows account for all of them.

`proc_pid_rusage` is listed above as available but is **not read in M01**: nothing before the
Processes pane (phase-04) consumes per-process disk I/O, idle wakeups, or energy, and a
fourth call across ~840 PIDs is roughly a third more enumeration cost against §5.5.4's
budget. Deferred to phase-04 by ruling, 2026-08-25.

#### 5.5.2 CPU per process

`pti_total_user` and `pti_total_system` are in mach absolute time units. Convert with `mach_timebase_info` (`numer`/`denom`) to nanoseconds, then:

```
cpuPercent = (Δuser_ns + Δsystem_ns) / (Δwallclock_ns) × 100
```

This yields a figure where a single fully-busy thread reads 100 % and a process saturating all 14 cores reads 1400 % — the same convention as `top` and `ps`. The UI displays it unchanged, so a value above 100 % is expected and correct. §4.9's percentage rule applies (one decimal).

Processes that appear between samples have no baseline: their first appearance shows `—` for CPU and a real value for memory, and they get a number on the next sample.

#### 5.5.3 Refresh cadence

1 Hz on the Processes pane and for the Summary pane's top-12 card. Not configurable in M01.

#### 5.5.4 Cost budget

Enumerating the machine costs one `proc_listallpids` plus 3 calls per PID (`proc_pidpath`,
`proc_name`, `proc_pidinfo`). **Measured in phase-02 on the reference machine: 11–19 ms for
838 processes**, against the 25 ms budget. The budget stands and the mitigation was not
needed.

The mitigation remains specified in advance so it is not invented under pressure: if the cost
exceeds 25 ms, enumerate PIDs every second but refresh `proc_pidpath` — the expensive call —
only for PIDs not already in the cache, since paths never change for a live PID.

`ProcessSample.enumerationMilliseconds` reports the cost on every sample, so a regression
shows up in the data rather than as a mystery hitch.

The enumeration runs on a background task, never on the main actor. A 25 ms hitch on the main thread is 1.5 dropped frames at 60 Hz and is visible.

#### 5.5.5 Verification

Process count must match `ps -A | wc -l` within ±3 (processes genuinely start and exit
between the two commands). **Phase-02 reading: 839 against 838 — within tolerance.**

The per-process CPU arithmetic is verified two ways, both of which are decisive where the
`top` comparison is not:

1. **Cumulative CPU time against `ps -o time=`.** The provider's converted total for a
   long-running process read 107.146 s against `ps`'s 107.15 s — an exact match, and the
   check that would catch a missing `mach_timebase_info` conversion, which on this machine
   would under-report every process by 42x.
2. **A process pinned at a known load.** A single busy thread is 100 % of one core by
   §5.5.2's convention. The provider read 100.4, 99.9, 100.1, 100.0 across four samples.

The original check here — busiest process within ±10 points of `top -l 2 -o cpu -n 5` — is
kept as a sanity check but is **not a gate**, for the reason §13.7.1 exists. Against the
pinned 100 % load `top` itself read 81.8, and on an uncontrolled target the two tools sample
different windows: a process whose own load swings 20 points inside the sampling period
produces a ±20-point disagreement while both instruments are working correctly. A tolerance
tighter than the target's own variation measures the target, not the instrument. Compare by
**PID, never by name** — several processes share a name, and matching on the name compares
one tool's busiest against the other's idlest namesake, which reads as a total failure.

### 5.6 GPU provider

#### 5.6.1 Data source — **private**

`IOReport` (from `/usr/lib/libIOReport.dylib`): `IOReportCopyChannelsInGroup`, `IOReportCreateSubscription`, `IOReportCreateSamples`, `IOReportCreateSamplesDelta`, and the accessors `IOReportChannelGetGroup`, `IOReportChannelGetChannelName`, `IOReportSimpleGetIntegerValue`, `IOReportStateGetCount`, `IOReportStateGetResidency`.

**This is a private framework.** There is no public header, no documented contract, and no compatibility guarantee across macOS releases. It is used because there is no public alternative for GPU residency, per-cluster frequency, or package energy on Apple Silicon, and because the only public-ish alternative (`powermetrics`) requires root (§2.4).

Mitigation, in full:

1. The library is loaded with `dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY)` at first use, and every symbol is resolved with `dlsym`. **The app does not link against it.** A missing library or a missing symbol yields `.unavailable("IOReport subscription failed")`, not a launch-time dyld failure that kills the app before its window appears.
2. Every returned CF object is released; every returned dictionary is checked for the expected keys before subscripting.
3. Every value is range-checked before display (§5.6.5).
4. The app is fully usable with this provider returning `.unavailable` for its entire lifetime. Three tiles show `—`; nothing else changes.

An alternative public path exists and is used as a fallback: `IOServiceMatching("IOAccelerator")` and reading the `PerformanceStatistics` dictionary, which contains a `Device Utilization %` key on many Macs. That path is **uncertain** (undocumented key names in a public registry) and is tried when IOReport is unavailable.

`/usr/lib/libIOReport.dylib` **does not exist as a file** on this macOS — it resolves only from the dyld shared cache — and `dlopen` on that exact path succeeds regardless (confirmed with a standalone C program before phase-03.1 wrote any Swift). This section's mitigation deliberately does not add a `FileManager.fileExists` precheck: it is a natural-looking defensive move, and it fails silently in the direction that looks like correct handling of a missing private library — it would return `.unavailable` for this provider on every Mac where it in fact works.

#### 5.6.2 GPU utilization

From the IOReport group `GPU Stats` / subgroup `GPU Performance States`, the channel reporting per-state residency. Utilization is `1 − (residency in the idle state / total residency)` over the sample delta.

#### 5.6.3 Package power — **private**, feeding §4.6.3

From the IOReport group `Energy Model`, channels named for CPU, GPU, and ANE energy — selected by **exact channel name** (`CPU Energy`, `GPU`, `ANE`), never by substring. The group also carries `GPU SRAM` and a second, unrelated `GPU Energy` channel denominated in **nanojoules**, a million apart from `GPU`'s **millijoules**; a substring match on `GPU` would select both, sum them, and mix units by 10⁶. Both are excluded from the headline sum and named in the tooltip alongside whichever channels did contribute. **`DRAM` joins the exact-name set in phase-11 as a fourth channel, read from the same subscription and confirmed as `mJ` on the reference Mac by the 2026-09-03 dump** — it is drawn only on §14.1's pane and is **not** added to this tile's headline sum, which stays `CPU Energy + GPU + ANE` so the readings recorded against §13.1 stay comparable; §14.1's card names all four and its tooltip lists them.

Values are cumulative energy, converted through **each channel's own unit label** rather than a single assumed unit: `IOReportChannelGetUnitLabel` states the unit in-band (confirmed at plan time: `mJ` for `CPU Energy`, `GPU`, and `ANE`), and this is a second, independent line of evidence **alongside**, not in place of, an unprivileged upper bound from IOPowerSources (§5.7.2: amperage × voltage on battery) — a label is a claim, and the failure this section fears is the one where the label is right and the arithmetic around it is off by a constant factor anyway.

```
watts = Δenergy / Δseconds   (Δenergy converted to joules by its own channel's unit label)
```

The **uncertain** tag stays: the unprivileged bound and the in-band label agree the unit is not wrong by orders of magnitude, but neither pins the constant, and a `powermetrics` confirmation needs root that a session will not take (§13.7.2, §2.4) — recorded as an open blocker with a named owner rather than assumed closed. Phase-03.1's own bound, run on battery: package power **0.51–1.30 W** against a computed whole-system upper bound of **11.70 W** (`IOPSCopyPowerSourcesInfo`'s amperage × voltage) — package below whole-system as required, at a ratio of roughly 17.6×, wider than a first guess of "within 2×" but consistent with a laptop's display/radio/SSD baseline draw not captured by the CPU+GPU+ANE package figure alone. See `phase-03.1-PLAN.md`'s `## Cross-checks (recorded)` for the full numbers. *Lifted 2026-09-21 (1.1.2):* Connor ran `sudo powermetrics --samplers cpu_power,gpu_power -i 1000 -n 20` while a session captured `glowtop-probe energy`; 20 of 20 seconds paired. GPU means 0.021 W against 0.022 W (ratio 1.04); CPU agrees second by second across the 16 quiet seconds, the four spike seconds differing only by which side of a one-second boundary the spike fell on. The constant is confirmed for the `CPU Energy` and `GPU` channels; `ANE` and `DRAM` share the same `mJ` unit handling and were not independently sampled. Raw output: `docs/measurements/2026-09-21-powermetrics-20x1s.txt`. The **private** tag is unchanged.

The Energy tile's headline is the sum of the available channels, and its tooltip lists which channels contributed. If the units turn out to be wrong by a constant factor, the tooltip is how that becomes visible rather than silently shipping a plausible wrong wattage.

#### 5.6.4 Neural Engine — **private**, **uncertain**

The ANE appears in IOReport's `Energy Model` as an energy channel on all recent Apple Silicon, but a *utilization* channel is not reliably present. GlowTop's NPU tile therefore shows:

1. ANE residency, if a residency channel is found; otherwise
2. ANE power normalized to a **provisional** ceiling of 8 W, presented as a percentage with a tooltip stating "derived from ANE power"; otherwise
3. `—`.

This is the least trustworthy number on the dashboard and the specification says so on the tile itself. The core count in the footer comes from the SoC identification (§9.2), not from IOReport.

On the reference Mac, IOReport carries exactly five groups — `AMC Stats`, `CPU Stats`, `Energy Model`, `GPU Stats`, `PMP` — with no ANE group and no residency channel, so path 1 never fires here and path 2 (power over the provisional 8 W ceiling) is what ships. Path 1's search is implemented anyway, for hardware that has one. Confirmed live (phase-03.1): under a Vision-inference controlled load, `aneWatts` rises sharply (rest median ≈ 0.001 W, loaded median ≈ 2.37 W) while `gpuWatts` does not move with it — the inference lands on the ANE on this Mac, not the GPU.

#### 5.6.5 Range checks

Every IOReport-derived value is validated before it reaches the UI: utilization must be 0.0–1.0 (values outside are clamped and the sample is marked `uncertain`), power must be 0–200 W (outside → `.unavailable` for that sample), residency deltas must be non-negative (negative → `.warming`, per §5.0.4).

#### 5.6.6 Chip identification — **public**

`sysctlbyname("machdep.cpu.brand_string")` gives the chip name (e.g. `Apple M4 Pro`). GPU core count comes from the IOKit registry `IOAccelerator` entry's `gpu-core-count` property when present (**uncertain**), else from a small static table keyed on the brand string, else omitted from the footer.

#### 5.6.7 Per-process GPU — **private**, **uncertain**

§4.3.3's GPU column is sourced from `AGXDeviceUserClient` entries nested under the `IOAccelerator` registry service (`IOServiceMatching("AGXDeviceUserClient")` itself returns zero on this Mac; the clients are only reachable as children of the accelerator service, found by a recursive child walk). Each carries `IOUserClientCreator = "pid <N>, <name>"` and an `AppUsage` array of dictionaries with an `accumulatedGPUTime` counter.

- **Attribution is by PID only, parsed numerically out of `IOUserClientCreator`, never by its name half** — the name is truncated to 16 characters (`NotificationCent`, `AXVisualSupportA`), which would silently miss the process a user is actually looking for.
- **The unit is nanoseconds**, confirmed by a controlled-duration test rather than assumed from magnitude: a delta measured over a known wall-clock interval matches that interval at nanosecond scale and is physically impossible at microsecond scale. This is the same class of error §5.6.3's channel trap describes, one subsystem over.
- `AppUsage` is an **array** per client (observed 1–3 entries); GlowTop sums every entry's `accumulatedGPUTime` for a client, which is itself an assumption, recorded rather than silently adopted.
- The registry walk rides the existing 1 Hz process-enumeration loop (§5.5) and costs roughly 1 ms warm — well under the 20 ms budget this feature was scoped against.
- **~40 % of PIDs refuse inspection unprivileged** (§5.5.1's own limit) and keep `—` in the GPU column regardless of this source; every other row gets a real, direction-verified percentage on the same convention as §5.5.2's CPU points (unclamped, `top`-style).

This is a per-device accounting API repurposed for a per-process reading it was not designed to publish, so the tag is **uncertain** in addition to **private**, and the column is expected to be the least stable one on the Processes-adjacent card if a future macOS changes `AppUsage`'s shape.

### 5.7 Energy provider

#### 5.7.1 Power figures

See §5.6.3 — the energy numbers come through IOReport and are **private**; the **uncertain** tag they carried until 1.1.2 was lifted on 2026-09-21 by the `powermetrics` cross-check recorded there.

#### 5.7.2 Power source — **public**

`IOPSCopyPowerSourcesInfo()` and `IOPSGetProvidingPowerSourceType()` from IOKit's IOPowerSources, which is public and documented. Yields `AC Power` or `Battery Power`, plus, on a laptop, charge percentage, time-to-empty, and cycle count from the power-source dictionary keys (`kIOPSCurrentCapacityKey`, `kIOPSTimeToEmptyKey`, etc.).

The Energy tile footer's second half (`· AC Power`) comes from here and is reliable even when the wattage is not.

### 5.8 Thermal provider

#### 5.8.1 Data source — **private**

Two paths, tried in order:

1. **IOHIDEventSystemClient** temperature sensors: create a client with `IOHIDEventSystemClientCreate`, set a matching dictionary for `PrimaryUsagePage = 0xff00` and `PrimaryUsage = 5` (temperature), copy the matching services, and read each service's event with `IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0)`, extracting the field value. Private; symbols resolved via `dlsym` on `/System/Library/Frameworks/IOKit.framework/IOKit`, never linked.
2. **SMC** (`AppleSMC` IOService, `kSMCReadKey` selector, keys `Tp01`…, `Tg0D`…): private, brittle across SoC generations, and used only if path 1 yields nothing.

If both fail: `.unavailable("unsupported on this Mac")`, the Temp meter and Thermals tile show `—`, and the temperature series disappears from the CPU overlay chart entirely (§4.4).

**Path 2 is deferred, not implemented, in phase-03.1.** Path 1 yields sensors on this Mac — 52 pass §5.8.2's filter — so path 2 would be a code path no hardware in this project can execute, and an untested branch is wrong the first time it runs. The stated fallback this section needs is already met by path 1's own `.unavailable("unsupported on this Mac")`. This reverses, and path 2 ships, the first time a Mac is added to this project where path 1 yields nothing.

#### 5.8.2 Sensor selection

Sensor names are SoC-specific and undocumented. GlowTop reads every matching sensor, filters to those reporting **0–120 °C** (anything outside is a sensor whose units are not Celsius, or is not a temperature at all), and:

- The Temp meter (§4.3.1) and Thermals headline show the **maximum** across sensors — the hottest thing in the machine is the number that matters.
- The Thermals chart shows the four hottest sensors as separate lines.
- Sensor display names are the raw sensor names, truncated to 12 characters. Prettifying undocumented names invents meaning that is not there.

#### 5.8.3 Meter scale

The Temp meter's 40 segments span **0–110 °C**, so one segment is 2.75 °C. Above 100 °C the lit segments switch from the thermal accent to red `#FF453B` regardless of theme, because at that point the color is information, not decoration.

#### 5.8.4 Thermal pressure — **public**

`ProcessInfo.processInfo.thermalState` — public, documented, four cases mapping directly to the footer text:

| `thermalState` | Footer text | Color |
|---|---|---|
| `.nominal` | `Nominal thermal pressure` | `#6E6E7E` |
| `.fair` | `Fair thermal pressure` | `#FFD60A` |
| `.serious` | `Serious thermal pressure` | `#FF9F0A` |
| `.critical` | `Critical thermal pressure` | `#FF453B` |

This is the reliable half of the thermal story and it works on every Mac, including when every raw sensor is unreadable. When sensors are unavailable, the Thermals tile still shows the pressure state — a tile with `—` for a temperature and a real pressure state is far more useful than an empty tile.

### 5.9 Frequency provider

#### 5.9.1 Data source — **private**, feeding the Clock meter (§4.3.1)

IOReport group `CPU Stats`, subgroup `CPU Complex Performance States` / `CPU Core Performance States`: per-cluster residency across DVFS states. Average frequency is the residency-weighted mean of the state frequencies:

```
avgFreq = Σ (residency_s × frequency_s) / Σ residency_s
```

The Clock meter reads one number, summed across the P clusters. **§14.1's pane reads the same subgroup per cluster** — one column per channel whose name is a cluster (`ECPU`, `PCPU`, `PCPU1` here; never the `*CPM*` accounting channels) — and pairs each cluster against a table chosen **by cluster kind**: `voltage-states5-sram`/`voltage-states5` for the P clusters, `voltage-states1-sram`/`voltage-states1` for the E cluster, with the pairing **validated by table length against that cluster's own active-state count** rather than by key order. A cluster whose table does not pair is unavailable on its own (§14.1, §4.8) and names the key; the summed reading this section specifies is unaffected either way.

State frequency tables come from the IOKit device tree (`voltage-states5-sram` and siblings on the `pmgr` node) — **private** and **uncertain**, since the encoding is undocumented and differs across SoC generations.

#### 5.9.2 Maximum frequency

The Clock meter's full scale is the highest frequency in the P-cluster's state table. If the table is unreadable, fall back to `sysctlbyname("hw.cpufrequency_max")` — **uncertain**, because on Apple Silicon this key is frequently absent or returns 0. If both fail, the meter is unavailable.

#### 5.9.3 Fallback

Frequency unavailable → the Clock meter shows all segments unlit and its label reads `—`, while the caption still reads `CLOCK`. The label `Auto` in the reference layout describes macOS's DVFS policy, and GlowTop shows `Auto` whenever a frequency reading is available, since no user-selectable governor exists on this platform.

### 5.10 Provider risk summary

| Provider | § | Primary API | Tag | If it fails |
|---|---|---|---|---|
| CPU | 5.1 | `host_processor_info` | **public** | App is pointless; treat as a bug, not a fallback |
| Memory | 5.2 | `host_statistics64` | **public** (arithmetic **uncertain**) | Memory card shows `—` |
| Disk | 5.3 | IOKit `IOBlockStorageDriver` | **public** iface / **uncertain** keys | Disks tile shows `—` |
| Network | 5.4 | `getifaddrs` | **public** | Network tile shows `—` |
| Processes | 5.5 | `libproc` | **public** | Processes pane empty with an explanatory row |
| GPU | 5.6 | IOReport (`dlopen`) | **private** | GPU tile + GPU meter show `—` |
| NPU | 5.6.4 | IOReport | **private**, **uncertain** | NPU tile shows `—` |
| Energy | 5.7 | IOReport / IOPowerSources | **private** / **public** | Wattage `—`; power source still shown |
| Thermals | 5.8 | IOHIDEventSystem / SMC | **private** | Temperature `—`; pressure state still shown |
| Frequency | 5.9 | IOReport + device tree | **private**, **uncertain** | Clock meter shows `—` |
| Connections | 14.5 | `libproc` (`proc_pidfdinfo`) | **public** (sparsely documented) | Pane shows `Unavailable on this Mac`; not counted in §4.7's health phrase (samples only while visible, by design) |
| Installed Apps | 14.3 | `Bundle` / `Security` / `FileManager` | **public** | Scan reports what it could read; an unreadable bundle is a row, not an omission |
| Disk Space | 14.6 | `FileManager` volume keys (`getattrlist`/`statfs`) / `FileManager` enumerator | **public** | Volume row shows `—`; an unreadable directory is a drawn `Locked` rectangle with `—`, never a low number; not counted in §4.7's health phrase (a one-shot read, by design) |
| System info | 9 | sysctl / IOKit | **public** | Individual rows show `—` |

**The acceptance criterion this table exists to state:** with every **private** provider forced to `.unavailable` (a debug flag does exactly this, §13.7.3), GlowTop must launch, run for 30 minutes, animate at full frame rate, and show correct CPU, memory, disk, network, and process data, with four tiles reading `—`. If that is not true, a private API has become load-bearing and the design is wrong. Connections and Installed Apps are outside this table's `.unavailable`-under-the-flag criterion in one respect: both read only public APIs, so §13.7.3's flag does not touch them, and gate 3 (phase-12, 5.2) states that both stay live under it rather than going dark. Disk Space (§14.6, phase-13) is the third such pane and carries the same expectation.

---

## 6 Rendering model

### 6.1 The split

Two independent clocks:

- **Sampling** — providers, at the rates in §5.0.2, on a background actor. Nothing here touches a view.
- **Rendering** — display-link driven, at the display's refresh rate (60 Hz on the reference machine's built-in panel, 120 Hz on a ProMotion display), on the main thread. Nothing here makes a syscall.

Between them sits `MetricStore`, which holds the last two snapshots per metric plus a ring buffer of history. The renderer reads; the sampler writes; neither waits for the other.

This is the single most important structural decision in the app. Sampling at 60 Hz would multiply syscall cost sixfold for no additional information, since none of these counters meaningfully change in 16 ms. Rendering at 10 Hz would produce visible stepping. Doing both at their own rate costs one interpolation per mark per frame.

### 6.2 Display link

`NSView.displayLink(target:selector:)` (macOS 14+, **public**), added to the main run loop in `.common` mode so it keeps firing during window resize and menu tracking.

| Rule | Detail |
|---|---|
| Creation | In `viewDidMoveToWindow`, when `window != nil` |
| Invalidation | In `viewDidMoveToWindow` when `window == nil`, and in `deinit` |
| Callback | Sets `needsDisplay = true`; it does not draw |
| Occlusion | When the window is fully occluded or minimized (`NSWindow.occlusionState` lacks `.visible`, observed via `NSWindow.didChangeOcclusionStateNotification` and filtered to the app's own window), the display link is paused and sampling drops to 1 Hz for all providers |
| Multiple displays | The display link follows the window's screen automatically; a window dragged from a 60 Hz to a 120 Hz display re-times without restarting |

On macOS 13 the equivalent is `CVDisplayLink`. The reference machine runs macOS 26, so this path is specified but not implemented (§2.1).

Pausing on occlusion matters more than it looks: a monitor left open behind a full-screen window would otherwise burn its full frame budget drawing pixels nobody can see, which is precisely the failure mode §1.3 item 4 exists to prevent.

### 6.3 MetricStore

A Swift `actor`. It owns:

- One background `Task` per distinct sample interval (100 ms, 250 ms, 500 ms, 1000 ms) — four timers total, not one per provider.
- For each metric: `previous` and `current` snapshots, plus their timestamps.
- For each time series: a `RingBuffer` (§6.4).
- A monotonic `generation` counter, incremented on every completed **100 ms** pass,
  displayed in the status bar (§4.7). With several loops running, "a completed sample pass"
  is no longer one thing, and a live 1 Hz process loop must not make a dead 10 Hz loop look
  healthy. Per-provider liveness is `Frame.state == .stalled`, computed at read time from the
  sample's own timestamp — a dead loop cannot mark itself dead.

Each timer is a **detached** task that owns its providers as task-local values rather than as
stored properties of the actor. This is not a style choice: `sample()` is `mutating`, and a
mutating call on an actor's stored property can only run on that actor, so providers stored on
`MetricStore` would drag every syscall into the critical section that readers and the other
loops need — and §5.5.4's process enumeration would hold it for 11–19 ms. The task must be
`Task.detached`, never `Task { }`, because an unstructured task created inside an actor method
inherits that actor's isolation and would silently undo this with no compiler error.

Timers use `ContinuousClock` and `Task.sleep(until:)`, which is monotonic and unaffected by wall-clock changes. Each tick computes its next deadline from the *previous deadline*, not from "now", so intervals do not drift; if a tick is late by more than one full interval, the missed ticks are dropped rather than run back-to-back.

Views read snapshots through a `@MainActor`-isolated observable projection updated once per sample, not per frame. A view that awaited the actor on every frame would introduce a suspension point into the draw path, which is how a 60 Hz renderer becomes a 40 Hz renderer.

### 6.4 Ring buffers

`RingBuffer<T>` is a fixed-capacity circular buffer in `GlowTopCore` — a preallocated array plus a write index. It never reallocates and never grows.

| Series | Capacity | Interval | Span |
|---|---|---|---|
| CPU total, user, system, kernel | 600 | 100 ms | 60 s |
| Per-core utilization (× N cores) | 600 | 100 ms | 60 s |
| Memory composition (4 layers) | 600 | 100 ms | 60 s |
| Disk read/write | 240 | 250 ms | 60 s |
| Network in/out | 240 | 250 ms | 60 s |
| GPU utilization | 120 | 500 ms | 60 s |
| Per-cluster DVFS residency (× N clusters, × S states) | 120 | 500 ms | 60 s |
| Per-cluster average frequency (× N clusters) | 120 | 500 ms | 60 s |
| Energy watts | 60 | 1000 ms | 60 s |
| Package power channels (CPU, GPU, ANE, DRAM) | 60 | 1000 ms | 60 s |
| Temperature (× 4 sensors) | 60 | 1000 ms | 60 s |

Every buffer spans exactly 60 seconds, so every chart in the app covers the same window and two charts can be compared directly by eye. Total memory: on a 14-core machine, roughly 600 × (4 + 14 + 4) × 8 bytes ≈ 106 KB for the 10 Hz series, plus under 20 KB for everything else. Bounded by construction — the RSS budget in §13 cannot be blown by history accumulation.

### 6.5 Drawing

**Quantized meters are composited on the GPU. Charts are drawn on the CPU.** The split is
by what the mark does, not by taste.

A meter is a static picture revealed to a variable height. Nothing about its pixels changes
between frames — only how much of it is visible. That is a crop, and a crop is what a
compositor does for free:

- Each bar is a `CALayer` whose `contents` is a column texture rendered **once** per backing
  scale: 40 rounded segments with their glow baked in, plus `glowRadius` of padding on every
  side so the glow is not clipped.
- The lit fraction is a `contentsRect` crop with `contentsGravity = .bottom`, so the cropped
  sub-image is drawn at natural size against the layer's bottom edge and shortening the crop
  shortens the bar instead of squashing it.
- On each new sample the crop is animated to its new value over the sample interval with a
  linear `CABasicAnimation`. The render server interpolates; the app sets two properties per
  bar, ten times a second, and does nothing at all on the other fifty frames.

`contentsRect` is in the unit coordinate space of the contents image, whose origin is its
top-left, so revealing the bottom fraction `v` means `CGRect(x: 0, y: 1 - v, width: 1,
height: v)`. That orientation is a platform convention rather than arithmetic, so it is
**verified against rendered pixels**, not reasoned about: `GLOWTOP_SELFCHECK=1` renders the
layer tree offscreen and reports the measured lit height against the expected one at 25 %,
50 %, 75 %, and 100 %. It must print `selfcheck: PASS` before any phase advances (§13.7.12).

**Charts are composited too.** A time series is different in kind from a meter — every point
moves every frame and there is no static texture to crop — but the thing that moves is a
*path*, and a path is what `CAShapeLayer` exists to hold. Each plot rect is one `ChartLayer`
container (`masksToBounds` standing in for the clip), holding one `CAShapeLayer` per stroked
series, one per §4.5 band, one `CAGradientLayer` masked by a shape layer per §4.4 gradient
fill, and one shape layer for the gridlines. The app assigns `path` on the data tick and on
each backing-pixel scroll step (§6.6) inside a `CATransaction` with actions disabled, and
resolves colour once per theme change (§7.3). The render server rasterizes. Nothing
animates implicitly: an implicit `path` animation would interpolate the series' *values*,
which §6.6 rule 4 forbids, so `actions` are nulled at construction and every write sits in a
disabled transaction.

**What this section used to say, and why it was wrong — twice.** It first mandated
CoreGraphics drawing in `draw(_:)` for everything, including the meters, and pre-rendered
the glow on the theory that the shadow blur was the expensive part; phase-01 measured that
model at 7.2 % of a core for fourteen bars and nothing else (§13.1.2), and the meters moved
to the compositor. It then said **"charts stay on the CPU"** — that a `CGPath` of 600 points
stroked once per frame is cheap and exact. Exact, yes. Cheap, no: phase-05's profile found
CoreGraphics's own antialiased rasterization of exactly §4.4's geometry to be the pane's
dominant cost with this project's code under 0.01 % (§13.1.11), and gate 8 was carried out
of M01 unmet at 94.2 %. Phase-09 measured the two paths against each other from one binary,
interleaved, on the unedited harness (§13.1.13): the CoreGraphics path served 86.8 % of the
120 Hz panel at 25.37 % of a core; the composited path served **100.0 %** on every round at
**9.97 %**, with `rss` 92.8 MB lower and the plot pixels identical to `maxdelta` 3. Both
mandates were written before their measurement; both measurements contradicted them; both
mandates changed. The pre-rendered-glow instinct survives in the meters, and the
one-clock rule survives everywhere — the display link in `SummaryPaneView` is still the
only thing that decides when a path is assigned.

### 6.6 Interpolation

Every animated mark reads two snapshots and the current time:

```
t = clamp((now − current.timestamp) / sampleInterval, 0, 1)
displayed = previous.value + (current.value − previous.value) × t
```

Rules:

1. **Wall-clock, not frame count.** Interpolating by frame index breaks the moment a frame is dropped or the display refresh differs from 60 Hz.
2. **Clamped to 1.0.** If the next sample is late, the mark holds at the current value rather than extrapolating past it. Extrapolation invents data.
3. **Linear.** Easing a *measurement* introduces overshoot that reads as a real value the machine never had.
4. **Charts scroll, they do not interpolate.** The x-offset of the plot advances continuously (that is the interpolation), but each plotted point sits at its measured value. Smoothing a time series would flatten exactly the single-sample spikes worth seeing.

### 6.7 FPS counter

A debug overlay, top-right of the animated view, SF Mono 10 pt, `#5A5A68`, showing 1-second rolling averages of the two numbers defined below — `fps`, the display-link ticks serviced, and `draws`, the ticks that produced new pixels.

Toggled with ⇧⌘F, off by default in release builds, on by default in debug. With `GLOWTOP_LOG_FPS` set it also prints one line per second to stdout so a phase gate can read the number without a screenshot.

**Two numbers, because they answer different questions.** `fps` counts display-link ticks serviced — the rate the view sustains, and the one the §13.7 gate checks. `draws` counts the ticks that actually produced new pixels; a tick whose output would be pixel-identical to the frame already on screen is skipped (§6.6), so at idle `draws` runs well below `fps` and that is the system working, not dropping frames.

Counting only `draw(_:)` calls, as this section originally specified, understates the frame rate the moment identical frames are skipped — it reports the redraw rate and calls it the frame rate.

### 6.8 Pause

`Space` (§3.5) suspends the sample timers and the display link. Meters hold their last values at full opacity, and the status bar reads `Paused · Generation 4218`. Resuming discards every provider's delta baseline (§5.0.3), so the first post-resume sample is `.warming` — a "utilization" measured across a pause is not a measurement.

### 6.9 Frame budget

**Two ceilings, two different quantities.** They were written as if they competed; they do
not, and stating what each one governs is the whole resolution:

| Ceiling | Governs | Value | Fails when |
|---|---|---|---|
| **Latency** (this section) | Time to produce one frame, from tick to submitted | **≤ 4 ms** of the 16.67 ms budget | A frame misses vsync and the eye sees a stutter |
| **Cost** (§13.1) | CPU consumed per wall-clock second, **the app process** | **≤ 35 %** of one core (§13.1.11) | The monitor is a meaningful fraction of what it is monitoring |

The missing sentence, which made them look like a contradiction: **§6.9 silently assumed
that per-frame work lands on the CPU.** Under that assumption 4 ms per frame at 60 Hz is
240 ms of CPU per second — 24 % of a core — and the two ceilings cannot both hold. Invert
the assumption and both survive comfortably: when a frame is produced by the compositor from
a texture the app uploaded once (§6.5), the latency ceiling is a GPU-side deadline and costs
the app nothing per frame. Neither number was wrong. The assumption was unstated.

So: the 4 ms applies to work the app does per frame, which after §6.5 is path assembly on
the ticks that change a path — a data sample or a backing-pixel scroll step, together
roughly 30 times a second at 120 Hz — and nothing on the other frames. Meters and, since
phase-09, chart rasterization cost the app nothing per frame by construction.

Approximate allocation at 14 cores, with the Summary pane visible:

| Work | Where | Budget |
|---|---|---|
| 4 vertical meters × 40 segments | GPU composite | 0 ms app-side |
| 14 per-core mini-meters | GPU composite | 0 ms app-side |
| CPU overlay chart, 3 paths × 600 points | `CAShapeLayer` paths, render-server rasterized (§6.5) | path assembly only, ~30/s; 0 ms rasterization app-side |
| Memory timeline, 4 stacked areas | `CAShapeLayer` bands (§6.5) | path assembly only, ~30/s |
| 6 tile charts | `CAShapeLayer` + masked `CAGradientLayer` (§6.5) | path assembly only, ~30/s |
| Text (headlines, labels, status bar) | `CATextLayer` | 0 ms app-side |

The three chart rows used to read `CPU draw(_:)` at 1.2 / 0.8 / 1.0 ms. Phase-09 did not
measure the per-frame latency of path assembly — it measured the cost ceiling instead: the
app process at **9.97 %** of a core with every chart moving at 120 Hz (§13.1.13), against
25.37 % on the path these rows described.

Text was called out here as the sneaky one — 40 attributed strings drawn per frame costing
more than every meter combined. It is now a `CATextLayer` per label, whose string is set only
when it changes, so it left the per-frame path entirely for the same reason the meters did.

---

## 7 Theme system

### 7.1 Structure

A theme is a flat set of named color tokens. There are no derived colors, no computed shades, and no color math at render time — every color the app draws is a token, so changing a token changes every mark that uses it and nothing else.

Tokens are `struct Theme: Codable, Sendable` in `GlowTopCore` (colors as hex strings; `NSColor` conversion lives in `GlowTopApp`, preserving the layering rule in §2.7).

### 7.2 Token list

Three presets ship in M01: Neon (default), Classic Green, and **Amber Retro** (added
phase-05) — monochrome amber phosphor, on the same principle as Classic Green: everything
one colour, except the alarm tokens, which stay red/yellow/orange in every preset because a
status rendered in the palette's own colour is not a status.

| Token | Neon (default) | Classic Green | Amber Retro | Used by |
|---|---|---|---|---|
| `background` | `#0B0B0F` | `#000000` | `#0F0B00` | Detail area |
| `sidebarBackground` | `#0E0E13` | `#050A05` | `#140E00` | Sidebar, status bar |
| `cardBackground` | `#101017` | `#001400` | `#1A1200` | All cards |
| `cardBorder` | `#1E1E28` | `#0A3A0A` | `#3A2A00` | Card borders |
| `gridline` | `#1A1A22` | `#0A2A0A` | `#2A1E00` | Chart gridlines |
| `textPrimary` | `#F2F2F7` | `#33FF33` | `#FFB000` | Headlines, selected rows |
| `textSecondary` | `#8A8A99` | `#22AA22` | `#C88600` | Titles, status bar |
| `textTertiary` | `#6E6E7E` | `#177717` | `#A87000` | Footers, axis labels |
| `textDisabled` | `#5A5A68` | `#115511` | `#7A5200` | `—`, warming `···` |
| `accentCPU` | `#39FF14` | `#33FF33` | `#FFB000` | CPU meters, chart, per-core strip |
| `accentMemory` | `#FF2D95` | `#33FF33` | `#FFB000` | Memory card |
| `accentDisk` | `#39FF14` | `#33FF33` | `#FFB000` | Disks tile |
| `accentNetwork` | `#0A84FF` | `#33FF33` | `#FFB000` | Network tile |
| `accentEnergy` | `#FFD60A` | `#33FF33` | `#FFB000` | Energy tile |
| `accentGPU` | `#0A84FF` | `#33FF33` | `#FFB000` | GPU tile and meter |
| `accentNPU` | `#FF453B` | `#33FF33` | `#FFB000` | NPU tile |
| `accentThermal` | `#FF9F0A` | `#33FF33` | `#FFB000` | Thermals tile, Temp meter |
| `accentKernel` | `#FF453B` | `#1F7A1F` | `#B37A00` | Kernel series on the CPU chart |
| `accentClock` | `#FF3B30` | `#33FF33` | `#FFB000` | Clock meter |
| `warning` | `#FFD60A` | `#FFD60A` | `#FFD60A` | Degraded status, 60–80 % pressure |
| `critical` | `#FF453B` | `#FF453B` | `#FF453B` | > 80 % pressure, > 100 °C, kill confirmation |
| `statusDegraded` | `#FF9F0A` | `#FF9F0A` | `#FF9F0A` | Status bar, 3+ providers unavailable (§4.7) |
| `glowOpacity` | `0.55` | `0.75` | `0.70` | Glow strength (0–1) |
| `glowRadius` | `6.0` | `8.0` | `8.0` | Glow blur radius in points |

Classic Green and Amber Retro are monochrome on purpose — each is a single-phosphor
terminal preset, and the whole point is that everything is one colour. `warning`,
`critical` and `statusDegraded` stay red/yellow/orange in every preset for the same reason.

**`statusDegraded` is a new token (added phase-05).** §4.7's third health row (3+ providers
`.unavailable`) previously read through `accentThermal`, which had the right value and the
wrong model: the moment a token could be edited, changing the Thermals accent would have
silently recolored the status bar too. It carries `accentThermal`'s value unchanged in every
shipped preset — a token of its own so the two can now diverge.

### 7.3 Editing

The **Colors** sidebar item opens an editor: every token as a row with its name, a swatch, and a hex field. Changes apply live to the running dashboard — no apply button, no restart, no preview pane. `Cmd-Z` undoes; `Reset to preset` restores.

**Rebuild cost, as implemented (amended phase-05).** §7.2 said this would rebuild "the glow
image cache for that color only, which takes under 5 ms"; the implementation invalidates the
resolved token→`CGColor` table, `MeterLayer`'s texture cache (§6.5) and the gradient cache
**as a unit**, rebuilt lazily on the next draw rather than per-color. One invalidation is one
code path; a per-color invalidation would be three caches keyed three ways for a saving on a
user-triggered action, not a per-frame one. The rebuild's cost was not measured in phase-05 —
no millisecond figure is claimed here until one is.

### 7.4 Persistence

`UserDefaults` under the app's own domain:

| Key | Type | Meaning |
|---|---|---|
| `theme.presetName` | String | `"Neon"`, `"Classic Green"`, `"Amber Retro"`, or `"Custom"` |
| `theme.customTokens` | Data (JSON) | The full token set, written only when `presetName == "Custom"` |
| `theme.version` | Int | Schema version, currently `1` |

Loading rules: a missing key yields the Neon default. A token missing from a stored custom theme takes the Neon value — adding a token in a later version must not break a saved theme. A malformed hex string is logged via OSLog and falls back to Neon's value for that token, and the app does not refuse to launch over a bad color. **Stated explicitly (amended phase-05, implemented as of §7.4's first build):** an unknown or missing `presetName` also yields Neon, and a stored `theme.version` above the schema this build understands (currently `1`) yields Neon rather than being read as if it were the current schema — reading a future schema as the present one is how a theme file corrupts on downgrade.

### 7.5 Accessibility

Contrast: every text token against its background meets a **4.5:1** contrast ratio, checked once at theme-edit time and reported inline in the editor when a custom color falls below it. It is a warning, not a block — this is a personal tool and its owner is allowed to make it unreadable.

**Measured (phase-05), against each shipped preset's own `background`:** `textTertiary` and
`textDisabled` both fail 4.5:1 in Neon (3.9:1, 2.9:1) and in Classic Green (3.7:1, 2.3:1).
Amber Retro's `textTertiary` was chosen to clear the threshold (4.7:1); its `textDisabled`
was not, on purpose (2.8:1), matching Neon's and Classic Green's — `—` and `···` are meant
to recede. The warning above does not block, and the shipped palettes trip their own checker
on these rows in all three presets; that is recorded here so a future reader does not mistake
the warning for a defect.

Color is never the sole carrier of information. The four meters are labeled (`CPU`, `CLOCK`, `TEMP`, `GPU`); chart series are distinguished by dash pattern as well as color (§4.6.1); thermal and memory pressure states carry text, not just a color change.

Reduced motion: when `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true, interpolation is disabled — meters step at the sample rate instead of gliding. Data updates at exactly the same rate; only the tweening stops.

Reduced transparency and increased contrast are respected by bumping `cardBorder` and `textSecondary` one step brighter.

*Not built as of v1.1.2:* no code path reads `accessibilityDisplayShouldReduceMotion`, Reduce Transparency or Increase Contrast — meters always interpolate and tokens are never bumped. The contrast warning above is the only part of this section that shipped; the rest is carried, unscheduled.

---

## 8 Processes pane

### 8.1 Layout

Full-width table filling the detail area, with a 44-point toolbar above it and the standard status bar below.

Toolbar: a search field (leading, 240 pt), a live process count (center, `1138 processes · 24 shown`), and a refresh-cadence label (trailing, `1 Hz`). No refresh button — ⌘R exists for a forced sample and the table is always live.

### 8.2 Columns

| Column | Width | Alignment | Font | Content |
|---|---|---|---|---|
| PID | 60 pt | trailing | SF Mono 11 | Process ID |
| Name | flexible, min 180 pt | leading | SF Pro Text 11 | Executable name; 16 pt icon from `NSWorkspace` when the process has a bundle |
| CPU % | 70 pt | trailing | SF Mono 11 | §5.5.2, one decimal, may exceed 100 |
| Memory | 90 pt | trailing | SF Mono 11 | `pti_resident_size`, §4.9 byte formatting |
| Threads | 60 pt | trailing | SF Mono 11 | `pti_threadnum` |
| User | 110 pt | leading | SF Pro Text 11 | Resolved from the process UID via `getpwuid` |
| Energy | 70 pt | trailing | SF Mono 11 | `ri_energy_nj` delta, relative impact 0–100, or `—` |
| Path | flexible, min 200 pt | leading | SF Pro Text 11 | `proc_pidpath`, truncated with a head ellipsis |

Row height 20 pt; alternating row backgrounds `#101017` and `#0D0D13`; selected row `#1C2A1C` with the CPU accent as a 2 pt leading bar.

Column widths and visibility persist under `UserDefaults` key `processes.columns`.

### 8.3 Sorting

Click a header to sort; click again to reverse. Default: CPU % descending. The sort indicator is a 8 pt chevron in `textSecondary`.

Sort is stable — rows with equal values keep their previous relative order, which stops the large block of 0.0 % processes from reshuffling every second.

Sorting is applied after each 1 Hz refresh, and rows animate to new positions over 250 ms (§4.3.3). Rows entering the table fade in over 250 ms; rows leaving fade out over 250 ms before their space closes, so a process exiting is visible rather than a silent gap.

### 8.4 Search

The search field filters on a case-insensitive substring match against Name, Path, and PID (typing `1138` matches the PID exactly and also any path containing `1138`). Filtering is applied to the full snapshot on every refresh, and it does not stop the table from updating.

⌘F focuses the field; Esc clears it and returns focus to the table.

### 8.5 Kill flow

This is the only destructive action in M01, and it is specified in full because "kill a process" is exactly the feature that should not be improvised.

1. **Trigger:** ⌫ or ⌘⌫ with a row selected, the `Quit Process` toolbar item, or right-click → `Quit Process`.
2. **Confirmation sheet**, always, with no "don't ask again" option:

   > **Quit `Google Chrome Helper (Renderer)`?**
   > PID 48213 · 4.2% CPU · 1.8 GB memory · user `jappleseed`
   >
   > This sends SIGTERM. The process may lose unsaved work.
   >
   > `[Cancel]` `[Force Quit]` `[Quit]`

   `Quit` is the default button; Esc cancels.
3. **`Quit`** sends `SIGTERM` via `kill(pid, SIGTERM)`.
4. **`Force Quit`** sends `SIGKILL`. The button is styled with the `critical` token and is never the default.
5. **After SIGTERM**, the app polls the PID (`kill(pid, 0)`) every 500 ms for 5 seconds. If it is still alive, a second sheet offers `Force Quit` or `Leave it`.
6. **Failure:** `EPERM` (not the owner) shows `Not permitted — this process belongs to another user or the system.` `ESRCH` (already gone) closes the sheet silently and removes the row.

**Guardrails.** PID 0 and PID 1 (`kernel_task`, `launchd`) are never killable — the menu item is disabled with a tooltip. Processes owned by UID 0 show an additional line in the sheet: `This is a system process. Quitting it may destabilize macOS.`

**Logging.** Every attempt — success or failure — appends one line to `~/Library/Logs/GlowTop/actions.log`, created lazily with mode `0600`:

```
2026-08-25T14:32:07Z KILL pid=48213 name="Google Chrome Helper" signal=SIGTERM uid=501 result=ok
2026-08-25T14:33:11Z KILL pid=1 name="launchd" signal=SIGTERM uid=0 result=blocked-guardrail
```

`result` is one of a closed vocabulary: `ok`, `blocked-guardrail`, `eperm`, `esrch`, or `failed:<errno>` for anything else `kill(2)` returns. A cancelled sheet writes **no** line — it is not an attempt, and the log only ever records something GlowTop actually tried.

A process name can contain a `"` or a control character; written verbatim, either could make a log line parse as more or fewer fields than it has. Before logging, `"` becomes `'` and control characters (including newlines) are dropped from `name`, so `foo" result=ok` (a real process could name itself this) logs as `name="foo' result=ok"` — one field, not two.

The log is append-only, never rotated by the app in M01 (it grows by roughly 100 bytes per action; a heavy user generates a few KB a year), and is the first thing to read when someone asks what happened to a process.

### 8.6 Inspector

Double-clicking a row (or ⌘I) opens a detail sheet: full path, arguments where readable, parent PID with the parent's name, start time and elapsed run time, UID and user name, thread count, resident and virtual memory, cumulative user and system CPU time, cumulative disk bytes read and written, and the process's architecture.

Read-only in M01. Arguments come from `sysctl KERN_PROCARGS2`, which fails for processes owned by other users; those show `—` rather than an error.

### 8.7 Refresh and selection stability

Selection is keyed on PID, not row index. A selected row that moves during a re-sort stays selected and scrolls into view if it moves off screen. If the selected process exits, the selection clears and the table does not jump.

Scroll position is preserved across refreshes. A table that scrolls back to the top every second is unusable, and this is the single most common way process viewers get this wrong.

---

## 9 System Info pane

### 9.1 Layout

A single scrolling column of grouped rows — no charts, no animation, no live values except uptime and the memory-pressure line. Groups are cards (§4.2) with a title and label/value rows: label leading in `textSecondary`, value trailing in `textPrimary`, 22 pt row height, SF Mono for values that are numbers or identifiers.

### 9.2 Content

**Hardware** — all **public** sources:

| Row | Source |
|---|---|
| Model name | `sysctlbyname("hw.model")` mapped through the IOKit `product-name` when present |
| Model identifier | `hw.model` |
| Chip | `machdep.cpu.brand_string` |
| Total cores | `hw.logicalcpu` with the P/E split: `14 (10 performance, 4 efficiency)` |
| GPU cores | §5.6.6 — **private**; reads `—` under §13.7.3's blackout |
| Neural Engine cores | §5.6.4 footer source — **private**; reads `—` under §13.7.3's blackout |
| Memory | `hw.memsize`, §4.9 formatting |
| Serial number | IOKit `IOPlatformSerialNumber` from the `IOPlatformExpertDevice` service |
| Hardware UUID | IOKit `IOPlatformUUID` |

The serial number and hardware UUID are shown but are **not** copied to the clipboard by a single click — they are identifiers, and a screenshot of this pane is a common way to leak them. A right-click → Copy exists; a click does nothing.

GPU cores and Neural Engine cores are the first System Info rows sourced from a private API (§5.6.6 and §5.6.4 respectively) — under §13.7.3's blackout (`GLOWTOP_DISABLE_PRIVATE=1`) both read `—`, which is gate 3 reaching a pane other than Summary for the first time.

**Software** — **public**:

| Row | Source |
|---|---|
| macOS version | `ProcessInfo.processInfo.operatingSystemVersionString` |
| Build | `sysctlbyname("kern.osversion")` |
| Kernel | `sysctlbyname("kern.version")`, first line only |
| Uptime | `sysctlbyname("kern.boottime")` → `struct timeval`, formatted per §4.9, updating once a minute |
| Boot volume | `NSFileManager` on `/`, name and filesystem type |
| Computer name | `Host.current().localizedName` |

**Memory and storage:**

| Row | Source |
|---|---|
| Memory in use | §5.2.3, live at 1 Hz |
| Memory pressure | §5.2.3 bucket, colored |
| Swap used | `vm.swapusage` |
| Boot volume capacity / free | `URL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])` |

**GlowTop itself:**

| Row | Source |
|---|---|
| Version | Bundle short version and build |
| Own CPU / RSS | `proc_pid_rusage` on `getpid()`, live at 1 Hz |
| Frame rate | Summary's **last** 1-second average from §6.7, labelled with its age: `99.9 fps · Summary, 14 s ago` |
| Providers | `9 healthy · 2 unavailable`, with the unavailable ones named on hover |

Putting GlowTop's own overhead on a pane in GlowTop is not vanity — §13's budget is not credible unless it is visible while the app runs, and it is the fastest way to notice a regression.

**The Frame rate row cannot be live, and that is deliberate.** §6.7's counter belongs to Summary's display link, and the moment this pane is showing, Summary's view has no window — §6.2 invalidates the link, and no current frame rate exists anywhere in the process. Keeping a display link alive on a hidden pane to produce one is exactly the cost §6.2 exists to avoid. So the row shows the last reading Summary took, stamped with the instant it was computed, and displays how old it is; the age climbs on its own while the number stays frozen. A number presented as current when it is not would be §4.8's violation, and the age is what keeps it honest. `glowtop-probe sysinfo` has no window and no display link at all, so it reads `—`.

### 9.3 Refresh

Static rows are read once at launch and refreshed on wake from sleep (`NSWorkspace.didWakeNotification`). Live rows (uptime, memory, own overhead, frame rate) update at 1 Hz while the pane is visible and not at all when it is not.

---

## 10 Startup Apps pane

### 10.1 What it shows

Everything that launches automatically for this user, from four sources, in one table.

| Source | Path | Type shown | API |
|---|---|---|---|
| User launch agents | `~/Library/LaunchAgents/*.plist` | `Launch Agent` | Filesystem read + `PropertyListDecoder` — **public** |
| System launch agents | `/Library/LaunchAgents/*.plist` | `Launch Agent (system)` | same |
| System launch daemons | `/Library/LaunchDaemons/*.plist` | `Launch Daemon` | same |
| ~~Login items~~ | ~~Registered via `SMAppService`~~ | — | **Not implemented in M01 — see below.** |

**Login items are not listed in M01.** `SMAppService` — the source this section originally named — has no enumeration API: `mainApp`, `agent(plistName:)`, `daemon(plistName:)` and `loginItem(identifier:)` each require an identifier the caller already holds, so it can report the calling app's own registration and nothing else. The Background Task Management store at `/private/var/db/com.apple.backgroundtaskmanagement/BackgroundItems-v*.btm` is world-readable and holds the records, but question 3 of the timeboxed investigation (phase-04 plan, 4.2) failed: at least one record on the reference machine carries a real identifier and no name at all (a disabled, orphaned entry), and §10.1's own rule is that every item must yield both a name and an identifier or the whole read fails — a partial list is worse than none. `sfltool dumpbtm` is not used: it requests `system.privilege.admin`, which GlowTop never asks for (§2.4), and it emits human-formatted stdout, which §12.1 ruled out permanently for `launchctl` and which is ruled out here for the same reason. The three launchd plist directories above are unaffected and remain the pane's content.

The consequence is that a login item — old or new, however it registered — does not appear anywhere in this pane in M01; that is a known and accepted gap, noted on the pane's footer, which now carries two sentences: the pre-existing `Legacy login items are not listed.` plus a second one naming this section's finding directly. *Amended 2026-09-21 (1.1.1):* that second sentence reads `Login items are not listed: macOS gives apps no supported way to read them.` It shipped as `Login items are not listed in M01.` — milestone vocabulary on a user's screen, and stale from the day M02 shipped.

### 10.2 Columns

| Column | Content |
|---|---|
| Enabled | A checkmark or `—`, read-only in M01 |
| Name | The plist `Label`, or the app name for login items |
| Type | From the table above |
| Program | `Program` or the first element of `ProgramArguments` |
| Run at load | `RunAtLoad` boolean |
| Keep alive | `KeepAlive` boolean or dictionary summary |
| Path | The plist path |

Sorted by Type then Name. Search filters on Name, Program, and Path.

### 10.3 Read-only in M01

**M01 does not enable, disable, add, or remove anything.** The Enabled column reflects state; it is not a control. Loading and unloading launch agents is an OS write action with real consequences (a disabled agent can break an app's updater, a mis-parsed plist can be written back malformed), and it is deliberately deferred to M02 (§14.4) where it gets a confirmation dialog and an `actions.log` entry like the kill flow.

Every row has a `Reveal in Finder` context action, which is the useful read-only escape hatch.

**Write actions shipped in phase-14 (M02):** `Launch Agent` rows (this user's own `~/Library/LaunchAgents`) gain `Enable`/`Disable` context-menu items per §14.4, while `Launch Daemon` and `Launch Agent (system)` rows stay read-only with §14.4's stated reason in the tooltip.

### 10.4 Failure behavior

An unreadable directory (permissions) contributes no rows and adds a footer note naming it. A malformed plist contributes a row with the filename and `Unparseable` in the Type column rather than being silently dropped — a launch agent that macOS cannot parse either is exactly the thing worth seeing.

---

## 11 Users pane

### 11.1 Content

Two sections.

**Accounts** — from `getpwent(3)` (**public**), filtered to `500 ≤ uid < 0x7FFFFFFF`, plus root shown explicitly, deduped on `(name, uid)`:

A bare `uid >= 500` is wrong on real hardware: `nobody`'s `pw_uid` is `-2`, which reads through the unsigned `uid_t` as `4294967294` — comfortably `>= 500` — and `getpwent` returns the `nobody` entry twice. Excluding it means also requiring the value stay below the signed range's top, which every real account (never allocated anywhere near `UInt32.max`) satisfies. Measured on the reference machine: `getpwent` enumerates 266 entries; 4 pass a bare `uid >= 500` floor (`nobody` counted twice, plus one real account); the corrected filter plus root yields the 3 real accounts (`root`, the owner's account, and a second account) the pane is supposed to show.

| Column | Source |
|---|---|
| User name | `pw_name` |
| Full name | `pw_gecos`, first comma-separated field |
| UID | `pw_uid` |
| Primary group | `pw_gid` resolved via `getgrgid` |
| Home | `pw_dir` |
| Shell | `pw_shell` |
| Admin | Membership in the `admin` group, from `getgrnam("admin")` member list |

**Sessions** — currently logged-in users, from `utmpx` (`getutxent`, **public**), filtered to `ut_type == USER_PROCESS`:

Unfiltered, `getutxent` also yields `BOOT_TIME` and `DEAD_PROCESS` records — bookkeeping entries with empty `ut_user`/`ut_line`, not sessions. On the reference machine, unfiltered `getutxent` returns 15 records against `who`'s 3 live sessions; only `USER_PROCESS` records are real logins.

| Column | Source |
|---|---|
| User | `ut_user` |
| Type | Console, terminal, or remote, from `ut_type` and `ut_line` |
| Line | `ut_line` (e.g. `console`, `ttys003`) |
| Host | `ut_host`, empty for local |
| Since | `ut_tv`, formatted as elapsed time |

The Sessions section is the one that occasionally matters: an unexpected remote session is worth noticing, and no other pane in the app would show it.

### 11.2 Refresh and actions

Accounts are read once at launch (they effectively never change). Sessions refresh at 0.2 Hz (every 5 seconds) while the pane is visible.

Read-only entirely. No account creation, deletion, password change, or session termination — in M01 or in any planned milestone. That is `System Settings`' job and doing it here would mean holding privileged operations for no benefit.

---

## 12 Services pane (configured jobs)

### 12.1 Content — a configured-jobs inventory

GlowTop **does not parse `launchctl list` or `launchctl print` stdout.** That output has never been a stable contract; it is formatted for a human reading a terminal and changes without notice. A monitor built on it breaks silently and reports confidently.

The inventory is built instead from the sources that are structured and documented:

- The `launchd` plist directories in §10.1 (`~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`), decoded with `PropertyListDecoder` — **public**.
- `SMAppService.status` for anything registered through `ServiceManagement` — **public**. *Removed 2026-09-21 (1.1.3):* this source never contributed a row — `SMAppService` can only answer for an identifier the caller already holds, which in practice is GlowTop itself (§10.1's finding, applying here too). Its one unused accessor and the `ServiceManagement` import are gone, and the footer below no longer names it.
- Running-process correlation: a job whose `Program` (or first `ProgramArguments` element) matches a running process's executable path (§5.5) is annotated with that PID.

**The pane is titled and labeled "configured jobs," not "services running."** That is what a plist directory tells you: what is configured to run, not what is running. The distinction is on the pane, not just in this document, because the entire failure mode being avoided here is a list that looks authoritative and isn't.

**The pane discloses its own gap, on its face.** A permanent footer, always visible, not a tooltip:

> Configured jobs from launchd plist directories. Jobs registered at runtime, jobs in domains this user cannot read, and system jobs without an on-disk plist are not listed. Running state is inferred by matching against the process table.

Whatever v1 misses, the pane says so. A disclosed gap beats silent wrong coverage, and a user who knows the list is partial can reach for `launchctl` themselves.

**Measured, so the disclosure has a size and not just a shape.** On the reference machine, the three plist directories yield **30** configured jobs (20 user launch agents, 3 system launch agents, 7 launch daemons); `launchctl list` on the same machine carries **531** labels, of which **282** report a PID. The gap is a factor of roughly **eighteen**, not a rounding error — most of what `launchctl` tracks (runtime-registered jobs, jobs in domains this user cannot read, system jobs with no on-disk plist) is exactly what §12.1 says this pane does not attempt to cover. The two counts answer different questions, and comparing them as if they answered the same one is the mistake this disclosure exists to head off.

Where running state cannot be determined, the row reads `Unknown` rather than guessing from the plist alone.

**The correlation resolves symlinks (amended phase-05).** A job's `Program` path is resolved
through `resolvingSymlinksInPath()` before comparison against a running process's executable
path, and the uniqueness guard (which disambiguates a shared interpreter matching more than
one job, §12.1's original rule) counts **resolved** paths, not raw ones — counting raw paths
would let two symlinks to one binary both match, reintroducing the false positive the guard
exists to prevent. This closes a real gap phase-04 found and left: on the reference machine,
`homebrew.mxcl.redis`'s plist names `Program` as `/opt/homebrew/opt/redis/bin/redis-server`
(Homebrew's `opt/` symlink), while the running PID's own executable path resolves to
`/opt/homebrew/Cellar/redis/8.4.0/bin/redis-server` — two strings for one file, which a
literal comparison never agrees on. Before the fix, the job read `Unknown` and its PID did
not agree with `launchctl list homebrew.mxcl.redis` (0/1 agreement); after, it reads
`Running` and agrees (1/1).

### 12.2 Columns

| Column | Content |
|---|---|
| Status | `Running` (green dot, PID matched), `Configured` (gray dot), `Unknown` (hollow dot) |
| Label | The job label, e.g. `com.apple.Spotlight` |
| PID | When running, from the correlation above; else `—` |
| Domain | `User`, `System`, `Daemon` |
| Program | Executable path |
| CPU / Memory | For running services, from §5.5's snapshot |

Sorted by Status (running first), then Label. Search filters on Label and Program.

### 12.3 Read-only in M01

No start, stop, load, or unload in M01 — same reasoning as §10.3. `Reveal in Finder` and `Show Process` (jumps to the Processes pane with the PID selected) are the available actions. Write actions are M02 (§14.4), with confirmation and `actions.log`.

**Write actions shipped in phase-14 (M02):** user-domain rows gain `Start`/`Stop` context-menu items per §14.4, offered on every actionable row regardless of `Status` (D-10); `Launch Daemon` rows stay read-only with §14.4's stated reason.

---

## 13 Performance budget & test plan

### 13.1 The budget

| Metric | Limit | Measured how |
|---|---|---|
| Idle CPU, **whole system** (Summary visible, machine otherwise idle) | n/a — documented, not gated (§13.1.9) | Whole-system CPU-time delta, app running vs closed (§13.1.1) |
| Idle CPU, **GlowTop process** (Summary visible, machine otherwise idle) | **≤ 35 %** of one core | `scripts/overhead-harness.sh` app CPU-time delta; scope ruled app-process (§13.1.10), cap derived §13.1.11 |
| Resident memory, **GlowTop process**, Summary pane visible at 1440×900 | **≤ 210 MB** | `ps -o rss` (KB); limit 215040. `scripts/overhead-harness.sh`'s `rss` column. Scope and cap both ruled 2026-09-01, derivation in §13.1.12 |
| Resident memory after visiting every pane | n/a — documented, not gated (§13.1.12) | Same instrument; **295.60 MB** measured, and it does not fall back — `PaneHostView` rebuilds a pane on return but the walk's peak is retained state, §3.3 |
| Frame rate (Summary pane) | **≥ 95 %** of the display's own refresh (§13.7.8) | In-app counter (§6.7), 60-second average. RENDER-02's original ≥ 55 fps amended to this 2026-08-28; unmet through M01, **met in phase-09** — 120.00 fps on a 120 Hz panel, three rounds, spread 0.00 (§13.1.13) |
| Frame rate (occluded) | n/a — display link paused | `NSWindow.occlusionState` |
| Main-thread time per frame | **≤ 4 ms** (provisional) | Instruments Time Profiler, main thread |
| Full process enumeration | **≤ 25 ms** (provisional) | `ContinuousClock` around the enumeration, logged in debug |
| Launch to window visible | **≤ 1200 ms** | `ContinuousClock` from `applicationDidFinishLaunching` to `windowDidBecomeKey` |
| Launch to first real value | **≤ 400 ms** after window | Debug log line |
| 30-minute run | No crash, no unbounded growth: RSS at 30 min within **10 %** of RSS at 1 min | `ps` sampled once a minute |

**Phase-01 result for the idle-CPU row: failed-with-cause.** The app process reads 2.22 %
visible and 1.07 % at the floor (§13.1.6). WindowServer's share reads about +39 and cannot
be resolved to gate precision by CPU time on this hardware (§13.1.7). Tagged `v0.0.1-spike`
on that record. The row splits into an app-process budget and a compositor budget in
milestone M01.5 (§13.1.8).

#### 13.1.1 How idle CPU is measured

Two rules: the right instrument, and the right scope.

**The instrument is a CPU-time delta, never `ps -o %cpu`.** That column is a decaying
average weighted toward recent activity, and it charges the app for its own launch — window
creation, SwiftUI setup, and the first Metal surface cost real CPU for a second or two, which
pollutes the reading for a minute afterward. Measured that way the spike read 8.9 % while a
`sample` of the same process showed it parked in `mach_msg2_trap`, doing nothing.

**The scope is the whole machine, not the app.** Compositing (§6.5) moves per-frame work out
of GlowTop and into WindowServer and the GPU. It does not delete that work. An app that
reports its own process cost after moving the cost elsewhere is doing the same thing as a
memory figure reverse-engineered to match a black box (§5.2.3): producing an authoritative
number that measures the wrong quantity. In a monitor, that failure is not cosmetic — it is
the app lying about the one subject it exists to report on.

So the gate is a difference of two whole-system measurements over equal windows:

```
# app closed
t0 = sum of cputime over every process ;  wait 60 s ;  t1 = same
baseline = (t1 - t0) / 60

# app running, at least 20 s after launch
t0 = sum of cputime over every process ;  wait 60 s ;  t1 = same
loaded = (t1 - t0) / 60

idle cost = (loaded - baseline) x 100 %      # must be <= 3.0 % of one core
```

WindowServer and GlowTop are also measured individually across the same windows, because
where the cost lands is diagnostic: a rise in WindowServer with a flat app figure is
compositing doing its job at a price, and it counts against the same 3 %.

Both windows must run under comparable machine load, and the load must be stated with the
result. A baseline captured on an idle machine against a loaded run on a busy one measures
the machine, not the app.

**Scope, as of 2026-08-28.** The whole-system method above is retained as the *documented*
measurement, not the gated one: M01.5 established that whole-system cost is not resolvable to
gate precision on this hardware (§13.1.9). The gated number is the **app process's**, ruled
§13.1.10 and capped at 35 % of one core by the derivation in §13.1.11. The `3.0 %` in the
worked example above is the historical whole-system figure and is left as written, because it
is what the readings recorded in §13.1.2–§13.1.9 were taken against.

#### 13.1.2 Phase-01 measurement and the ruling that followed

The phase-01 spike (14 bars, one display-linked view, no charts, no tiles) was measured at
each step of four optimization rounds. Release build, CPU-time delta method, app-process
scope:

| Drawing approach | App CPU | Frame rate |
|---|---|---|
| Naive: `NSImage` glow resolved per segment per frame (560 resolutions/frame) | 25.2 % | 60.0 |
| Cached `CGImage` per segment; unlit segments batched into one fill | 13.6 % | 60.0 |
| One clipped blit of a pre-rendered column per bar (28 draws/frame) | 9.7 % | 60.0 |
| Skip redraws whose quantized output is unchanged | 7.2 % | 60.0 ticks/s, 17–44 draws/s |
| **GPU composite via `CALayer.contentsRect` (§6.5)** | **4.4 % app / 46.1 % whole system** | **120.0** |
| **Gate** | **≤ 3.0 %** | **≥ 55** |

That measurement established two things. The frame-rate risk was retired outright — the
display link held 60.0 ticks per second throughout, and nothing about 60 Hz rendering was
ever in doubt. And the 3 % budget was unreachable with CPU-side CoreGraphics drawing, in the
smallest case the app will ever have: phase-03 adds three streaming charts, a memory
timeline, six tiles, and a process table to the same frame.

**The ruling (Connor, phase-01): composite on the GPU.** §6.5's CGContext mandate predated
any measurement, measurement contradicted it, and that is the case for amending a
specification rather than working around it in code.

Rejected on the record, with reasons, so neither is quietly revisited:

- **Relaxing the budget to 5–10 %** moves the goalpost on the first spike. On this product
  3 % is not arbitrary — a CPU monitor that costs 7 % of a core is a punchline. The number
  stays.
- **Dropping to 10 Hz when nothing moves** discards the one thing phase-01 proved, and barely
  engages: on a CPU monitor the bars twitch constantly, so "nothing moves" is a rare state.

Conditions attached to the ruling, all three now part of this specification:

1. The gate became a whole-system measurement (§13.1.1). Cost moved to WindowServer is still
   cost.
2. The sample rate was checked rather than assumed. Providers already read mach at **10 Hz**
   (§5.0.2); the display-link path makes no syscalls at all. The entire 7.2 % was rendering,
   not sampling, so there was no sample-rate fix to make.
3. One attempt, then report — no fifth optimization round. If the composited build misses
   3 %, the number goes back to Connor as a specification question with data behind it.

#### 13.1.3 Route 1 measured: the app got cheaper, the machine got dearer

The composited build (§6.5) was measured against the whole-system gate in §13.1.1. Two
60-second windows, same machine, nothing else started or stopped between them:

| | App closed | App running | Delta |
|---|---|---|---|
| GlowTop process | 0.00 % | 4.36 % | **+4.36** |
| WindowServer | 5.49 % | 47.77 % | **+42.28** |
| Whole machine (kernel ticks, 14 cores) | 77.97 % | 124.06 % | **+46.09** |
| Frame rate | — | 120.0 ticks/s | — |
| RSS | — | 90.5 MB | — |

**Whole-system cost: +46 % of one core, against a 3 % gate. Route 1 fails, and fails worse
than what it replaced.**

The app-scope figure improved exactly as predicted — 7.2 % down to 4.4 % — and it is
meaningless on its own. WindowServer went from 5.5 % to 47.8 %, nearly nine times its idle
cost. The work did not disappear when it left `draw(_:)`; it moved one process over and got
more expensive in transit. Had the gate stayed app-scoped, this build would have been
recorded as a 40 % improvement and shipped. That is precisely the failure the whole-system
scope was added to catch, and it caught it on the first run.

A second finding, free: the panel is 120 Hz. Every earlier "60.0 fps" reading was the CPU
draw path saturating, not the display's rate. The composited build services 120 ticks per
second — which is also part of why WindowServer costs what it does, since it now composites
fourteen alpha-blended glow textures twice as often as anything measured before.

What is *not* yet established is how much of the 42-point WindowServer delta is inherent to
compositing fourteen animated layers versus incidental to how this build does it. Three
candidates, none tested:

1. Compositing at 120 Hz rather than 60. The display link's rate is not the compositor's
   obligation; a 10 Hz data source does not need 120 Hz recomposition.
2. A fresh `CABasicAnimation` added to all fourteen layers every 100 ms, which keeps the
   render server in a continuously-animating state rather than letting it idle.
3. Large soft-alpha glow textures, which are the most expensive kind of layer to blend, and
   there are fourteen of them stacked over an opaque background.

Per the phase-01 ruling's third condition — one attempt, then report — none of these were
tried. The number goes back to Connor as a specification question with data behind it. A monitor that grows 2 MB an hour looks fine in a 5-minute test and is unusable after a workday, and ring-buffer discipline (§6.4) plus IOKit object release (§5.3.2) are the two places that would break it.

#### 13.1.4 Bisection: the glow is not the cost, and the app has a floor

Two isolation switches, measurement instruments rather than features: `GLOWTOP_NO_GLOW`
(flat opaque bars — no shadow, no alpha channel) and `GLOWTOP_STATIC_ANIM` (one animation
per layer installed at startup, layers never touched again).

| | glow | installs/s | display | WindowServer | app |
|---|---|---|---|---|---|
| baseline, closed | — | — | — | 5.49 % | 0.00 % |
| full build | on | 140 | 120 Hz | 47.77 % | 4.36 % |
| variant B | **off** | 140 | 120 Hz | 48.85 % | 3.41 % |
| variant A | on | **once** | 60 Hz | 31.27 % | 2.83 % |

Candidate 3 of §13.1.3 is falsified: removing the glow entirely left WindowServer unmoved.
Candidate 2 is confirmed and small — about 1.5 points, app-side only. The residual is the
finding: variant A installs fourteen animations and then does nothing per sample, and still
costs 2.83 %. Variant A's compositor figure is confounded — its window opened on a 60 Hz
external — caught only because gate 8's rewrite made the view report the display's rate.

#### 13.1.5 Attribution: the compositor cost is GlowTop's

Interleaved harness, five arms × five repeats, quiet machine, window pinned to one display,
AC confirmed. Medians:

| arm | display | fps | WindowServer | ΔWS | app |
|---|---|---|---|---|---|
| quiet baseline | — | — | 5.56 | — | 0.00 |
| visible | 120 Hz | 119 | 46.75 | **+41.19** | 4.10 |
| visible | 60 Hz | 60 | 29.68 | +24.12 | 3.39 |
| covered by an opaque window | 120 Hz | 119 | 26.32 | +20.76 | 4.03 |
| minimized | 120 Hz | 118 | 6.65 | **+1.09** | 2.71 |

Minimizing takes WindowServer from +41.19 to +1.09 with the same app running, the same
providers at 10 Hz, the display link still ticking. Baseline spread 0.49 points against a
41-point effect. Refresh rate is a real and roughly linear term. A covered window is not
free — macOS keeps compositing it; only a minimized one is. The ambient-load covariate was
unusable: baseline machine spread was 196 points, because the measuring session is itself
the load (§13.7.1).

#### 13.1.6 Three removals: the app floor

Ruled by Connor. The display link is gone from the running app (it survives only under
`GLOWTOP_LOG_FPS`, as gate 8's instrument); SwiftUI is out of the sample path (the
coordinator writes layer properties directly); text is decimated to 1 Hz.

| arm | before | after |
|---|---|---|
| app, visible, 120 Hz | 4.10 % | **2.22 %** (−46 %) |
| app, minimized (floor) | 2.71 % | **1.07 %** (−61 %) |
| WindowServer, visible | +41.19 | +39.00 — unchanged; that arm's spread was 33.45 points |

App 2.22 + WindowServer 39 ≈ 41 % of one core against a 3 % gate. The app is nearly
affordable. The window is not.

#### 13.1.7 Area test: the compositor cost is not per-pixel

The experiment that partitions what is left. Full-surface recomposition scales with
pixels × refresh; per-object cost does not. So: shrink the window to a quarter of its area
— same fourteen bars at the same size, same animation, same display, same origin — and
re-measure WindowServer. If ~39 becomes ~10, the compositor is blending the whole surface
every frame and the bars are irrelevant; if it stays, the cost is per-layer or
per-transaction and the bars are back in scope.

Three arms (app closed, 900 × 400, 450 × 200), five interleaved rounds with the start
rotated each round, 20 s settle, 60 s window; `scripts/overhead-harness.sh`. Built-in
panel at its native mode — 3456 × 2234 backing for 1728 × 1117 points at 2×, 120 Hz,
**not scaled**. AC power, macOS 26.6.1. The only other window on that display was the
Claude desktop app behind GlowTop, recorded rather than hidden. Release build.

WindowServer per round, % of one core:

| round | baseline | 900 × 400 | 450 × 200 | quarter − full |
|---|---|---|---|---|
| 1 | 15.68 | 32.68 | 50.08 | +17.40 |
| 2 | 45.68 | 42.18 | 53.38 | +11.20 |
| 3 | 13.68 | 47.93 | 32.68 | −15.25 |
| 4 | 37.93 | 47.47 | 49.05 | +1.58 |
| 5 | 11.63 | 43.45 | 44.30 | +0.85 |
| **median** | **15.68** | **43.45** | **49.05** | **+1.58** |
| spread | 34.05 | 15.25 | 20.70 | |

App: 3.10 % at 900 × 400 and 3.18 % at 450 × 200 (spreads 0.85 and 0.57), with the gate-8
display link running as the fps instrument — about 0.9 points above §13.1.6's 2.22, which
was measured without it. 120.0 fps on every visible reading.

**Quartering the surface did not move WindowServer.** Under the surface hypothesis every
paired round should read about −29; not one does, and the quarter arm is the higher of the
pair in four rounds of five. The lowest quarter-area reading, 32.68, is above the ~26 the
hypothesis predicts for the *median*. Surface-area scaling is dead.

What that does **not** establish — corrected by Connor before it hardened — is a
per-object cost. Falsifying area-scaling rules out one hypothesis and leaves two standing,
and they lead to different designs: **cost per animated layer**, and **a fixed cost for
having any animating window at all** — WindowServer waking, running its pass, and swapping
the surface 120 times a second whether that surface holds one bar or fourteen. The
animation-install switch (§13.1.4) separates neither, and its variable has already been
measured twice. **Bar count does**: one bar against fourteen, everything else identical.
That is the first experiment of the compositor milestone, after the instrument question
(§13.1.8).

Two things also settled by direct observation, printed by the measurement hook: the window
surface is opaque (`isOpaque` true, background alpha 1.0, standard titlebar, shadow on,
`fullSizeContentView` on) and the display is not scaled. Neither surface-level candidate
— a non-opaque window, a scaled display mode — is present, so there is no defect to fix at
that level. What happens to the gate is ruled in §13.1.8.

**On the instrument.** The screen was controlled — fixed position and size, one display,
one static window behind — and the spread did not close: 15 and 21 points on the visible
arms, 34 on the control. Two baseline windows (rounds 2 and 4) read 38 and 46 with
whole-machine CPU 50 points above the other three: something else ran, and the control arm
recorded it, which is its job. WindowServer CPU time over a 60 s window has an ambient
spread of tens of points on this machine even with nothing of ours on screen. By §13.7.1's
own rule the control spread (34) meets the predicted effect (~29), so this run supports no
*magnitude*; it decides a *sign*, because the design is paired and interleaved and no pair
moved the predicted way. A 3-point decision cannot be made with this instrument.

#### 13.1.8 Ruling: tag the spike, change the instrument first, split the gate

Connor, after §13.1.7. Recorded in full because it releases a rule set three rulings
earlier and it reverses the order the rest of this section assumed.

**Tag `v0.0.1-spike` with gate 13.1 recorded failed-with-cause, evidence chain as it
stands.** The no-tag-until-green rule assumed the gate was adjudicable; §13.1.7's
controlled run says it is not. A gate the instrument cannot resolve is not a gate, it is a
trap, and a spike tag is not held against one. The spike's question was whether a native
120 Hz task manager is buildable. It is — 120 fps served on the real panel, the app at
2.22 % visible and 1.07 % at the floor, 23 tests green, a self-check that renders offscreen
and asserts geometry. That is the artifact, and it is a better one with a documented failure
than with a green tag over a number nobody could measure.

**The instrument changes first — triggered by §13.1.7's finding, not by the condition set
in advance.** The watts condition (cost proved structural) did not fire; a different one
did. A control spread of 34 points with the screen controlled, two control rounds above the
lowest treatment reading, means the control overlaps the treatment. A 29-point effect can
still be falsified through that, which is why the surface hypothesis is honestly dead and
the paired minimize test (§13.1.5) stands on its own 0.49-point spread. But nothing smaller
than about 30 points is measurable this way, and the gate is 3.

So the compositor milestone (M01.5) starts with the instrument, not the app: one
`powermetrics` run, package power with combined CPU and GPU, **baseline spread only** —
`scripts/power-baseline.sh`, run by Connor under `sudo`; sessions never run it and the app
never calls it. If watts is quiet enough to resolve a few percent, the two decisive arms are
redone in it: visible against minimized, then one bar against fourteen. If watts is also
unusable here, the honest finding is that GlowTop's compositor cost cannot be measured to
gate precision on this hardware, and that ends the question rather than leaving it open.

**The gate splits into two budgets in that milestone.** The app process keeps 3 %, which it
nearly meets and which is what any tool a user checks will attribute to GlowTop. Compositor
cost gets its own name, its own instrument, and its own number, set from a real reading.
This is not the relaxation refused in §13.1.2 — it is two quantities that were never the
same thing, measured separately.

**Not run: the animation switch.** Its variable has been measured twice — about 1.5 points
app-side, unchanged within spread on WindowServer — and a third look at a small effect
through a noisy instrument buys nothing. It also does not separate the two hypotheses
§13.1.7 leaves standing. Bar count does.

#### 13.1.9 M01.5 phase 1: package-power baseline spread — closed, not measurable

Instrument: `scripts/power-baseline.sh 5 60` — `powermetrics --samplers cpu_power,gpu_power
-i 1000`, a 20-sample settle discarded, then five windows of **60 samples** each. A window
counts samples, not seconds: at `-i 1000` a sample takes about 1.02 s on this machine, so a
60-sample window is roughly 61 s. Three channels are reported separately — CPU, GPU, and
combined (CPU + GPU + ANE). Each window is aggregated by its **median**, per §13.7.1; the
window mean is printed alongside it purely as a diagnostic for how burst-heavy the window
was. Median and spread across windows follow from the per-window medians.

**Why three channels.** A five-sample smoke run of the summing version moved 188 to 2238 mW
in CPU across five idle seconds and 14 mW in GPU over the same five. Every bit of that noise
was in one channel, and the sum carried it into the reading the milestone would have closed
on. `GPU Power:` is printed twice per sample — once in the processor block, once in the GPU
block — and only the first is taken; counting both desynchronizes the windowing.

The script prints the confound block below as well as the tables: date, power source, macOS
version, each display with its refresh rate, and an on-screen census of layer-0 windows with
owner, size, and origin. The raw log is written to `docs/measurements/` (gitignored) and the
run prints the `chown` needed afterwards, since `powermetrics` runs as root.
`--parse FILE [samples]` replays a saved log; `--selftest` parses the committed fixture at
`scripts/fixtures/power-baseline.log` and asserts the median and spread of all three
channels, exiting non-zero on mismatch.

**The rule, declared before the numbers exist.** A channel is usable when its spread across
windows is at or under **one third** of the smallest effect the milestone must resolve. The
current prior for that effect is 3 % of one core ≈ 30–120 mW (§13.1.8), so against its
30 mW low end the threshold is **10 mW**. Phase 2's calibration pair (visible against
minimized) replaces the prior with a measured mW-per-CPU-point; the one-third rule survives
that replacement, and the threshold is recomputed from the measured effect when it does. The
verdict is applied to each channel independently — the run can produce a usable channel and
an unusable one in the same table.

A channel that is quiet at idle is **not** thereby the answer. Idle quiet is not
responsiveness to compositing, and §13.1.5 measured the compositor's cost in CPU time, not
in power. Which channel carries the effect is settled by phase 2's visible-versus-minimized
pair, not by this table.

**Procedure.** Machine quiet, AC power, GlowTop closed, nothing of ours on screen. **No
Claude Code session, build, indexing, or terminal activity may run during the measurement
window.** The 2238 mW smoke sample is session-class load, and the two earlier instruments in
this project failed for exactly that reason: the whole-machine control spread was 196 points
in §13.1.5 and 61 points in §13.1.7 because the measuring session was itself the load.

**Run 1 — 2026-08-25 20:53 CDT.** Per-window statistic is the median (see the instrument
defect below); the window mean is given alongside because the gap between them is the
finding.

| window | CPU (mW) | GPU (mW) | combined (mW) | (window means: CPU / GPU / combined) |
|---|---|---|---|---|
| 1 | 246 | 47 | 299 | 517 / 49 / 566 |
| 2 | 207 | 51 | 257 | 475 / 53 / 528 |
| 3 | 496 | 59 | 596 | 795 / 106 / 901 |
| 4 | 474 | 58 | 603 | 630 / 85 / 716 |
| 5 | 195 | 46 | 241 | 423 / 57 / 480 |
| **median** | **246** | **51** | **299** | |
| **spread (max − min)** | **301** | **13** | **362** | |
| **usable (spread ≤ 10 mW)** | **no** — 30× over | **no** — by 3 mW | **no** — 36× over | |

| confound | value |
|---|---|
| Date / time | 2026-08-25 20:53:11 CDT |
| Power source | AC Power |
| macOS version | 26.6.1 (build 25G76), Mac16,7 |
| Displays + refresh | Built-in Retina 1728×1117 @ 120 Hz (main); DELL P2219H 1920×1080 @ 60 Hz; DELL P2414H 1920×1080 @ 60 Hz |
| On-screen census | Terminal 1920×68 and 1920×1044 at x=1728 (DELL); Claude 1728×32 and 1728×1084 at x=0 (built-in) |
| Settle / window | 20 samples discarded; 5 windows × 60 samples |
| Raw log path | `docs/measurements/power-baseline-20260825-205311.log` (local only — gitignored, 2.2 MB) |
| Verdict per channel | CPU fail, GPU fail, combined fail |

**Instrument defect found by this run and fixed before the verdict was written.** The script
aggregated each window with a **mean**, which §13.7.1 forbids in as many words: "report the
median and the spread, never a mean." It matters here more than anywhere it has mattered so
far. Idle CPU power on this machine is burst-distributed — between 11 and 20 of every 60
samples land above twice their window's median, with single samples over 5000 mW — so the
window mean read 517 mW where the median read 246. The mean was measuring the bursts, and
the first printed reading (CPU spread 372 mW, GPU 58 mW, combined 421 mW) was that artifact.
The numbers above are the same log re-parsed with the median. The committed fixture now
carries a burst sample per window, so a regression back to the mean fails `--selftest`.

**CPU and combined are closed, and no further run changes that.** 301 mW and 362 mW of
spread against a 10 mW threshold is thirty-fold. The smallest effect this milestone must
resolve is 30 mW; these channels move ten times that between one idle minute and the next.
No amount of machine quiet closes a gap of that size, and the correct output for both is
§13.7.1's: **not separable.**

**GPU failed on protocol, not on physics, and gets exactly one more run.** It missed by
3 mW, and run 1 violated the procedure written directly above it: a Claude Code session was
live on the main display throughout, and its session-close hook ran a commit inside the
measurement window. That episode is visible in the data rather than merely alleged — windows
3 and 4 are jointly elevated in *both* channels (CPU 496 and 474 against 246, 207, 195; GPU
59 and 58 against 47, 51, 46), and the three uncontaminated windows give a GPU spread of
**5 mW**. A reading taken outside its own stated conditions is not evidence that the
instrument failed; it is evidence that the procedure was not followed.

**Run 2's rule, fixed here before run 2 exists.** One run, machine genuinely quiet: no Claude
Code session, no editor, no build, no indexing, and the terminal issuing the command
minimized or on a non-main display. GPU spread across all five windows **≤ 10 mW** and the
channel is usable, and M01.5 proceeds to phase 2 on the GPU channel alone. Above 10 mW and
M01.5 closes on the finding that GlowTop's compositor cost is not measurable to gate
precision on this hardware, with PERF-03 and the roadmap's M01 acceptance criteria amended
to match rather than left open. There is no run 3. The threshold does not move, and a
quiet-subset of run 2 is not a result — all five windows count, which is the rule run 1's
own quiet-subset is deliberately not being credited under.

**What run 2 does not decide.** A GPU channel that passes is a channel quiet enough to read,
which is not the same as a channel that responds to compositing. §13.1.5 measured the
compositor's cost in CPU time, and nothing has yet shown it appears in GPU power at all.
Phase 2's visible-against-minimized pair is what establishes that, and if the pair moves GPU
power by less than the instrument's own spread, the milestone closes on the same finding by
a different route.



**Run 2 — 2026-08-25 21:14 CDT.** Claude Code quit, Terminal at 580×385 on a DELL. Obsidian
and Notes were open and are named here because they turned out to be the finding.

| window | CPU (mW) | GPU (mW) | combined (mW) | (window means: CPU / GPU / combined) |
|---|---|---|---|---|
| 1 | 198 | 15 | 212 | 266 / 114 / 380 |
| 2 | 779 | 53 | 879 | 1035 / 83 / 1121 |
| 3 | 571 | 30 | 607 | 560 / 50 / 609 |
| 4 | 45 | 0 | 45 | 200 / 0 / 200 |
| 5 | 31 | 0 | 31 | 57 / 1 / 58 |
| **median** | **198** | **15** | **212** | |
| **spread (max − min)** | **748** | **53** | **848** | |
| **usable (spread ≤ 10 mW)** | **no** — 75× over | **no** — 5× over | **no** — 85× over | |

| confound | value |
|---|---|
| Date / time | 2026-08-25 21:14:31 CDT |
| Power source | AC Power |
| macOS version | 26.6.1 (build 25G76), Mac16,7 |
| Displays + refresh | Built-in Retina 1728×1117 @ 120 Hz (main); DELL P2219H 1920×1080 @ 60 Hz; DELL P2414H 1920×1080 @ 60 Hz |
| On-screen census | Terminal 580×385 (DELL); Notes 961×1050 and 53×48 (left-hand display); Obsidian 1024×800 on the built-in |
| Settle / window | 20 samples discarded; 5 windows × 60 samples |
| Raw log path | `docs/measurements/power-baseline-20260825-211431.log` (local only — gitignored, 2.2 MB) |
| Verdict per channel | CPU fail, GPU fail, combined fail |

**The rule fires. M01.5 closes on the finding.** GPU's spread went the wrong way — 13 mW in
run 1, 53 mW in run 2 — with the machine quieter by the one variable run 1 was faulted for.
Every channel has now failed the 10 mW threshold twice. Per the rule written into this
section before run 2 existed, there is no run 3, and the recorded finding is:

> **GlowTop's compositor cost is not measurable to gate precision on this hardware.**
> Package power cannot resolve an effect of 30–120 mW in any of its three channels, because
> the machine's own idle baseline moves between five and eighty-five times that much from
> one minute to the next.

**Why it fails is not sensor noise, and the distinction is worth recording.** The GPU channel
reads **exactly 0 mW** when the machine is genuinely at rest: 57 of 60 samples in window 4
and 53 of 60 in window 5 are zero, and the per-window medians run 19, 55, 30, 0, 0 as the
machine settles across the five minutes. The instrument is not noisy — it is faithfully
reporting that other applications use the GPU in bursts. Obsidian and Notes were on screen,
and that is enough. A baseline that depends on which unrelated applications happen to be
open cannot be held constant on a machine anyone actually works on, which is the same reason
§13.7.1 demoted the ambient-load covariate from a control to a diagnostic column.

**This observation does not reopen the question, and should not be read as leaving a door
ajar.** It says the *baseline-spread* method is defeated by ambient application load, and it
is at least arguable that a tightly interleaved paired test would fare better — §13.1.5's
paired minimize test reached a 0.49-point control spread by pairing where the same
instrument's unpaired spread was 15–34 points. That argument was available before either run
and was not the test that was declared. Adopting it now, after two failures, would be
choosing the method by its result. If it is ever run it is a new question under a new rule,
opened deliberately by Connor and not inherited from this section.

**What is nonetheless known about the compositor cost.** It is not unmeasured, only
un-gateable at a few percent. §13.1.5 resolved it cleanly in CPU time: WindowServer at
+41.19 points with the window visible against +1.09 minimized, a 40-point effect against
that paired test's 0.49-point control spread. Its magnitude is established and its
attribution to GlowTop is established. What no instrument in this project can do is
adjudicate a 3-point budget against it, and two hypotheses for its structure — cost per
animated layer, cost fixed per animating window — remain unseparated, because bar count was
to have been tested through the instrument that just failed.

Status: **closed.** M01.5 ends here on the finding above. PERF-03 and M01's acceptance
criteria are amended to match rather than left open; the one item still requiring a ruling is
gate 9's scope, recorded in §13.1.10.

#### 13.1.10 Gate 9's scope — ruled 2026-08-25: app-process only

M01.5 was to have ended by splitting §13.1's budget in two, with the compositor half's number
set from a real reading (§13.1.8). §13.1.9 establishes there is no such reading and there
will not be one. That leaves one contradiction that the close does not itself resolve, so it
is named here rather than left to be discovered.

**Gate 9 does not say what it measures.** It reads "≤ 3.0 % CPU and ≤ 120 MB RSS after 30 s
idle" and names no scope. §13.1.1 was widened to a whole-system measurement during phase-01,
which makes gate 9 whole-system by inheritance — and whole-system with the window visible is
about 41 points, dominated by WindowServer (§13.1.5, §13.1.6). Read that way the gate cannot
be met by any amount of work on GlowTop, since §13.1.6's three removals took the app's own
floor to 1.07 % and moved WindowServer not at all. Meanwhile PERF-01 already reads
"the GlowTop *process*", so the requirement and the gate now disagree about scope.

This was a ruling, not a reconciliation. **Connor ruled on 2026-08-25: option 1.** Gate 9
is now app-process only and is written that way in §13.7; PERF-01 and M01's acceptance
criteria match it. The three options are kept below as the record of what was chosen
over what, because a ruling with its alternatives deleted reads as the only thing
anyone thought of.

1. **Gate 9 becomes app-process only** — ≤ 3.0 % CPU for the GlowTop process by
   `scripts/overhead-harness.sh`, which resolves app-level readings comfortably (2.22 %
   visible, 1.07 % floor, small spreads). Compositor cost is then **documented and not
   gated**: §13.1.5's +41.19 against +1.09 is recorded as its measured magnitude, with
   §13.1.9's finding recorded as the reason no threshold sits on it. *Recommended* — it
   gates what the project can measure and what a user attributes to GlowTop, and it stops
   claiming a number nobody can check.
2. **Gate 9 stays whole-system** and GlowTop ships permanently failing it with cause, the way
   phase-01's tag was taken. Honest, but a gate that can never pass is the trap §13.1.8
   named.
3. **Gate 9 stays whole-system with a raised ceiling** set from §13.1.5's measured 41 points
   plus headroom. This is the relaxation §13.1.2 refused, and it would be adopting a number
   from a single unpaired reading, so it is listed for completeness rather than proposed.

**Consequence of the ruling.** Gate 9 is evaluable again from phase-02 onward, against the
process and not the machine. The compositor question is not reopened by it: §13.1.9 closed
that, and this ruling is what stops a closed question from silently blocking every future
phase through a gate nobody could pass.

#### 13.1.11 Phase-05 tuning: the floor, the per-lever deltas, and the cap-amendment ruling

§13.1.10 ruled gate 9 app-process only; this subsection is what phase-05 measured against
that scope, entered here so the amendment it produced has a heading gate 13 can resolve
against before it is cited anywhere else.

**The clean re-baseline.** Every gate-9 arm taken before phase-05 was measured with a live
agent session polling alongside it (§13.7.1's own confound). Phase-05 re-baselined on the
phase-04 tree with no source change, as quiet as this project's own tooling allows: `app`
median **26.10 %**, spread 6.21 (five interleaved rounds, `SETTLE=20 WINDOW=60`,
`scripts/overhead-harness.sh 5 baseline 1440x900`); RSS median 196.90 MB, spread 0.50 — both
over the cap in force at the time (3.0 %) and over PERF-02's 120 MB cap, by a margin far
outside either spread.

**Lever 1 — dirty-rect chart redraws.** Per-chart plot-rect invalidation replacing the two
whole-layer `setNeedsDisplay()` calls, measured against the re-baseline: 22.73 %, spread
1.80 — a −3.37-point delta. The keep/revert rule, fixed before the reading (keep if the delta
exceeds the larger of the two arms' spreads), says revert: 3.37 does not clear 6.21. A second,
independent signal corroborated the revert — the diagnostic `machine` column read roughly
double its re-baseline value for reasons this session could not identify, meaning the two
runs were not taken under comparable ambient conditions even before the spread rule applied.
The lever was implemented, measured, and reverted; both commits are in the phase-05 history.

**Lever 2 — none implemented.** A Time Profiler pass (`xctrace`, release build, Summary pane
visible, 1440×900, 60 s) found the top ten main-thread frames are CoreGraphics's own
antialiased rasterization internals (`aa_render` 47.75 %, `aa_distribute_edges` 6.49 %, and
seven more `aa_*`/`rgba64_*` symbols) — none of this project's own Swift code appears above
0.01 % combined, including every candidate named in the phase-05 plan
(`Theme.cgColor(hex:alpha:)`, `ChartSeries.points`, `CATextLayer` string updates,
`ProcessesPaneController`'s row-animation diffing). The cost is proportional to the path
geometry §4.4 already specifies (round joins and caps, no anti-aliasing tricks beyond
CoreGraphics defaults), not an inefficiency in this project's code that tuning can remove.
No lever was implemented, and no third or fourth lever was pulled to chase one — the
pre-declared rule stops at the named levers.

**The floor.** With every kept lever in (none) and every reverted one out, a second full
gated run on the unchanged tree: **29.70 %**, spread 5.15; RSS 196.30 MB, spread 6.20. This
is *higher* than the re-baseline (26.10 %), not lower: two back-to-back readings of one
unchanged binary landed 3.60 points apart, each with its own 5–6-point spread — close to the
entirety of lever 1's measured effect, and the reason that lever could not be kept. Verdict
against the cap in force at the time (3.0 %): `|29.70 − 3.0| = 26.70`, against a 5.15 spread
— overwhelmingly separable. **Gate 9 FAILed against that cap**, and every one of phase-05's
three independent readings that day (26.10, 22.73, 29.70) sat 7–10× it. Gate 8 (frame rate),
read from the same runs and not separately tuned, stayed in the 85–95 %-served band this
project has recorded every phase since 03.1.

**No further tuning was attempted, because the pre-declared rule says so** — one lever was
measured and reverted, the profiler named no second lever that does not touch spec'd drawing
behavior, and `phase-05-CONTEXT.md`'s rule stops at the named levers rather than at whatever
number a third or fourth attempt might eventually clear.

**Ruling: Connor approved option 1, 2026-08-28. The cap is raised, 3.0 % → 35 % of one
core.** §13.1's 3.0 % cap predates any measurement (§13.1.2's own account) and had by this
point been tested three independent times, by two levers' worth of investigation, cleared by
none of them. §13.1.6 measured this architecture's floor at 1.07 % of one core with the
display link **deleted entirely** — no animation, no per-frame redraw — which is the floor
for a static tool, not for the 60 Hz, eight-chart, live-animated dashboard this milestone
specifies and draws with CoreGraphics' default antialiased stroking. Two options were put:

1. **Raise the cap** to a number this architecture can hold at 60 Hz on a 120 Hz panel —
   **chosen**.
2. **Keep 3.0 %** and record M01 as shipping with gate 9 failed-with-cause, the way
   phase-01's tag was taken under §13.1.8's precedent.

**The new number and its derivation, recorded verbatim because the number's defensibility is
the derivation and nothing else:** the cap is the highest median observed across the phase's
three independent readings (29.70 %, this subsection's floor) plus one full spread (5.15) —
34.85, rounded to **35 %**. The three readings were 26.10 % (spread 6.21, the clean
re-baseline above), 22.73 % (spread 1.80, lever 1 before its revert) and 29.70 % (spread
5.15, the floor). The margin is one spread because this environment's run-to-run drift was
measured at 3.60 points between two readings of one unchanged binary, and the spreads
themselves run 1.8–6.2 points; a cap set closer than one spread to the floor could not be
distinguished from the floor under §13.7.1's own separability rule. **The cap was fixed
before phase-05's final gate-9 reading (§13.7's gate 9) was taken**, and wave 3's draw-path
change (the resolved colour table, §7.3) was unmeasured against it at the time the number
was set — a pre-declaration, not a result chosen to fit one.

**Why option 1 over option 2:** GlowTop is a single-user tool running on its owner's own
machine (§7.5's "personal tool" framing applies here too), not a background daemon competing
for review against other processes' budgets — holding a milestone open against a number
nothing had ever hit is a worse outcome than setting the number to what a live, animated,
antialiased dashboard genuinely costs. The question re-opens if a future rendering approach
(e.g. Metal-backed charts, which §13.1's text does not currently contemplate) changes the
floor.

**§13.1.2 and §13.1.10 stand as written** — the earlier refusal to relax the cap (§13.1.2)
and the ruling that scope changes to gate 9 are Connor's to rule on (§13.1.10) are exactly
why this amendment is recorded as a ruling with its derivation shown rather than as a number
picked to make a reading pass: the cap moved because three independent readings and a
profiler pass cleared none of the old one, not because a session raised its own gate.
**PERF-02's 120 MB RSS cap is untouched by this ruling** — it was not part of the approved
proposal, and no RSS lever was ever named or tried this phase. The re-baseline and floor RSS
readings above (196.90 MB, 196.30 MB) both read against that unchanged 120 MB line, and
whether 120 MB is reachable on this architecture remains unmeasured, not disproven — no
allocation profile was taken this phase.

#### 13.1.12 Phase-08's RSS profile: the instrument, the floor, the architecture's lower bound, and two proposals

§13.1.11 recorded that PERF-02's 120 MB cap was left untouched because no RSS lever had ever
been tried and no allocation profile existed — *"whether 120 MB is reachable on this
architecture remains unmeasured, not disproven."* Phase-08 measured it. This subsection records
what the profile found, what the one kept lever bought, and the two questions it hands to a
ruling. **Both are proposals. Neither is applied here, and the budget table's 120 MB limit
stands until Connor rules.**

**The instrument, before any lever.** Five predictions with kill conditions were committed
before the first reading existed. `footprint`, `vmmap --summary` and a `heap` census were read
at four corners of a 2×2 — Summary-only and a seven-pane walk, at 1440×900 and 1100×732 — on
`.build/release/GlowTopApp`, which is the subject `scripts/overhead-harness.sh` launches and
therefore the only subject a lever can be scored against without editing the gate instrument.
The two headline numbers this phase inherited (206.50 MB and 124.2 MB) were **not comparable**:
they differ in `UserDefaults` domain, in theme, and in restored window frame. A `RSS = F + k·A`
fit on them yields a **negative fixed footprint**, so the 2×2 replaced that fit rather than
refining it.

**Where the bytes are.** `footprint` Dirty, median of three rounds, MB:

| Category | Summary @1440×900 | Summary @1100×732 | Walk @1440×900 | Walk @1100×732 |
|---|---|---|---|---|
| **CoreAnimation** | 99.00 | 74.00 | 120.00 | 95.00 |
| **MALLOC_SMALL** | 28.00 | 26.00 | 84.00 | 76.00 |
| **TOTAL** | **137.00** | **112.00** | **227.00** | **195.00** |

`CoreAnimation` is **72 % of the gated arm's entire footprint**. Its movement decomposes cleanly
and reproducibly: **+25.00 MB** with window area and **+21.00 MB** with pane count, both deltas
identical across two independent pairs. Everything below `MALLOC_SMALL` is under 2.5 MB —
smaller than the arm's own spread, and so unable to be separated from noise at 100 % success.
The eight `RingBuffer` histories are **under 1 MB in total**; the live-object census puts the
**largest single allocation of any class at 352 KB**, and the whole live heap at 20.4 MB.

**The one lever, and the one empty slot.** `PaneHostView.show(_:)` retained every pane
controller for the app's lifetime (§3.3). Releasing the outgoing controller instead measured
**−49.60 MB** on the seven-pane arm against a spread of 1.50, with no regression in app CPU,
frame rate, or the gated arm — **kept**. A second slot was left **empty**: `CoreAnimation` tops
the ranking and is still not a lever, because **3.34 of its full-window buffers are Core
Animation's own buffering of the window surface** and the remaining **33.0 MB** is the per-layer
surface set for the layout §4.4 specifies. The stopping rule, written before any number existed,
forbade a third attempt.

**What retention actually cost, and what §3.3 claims it buys.** `removeFromSuperview()` already
frees a switched-away pane's backing stores, so retention never held pixels; it held **view
hierarchies and Auto Layout constraint graphs** — a live-object census after visiting all seven
panes reads 558,375 nodes / 69.5 MB against 108,111 / 20.4 MB for Summary alone. §3.3 justifies
retention on two grounds, that switching back is instant **and** that it does not re-warm a
provider's delta baseline. **The second is not served by that dictionary**: delta baselines live
inside `MetricStore`, an actor owned by the app, and no pane controller holds one. Releasing a
controller cannot re-warm a baseline it never had. Only switch-back latency was ever traded.
§3.3's wording is left unamended here pending the ruling below, and is flagged as overstating
what retention buys.

**Three instruments, three quantities.** `ps -o rss=` read **216.20 MB** where `footprint`'s
`phys_footprint` read **137.00 MB** and `vmmap`'s TOTAL DIRTY read **138.9 MB** on the same
process at the same instant. The last two corroborate each other to within 2 MB; `ps` stands
apart by **65–79 MB**, which is clean, file-backed, shared pages that `phys_footprint` excludes
and that this app cannot unmap. **PERF-02 is written against `ps -o rss=`.** Levers are therefore
diagnosed on `footprint`'s categories and scored on `ps`, and the two differ by roughly 79 MB on
the gated arm.

**The floor.** With the kept lever in: **202.40 MB** (spread 0.70, n=5) Summary-only at
1440×900; **177.80 MB** (0.50) at 1100×732; **295.60 MB** (2.50, n=3) after all seven panes at
1440×900; **256.30 MB** (5.00) at 1100×732. Three independent five-round runs of the gated arm
across the phase read 201.80, 202.50 and 202.40. **`|202.40 − 120| = 82.40` against a spread of
0.70 — 118 times the spread. PERF-02 FAILS, separably.**

**The architecture's lower bound, measured for the first time.** An empty SwiftUI app with a
single 1440×900 window costs **80.90 MB** of `ps -o rss=` (spread 0.30, n=5); a bare AppKit
`NSWindow` of the same size costs **72.30 MB** (spread 4.50). SwiftUI's increment is **8.60 MB**,
separable. **An empty window is therefore 80.90 MB of the 120 MB cap, leaving 39.10 MB for every
provider, all history, every layer, seven panes and the whole TMOG Summary layout.** GlowTop's
content above that shell measures **121.50 MB**; reaching the cap means shrinking it by 82.40 MB,
to **32 % of its measured size**, while `CoreAnimation` for one visible pane is 68–99 MB.
§13.1.6's 1.07 % is **not** quoted as a floor here: it is a CPU figure and has no bearing on
residency.

**Ruling 1 — the cap. Approved by Connor 2026-09-01: option 1.**

**PERF-02's cap is raised 120 MB → 210 MB**, for the Summary-only state at 1440×900 (see ruling 2).
Derived exactly as §13.1.11 derived gate 9's 35 %: **the highest median across this phase's
independent readings (202.50) plus one full spread (4.40) = 206.90, rounded to 210.** The three
independent five-round runs behind that derivation are 201.80 (spread 4.40), 202.50 (1.70) and
202.40 (0.70), all in this subsection above.

**Unlike §13.1.11's, this cap was derived from readings already taken**, because the phase's whole
purpose was to take them; the derivation is stated so it can be checked against the numbers rather
than trusted. `ps -o rss=` is retained as the instrument, which PERF-02 and the budget table name,
so every RSS reading already in this record stays comparable.

The options are kept below as the record of what was chosen over what — §13.1.10's own convention,
because a ruling with its alternatives deleted reads as the only thing anyone thought of.

- **Option 1 — raise to 210 MB. ✅ TAKEN.**
- **Option 2 — keep 120 MB and ship PERF-02 failed-with-cause** (§13.1.8's precedent). Not taken.
  It would have left a gate no window size can pass: the smallest arm reads 177.80 MB and an empty
  SwiftUI window is 80.90 MB.
- **Option 3 — change the instrument to `phys_footprint`.** Not taken. It remains the only option
  that would make the cap describe what this project controls — the `ps`/`phys_footprint` gap is
  **65–79 MB** of unmappable shared pages — and it was declined because changing an instrument
  retroactively rewrites the meaning of every reading already in the record, including §13.1.11's
  and every gate-10 soak.

**The verdict under the ruled cap: floor 202.40 MB (spread 0.70) against 210 MB — margin 7.60,
which is 10.9× the spread. Separably under. PERF-02 is SATISFIED**, for the first time in this
project's history, and satisfied against a cap derived from measurement rather than assumed.

**Ruling 2 — the scope. Approved by Connor 2026-09-01: option A.**

**PERF-02 is evaluated Summary-only, at 1440×900, on `scripts/overhead-harness.sh`'s `rss`
column** — one subject, one geometry and one instrument shared with gate 9. **The seven-pane
steady state is recorded beside it as documented, not gated**, which is the treatment §13.1's
budget table already gives the whole-system idle-CPU row after M01.5 (§13.1.9).

This closes the defect §13.1.10 identified one requirement over: the requirement named no window
size and no pane state, and inherited whichever the reader assumed.

- **Option A — Summary-only at 1440×900, gated; seven-pane documented-not-gated. ✅ TAKEN.**
  Governs **202.40 MB**; documents **295.60 MB**.
- **Option B — Summary-only at the packaged default 1100×732.** Not taken. Governs 177.80 MB, and
  is the weakest of the three against the charge that the geometry was chosen to flatter the number.
- **Option C — the seven-pane steady state as the gated figure.** Not taken. Governs 295.60 MB. It
  is the most honest description of the app in use, and it is preserved as the documented row
  precisely so it does not disappear from the record the way the audit's 258.1 MB did between
  phase-05 and the M01 audit.

**The multi-pane figure is documented and not gated, which is a statement about what is measured,
not a claim that 295.60 MB is acceptable.** It is 85.60 MB above the gated cap, it is what a user
reaches by clicking through the sidebar, and the lever that would reduce it further is a redesign
of §4.4's layout rather than a tuning pass.

#### 13.1.13 Phase-09's renderer spike: two chart paths in one binary, the reading, and the instrument's own limit

Gate 8 left M01 unmet at 94.2 % (§13.7.8, §14.8), and §13.1.11 had already named the cost:
CoreGraphics's own antialiased rasterization of §4.4's geometry, with this project's code
under 0.01 % of the profile. There was no lever inside the app's code because the cost was
not the app's code. So phase-09 changed the renderer — and, before changing anything the
user sees, measured the change.

**The protocol, committed before the first reading.** The composited path was built behind
`GLOWTOP_CHART_CA` as an *addition*: the CoreGraphics path stayed the default and stayed
byte-identical, so both arms ran from one `.build/release/GlowTopApp` and the pair was a
pair. The process printed which path it installed (`charts: ca` / `charts: coregraphics`),
so a flag that silently failed to apply would have been caught as two identical arms rather
than published as a difference. Three 60 s rounds per arm at 20 s settle, on the 120 Hz
panel at 1440×900, alternating CG/CA at the invocation level, through
`scripts/overhead-harness.sh` unedited — the `fps` column being the harness's per-round
median of the app's own §6.7 counter. A five-condition **void rule** (an empty `fps=`; fewer
than 55 settled samples; any `visible no`; a `display` other than 120; the `charts:` marker
disagreeing with the arm) was applied to every round before any statistic was computed,
with the rule that more than two void rounds of one arm in a campaign stops the campaign.
A **decision rule** routed every outcome in advance: CA wins separably if it serves ≥ 95 %
with a margin above 114.0 fps larger than its own three-round spread; a tuning wave of four
named levers if it lands in 90–95 %; Metal only on a measured failure. And a
**resolvability threshold**: if the CoreGraphics control's own spread exceeded 6.00 fps —
the whole width of the 90–95 % band — the instrument could not resolve the band, and every
verdict would carry the spread beside it.

**The first campaign stopped under the void rule.** Four of six rounds published an empty
`fps=` with the app at ~2.5 % of a core: the operator was using the machine, and the app's
self-activated window ended up behind the foreground application, which invalidates the
display link (§6.2). Three void rounds on one arm exceeded the limit; the campaign was
recorded and not re-rolled. The second campaign ran only once the machine had been idle for
three minutes and stayed idle throughout.

**The reading** (2026-09-02 14:06–14:14, load average 3.68 → 2.42, AC power, macOS 26.6.1,
every settled line `display 120`):

| Arm | `fps` median (spread, n=3) | served | settled samples < 114.0 | `app` % (spread) | `ws` % (spread) | `rss` MB (spread) |
|---|---|---|---|---|---|---|
| CoreGraphics | **104.20** (8.40) | 86.83 % | 61 / 57 / 57 of 61 | 25.37 (7.32) | 49.82 (1.78) | 202.60 (2.00) |
| Composited | **120.00** (0.00) | **100.00 %** | **0 / 0 / 0**, minima 118.0 / 119.0 / 118.0 | **9.97** (0.21) | 48.95 (1.23) | **109.80** (0.40) |

The composited arm's margin above the 114.0 fps floor is 6.00 fps against its own spread of
0.00 — the first row of the decision rule, **separably**. The arm-to-arm difference of 15.80
fps exceeds the control's spread; so do `app` (−15.40 points against spreads 7.32 / 0.21)
and `rss` (−92.8 MB against 2.00 / 0.40, the legacy layer's pane-sized 2× backing store and
its buffer gone). `ws` moved −0.87 inside spreads of 1.78 / 1.23 — not separable, in either
direction. The levers wave and the Metal wave were not run, under the rule.

**The instrument's own limit, recorded as the finding it is.** The CoreGraphics control's
three-round spread was **8.40 fps** in a campaign as steady as this machine offers. That is
above the 6.00 fps threshold fixed in advance: on the CPU-bound path, three 60 s rounds
cannot resolve a question narrower than the 90–95 % band, and gate 8's original 0.96 fps
question (114.0 against phase-08's 113.04) was never answerable that way. The composited
path did not need the question answered — every one of its 219 settled samples sat above
the floor — so no threshold amendment is proposed. **Proposed and not applied:** a longer
window and more rounds for any future reading of a CPU-bound path, an instrument change to
be made in a phase that does not read the instrument.

**Pixel parity, and a second instrument finding.** D-03 required the composited charts to be
indistinguishable from the CoreGraphics ones, proven per plot rect on gate 12's fixed §5.10
fixture at a tolerance stated before the first comparison (≥ 99.0 % of pixels within 8
levels, none over 64, accent hit counts within ±5 %). The first comparison failed it on four
rects — 98.0–98.8 %, one pixel at 73 — with the crops indistinguishable by eye and the
difference a periodic phase pattern along every stroke edge. Twelve synthetic constructions
rendered both ways matched byte-for-byte; the renderer was not the difference. **Gate 12's
capture was:** windowless, the pane gives its layers a 2× `contentsScale`, so the legacy
layer drew a 2× backing store that `render(in:)` downsampled into the 1× context while the
shape layers rasterized directly into it. With both paths pinned to the context's scale for
the offscreen check, every rect reads `match8=100.00% maxdelta ≤ 3 differing=0` and the
accent counts are identical (263 / 2796 / 145 / 144 / 0 / 0 / 0 / 0). The live 1440×900
capture pair agreed on every static region (row gaps, axis labels, bottom edge: exact) and
differed where live content lives; the plan's 99.5 %-outside-the-plots chrome threshold
cannot be met by any renderer on live content and is recorded as mis-specified, not
loosened.

**RENDER-06 — where the cost went.** §13.1.5 measured the CoreGraphics pane's WindowServer
cost at +41.19 points visible and +1.09 minimized. Re-run on the shipped build, same harness,
three interleaved rounds per arm: baseline `ws` 50.22 (spread 9.54), visible **47.12**
(0.05), minimized **50.07** (3.79) — **ΔWS −3.10 visible, −0.15 minimized**, both inside the
baseline's spread, and beside them gate 9's `app` at **10.03 %** (spread 0.99). The app
process got cheaper and the compositor did not get dearer by any amount this machine can
resolve; against §13.1.5's +41.19 the visible delta shrank separably (44.29 points against a
9.54 spread), with the caveat that the two baselines are different days under different
ambient load. Record-only, per §13.1.9.

**What did not change.** `Sources/GlowTopCore/` — `ChartSeries.swift`'s renderer-agnostic
contract included — was not touched, proved by `git diff --stat main..HEAD --
Sources/GlowTopCore/` printing nothing across the phase. `scripts/overhead-harness.sh` was
read in every wave and edited in none. The 95 % threshold stands.

### 13.2 Where the budget goes

At 60 Hz with the Summary pane visible, the sampling cost is: CPU + memory at 10 Hz (2 syscalls × 10/s), disk + network at 4 Hz, GPU + frequency at 2 Hz, processes + energy + thermals at 1 Hz. Total, roughly 40 syscalls per second plus one ~840-process enumeration per second (measured, §5.5.4).

That enumeration is the single largest cost in the app, which is why it is 1 Hz, why it runs off the main thread, and why §5.5.4 pre-specifies its mitigation.

**Measured in phase-02**, per sample and scaled by each provider's rate:

| Provider | Rate | Per sample | Share of one core |
|---|---|---|---|
| CPU | 10 Hz | 0.014 ms | 0.014 % |
| Memory | 10 Hz | 0.001 ms | 0.001 % |
| Disk | 4 Hz | 0.053 ms | 0.021 % |
| Network | 4 Hz | 0.014 ms | 0.006 % |
| Process table | 1 Hz | 0.837 ms | 0.084 % |
| **Total** | | | **0.13 %** |

Sampling is therefore **not** where the idle budget goes: all five providers together cost
about a twentieth of the 3 % gate. The process table is still the largest single line, and it
is the one §5.5.4's name cache addresses — before that cache the same enumeration measured
11–19 ms cold, against 0.837 ms warm, because two of its three per-PID calls exist only to
resolve a name that cannot change while the PID lives.

The figures above are per-sample costs measured in a tight loop, so they exclude the timer
wakeups and actor hops around them. They are the right numbers for deciding which provider to
optimise and the wrong ones for predicting the app's total, which gate 9 measures end to end.

### 13.3 Overhead visibility

GlowTop displays its own CPU and RSS in the System Info pane (§9.2) and, when the FPS counter is on, its frame rate on screen. Its own row in the Processes pane is not specially highlighted or hidden — it appears like any other process, which is the honest presentation and also the quickest sanity check.

### 13.4 Known overhead traps

Recorded here because each one was identified in advance and has a specific countermeasure, so that hitting one is a known state rather than a mystery:

| Trap | Symptom | Countermeasure |
|---|---|---|
| Per-segment shadow blur | 8–15 % CPU instead of 3 % | Pre-rendered glow images (§6.5) |
| Redrawing on sample instead of display link | FPS reads ~10 | Display link sets `needsDisplay`; sampler never does |
| Interpolating by frame count | Motion stutters when a frame drops | Wall-clock interpolation (§6.6) |
| Unbounded history arrays | RSS climbs steadily | Fixed-capacity `RingBuffer` (§6.4) |
| IOKit objects not released | RSS climbs, then IOKit failures | `IOObjectRelease` on every path (§5.3.2) |
| `vm_deallocate` with the wrong size | Crash on the second CPU sample | `infoCount × stride`, never `count × stride` (§5.1.1) |
| Attributed-string drawing per frame | 3–5 ms/frame in text alone | Cache label images, invalidate on string change (§6.9) |
| Sampling while occluded | Full cost behind a full-screen window | Pause on occlusion (§6.2) |
| `await`ing the store in the draw path | 60 Hz becomes ~40 Hz | Main-actor projection updated per sample (§6.3) |

### 13.5 Test plan — unit

In `GlowTopCoreTests`, no window, no display link, no run loop:

1. **Tick math.** Synthetic `host_processor_info` arrays with known deltas produce known utilizations. Include: all-idle (0.0), all-busy (1.0), a 30/70 user/idle split, and a wrapped counter (current < previous → `.warming`).
2. **Core count.** `perCore.count == sysctl hw.logicalcpu`.
3. **Short interval.** Two samples 10 ms apart return the previous value, not a divide-by-near-zero result.
4. **Long gap.** Two samples 6 s apart return `.warming`.
5. **Ring buffer.** Capacity is never exceeded; after `capacity + 10` writes the oldest 10 are gone and the order is correct.
6. **Interpolation.** `t = 0` yields the previous value, `t = 1` the current, `t = 0.5` the midpoint, `t = 2` clamps to the current.
7. **Byte formatting.** Every row of §4.9's table is a test case.
8. **Theme decoding.** A theme JSON missing a token decodes with that token defaulting; a malformed hex value falls back without throwing.
9. **Unavailable propagation.** A provider stub returning `.unavailable` results in a UI-facing state of `unavailable`, never `0.0`.

Minimum for the phase-01 gate: **3 tests in `CPUProviderTests`** (items 1, 2, 3).

Minimum for the phase-02 gate: **items 3 and 4 for every delta provider** (disk, network, and
per-process CPU — memory is an absolute gauge and has no baseline to divide by, so neither
applies to it), **item 7 in full** — every row of §4.9's table is its own case — and **item 9**
for the provider most likely to be legitimately absent, which is disk (§5.3.3). Phase-02
shipped 68 tests against that floor: 12 process, 11 network, 10 disk, 17 formatting, 12 store,
6 memory composition.

Minimum for the phase-03 gate: **items 6 and 9 in full**, plus at least one test per public
entry point in `Theme`, `ChartSeries` and `SummaryModel`, against a floor of phase-02's 93
total plus the new suites. Phase-03 shipped **148 tests** against that floor.

Minimum for the phase-03.1 gate: **item 9 in full for all four new providers**, §5.6.5's range
checks in full, every unit-conversion case §5.6.3's shim handles (`mJ`, `uJ`, `nJ`, `J`, and an
unrecognised label), §5.8.2's 0–120 °C filter, and §5.9.1's residency-weighted mean and
device-tree decode from fixture bytes — against a floor of phase-03's 148. Phase-03.1 shipped
**205 tests** (1 skipped, 0 failures) against that floor.

Minimum for the phase-04 gate: §8.3's stable-sort property, §8.4's search, the kill flow's
guardrail/errno/logging paths (`ProcessActionsTests`), §11.1's two corrected filters
(`testNobodyIsExcludedDespitePassingTheUidFloor`, `testOnlyUserProcessRecordsAreSessions`),
and §12.1's path-match-not-basename correlation — against a floor of phase-03.1's 205. Phase-04
shipped **254 tests** (1 skipped, 0 failures) against that floor.

Minimum for the phase-05 gate: item 8 in full (a stored theme missing a token decodes with
that token defaulting; a malformed hex falls back without throwing; a round trip is lossless;
an unknown preset name or future schema version yields Neon; an unknown extra key is
ignored), plus a preset suite (every preset carries every token; the alarm tokens identical
across all three presets; `accentKernel` separable from `accentCPU` in each) and a contrast
suite (known ratios, plus the measured verdicts for all three shipped presets asserted rather
than described) — against a floor of phase-04's 254. Phase-05 shipped **281 tests** (1
skipped, 0 failures) against that floor.

Item 1's wrapped-counter clause generalises beyond CPU: every cumulative-counter provider
(§5.0.4) needs it, and network's is not hypothetical — `if_data` counters are 32-bit and wrap
in about 34 s at 1 Gb/s (§5.4.3).

### 13.6 Test plan — cross-check against system tools

Every provider is checked against an independent tool. These are run by hand and their numbers pasted into the phase record; a provider without a recorded cross-check does not ship.

| Provider | Command | Tolerance |
|---|---|---|
| CPU total | `top -l 2 -n 0 \| grep 'CPU usage'` | ±10 points |
| Core count | `sysctl -n hw.logicalcpu` | exact |
| Memory total | `sysctl -n hw.memsize` | exact |
| Memory pages | `vm_stat` | ±5 % |
| Memory composition vs Activity Monitor | Activity Monitor, Memory tab | **observation only — no tolerance, not a gate** (§5.2.3) |
| Swap | `sysctl vm.swapusage` | exact |
| Network bytes | `netstat -ib` | ±1 % |
| Disk throughput | `dd` of a 1 GB file | ±20 % |
| Process count | `ps -A \| wc -l` | ±3 |
| Top process CPU | `top -l 2 -o cpu -n 5` | ±10 points |
| Uptime | `uptime` | ±2 s |
| Thermal state | `pmset -g therm` | qualitative match |
| GPU utilization | `glowtop-probe gpu --load <n>`, controlled Metal compute load | direction only — loaded median exceeds rest median by ≥ 0.5; no second instrument runs continuously enough to hold a value tolerance (§13.7.1) |
| GPU utilization, path agreement | IOReport vs `IOAccelerator`'s `Device Utilization %` in the same load window | within 10 points |
| Package power, upper bound | `IOPSCopyPowerSourcesInfo`'s amperage × voltage, on battery | package < whole-system, and the ratio recorded whatever it is — this is an order-of-magnitude check, not a value tolerance |
| Package power, constant | `sudo powermetrics -s cpu_power,gpu_power` | ±20 % — **run by Connor only** (§2.4, §13.6.1) |
| ANE power | `glowtop-probe npu --load <n>`, Vision-inference controlled load | direction only — `aneWatts` rises under load, or the run records that the load routed to the GPU instead |
| Die temperature | `glowtop-probe thermal --load <n>`, sustained CPU load | direction only — the hottest real sensor rises ≥ 5 °C under load and returns near baseline after idle |
| P-cluster frequency | `glowtop-probe frequency --load <n>`, sustained CPU load | direction only — loaded median within 10 % of the P-cluster maximum, rest median below 60 % of it |
| Max P-cluster frequency | `sysctl -n hw.cpufrequency_max` vs the device-tree table's top entry | record both; the sysctl key is expected absent or 0 on Apple Silicon — confirmed, not assumed |
| Per-cluster frequency | `glowtop-probe frequency --load <n>`, sustained CPU load, **one** invocation | direction only, per cluster — each P cluster's loaded `averageMegahertz` median within 10 % of that cluster's own `maxMegahertz`, the E cluster's loaded median below its own maximum by more than 10 %; all three loaded and rest medians and all three maxima recorded (§14.1, phase-11) |
| DRAM power | `glowtop-probe energy` while a bounded `dd if=/dev/zero of=/dev/null bs=64m count=2000` repeats for ~30 s of a 90 s window | direction only — `dramWatts`' loaded median exceeds the rest medians either side, **or the run records that it did not** (phase-11's D-26); no unprivileged instrument reads DRAM energy continuously (§13.6.1) |
| Processes pane: process count | `ps -A -o pid= \| wc -l` vs the pane's `<n> processes` | ±3 |
| Processes pane: process CPU, one row | `ps -o %cpu= -p <pid>` vs the pane's CPU cell | sanity only, no tolerance (§5.5.5) |
| Processes pane: cumulative CPU | `ps -o time= -p <pid>` vs the inspector's cumulative user + system | ±1 s |
| Processes pane: owner | `ps -o user= -p <pid>` vs the User column | exact, over 10 sampled PIDs |
| Processes pane: path | `ps -o comm= -p <pid>` vs the Path column | exact, over 10 sampled PIDs |
| Processes pane: enumeration cost | `enumerationMilliseconds`, plain vs `--detail`, 20 samples each | recorded, median and spread, against §5.5.4's 25 ms budget |
| Connections: socket count | `lsof -nP -i` row count minus its non-TCP/UDP rows | ±3 |
| Connections: LISTEN set | `lsof -nP -i \| grep LISTEN`, `(pid, local port)` tuples | exact |
| Connections: TCP state histogram | `lsof -nP -iTCP`, states counted | ±3 per state |
| Connections: five sampled rows, field by field | `lsof -nP -i` at the same instant | exact |
| Connections: enumeration cost | `enumerationMilliseconds`, cold vs. 19-sample warm median | recorded against the 25 ms / 50 ms bands (§14.5) |
| Installed Apps: bundle count | `ls -d /Applications/*.app /Applications/*/*.app ~/Applications/*.app ~/Applications/*/*.app \| wc -l` | exact |
| Installed Apps: size, five bundles | `du -sk` | ±1 % |
| Installed Apps: signing identity, five bundles | `codesign -dv --verbose=2 2>&1 \| grep '^Authority' \| head -1` (or `Signature=adhoc`) | exact |
| Installed Apps: architectures, five bundles | `lipo -info` | exact set |
| Installed Apps: version / bundle ID, five bundles | `plutil -extract … raw` | exact |
| Disk Space: volume capacity | `df -k /`, `diskutil info /` | exact |
| Disk Space: volume free | `df -k /` at the same instant | ±1 % — `statvfs` and the `URLResourceValues` keys read 12.9 MB apart within one second on this Mac |
| Disk Space: browsable volume count | **Corrected 2026-09-08, phase-13 execution (§14.9):** `ls -1 /Volumes \| wc -l` plus the root double-counts on this Mac, because `/Volumes/Macintosh HD` is a symlink to `/` — use `1 + $(for v in /Volumes/*; do [ "$(readlink -f "$v")" != "/" ] && echo x; done \| wc -l)` instead | exact |
| Disk Space: child apparent size, five directories | `du -A -k` | ±1 % |
| Disk Space: child allocated size, same five | `du -k` | ±1 % |
| Disk Space: child count at one level | `ls -A \| wc -l` | exact |
| Disk Space: sizing rate | entries per second over `/Applications`, cold and warm | recorded, median and spread, against §14.6's bands |
| Disk Space: a volume root beneath the node is not crossed | `/System`'s children against `du -k -d 0 /System/<child>` for each, with `Volumes` reading `0 B` — not `du -x`, which walks the Data volume through the firmlink (384.4 GB against the reader's 27.9 GB for `/System` on this Mac) | exact per child |
| Disk Space: reader peak RSS over `~` | `/usr/bin/time -l glowtop-probe disk-space ~`, maximum resident set size | recorded; ≤ 210 MB (§13.7's whole-process cap) |
| System Info: model, chip, cores, memory, build, kernel | `sysctl -n hw.model machdep.cpu.brand_string hw.logicalcpu hw.memsize kern.osversion`; `uname -v` | exact, per row |
| System Info: uptime | `uptime` | ±2 s |
| System Info: swap | `sysctl vm.swapusage` | exact |
| System Info: own RSS | `ps -o rss= -p $(pgrep -x GlowTopApp)` | ±5 % |
| System Info: provider health | §4.7's status-bar phrase at the same moment | exact — two renderings of one `health()` call |
| Startup Apps: job counts by type | `ls ~/Library/LaunchAgents/*.plist \| wc -l` and the two system directories | exact, per directory |
| Startup Apps: login items | `sfltool dumpbtm \| grep -c '^ *UUID:'` | exact if built; N/A with the recorded reason otherwise (§10.1) |
| Users: accounts | `dscl . -list /Users UniqueID \| awk '$2>=500'` plus root | exact |
| Users: admin membership | `dscl . -read /Groups/admin GroupMembership` | exact |
| Users: sessions | `who \| wc -l` | exact |
| Services: configured job count | the three plist directories | exact |
| Services: running PIDs | `launchctl list <label>` per row the pane reports as Running | exact PID agreement over the overlap — the total counts do **not** match and are recorded as the disclosed §12.1 gap, not a failure |
| Startup Apps: Enabled column vs the launchd override store | `plutil -p /var/db/com.apple.xpc.launchd/disabled.$(id -u).plist` against the pane's Enabled column, for every label the store names that the pane also shows | exact, per label |
| Write actions: the observed post-action state | `glowtop-probe job <verb> com.glowtop.phase14-test` — **the throwaway agent only, never a live label** — against `launchctl print gui/<uid>/com.glowtop.phase14-test; echo $?` and its `pid =` line at the same instant, over the five-step D-13 sequence | exact, per verb |
| Signed bundle: signature fields | `codesign -dv --verbose=2 ~/Applications/GlowTop.app` and `codesign -d --entitlements - ~/Applications/GlowTop.app` | exact, per field — `Authority=Developer ID Application:` present, `TeamIdentifier=` present and not `not set` (on the reference Mac, `G7FX8CR43U`), `flags=0x10000(runtime)`, and no entitlement beyond the `Executable=` line |
| Signed bundle: Gatekeeper's own verdict | `spctl --assess -vv --type execute ~/Applications/GlowTop.app` and `xcrun stapler validate ~/Applications/GlowTop.app`, against §14.11's recorded pre-signing baseline | exact — `accepted`, `source=Notarized Developer ID`, `stapler validate` exit 0, against the baseline `rejected` (exit 3) |

On the reference Mac the store's four disabled labels are all `com.apple.*` and none is on the pane (§14.9, phase-14 F-7), so the first row's live content is an agreement check on **enabled** labels; the disagreement direction is exercised by the throwaway agent's own `disable`.

`spctl` is the assessor Gatekeeper itself runs, reading the same ticket and the same signature at the same instant, which is §13.6.1's own criterion for a value check rather than a direction check.

#### 13.6.1 Why some rows are direction checks and others are value checks

Every row above phase-03 shipped, and every phase-04 pane row above, compares against an independent system tool holding roughly the same instant. None of §5.6–§5.9's providers has that: `powermetrics` needs root a session will not take, and nothing else on macOS reads GPU residency, package energy, or die temperature unprivileged and continuously. §13.7.1's ruling — a control arm whose own spread meets the effect cannot gate the effect — applies in reverse here: there is no control arm at all, so the only sound check left is a **controlled input** (§13.6's own load generators, §1.3) with an **asserted direction**, never a value pinned against nothing. This is the same reasoning phase-02's `top` comparison was demoted to a sanity check under, one layer earlier.

Phase-04's pane rows are the opposite case, and deliberately so: `ps`, `sysctl`, `launchctl`, `who` and `dscl` each read the same kernel or the same on-disk files GlowTop reads, at the same instant, unprivileged and continuously. An independent instrument that good makes a **value** check the sound one — a direction check would be throwing away information the instrument can actually give. Every phase-04 row above is a value check for exactly this reason, and a tolerance wider than "exact" on most of them would be measuring nothing, the same complaint §13.7.1 makes about a covariate that moves more than the effect.

### 13.7 Shipping gates

A phase does not advance until every applicable gate passes.

1. **Build** — `swift build` completes with zero warnings.
2. **API tagging** — every API named in §5 carries a public/private/uncertain tag and a stated fallback.
3. **Private-API blackout** — with `GLOWTOP_DISABLE_PRIVATE=1` set, the app launches, runs 30 minutes, holds frame rate, and shows correct CPU/memory/disk/network/process data with the private-sourced tiles reading `—`.
4. **Tests** — `swift test` green, with at least the minimum test count for the phase.
5. **Cross-checks** — §13.6's table, numbers recorded.
6. **No dependencies** — `Package.swift` `dependencies` array is empty.
7. **No network** — `lsof -nP -i -a -p $(pgrep -x GlowTopApp)` returns no rows after 10 minutes of running.
8. **Frame rate** — the view services **≥ 95 % of the display's own refresh rate**,
   sustained for 60 s, where that rate is read at measurement time from
   `NSScreen.maximumFramesPerSecond` and recorded with the result.

   *What it measures:* whether the view keeps up with the panel it is actually on.
   *What would make the reading meaningless:* comparing against a hardcoded 60. This
   machine has a 120 Hz built-in display and two 60 Hz externals, and a window can be on
   any of them. Every phase-01 reading of "60.0 fps" taken before this rewrite is **void**
   — on the built-in panel it recorded the CPU draw path saturating at half the available
   rate and reported it as a pass.

   **This gate governs RENDER-02** (Connor, ruled 2026-08-28). That requirement's original
   ≥ 55 fps assumed a 60 Hz panel and predates this gate's phase-01 rewrite against the
   display's actual refresh; where the two disagree, this threshold is the one that holds.
   First met in phase-09, on the composited chart path, at 120.00 fps of 120 with a
   three-round spread of 0.00 — the reading, the control arm it was paired with, and the
   instrument finding that came with it are in §13.1.13. The threshold is unchanged.
9. **Overhead** — the **GlowTop process** holds ≤ 35 % of one core (raised from 3.0 %,
   Connor's ruling 2026-08-28, derivation in §13.1.11) and **≤ 210 MB RSS, Summary visible at 1440×900**
   (Connor's ruling 2026-09-01, derivation in §13.1.12), after 30 s idle,
   measured by `scripts/overhead-harness.sh`. Scope is the process, not the machine
   (§13.1.10, ruled 2026-08-25).

   *What it measures:* the cost a user attributes to GlowTop — what its row in Activity
   Monitor or `top` shows — as a CPU-time delta over a settled window, never `ps -o %cpu`.
   *What would make the reading meaningless:* reading it whole-system. WindowServer's
   compositor cost is real, is GlowTop's, and is roughly 41 points (§13.1.5), but it is not
   gateable — §13.1.9 established that no instrument on this hardware can resolve it to a
   few percent. A whole-system reading here would fail permanently while telling nobody
   anything, which is the trap §13.1.8 named. Compositor cost is **documented, not gated**.
   *Its confounds:* which display and its refresh rate, window geometry, and power source,
   all recorded with the result. Ambient machine load is a **diagnostic column, not a
   control** (§13.7.1).
   *Interleaved repeats:* arms run rotated, never all of one then all of the other, and the
   result is a median and a spread — never a mean.

   Compositor cost is recorded alongside this gate rather than judged by it: §13.1.5's
   +41.19 points visible against +1.09 minimized is its measured magnitude, and §13.1.9 is
   the reason no threshold sits on it.
10. **Stability** — 30-minute run with no crash and RSS growth under 10 %.
11. **Repository safety** — `git remote -v` lists `origin` → `glowtop-dev`, the private archive, and nothing else (empty until 2026-09-21, when the repository was created on Connor's explicit authorization — §14.11; *amended 2026-09-21:* the public repository `UsernameTron/glowtop` is published from an export of this tree that omits the planning records and task notes (the `.planning` and `tasks` directories), with fresh history — §14.11), and no session pushes to either repository without his go for that push; nothing written outside the repository except `~/Library/Logs/GlowTop/`; `~/Applications/GlowTop.app` (§2.8, as of phase-05) — written only by `scripts/package-app.sh`, whose install target is a literal path in the script with pre-removal assertions guarding it, never a computed or parameterized one; and the app's own preferences domain `~/Library/Preferences/com.glowtop.GlowTop.plist`, which §7.4 and §8.2 require it to write through `UserDefaults` (theme selection and edited colours, column widths). The preferences domain was absent from this list until 2026-09-09 although the gate had passed at every close since phase-05 with those writes occurring — a list that did not describe the app, corrected in §14.9 rather than by loosening the gate. Gate 12's scratch domains are a separate matter and are held in memory (phase-08's fix); the count of leaked `com.glowtop.selfcheck.theme.*.plist` files is read at every close and must not grow.
12. **Layer geometry self-check** — `GLOWTOP_SELFCHECK=1` prints `selfcheck: PASS`. The
    `contentsRect` crop that reveals a meter's lit fraction (§6.5) depends on a platform
    coordinate convention, not on arithmetic; inverted, it produces a meter that fills from
    the wrong end while every other gate stays green.
13. **Traceability checked** — `scripts/check-spec-refs.sh` prints `spec refs: PASS`. It
    resolves every section citation — written `§13.1.9` or `SPEC 13.1.9` — in this
    document, in the planning records where they are present (private archive only), in
    `CLAUDE.md`, and in `scripts/*.sh`, plus every
    section in §14.8's table, against this document's headings; a `§13.7.N` citation
    resolves to gate N in the list above rather than to a heading. §13.1.4–13.1.6 were
    cited in §14.9 across three commits before they were written, and the planning `STATE.md`
    cited §13.1.9 before it existed (§13.7.1); a citation nobody validates is a reading
    that measures nothing.

Gate 3 is the one that protects the app's future. Every other gate proves it works today;
gate 3 proves that the next macOS update cannot take it out.

Gate 12 exists because this environment cannot take screenshots, and it turned out to be the
better instrument anyway: a rendered-pixel assertion catches an inverted meter every run,
where a human glance catches it only when someone happens to look.

#### 13.7.1 Every gate states what it measures and what would void it

Three instruments were caught reporting a bottleneck as a success inside three phases:
`ps -o %cpu` charged the app for its own launch (§13.1.1), an app-scoped CPU gate credited
work that had merely moved to another process (§13.1.1), and a hardcoded 60 fps target
recorded a saturated draw path as a pass on a 120 Hz panel (gate 8). Each was plausible,
each produced a confident number, and each was wrong in the direction that flatters the
build.

So every gate in this table carries four things:

- **What it measures** — the quantity, in units, at what scope.
- **What would make the reading meaningless** — the condition under which the number is
  still produced but no longer means what it appears to mean.
- **Its confounds** — the variables that must be held constant, named explicitly, and
  recorded alongside the result rather than assumed. For any timing or overhead gate that
  is at minimum: which display and its refresh rate, window geometry, and power source.
  The machine's ambient load during the window is **recorded as a diagnostic column and
  is not a control** — this rule originally required it as one, and that requirement was
  wrong. On this machine the control arm's whole-machine spread was 196 points (§13.1.5)
  and 61 points (§13.1.7), because the measuring session is itself the load; a covariate
  that moves more than the effect cannot gate the effect. Interleaved repeats are what
  absorb ambient load, not a covariate.
- **Interleaved repeats** — no gate reports a single reading. Arms run A/B/A/B/A rather
  than all of A then all of B, so thermal drift and ambient load spread across every arm
  instead of landing on whichever ran last. Report the **median and the spread**, never a
  mean. **If the control arm's spread meets or exceeds the effect being measured, the
  arms are not separable on that machine and the correct output is "not separable", not a
  number.**

A gate with only the first item is not finished. Three instrument defects in three phases
is not bad luck, it is a missing structural requirement, and each of the three would have
been caught by one of the items above:

| Defect | Caught by |
|---|---|
| `ps -o %cpu` charging the app for its own launch | what it measures |
| App-scoped CPU crediting work that moved to WindowServer | what would void it |
| A hardcoded 60 fps target on a 120 Hz panel | confounds (display rate unrecorded) |
| A variant that silently ran on a 60 Hz external | confounds (display rate unrecorded) |
| An ambient-load covariate required as a control, on a machine where the measuring session is the load | interleaved repeats (control-arm spread) |
| WindowServer CPU time over 60 s, spread 15–34 points with the screen controlled (§13.1.7) | interleaved repeats — "not separable" for any magnitude under ~30 points |
| A traceability table citing §13.1.4–13.1.6 across three commits before they existed | gate 13 — a checked artifact |

**The phase's actual finding.** Five signals in one phase read as authoritative while
measuring nothing: `ps -o %cpu`, gate 8's fps, the ambient-load covariate this rule wrongly
required, WindowServer CPU time itself, and a traceability table nobody validated. Every
one was caught by asking what would make the reading meaningless, and not one by the
reading. That question is the phase's product alongside the spike, and gate 13 exists so
the sixth does not get through.

---

## 14 M02 Pro panes, M03 distribution, and later

This section began as an outline — written so M01's architecture would not foreclose these features, not to be built from — and each subsection was expanded in place to §5-level detail before its phase was planned. As of v1.1.2 the features in §14.1, §14.3–§14.6, §14.10 and §14.11 have shipped; §14.2 and §14.7 remain outlines; §14.8 and §14.9 are the traceability table and the amendment log.

### 14.1 Power & Freq (M02)

The first `PRO` pane (§3.2), selected from the sidebar's `PRO` block and by ⌘8 (§3.4, §3.5). Per-cluster frequency residency as stacked charts, a per-cluster DVFS state histogram, and package power split into channels — all from the IOReport `CPU Stats` and `Energy Model` groups §5.6 and §5.9 already open. Unlike §14.10's pane, this one **is** provider work: §5.9 graduates from feeding one meter to feeding three charts, which means retaining per-cluster residency in ring buffers (§6.4) rather than collapsing to a single average, and §5.6.3 gains a fourth exact-name channel. The Summary pane's Clock meter (§4.3.1) and Energy tile (§4.6.3) are unchanged by all of it.

**Three stacked full-width cards** in §4.2's chrome, in this order, inside §4.1's 16 pt outer padding and 12 pt gaps, at **equal thirds** of the detail area:

| Card | Title | Headline | Footer | Content |
|---|---|---|---|---|
| 1 | `FREQUENCY RESIDENCY` | none | none | Three cluster columns, each a stacked residency chart with an average-frequency line |
| 2 | `DVFS STATES` | none | The window's span, `12 s` growing to `60 s` | Three histogram columns, aligned under card 1's |
| 3 | `PACKAGE POWER` | `8.4 W`, 24 pt, yellow | `CPU 3.1 · GPU 0.9 · ANE 0.0 · DRAM 1.2 W` | §4.5's stacked-band timeline, full width |

Cards 1 and 2 carry **no 24 pt headline** — the per-column caption and its current frequency replace it. The pane fills the detail area and **does not scroll**: each card is `(paneHeight − 32 − 24) / 3`, ≈204 pt at §3.1's minimum window, and all three shrink with the window rather than clipping.

**Cluster identity.** One column per `CPU Stats | CPU Complex Performance States` channel whose name is a cluster. The reference Mac carries three:

| Channel | Label | Accent | Cores |
|---|---|---|---|
| `PCPU` | `P0` | §7.2's Clock accent | 5 |
| `PCPU1` | `P1` | §7.2's Clock accent | 5 |
| `ECPU` | `E` | §7.2's GPU accent | 4 |

Column order is **fixed at P0, P1, E** regardless of IOReport's enumeration order, and a cluster occupies the identical x-range in card 2 that it occupies in card 1, so one cluster reads top to bottom. The same subgroup also carries `ECPM`, `ECPM_IDLE`, `PCPM`, `PCPM_IDLE`, `PCPM1` and `PCPM1_IDLE` — a second, differently-bucketed accounting of the same silicon, confirmed by their identical `DOWN` residencies — and **none of them is ever treated as a cluster** (§5.9.1's recorded deviation). The cluster count comes from the channel list, so a single-P-cluster SoC draws two columns and this section names no fixed number. **As built in phase-11 the pane view lays out at most three column layer sets** (`PowerFreqPaneView.columnCount`), so a SoC with more than three clusters would draw three — the provider, the model and the probe carry every cluster; widening the view is recorded for Phase 12 in `phase-11-PLAN.md`. Core counts come from the `CPU Core Performance States` channel names (`PCPU0xx` → `PCPU`, `PCPU1xx` → `PCPU1`, `ECPU0xx` → `ECPU`), read once, because `hw.perflevel0.logicalcpu` reports both P clusters as one number and cannot split them.

**Column geometry.** `columnWidth = (cardWidth − 24 − 12 × (N − 1)) / N` for `N` clusters, every column the same width — unequal widths would make one cluster's 100 % a different *size* as well as a different caption, which is the misreport §5.1.4's caption exists to prevent. The gutter is §4.1's own 12 pt.

**Card 1 — frequency residency.** One cumulative filled band per DVFS state (§4.5's band form: `solid` fill, no stroke), ordered lowest → highest frequency, bottom → top, on a 0–100 % of wall time left axis with gridlines at 0/25/50/75/100. The power-gated `DOWN`/`IDLE` states are **one band at the very bottom**, rendered at the cluster accent's 8 % — §4.3.1's unlit tone, reused — so the stack totals 100 % of wall time and a mostly-asleep cluster looks asleep. Active states take an opacity ramp of the same accent: for `N` active states ranked 0 (lowest) to `N−1`, `opacity = 25 + (rank / max(N−1, 1)) × 75` percent. Brighter is faster, without a legend.

Each column also carries that cluster's **average frequency** (§5.9.1's residency-weighted mean over its active states) as a 1.5 pt line in the cluster's accent, on a **right-hand axis scaled per column** to that cluster's own 0–max — never a scale shared across columns, which would flatten the E cluster's line against a P cluster's ceiling. Three ticks per column: 0, max/2, max, labelled by §4.9's frequency rule, in §4.4's right-axis manner.

The column caption is `{label} · {N} cores  {G.GG} GHz` — SF Mono 10 pt in the cluster's accent, the live average beside the identity.

**Card 2 — DVFS states.** One bar per DVFS state per cluster, computed over §6.4's 60 s window: bar height is that state's share of wall time in the buffer's current span, 0–100 %, same gridlines as card 1. Bars ascend by frequency left to right with `DOWN`/`IDLE` leftmost, and take **the same ramp as card 1**, so a state reads the same brightness in both. Gap 2 pt (§4.3.2's), minimum bar width 4 pt — below that floor adjacent states are merged **at the rendering step only**, and the provider, the probe and this card's own state count keep every state. X labels are sparse: at or below 8 bars, the first, middle and last; above 8, every fourth plus the last. Before the window is full the card's footer reads the actual span (`12 s`) rather than the card holding a warming state — there is no reason to withhold a histogram of the seconds that exist.

**Card 3 — package power.** Four `Energy Model` channels selected by **exact name** per §5.6.3 — `CPU Energy`, `GPU`, `ANE`, `DRAM`, all four confirmed present as `mJ` channels on the reference Mac by the 2026-09-03 channel dump recorded in `phase-11-PLAN.md` — drawn as cumulative stacked filled bands over 60 s, bottom to top CPU, GPU, ANE, DRAM, matching the footer's own order so a footer number maps onto a band without a legend. The stack's top edge is the total, and the 24 pt headline is that total. The left axis auto-scales as §4.6.1's do, with a 5 W floor so a near-idle machine does not read as saturated.

The other channels in the group — `GPU SRAM`, `AFR`, `ISP`, `AVE`, `MSR`, `AMCC`, `DCS`, `DISP`, `DISPEXT`, the PCIe-port `uJ` channels and the second `GPU Energy` channel in `nJ` — are **not drawn and are not folded into an "Other" band**: an unnamed remainder is a number nobody can check. `GPU Energy` is also §5.6.3's own trap, a million units away from `GPU`.

§5.6.3's **uncertain** tag rides in the footer as a trailing word and does not toggle off, because the `powermetrics` confirmation it waits on needs root this app will not take (§2.4, §13.7.2). The card's tooltip says so in a sentence. *Amended 2026-09-21 (1.1.2): the confirmation arrived — see §5.6.3 — so the trailing word is gone from the footer and the tooltip now says the unit was confirmed. The rest of this paragraph is history.*

**States follow §4.8**, with one addition this pane needs and no other has: a **single column** may be unavailable while its neighbours are live. A cluster whose residency table cannot be paired with a frequency table — the E cluster pairs against a different `voltage-states*` key than the P clusters, and the pairing is validated by table length against that cluster's own active-state count — shows `—` in place of its frequency in its caption, omits its plot, and names the key it wanted (`No voltage-states1-sram table`), the way §5.9.1's `tableSource` already names which source answered. The other columns are unaffected. **The whole pane** goes unavailable only under §13.7.3's flag or a failed subscription; unlike §14.10's pane, every card here reads a private API, so that state is reachable live and is verified live rather than only by §5.10's construction.

Requirements PWR-01..05; built in phase-11.

### 14.2 Benchmarks (backlog — not built)

*Ruled 2026-09-08: moved out of M02 to backlog 999.1. Not built in v1.1.2; the sidebar row is present and disabled with the tooltip `Not in this version` (§3.2). The outline below is kept so the idea has a home.*

Three micro-benchmarks with results kept only in memory: single-core integer and floating-point throughput, multi-core scaling across all logical cores, and memory bandwidth (a large-block copy loop). Each reports a number and a comparison against the previous run in this session.

Explicitly not: a score leaderboard, an online comparison database, or any claim that these numbers are comparable to a published benchmark suite. They exist to answer "is this machine slower than it was an hour ago", which thermal throttling makes a real question.

### 14.3 Installed Apps (M02)

Selected from the sidebar's `PRO` block, third in it, and opened by ⌘0 (§3.4, §3.5).

**Roots and depth.** `/Applications` and `~/Applications`, one level deep into a non-bundle
subdirectory of either (`/Applications/Utilities`-style folders). `/System/Applications` was
in an earlier outline of this section and is dropped here: its bundles are SIP-protected and
cannot be reclaimed, so a size-sorted pane has nothing to act on there, and it is the root
whose TCC exposure is the least consistent of the three the reference layout might suggest.
A symlinked bundle is followed and listed under the link's own name — `/Applications/Safari.app`
resolves into a `/System/Cryptexes` path on this Mac, and the link's name is the row a user
expects to see.

**Columns**, six: Name (with icon), Version, Bundle ID, Size, Signing identity,
Architectures. Name, Version (`CFBundleShortVersionString`) and Bundle ID
(`CFBundleIdentifier`) come from `Bundle(url:)`; Architectures from
`Bundle.executableArchitectures` — Foundation's own Mach-O header read, no parser of this
project's own; Size from a `FileManager` enumerator summing allocated (not apparent) on-disk
size, without following symlinks; Signing identity from `Security`'s
`SecStaticCodeCreateWithPath` and `SecCodeCopySigningInformation` — read, never validated —
rendered as the leaf certificate's summary, `Ad-hoc`, `Unsigned`, or `—`. Sortable by size,
default descending, `—` sorting last in both directions — sortable by size is the reason
anyone opens such a pane.

**`Unparseable`** (§10.4's pattern). A bundle whose `Info.plist` is missing or fails to parse
contributes a row, never a silent drop: Name is the bundle folder's own stem, `Unparseable`
fills the **Bundle ID** column — the column whose source actually failed — Version, Signing
and Architectures show `—`, and Size is still computed, because a folder can be walked
whether or not its plist parses and size is the column this pane exists for. An unreadable
root contributes no rows and adds a footer note naming it; a bundle whose size walk itself
fails shows `—` for size, never a low number, and is counted in a footer note of its own.

**Scan lifecycle.** On-demand, never continuous — computing on-disk size for roughly 200
bundles means walking a lot of directory trees, which is why this is a background scan and
not a live pane. It starts on first visibility, runs off the main thread with cancellable
progress (`Scanning {n} of {N}…`), and offers `Rescan` and, while running, `Stop Scan`. A
cancelled scan keeps every row it already found and adds a footer note (`Scan stopped at {n}
of {N} bundles.`) rather than discarding them.

**TCC.** Neither root is in the protected set (`~/Desktop`, `~/Documents`, `~/Downloads`, and
the `~/Library/*` containers are; `~/Applications` — this app's own install target — is not).
No Full Disk Access is requested and no entitlement changes; a bundle that refuses to be read
is a `—` row, not a prompt.

Requirements APPS-01..05; built in phase-12.

### 14.4 Write actions (M02)

The deferred halves of §10 and §12: enable/disable launch agents, start/stop services. Each gets the same treatment as the kill flow (§8.5) — a confirmation sheet naming exactly what will happen, a non-default destructive button, an `actions.log` entry with the outcome, and guardrails against the handful of jobs whose removal breaks the login session.

**The privilege boundary, measured 2026-09-08 on the reference Mac (macOS 26.6.1) against a throwaway agent `com.glowtop.phase14-test`.** The `gui/<uid>` domain is writable by its own user without root: `bootstrap`, `bootout`, `enable`, `disable`, `kickstart` and `kill TERM` all exited 0. The `system/` domain is not: `launchctl bootout system/com.example.daemon` returned `Boot-out failed: 1: Operation not permitted`, exit 1, and left the daemon untouched. `launchctl print` and `print-disabled` read either domain unprivileged, so the poll below can look anywhere; only the user domain is ever written. GlowTop never runs as root and never asks (§2.4, CLAUDE.md), and `SMAppService` is no route around that: `SMAppService.agent(plistName:)` registers only plists shipped inside the calling app's own `Contents/Library/LaunchAgents`, so it cannot manage a third-party job any more than it could enumerate one (§10.1). The consequence, row by row: **`Launch Agent` rows (`~/Library/LaunchAgents`) are actionable; `Launch Daemon` rows (`/Library/LaunchDaemons`) are read-only, with the tooltip `Read-only — this job runs as root in the system domain, and GlowTop never asks for root.`; `Launch Agent (system)` rows (`/Library/LaunchAgents`) are read-only in this phase too**, with the tooltip `Read-only — installed for every user by a package; only jobs in your own ~/Library/LaunchAgents can be changed here.` The second is a scope choice, not a privilege fact: those plists are root-owned, the verbs were not exercised against one, and this Mac's own `/Library/LaunchAgents` third-party agent is not even bootstrapped in `gui/501` — a row whose loaded state is that unclear does not get a write action on the strength of an untested assumption.

**The four verbs and their exact argv.** `enable`/`disable` alone are override edits, not load/unload, and the recon shows it: `launchctl enable` on a plist that is not loaded loads nothing (`print` still exit 113 after it), and `launchctl disable` on a loaded job leaves it loaded, leaves a running instance running with its PID unchanged, and still lets `kickstart` start it — only the *next* `bootstrap` is refused (exit 5). `bootout` of a running instance terminates the process and unloads the job in one call. So `bootstrap`/`bootout` ride with `enable`/`disable`, and they are conditional on a read-only pre-check by exit status — 6 of this Mac's 22 user agents are not loaded at all, so the not-loaded case is the common one, not an edge. Nothing here parses stdout to decide anything (ACT-07, §12.1).

| Verb | Pane | `launchctl` calls, in order | The poll observes |
|---|---|---|---|
| Enable | Startup Apps | `enable gui/<uid>/<label>`; then, if `print gui/<uid>/<label>` exits 113, `bootstrap gui/<uid> <plist path>` | `print` exits 0 |
| Disable | Startup Apps | `disable gui/<uid>/<label>`; then, if `print` exits 0, `bootout gui/<uid>/<label>` | `print` exits 113 |
| Start | Services | if `print` exits 113, `bootstrap gui/<uid> <plist path>`; then `kickstart gui/<uid>/<label>` | a `pid =` line is present |
| Stop | Services | `kill TERM gui/<uid>/<label>` | no `pid =` line |

Every call is a fixed argv built by one purpose-built function per verb; no function anywhere takes a subcommand string. Measured exit codes, recorded so `failed:<code>` lines can be read: `113` service not found (`print`, `kickstart`); `5` `bootstrap` refused — **both** for a disabled job and for one already loaded, which is why the pre-check is `print`'s exit status and never a second `bootstrap`; `3` `kill` with nothing running (`No process to signal.`) and `bootout` of an absent job (`No such process`); `1` any write to `system/`.

**The post-action poll.** After the last call, `launchctl print gui/<uid>/<label>` every 500 ms for up to 5 s — §8.5's cadence. The contract with its output is exactly this and nothing more: the exit status (`0` loaded, `113` not), and the first line matching `<tab>state = ` and the first matching `<tab>pid = ` at **one** tab of indentation — nested blocks carry their own `state = active` lines and are ignored. `state = xpcproxy` shows between `kickstart` and the PID's arrival (measured), so `started` keys on the `pid =` line, never on `state = running`. The Enabled column (§10.2) stops reading the plist's `Disabled` key alone: `launchctl disable` never touches the plist, so after this pane's own action that column would lie. It now reads the override store `/var/db/com.apple.xpc.launchd/disabled.<uid>.plist` — world-readable (`-rw-r--r-- root wheel`), a flat `label → Bool` dictionary where `true` means disabled, decoded with `PropertyListDecoder` like every other source in §10.1 — with the plist key as the fallback for a label the store does not name. An unreadable store falls back to the plist key and says so in the footer. No `print-disabled` stdout is parsed.

**The log.** `~/Library/Logs/GlowTop/actions.log` — §8.5's file, its lazy `0600` creation, its append-only rule and its `"`/control-character escaping, applied to the label. One line per attempt, §8.5's shape with a new verb word:

```
2026-09-08T22:41:07Z DISABLE label="com.example.nightly-report" domain=gui/501 result=disabled
2026-09-08T22:42:19Z START label="homebrew.mxcl.redis" domain=gui/501 result=started pid=2581
2026-09-08T22:43:02Z STOP label="com.apple.Siri.agent" domain=gui/501 result=blocked-guardrail
```

`result` is closed: `enabled`, `disabled`, `started`, `stopped` — the state the poll **observed**, never the API's return; `blocked-guardrail`; `failed:<code>` for the first non-zero `launchctl` exit in the sequence (the poll does not run); and `failed:timeout` when every call exited 0 but the poll never saw the state within 5 s — a `KeepAlive` job that launchd relaunches after `kill TERM` lands here, with the new `pid=` appended. A cancelled sheet writes no line.

**The guardrail**, §8.5's PID 0/1 rule in launchd's terms, applied in the same two layers — the control is disabled with a tooltip, and the function refuses and logs `blocked-guardrail` regardless. Refused: any label with the prefix `com.apple.` (425 of `gui/501`'s 457 services are Apple's and none is on the pane, but a stray `com.apple.*` plist in `~/Library/LaunchAgents` would be, and it is exactly the one not to touch); the label `com.glowtop.GlowTop` or any job whose `Program` resolves to GlowTop's own executable (it never unloads itself); and any row with no `Label` key (the reader falls back to the file stem, which launchd does not know — this Mac's two Google Keystone plists are empty dictionaries) or of type `Unparseable`. On the reference Mac the deny-list matches none of the 22 rows, so it is proved with a fixture, not live.

**Layer 1 only exists if the menu opts out of AppKit's auto-enabling (amended 2026-09-21, 1.1.1).** Every context menu in the app sets its items' `isEnabled` by hand in `menuNeedsUpdate`, and `NSMenu.autoenablesItems` defaults to `true`: AppKit then runs its own validation pass *after* the delegate call and re-enables any item whose target responds to its action. In the notarized 1.1.0 build that left `Enable`/`Disable` live on `Launch Daemon` rows, `Start`/`Stop` live on denied Services rows, and §8.5's `Quit Process` live on PID 0 and PID 1 — tooltip correct, control highlighting, click doing nothing because layer 2 refused it every time. All five hand-validated menus (Processes, Startup Apps, Services, Connections, Users) now set `autoenablesItems = false`, and gate 12 asserts the **live** item after `NSMenu.update()`, not the state the controller computed — which was right all along, and is why the three phase-14 assertions could not see this.

**The sheet**, one per action, patterned on §8.5 and never skippable:

> **Disable `com.example.nightly-report`?**
> Launch Agent · `~/Library/LaunchAgents/com.example.nightly-report.plist` · runs at load: No
>
> This runs `launchctl disable` and unloads the job now. It will not run again at login until it is enabled.
>
> `[Cancel]` `[Disable]`

`Enable`/`Start` are the default button, as `Quit` is; `Disable`/`Stop` are styled `critical`, are **never** the default, and leave `Cancel` as the default — the non-default destructive button this section has promised since M01. Esc cancels. `Stop` on a job with `KeepAlive` adds `KeepAlive is set — launchd will relaunch it. To keep it stopped, disable it in Startup Apps.` Cancel runs nothing and logs nothing.

Requirements ACT-01..07; built in phase-14.

### 14.5 Connections (M02)

The reference layout's PRO section carries a Connections pane between Power & Freq and
Installed Apps — second in the block (§3.2) and opened from the sidebar or by ⌘9 (§3.4,
§3.5).

A table of the machine's open sockets, reusing the Processes pane's sort, search, and row
chrome (§8.2–§8.4) rather than inventing a second interaction model, in its own model and
its own file — `ProcessesModel.swift` is untouched.

**Source — `libproc`, three calls deep, public but sparsely documented.** `proc_listallpids`
sizes and fills the PID list (a **count**, not a byte count — §5.5.1's own trap, applying
again here); `proc_pidinfo` with `PROC_PIDLISTFDS` lists each PID's file descriptors (this
call, in the same family, returns **bytes** — the opposite convention); `proc_pidfdinfo` with
`PROC_PIDFDSOCKETINFO` reads each socket descriptor. Only descriptors of kind `SOCKINFO_TCP`
and `SOCKINFO_IN` with protocol `IPPROTO_UDP` are kept; every other descriptor type is
skipped and not counted. Shelling out to `lsof` or `netstat` is ruled out for the reason
§12.1 rules out parsing `launchctl` stdout.

**Columns**, six: Process (name and icon), PID, Proto, Local address:port, Remote
address:port, State. `Proto` reads `TCP` / `TCP6` / `UDP` / `UDP6`. `State` decodes the
twelve `TSI_S_*` values into `lsof`'s own spelling — `CLOSED`, `LISTEN`, `SYN_SENT`,
`SYN_RCVD`, `ESTABLISHED`, `CLOSE_WAIT`, `FIN_WAIT_1`, `CLOSING`, `LAST_ACK`, `FIN_WAIT_2`,
`TIME_WAIT`, `RESERVED` — any other integer shows `state N`; UDP rows show `—` (no state
exists at that layer).

**Numeric addresses only**, via `inet_ntop` — never a resolver. Five forms cover every case:
`{v4}:{port}`, `[{v6}]:{port}`, `[{v6}%{ifname}]:{port}` (link-local), `*:{port}` (a wildcard
local address, `0.0.0.0` / `::`), and `—` (an unconnected remote — `0.0.0.0`/`::` **and**
port 0). **This pane reads the socket table; it does not open one.** The no-network rule
(CLAUDE.md, gate 7) is about GlowTop making connections of its own, and gate 7 stays exactly
as written — `lsof` against GlowTop's own PID must still return no rows. Reverse DNS on
remote addresses would violate that rule and is excluded for it: a tree-wide
`getnameinfo`/`getaddrinfo`/`CFHost`/`NSHost`/`gethostbyaddr` grep reads `0` at every commit.

**Cadence.** Enumerating every socket on every PID costs more than the Processes pane's own
enumeration, so the cost is bounded before it is wired, not tuned after: a warm median at or
under 25 ms samples on every tick of the existing slow loop (`1 Hz`); 25–50 ms samples every
second tick (`0.5 Hz`, labelled as such); over 50 ms is not wired, and the phase records the
reading and waits for a ruling rather than picking a number under pressure. Unlike every
provider in §5, this reader samples **only while its own pane is visible** and carries no
`ProviderID` — a slot read once and never refreshed again would show `.stalled` on the
Summary pane's status bar (§4.7) forever after a single visit, so it sits outside `health()`
by construction, not by omission.

**Coverage.** The same `proc_listallpids` fill the enumeration makes yields both `pidCount`
(every PID on the machine) and `inspectedPIDCount` (the subset whose file descriptors this
process could actually list, per §5.5.1's own refusal rate) — a refused PID is counted, not
dropped. The footer states both: `{i} of {t} processes inspected · sockets of the other {r}
are not listed`. A genuine zero-socket result among the inspectable set is a live, empty
table with its own body text, distinct from `.unavailable`.

**States follow §4.8**: warming shows `···` while the pane's first sample of this visit is
pending; a live empty result shows `No open TCP or UDP sockets among the {i} processes this
user can inspect`; unavailable (`proc_listallpids` itself failing) shows `Unavailable on this
Mac` with the §5.0.5 reason verbatim in the footer; stalled dims the table to 35 % opacity
after 2 s without a sample while the pane stays visible.

Requirements CONN-01..06; built in phase-12.

### 14.6 Disk Space (M02)

A treemap of volume usage, drillable by directory. Promoted here from §14.7's unscheduled
list, where it sat as a bullet while the sidebar, the roadmap, and §14.8's traceability
table all sold it as an M02 pane. Selected from the sidebar's `PRO` block, fourth in it, and
opened by **⌘D** (§3.4, §3.5) — the ten digit keys were spent by phase-12, and a pane this
environment can only drive by keystroke needs one it can reach.

Two halves that share a pane and not a mechanism. Above: **per-volume capacity, used and
free**, read instantly. Below: **a treemap of one directory level at a time**, drilled by the
user, each level's children sized by a walk that costs real seconds and says so before it
starts. **The pane reads; it never writes.** There is no delete, no trash, no move and no
reveal — §14.4's write actions are §10's and §12's, not this pane's — and `du`, `df` and
`diskutil` are cross-check instruments in §13.6, never data sources, for the reason §12.1
rules out parsing `launchctl` stdout.

**Volumes — instant.** `FileManager.mountedVolumeURLs` with `.skipHiddenVolumes`, then
`URLResourceValues` for volume name, total capacity, available capacity,
available-for-important-usage, and the removable / internal / root-filesystem flags —
Foundation's wrapper over `getattrlist`/`statfs`, whose total is byte-identical to `statvfs`'s
`f_blocks × f_frsize` on the reference machine (494 384 795 648 B, both, measured 2026-09-08).
**`.skipHiddenVolumes` is doing real work here, not tidying.** Unfiltered, that machine reports
**fourteen** volumes: the root, `VM`, `Preboot`, `Update`, `xART`, `iSCPreboot`, `Hardware`,
`home`, a CoreSimulator volume, two Docker installer mounts, an app-wrapper mount, a recovery
mount, and a *second* `Macintosh HD` at `/System/Volumes/Update/mnt1`. **Four of the fourteen
report the same 494 GB container total**, so summing the unfiltered list triple-counts the
disk — the APFS-container trap, and the reason the filter is specified rather than left to
taste. Filtered, the same machine reports one. `Used` is capacity minus available; per-
filesystem `df` rows are not summed, for the same reason.

`volumeAvailableCapacityForImportantUsage` — the figure "About This Mac" shows — reads
**81 890 841 618 B against `volumeAvailableCapacity`'s 69 934 710 784 B** on that machine: a
**12.0 GB gap** of purgeable space, with three local `com.apple.os.update-*` snapshots among
it. `Free` is the smaller, `df`-agreeing number, and the larger one is *named* rather than
shown — `12.0 GB more is purgeable (snapshots, caches)`, whenever the gap exceeds 1 GB.
Disagreeing with Finder by 12 GB while saying so beats disagreeing with `df` by 12 GB
silently, and one of the two disagreements is unavoidable.

This half is a **pane-owned one-shot read** on first visibility and on `Rescan` (§9.3's shape,
as §14.3's scan already elaborates it) — not a `MetricStore` slot, not a `ProviderID`, not in
§4.7's health phrase. A capacity figure has no current value between reads, §4.8's 2 s stall
rule would misfire on every idle minute, and a slot read once and never refreshed shows
`.stalled` on the Summary status bar forever after one visit: §14.5's argument, applying
unchanged to a second pane.

**Cost note — scan strategy, scope limit, and which number is reported.** This is the
paragraph the pane may not be built without, and every figure in it was measured on the
reference machine on 2026-09-08 before any of the pane existed.

*Scan strategy — one level per drill-down, and nothing at all on open.* The pane opens showing
the volume bars and **starts no walk**. A walk begins only when the user chooses a root or
descends into a rectangle. *Amended 2026-09-21 (1.1.3):* "chooses a root" had exactly one working form until 1.1.3 — ⌘D's second press. The body text's "Select a volume" promised a second that nothing implemented: no code path led from the volume bar to `enter(_:)`. Clicking the bar now enters that volume's root, with a tooltip naming the cost first; gate 12 asserts both that the bar carries a click recognizer and that the pick becomes the root (both read FAIL before the fix). **The offered default root is the home directory**, not the volume
root: 386.6 GB of this container's 494 GB sits on the Data volume while `/` proper is 16.2 GB
and SIP-sealed, so the home directory is where a user's reclaimable bytes actually are and it
bounds the first walk at a measured 73 s rather than leaving it open-ended (Connor, ruled
2026-09-08). Any volume or directory can be made the root; only the offered default is fixed
here. Entering a node sizes **exactly that node's children**, retains only
their totals, and **discards every subtotal beneath them**; descending into a child re-walks
that child's own children. The reason is memory, not time: `/System/Volumes/Data` carries
**4.9 M inodes**, a retained subtotal tree over every descendant is ~4.9 M nodes — hundreds of
megabytes against §13.7's 210 MB whole-process cap, on a pane whose nearest relative (§14.3's
bundle scan) already costs +252 MB — while one level at a time retains tens of entries. The
price is re-walking on descent, and it is small warm: `/Applications` (272 665 files, 60 712
directories) walks in **6.03 s cold and 1.78–1.81 s warm**, so a descent into a directory whose
parent was just sized is served from a warm cache. **A volume boundary is never crossed.** A
directory that is itself a volume root — `/System/Volumes/Data` behind the firmlinks, `/.nofollow`
and `/.resolve` at the root on macOS 26, a mounted disk image under
`/Library/Developer/CoreSimulator/Volumes`, an installer mount under `/private/var/folders` —
reads `0 B · 0 items` wherever it appears beneath a node and is sized on its own only when
entered; the volume bars above are where volumes are sized. Found at 5.3b: a `/` drill walked the
disk twice over through `/.nofollow` and the Data firmlink, minutes long at 2.5 GB RSS, and the
same walk held autoreleased `URL` attributes with no drain — a `~` walk (2.8 M entries) peaked at
2 032 MB in the reader alone. With one autorelease pool per directory and only multi-link files
entering the hard-link set, the same walk peaks at **102 MB** and its allocated total still
matches `du -k` to 0.02 %. `du -x` cannot express the boundary rule here — APFS presents one
device ID across the firmlink, so `du -x /System` walks the Data volume — which is why §13.6's
instrument for it is per-child.

*Scope limit — what a level actually costs, stated rather than implied.* A rectangle's area is
its child's **recursive** size, and there is no way to know a directory's recursive size without
walking it. Sizing one level is therefore a full walk of that level's subtree, by arithmetic:
sizing the **32 children of the home directory walked 2 799 301 entries in 73.07 s cold** — of
which `~/Library` alone was 1 571 155 entries in 47.3 s. "Never a whole-volume walk up front" is
honoured by **when**, not by how much: nothing walks until the user asks, every walk carries a
determinate progress indicator, a `Stop`, and a label that says what it is about to do
(`Sizing 32 items in ~ — this walks every file beneath them`) before it does it. Entering a
volume root *is* a whole-volume walk and this section says so rather than implying otherwise.

*The rate is bounded before it is wired, not tuned after* — §14.5's rule applied to a different
quantity. The measured quantity is **entries per second**, not seconds, because seconds are a
property of the directory and entries per second are a property of the code; the baseline
instrument is one level of `/Applications` (333 377 entries), which a bare enumerator walks at
**187 k entries/s warm** and the home directory's full level at **38 k entries/s cold**. At or
above **150 k entries/s** the reader ships as written; **50–150 k** ships with the finding
recorded and the plan naming what the reader does per entry that an enumerator does not; **below
50 k** is not shipped, and the phase records the reading and waits for a ruling rather than
picking a number under pressure.

*Which size number is reported.* **Rectangles are laid out by allocated (on-disk) bytes**, from
`.totalFileAllocatedSizeKey`. The walk reads **`.totalFileSizeKey` in the same `resourceValues`
call** and the apparent figure stays visible in the selected node's readout — reading both is
not separably more expensive than reading one (six warm passes over `/Applications`'s 272 665
files read 1.98–5.56 s with no ordering by which keys were requested; a quieter interleaved
pair read 1.791 / 1.782 s apparent against 1.812 / 1.785 s allocated, a §13.7.1 "not
separable" verdict), so **no cost argument favours either number** and the pane keeps both.

**DISK-03 and the roadmap's phase-13 criterion 4 both specified apparent, and measurement
reversed them.** A treemap's rectangle *is* its number — an area
is not a cell a reader can discount — and apparent bytes on this machine produce a map that is
not merely imprecise but structurally wrong: `~/Library/Containers/com.docker.docker` reads
**1 099 589 118 849 B apparent against 5 186 609 152 B allocated, a 212× overstatement** from
one sparse disk image, and would be drawn as most of the home directory while occupying about
one percent of the volume; cloud-evicted iCloud and OneDrive placeholders report their full
logical size at **zero** bytes on disk (one file reads 23 802 958 224 B apparent, 0 B
allocated) and would be drawn as the largest things on the machine; and the home directory's
children total **1 572 493 980 724 B — 1.57 TB apparent on a 494 GB disk**, 3.2× the volume
that contains them. Amending the requirement is the honest response and shipping a caption
under a distorted map is not (Connor, ruled 2026-09-08; §14.9). **This also makes the pane
agree with §14.3**, which sizes bundles by the same key for its own reason — allocated is the
reclamation number, and both panes are ultimately asked "what would deleting this give back".

**Neither key reconciles to the volume's used space**, and that has not changed with the
ruling: allocated double-counts every cloned block shared across a tree, apparent counts holes
in sparse files and bytes that are not on this disk at all. A treemap claiming to add up to
`df`'s `Used` would be lying whichever key it read, so this section does not claim it and the
volume bar above — read from `statfs`, not from any walk — remains the only reconcilable
used-figure in the pane.

**The APFS disclosure (a computed statement, not a boilerplate apology).** DISK-03's one-line
clone/sparse/snapshot disclosure survives the ruling with its sense flipped: it no longer
defends apparent as the layout key, it explains the gap the layout key hides. Whenever a
node's apparent total exceeds its allocated total by more than 10 %, the line states both:
`On-disk sizes. 5.19 GB here, from files whose logical size is 1.10 TB — sparse, cloned or
cloud-evicted.` When allocated is the larger — which happens, and is why the line is computed
rather than written once — it reads `On-disk sizes; 183 063 small files round up to 4 KB
blocks.` Below 10 % either way: `On-disk sizes; clones, sparse files and snapshots can differ
from logical size.` The apparent-larger direction occurs on the reference machine —
`/Applications` is 31 226 994 970 B apparent against 25 176 432 640 B allocated, a 24.0 % gap,
comfortably over the threshold. **Corrected 2026-09-08, phase-13 execution (§14.9):** this
paragraph previously cited `~/Documents` (3 812 725 259 B apparent against 3 925 614 592 B
allocated) as the allocated-larger worked example, but that pair is only a 2.96 % gap — under
this same paragraph's own 10 % threshold, so it renders as the **third** form, not the second,
and does not illustrate the case it was cited for. No directory sampled that day cleared 10 %
in the allocated-larger direction (4 KB rounding rarely produces a double-digit gap outside a
constructed case), so the second form is illustrated with a scaled fixture instead: 183 063
files with an apparent total of 3 000 000 000 B against an allocated total of 3 500 000 000 B
(16.7 %) reads `On-disk sizes; 183 063 small files round up to 4 KB blocks.` — the exact
fixture phase-13 shipped as
`DiskSpaceModelTests.testDisclosureNamesBlockRoundingWhenAllocatedExceedsApparent`. So neither
"apparent overstates" nor "allocated overstates" is true as a general claim and the line does
not make either.

**Scan lifecycle.** Off the main thread in a detached utility-priority task, with determinate
progress (`Sizing {n} of {N} — {name}`), a `Stop` button, and rectangles **appearing as their
children finish** rather than all at once. `Stop`, or switching away — §3.3 releases the pane,
and the release cancels the task — keeps every rectangle already sized and adds a footer note
(`Sizing stopped at {n} of {N} items.`) rather than discarding them. **Because a scan cannot
outlive its own pane, it cannot be running during a Summary-visible overhead window or a
chart-pane frame-rate window at all** (§13.7's gates 9 and 8); that is a property of §3.3's
teardown, and the phase that builds this pane proves it by removing the cancel once and showing
the instrument sees the difference, rather than asserting it from the architecture.

**Navigation.** `↩` descends into the selection, `⌫` ascends, the arrow keys move it, and a
breadcrumb above the map makes every ancestor selectable. Clicking a rectangle descends too —
it is the obvious gesture — but no acceptance check depends on a synthesized click: blind
coordinate clicks and AX-tree navigation are both unreliable in this project's test
environment while menu and key-equivalent keystrokes are not, so every driven check uses keys.

**Locked and unavailable (§4.8).** A directory a treemap walks into may refuse to be read, and
unlike §14.3's roots this pane's default territory includes the TCC-protected set. No Full Disk
Access is requested and no entitlement changes — §14.3's posture, carried into the harder case.
A directory that refuses enumeration is drawn as a **fixed-minimum-size rectangle in
`textDisabled` with its name and `—`**, never area-proportional and never a low number: a low
number in a treemap is worse than a wrong cell, because it silently shrinks the rectangle and
rearranges every sibling around it (§10.4's refusal to report a plausible wrong value, applied
to geometry). A partly-readable node states the shortfall in the footer:
`4 items could not be read; their sizes are not included.` If the chosen **root itself** cannot
be read, the map shows `Unavailable on this Mac` in `textDisabled` with the `FileManager`
error's own reason in the footer — and the volume bars stay on screen above it, because the
volume half did not fail. Locked, cancelled and unavailable differ in text, token and footer,
so they cannot be confused for each other.

Requirements DISK-01..05; built in phase-13.

### 14.7 Later, unscheduled

- **Menu-bar mini mode** — a status-bar item with a compact CPU/memory readout and a click-through to the main window. Not in M01's scope and not currently in M02's; listed so the idea has a home.
- **60-second CSV export** — dump the current ring-buffer contents to a file, for writing up a measurement rather than screenshotting a chart.
- **Per-cluster core grouping** in the per-core strip (§4.3.2), labeled P and E.

The signed, shareable build — Developer ID signing, notarization, the DMG and the release — sat in §2.8 as one M03 sentence until the milestone opened; it is specified in §14.11.

### 14.8 Traceability

Every feature, its specifying section, and the phase that builds it. This table is the contract between this document and the roadmap; a feature that is not in it does not get built, and a section with no phase is a spec that outran the plan.

| Feature | Spec § | Requirement | Phase |
|---|---|---|---|
| This specification | all | SPEC-01, SPEC-02 | phase-01 |
| SwiftPM package, target layering | 2.7 | BUILD-01 | phase-01 |
| Provider protocol, `Snapshot`, warming/unavailable | 5.0 | PROV-06 | phase-01 |
| `MetricStore` actor, sample loop, generation counter | 6.3 | RENDER-01 | phase-01 |
| `RingBuffer` | 6.4 | RENDER-01 | phase-01 |
| CPU provider | 5.1 | PROV-01 | phase-01 |
| `glowtop-probe` CLI | 2.7, 13.6 | PROV-07 | phase-01 |
| `DisplayLinkView`, per-core neon bars, interpolation | 6.2, 6.5, 6.6 | RENDER-01 | phase-01 |
| FPS counter | 6.7 | RENDER-02 | phase-01; RENDER-02 amended 2026-08-28 to gate 8's threshold, **unmet** (83.3–85.9 %), carried to M02 — **met in phase-09**, see the RENDER-02 row below |
| Composited chart path, gate 8 met | 6.5, 13.1.13 | RENDER-02 | phase-09 — **120.00 fps of 120, three rounds, spread 0.00, 100.0 % served; margin 6.00 fps against the arm's own spread of 0.00** (separably); the CoreGraphics control read 104.20 (spread 8.40, 86.8 %) in the same interleaved campaign. **RENDER-02 SATISFIED** |
| CA-composited first, Metal only on a measured failure | 6.5, 13.1.13 | RENDER-03 | phase-09 — the CA path was built behind a flag before any Metal code existed and won outright; the Metal wave and the levers wave were not run, under the decision rule written before the reading. **RENDER-03 SATISFIED** |
| Gate 12 asserts chart pixels on the new renderer | 13.7.12, 13.1.13 | RENDER-04 | phase-09 — all eight pane assertions PASS on the shipped path with `cpu-chart-pixels hits=263`; gate 12's capture was corrected in the same phase (chart layers pinned to the 1× context's scale offscreen) so the two paths could be compared at all. **RENDER-04 SATISFIED** |
| `ChartLayer` parameterised — series and colours in, no Summary-private state | 6.5 | RENDER-05 | phase-09 — `ChartLayer(capacity:)`, `apply(series:gridlines:axis:rightGridlines:rightAxis:scrollOffset:)`, `applyTheme(_:colors:)`; `SummaryPaneView` constructs eight; Phase 10 constructs its own. **RENDER-05 SATISFIED** |
| Visible-vs-minimized attribution re-run, WindowServer's delta recorded | 13.1.5, 13.1.13 | RENDER-06 | phase-09 — ΔWS visible **−3.10**, minimized **−0.15**, both inside the baseline's 9.54 spread; against §13.1.5's +41.19 the visible delta shrank separably. Recorded beside gate 9's `app` 10.03 %. Record-only. **RENDER-06 SATISFIED** |
| Memory provider | 5.2 | PROV-02 | phase-02 |
| Disk provider | 5.3 | PROV-03 | phase-02 |
| Network provider | 5.4 | PROV-04 | phase-02 |
| Process table provider | 5.5 | PROV-05 | phase-02 |
| Number formatting rules | 4.9 | — | phase-02 |
| GPU / NPU providers | 5.6 | PROV-06 | phase-03.1 |
| Energy provider, power source | 5.7 | PROV-06 | phase-03.1 |
| Thermal provider, thermal pressure | 5.8 | PROV-06 | phase-03.1 |
| Frequency provider | 5.9 | PROV-06 | phase-03.1 |
| §13.7.3's force-unavailable flag, one `dlopen` site | 5.0.5 | PROV-06 | phase-03.1 |
| Per-process GPU column | 5.6.7 | SUMM-02 | phase-03.1 |
| Summary grid, card chrome | 4.1, 4.2 | SUMM-01 | phase-03 |
| Four vertical meters | 4.3.1 | SUMM-01 | phase-03 |
| CPU Overview card, per-core strip | 4.3.2 | SUMM-01 | phase-03 |
| CPU overlay chart | 4.4 | SUMM-01 | phase-03 |
| Top CPU processes card | 4.3.3 | SUMM-02 | phase-03 |
| Memory Utilization card and timeline | 4.5 | SUMM-01 | phase-03 |
| Six tiles (Disks, Network, Energy, GPU, NPU, Thermals) | 4.6 | SUMM-01 | phase-03 |
| Status bar | 4.7 | SUMM-02 | phase-03 |
| Warming / unavailable / stalled states | 4.8 | PROV-06 | phase-03 |
| Window, sidebar, navigation, menus, keyboard | 3 | — | phase-03 |
| Pause, occlusion, force-sample | 6.8, 6.2, 3.5 | RENDER-01 | phase-03 |
| Theme tokens, read-only (`Theme.neon`) | 7.2 | THEME-01 | phase-03 |
| Processes pane: table, sort, search | 8.1–8.4 | PROC-01, PROC-02 | phase-04 |
| Kill flow, guardrails, `actions.log` | 8.5 | PROC-03 | phase-04 |
| Process inspector | 8.6 | PROC-01 | phase-04 |
| System Info pane | 9 | PANE-01 | phase-04 |
| Startup Apps pane (read-only) | 10 | PANE-01 | phase-04 |
| Users pane | 11 | PANE-01 | phase-04 |
| Services pane (read-only) | 12 | PANE-01 | phase-04 |
| Theme tokens, presets, editor, persistence | 7 | THEME-01 | phase-05 |
| Accessibility (contrast, reduced motion) | 7.5 | THEME-01 | phase-05 — the contrast warning shipped; reduced motion, reduced transparency and increased contrast are not built as of v1.1.2 (§7.5) |
| Overhead tuning to budget | 13.1–13.4 | PERF-01, PERF-02 | phase-05 |
| RSS profile, the retention lever, and PERF-02's floor and cap | 13.1.12 | PERF-02 | phase-08 — floor **202.40 MB** (spread 0.70); cap ruled **210 MB** and scope ruled Summary-only at 1440×900 (Connor, 2026-09-01); **PERF-02 SATISFIED, separably under by 10.9× the spread**. One lever kept (−49.60 MB, seven-pane arm), one slot empty; multi-pane 295.60 MB documented, not gated |
| 30-minute stability run | 13.1 | BUILD-02 | phase-05 |
| Install to `~/Applications`, ad-hoc signed | 2.8 | PKG-01 | phase-05 |
| Performance pane | 14.10 | PPANE-01..05 | phase-10 |
| Power & Freq pane | 14.1 | PWR-01..05 | phase-11 |
| Benchmarks pane | 14.2 | PRO-02 | backlog 999.1 — moved out of M02 by Connor's 2026-09-08 ruling; not built as of v1.1.2 |
| Installed Apps pane | 14.3 | APPS-01..05 | phase-12 |
| Disk Space pane | 14.6 | DISK-01..05 | phase-13 |
| Connections pane | 14.5 | CONN-01..06 | phase-12 |
| Startup/Services write actions | 14.4 | ACT-01..07 | phase-14 |
| Developer ID signing, hardened runtime, notarization, stapling | 14.11, 2.3, 2.8 | SIGN-01..05 | phase-16 — shipped 2026-09-08: signed, notarized and stapled; `spctl` reads `accepted` against the baseline `rejected` recorded in §14.11 |
| DMG, README, release, the unsigned fallback | 14.11 | REL-01..05 | phase-17 — DMG shipped 2026-09-08; first published as v1.1.1 on 2026-09-21, then v1.1.2 the same day, each on Connor's explicit authorization (§14.11) |

---

### 14.9 Amendment log

| Date | Section | Change | Ruling |
|---|---|---|---|
| 2026-09-21 | §13.7 item 11, §14.11 | **The public repository moved to `UsernameTron/glowtop`.** Published there fresh under that account's private GitHub address, with release `v1.2.0`; the first copy made private. Public files no longer name the private archive's owner. | Connor, 2026-09-21: "move it to UsernameTron" |
| 2026-09-21 | **new §4.10**, §3.4, §5.2.3, §8.2, §14.10 | **1.2 — Simple mode, so the dashboard can be read without a computer-science degree.** Plain labels, a one-word verdict per card (macOS's own thermal and memory-pressure judgements wherever they exist, a 5-point deadband everywhere else), one summary sentence in §4.7's leading slot, and a hover sentence per card. Technical is §4 verbatim and stays the whole of what 1.1.3 shipped; Simple is a relabelled copy of the same projection, so no reading, series or §4.8 state differs — asserted field by field in `SummaryModelTests`. Two new gate-12 pixel arms (verdict colour follows the pressure; a not-live tile carries no verdict), both proved FAIL-first. | Connor, 2026-09-21: simplify the language for a non-technical reader without changing features |
| 2026-09-21 | §2.6, §2.7, §4, §12.1, §14.6 | **1.1.3 — three things the pre-publication audit found that needed an app change.** (1) Disk Space's body text said "Select a volume" and the volume bar was not clickable; it is now, and the pick enters that volume's root. (2) The Summary pane sat at the bottom of a taller-than-content window, and opened scrolled to the bottom of a shorter one; a flipped clip view pins it to the top. (3) `ServicesModel.ownRegistrationStatus()` and `ProcessesPaneController.focusSearchField()` were dead; removed, with the `ServiceManagement` import and the Services footer's claim to that source. Three new gate-12 assertions, **3 FAILED on the unfixed build**, PASS after; self-check 63 assertions. No provider, reading or budget touched. A fourth, from the adversarial review of this change: `enter(_:)` set its `cancelled` flag and cleared it on the next line, and the reader never checked `Task.isCancelled`, so a superseded walk ran to completion behind the new one — invisible for a home folder, minutes of disk reads once a whole volume was one click away. The walk's cancel check now also reads `Task.isCancelled`. | Connor, 2026-09-21: "if these items remain open then this project is not complete" |
| 2026-09-21 | header, §1.4, §1.5, §2.2, §2.5–§2.9, §3.2, §3.4, §3.5, §4.1, §4.3.1, §4.3.3, §5.7.1, §5.8.3, §7.4, §7.5, §8.5, §10.1, §11.1, §13.1.9, §13.7 items 7, 11 and 13, §14, §14.2, §14.4, §14.8, §14.9, §14.11 | **Pre-publication true-up — the document read by strangers for the first time.** Header restated as the specification of shipped 1.1.2; wrong cross-references and the gate-7 process name fixed in place; §3.4/§3.5/§7.4/§4.3.1 trued to the code; §4.3.3's row clicks and §7.5's reduced-motion handling marked not built; §14 reframed, Benchmarks marked backlog; §14.8's accessibility, Benchmarks, signing and release rows closed out. Gate 11 and §14.11 record the split: `origin` is the private archive `glowtop-dev`, the public `UsernameTron/glowtop` is an export without the planning records and task notes, fresh history. Paths into the planning records replaced by the records' names; machine-specific labels, a third-party tool's name and account names replaced with placeholders or generic descriptions; no measured value changed. | Connor, 2026-09-21 |
| 2026-09-21 | §5.6.3, §14.1 | **1.1.2 — §5.6.3's `uncertain` tag lifted, open since phase-03.1.** The `powermetrics` cross-check was finally run (Connor under `sudo`, the session capturing the probe): GPU ratio 1.04, CPU agreeing on every quiet second. The Power card's footer drops its trailing `uncertain`, the tooltip says the unit is confirmed, two model tests follow. **Private** stays. | Connor, 2026-09-21: "remove the uncertain tag and cut 1.1.2" |
| 2026-09-21 | §13.7 item 11, §14.11 | **v1.1.1 published — the repository and the release exist.** Gate 11's "`git remote -v` is empty" becomes "lists `origin` and nothing else"; §14.11 records that the release block was run once by the session, for 1.1.1. Artifacts: app notarization `cf47cfee-66c5-49f7-908c-b5bc030a9e02`, image `f0b35286-06b4-44c9-b280-eb906a09c8ab`, both Accepted; SHA-256 `679f45b9…402c3d`; the quarantine test repeated on the new image. | Connor, 2026-09-21: "Yes, publish as private" |
| 2026-09-21 | §3.2, §8.5, §10.1, §14.4 | **1.1.1 — the first guardrail layer was live on every read-only row, found by the one check no session had been able to run.** Every audit since phase 14 carried "right-click a Startup Apps row and a Services row" as verifiable only by hand. Driven under screen control on the notarized 1.1.0 bundle: the menu and its tooltip were as specified, and `Enable` highlighted on a `Launch Daemon` row. Cause: `NSMenu.autoenablesItems` left at its default, so AppKit's validation pass undid `menuNeedsUpdate`'s `isEnabled = false` in all five hand-validated context menus, §8.5's `Quit Process` on PID 0/1 among them. Layer 2 held everywhere — nothing unsafe was reachable, and `actions.log` would have recorded `blocked-guardrail`. Fixed with `autoenablesItems = false` ×5; four new gate-12 assertions drive the real `NSMenuItem`s through `NSMenu.update()` and read **4 FAILED on the unfixed build**, PASS after; Processes gains its first gate-12 arm (9 of 12 panes now carry one; self-check 60 assertions plus the verdict line, 61 PASS lines). Same session, same build: the `Stop` footer was read live for the first time (`Sizing stopped at 56 of 137 items.`, rectangles kept), three strings that had outlived their milestone left the UI (§3.2's two tooltips, §10.1's footer sentence), and §3.2's tooltip appeared on screen for the first time — it had been suppressed since M01 by the row's own `.allowsHitTesting(false)`. | Connor, 2026-09-21: "fix whatever and get this project finished" |
| 2026-09-08 | §14.11 | **Phase-17 closed — the signed, notarized, stapled DMG shipped; the release itself stays Connor's.** `scripts/make-dmg.sh` and `make dmg` (1.1) stage `build/GlowTop.app` beside an `/Applications` symlink and build a UDZO image, refusing on an unverified bundle and reading the version from the bundle's own `Info.plist`; the certificate-free run produced an ad-hoc `build/GlowTop-1.1.0.dmg` printing `make-dmg: UNSIGNED — no GLOWTOP_SIGN_IDENTITY; spctl not asserted` (D-21), whose quarantine-flagged copy read `rejected` (exit 3) — the honest fallback reading REL-05 exists for. Against phase-16's stapled `build/GlowTop.app`, the same script with `GLOWTOP_SIGN_IDENTITY` set (2.1) signed the image, notarized it (`id: ffb28986-b4ca-4d6e-a5e4-b9044aa1ae98`, `status: Accepted`), stapled it, and `spctl --assess -vv --type open --context context:primary-signature` read `accepted` / `source=Notarized Developer ID`; a quarantine-flagged copy of the signed image mounted and its app read `accepted` on `spctl --assess --type execute` and launched with no Gatekeeper dialog (screenshot), reversing 1.1's `rejected` baseline. `build/GlowTop-1.1.0.dmg.sha256` verifies (`shasum -a 256 -c` → `OK`). `README.md` was rewritten for a reader who did not build the app (D-19, the M01 `## Status` block deleted rather than corrected), `docs/DEVOPS-HANDOFF.md:41` gained one sentence (D-20), and `docs/release-notes-v1.1.0.md` was written from `MILESTONES.md`'s v1.1 entry (D-17). **The release itself is Connor's**: `gh repo create`, `git remote add`, `git push`, the `v1.1.0` tag and `gh release create` are written verbatim in `phase-17-PLAN.md` with their directory and run by nobody but him — `git remote -v` read empty at every commit this phase made. **The release tag is `v1.1.0` at M03's merged tip** (D-16), the commit the shipped image was built from; `v1.1` stays on M02's close (`d41b2a5`, `Info.plist` `0.1.0`), unmoved. Gates 1, 2, 4, 5, 6, 11, 12, 13 re-read clean (0 build warnings, 404 tests / 1 pre-existing skip / 0 failures, `selfcheck: PASS`, `git diff --stat main..HEAD -- Sources/ Package.swift` empty); gates 3, 7 stand on phase-16's wave-2 readings and gates 8, 9, 10 on phase-14's, restated rather than re-run (REG-01, REG-02). **No threshold changed; no recorded reading in §13.1 is edited.** One correction carried in this same close: six stale references to the old placeholder repository owner (`SPEC.md`, `PROJECT.md`, `ROADMAP.md`, `phase-17-PLAN.md`, `phase-17-CONTEXT.md` ×2) corrected to Connor's own account per his ruling 2026-09-08 that the repository is not a placeholder (the public repository moved to `UsernameTron/glowtop` on 2026-09-21, §14.11). | phase-17 execution (2.1–2.2, wave 2) |
| 2026-09-08 | §2.3, §2.8 | **Phase-16 closed — the Developer ID run shipped and §13.6's two signing rows carry a live reading.** `GLOWTOP_SIGN_IDENTITY="Developer ID Application: Christopher Connor (G7FX8CR43U)"` signed, notarized (`id: 69ecdf4d-f50a-4bed-bc61-043ead5b45a7`, `status: Accepted`), stapled and installed; the installed copy reads `Authority=Developer ID Application: Christopher Connor (G7FX8CR43U)`, `TeamIdentifier=G7FX8CR43U`, `flags=0x10000(runtime)`, no entitlement beyond `Executable=`, `spctl` `accepted`/`source=Notarized Developer ID`, `stapler validate` exit 0 — against §14.11's baseline `rejected` (exit 3). D-07's proof: the signed bundle opened with no flag showed every private tile live (CPU, CLOCK, TEMP, GPU, GPU 0, NPU 0, THERMALS, ENERGY all numeric, status bar `Native providers healthy`), `log show`'s library-validation count 0. Gate 3 (30 min, `GLOWTOP_DISABLE_PRIVATE=1`) read the private tiles correctly unavailable with public data (CPU, memory, disk, network, process) intact; gate 7 (10 min `lsof`) read 0 network rows from the app. §2.3's hardened-runtime paragraph and §2.8's M03 paragraph are trued up to this built state. Gates 1, 2, 4, 6, 11, 12, 13 re-read clean; gates 8, 9, 10 stand on phase-14's readings because `git diff --stat main..HEAD -- Sources/ Package.swift scripts/overhead-harness.sh` prints nothing. **No threshold changes; no recorded reading in §13.1 is edited.** One instrument correction, not a code change: the plan's own detection check for the `glowtop-notary` profile (`security find-generic-password -s com.apple.gke.notary.tool -a glowtop-notary`) reads exit 44 on this Xcode/macOS pairing even though the profile is valid — confirmed by `xcrun notarytool history --keychain-profile glowtop-notary` (exit 0) against a deliberately-nonexistent profile name (exit 69, distinct error). Recorded in `phase-16-PLAN.md`'s own record rather than treated as a blocker, since the real submission then succeeded. | phase-16 execution (2.1–2.3, wave 2) |
| 2026-09-08 | §13.6 | **§13.6 gains phase-16's two signing cross-check rows, owed by §14.11's own paragraph saying they land with this plan.** The first checks `codesign -dv --verbose=2` and `codesign -d --entitlements -` against the signed installed bundle, five fields exact (`Authority=`, `TeamIdentifier=`, `flags=0x10000(runtime)`, and the entitlements print reduced to nothing beyond the `Executable=` line, per F-7 — it always prints that line, so "empty" means output minus that line, not literally empty). The second checks `spctl --assess -vv --type execute` and `xcrun stapler validate` against §14.11's recorded pre-signing baseline (`rejected`, exit 3): both are value checks, exact, because `spctl` is the same assessor Gatekeeper itself runs at the same instant against the same ticket, §13.6.1's own criterion for a value check over a direction check. No threshold changes; no recorded reading in §13.1 is edited. | phase-16 planning (SPEC first, gate 13; wave 1, sub-step 1.1) |
| 2026-09-08 | §2.3, §2.8, §14.7, §14.8, **new §14.11** | **§14.11 is written before M03 is planned — the signed, shareable build specified from a measured baseline, not from the one sentence §2.8 carried.** The recon, all read-only on the reference Mac: the installed bundle is `Signature=adhoc`, `flags=0x2(adhoc)`, `TeamIdentifier=not set`, no entitlements; `spctl --assess -vv --type execute` prints **`rejected`** (exit 3); `security find-identity -v -p codesigning` prints **`0 valid identities found`**; `security find-generic-password -s com.apple.gke.notary.tool -a glowtop-notary` finds no profile (exit 44); `notarytool` 1.1.2 and `stapler` are present under Xcode 26.6; `main` is `e05d59e` with no `v1.1` tag yet and `Info.plist` reading `0.1.0`. What the section now states, each with its alternative recorded in `phase-16-CONTEXT.md` / `phase-17-CONTEXT.md`: **the identity is selected by `GLOWTOP_SIGN_IDENTITY`** and the unset path is byte-for-byte today's ad-hoc signing, so every gate instrument keeps its control; **`--options runtime --timestamp` with no entitlements file**, because the hardened runtime's five restriction classes are each unneeded here and the one thing that could have needed an exception — the `dlopen` of `libIOReport.dylib` and `IOKit` — is a load of Apple platform binaries that library validation admits by construction (`com.apple.security.cs.disable-library-validation` is not needed and is refused as a first response to a `—` tile); **the app is notarized as a `ditto` zip and stapled in phase-16, the DMG signed, notarized and stapled again in phase-17** — two submissions, because the app's ticket is what a dragged-out copy validates offline and the image's is what a quarantined download is assessed by; **gates 3, 7 and 12 are re-read once from the signed bundle and gates 8/9/10 stand on phase-14's readings** because `Sources/` and `Package.swift` do not change; **§13.6 gains two value-check rows** (the `codesign -dv` fields, the `spctl`/`stapler` verdict); **`Info.plist` moves to `1.1.0`/`2` before the signed build**; **the release tag is `v1.1.0` at M03's merged tip**, the commit the DMG is built from, leaving `v1.1` on M02's close; **every remote step is Connor's**, written verbatim in the plan, `git remote -v` empty at every session commit; and **the fallback** is the same two scripts with no identity, an `UNSIGNED` banner and the README's right-click-Open section. Two corrections to the roadmap's Stage 3 as written: notarization is not one step but two artifacts, and the `v1.1` tag cannot be the release's tag because its commit predates the version bump and the scripts. §2.3's hardened-runtime paragraph and §2.8's M03 line point here; §14.7 records where the outline lived; §14.8's two `SHIP` rows become SIGN-01..05 / phase-16 and REL-01..05 / phase-17. No threshold changes; no recorded reading in §13.1 is edited; §13.6's rows land with phase-16's plan. | M03 discussion (SPEC first, gate 13; Connor's rulings 2026-09-08 — he is enrolled in the Apple Developer Program as of that evening, the deliverable is a notarized DMG on a GitHub release, the remote only on his go, no credential in a session's hands) |
| 2026-09-08 | §10.3, §12.3, §14.8 | **Phase-14 closed (screen-independent half, 5.1a) — Startup Apps and Services gain their write path.** `LaunchdOverrides` reads the override store so the Enabled column survives a `Disable` (§10.2 no longer lies once launchd's own store diverges from the plist's `Disabled` key); `JobActions` ships the four verbs, the two-line poll, the guardrail and the log exactly as §14.4 states them; `JobActionSheet` patterns §8.5's shape (D-02); both panes gained `Enable`/`Disable` and `Start`/`Stop` with both guardrail layers (D-03); `glowtop-probe job` is the REG-02 instrument. **The built system matches §14.4's text with no divergence found** — every verb's argv, every measured exit code, the poll's one-tab contract, the closed `result=` vocabulary, the deny-list's four entries, and the sheet's locked strings all shipped as §14.4 specifies. §10.3 and §12.3 each gain one sentence pointing here. §14.8's row for ACT-01..07 / phase-14 stands unchanged. §10.3, §12.3, §14.8 and §14.9 revised. No threshold changes; no recorded reading in §13.1 is edited. | phase-14 execution (record, 5.1a) |
| 2026-09-08 | §13.6 | **§13.6 gains the two write-action cross-check rows the §14.4 amendment below owed it** — that row's own closing sentence said §8.5, §10, §12, §13.6 and §13.7 were not edited, and phase-14 planning found the debt rather than assuming it away (F-2). The first new row checks the Startup Apps Enabled column against the override store `/var/db/com.apple.xpc.launchd/disabled.<uid>.plist`, per label, against the pane; the second checks the observed post-action state — `glowtop-probe job <verb> com.glowtop.phase14-test`, the throwaway agent only, never a live label — against `launchctl print`'s exit status and its `pid =` line at the same instant, over the five-step D-13 sequence. On the reference Mac the store's four disabled labels are all `com.apple.*` and none is on the Startup Apps pane, so the first row's live content is an agreement check on enabled labels only; the disagreement direction is exercised by the throwaway agent's own `disable`, not by a live row. No threshold changes; no recorded reading in §13.1 is edited. | phase-14 planning (SPEC first, gate 13; wave 1, sub-step 1.1) |
| 2026-09-08 | §14.4, §14.8 | **§14.4 is expanded in place before the phase is planned — the privilege boundary ROADMAP phase-14 criterion 2 requires, measured rather than asserted (criterion 1).** Three throwaway passes against `com.glowtop.phase14-test` (`/bin/sleep 3600`, `RunAtLoad` false, `KeepAlive` false, pre-authorised by Connor 2026-09-08) in `gui/501`, then torn down and proved gone, established what the section now states: **`gui/<uid>` is writable without root** (six verbs, all exit 0) and **`system/` is not** (`bootout system/com.example.daemon` → `Boot-out failed: 1: Operation not permitted`, exit 1, daemon untouched — not retried with `sudo`); **`enable`/`disable` are override edits, not load/unload** — `enable` on an unloaded plist loads nothing, `disable` on a loaded job leaves it loaded and a running instance running with its PID unchanged and still `kickstart`-able, only the next `bootstrap` refused (exit 5); **`bootout` of a running instance terminates and unloads in one call**; **`bootstrap` exits 5 for both "disabled" and "already loaded"**, so the pre-check is `print`'s exit status (0 / 113), never a second `bootstrap`; **`state = xpcproxy` shows transiently after `kickstart`**, so `started` keys on `pid =`; and **the override store `/var/db/com.apple.xpc.launchd/disabled.<uid>.plist` is a world-readable flat `label → Bool` plist**, which replaces the plist `Disabled` key as the Enabled column's source — `launchctl disable` never touches the plist, and this is the first phase whose own action would have made that column lie. Also recorded: 6 of this Mac's 22 user agents are not loaded at all (the not-loaded case is common, not an edge), and its two Google Keystone plists are empty dictionaries with no `Label` (a guardrail case, not a hypothetical). §14.4 now carries the verb table with exact argv, the measured exit codes, the poll's two-line contract, the extended `result=` vocabulary (`enabled`/`disabled`/`started`/`stopped`/`blocked-guardrail`/`failed:<code>`/`failed:timeout`), the deny-list, and the sheet. `Launch Agent (system)` rows are ruled read-only for this phase as a scope choice, flagged for Connor in `phase-14-CONTEXT.md`. §14.8's row reads ACT-01..07 / phase-14. §8.5, §10, §12, §13.6 and §13.7 are not edited; no threshold changes; no recorded reading is edited. | phase-14 planning (SPEC first, gate 13; ROADMAP phase-14 criteria 1 and 2) |
| 2026-09-08 | §14.6 | **The treemap is laid out by allocated bytes, not apparent — a stated requirement reversed by measurement, recorded rather than quietly rewritten.** DISK-03 and the roadmap's phase-13 criterion 4 both specified apparent (logical) sizes; both are amended in place, and both amendments name this row. The reason is that a treemap's rectangle **is** its number — an area is not a cell a reader can discount — and apparent bytes produce a structurally wrong map on the reference machine, not merely an imprecise one: `~/Library/Containers/com.docker.docker` reads 1 099 589 118 849 B apparent against 5 186 609 152 B allocated (**212×**, one sparse disk image) and would be drawn as most of the home directory while occupying about one percent of the volume; cloud-evicted iCloud and OneDrive placeholders report full logical size at **0 B** on disk (one file 23 802 958 224 B apparent, 0 B allocated) and would be drawn as the largest objects on the machine; and the home directory's children total 1 572 493 980 724 B — **1.57 TB apparent on a 494 GB disk**, 3.2× the volume containing them. The pane keeps reading `.totalFileSizeKey` alongside `.totalFileAllocatedSizeKey` — established the same day as **not separably** more expensive (§13.7.1) — and shows the apparent figure in the selected node's readout, so nothing is lost but the layout key. DISK-03's one-line disclosure survives with its **sense flipped**: it no longer defends apparent as the layout key, it explains the gap the layout key hides, and it stays computed because the gap runs both ways (`/Applications` apparent exceeds allocated by 24 %, `~/Documents` allocated exceeds apparent by 3 % from 4 KB rounding over 183 063 files). The pane now agrees with §14.3, which sizes bundles by the same key for its own reason. Unchanged by the ruling and restated: **neither key reconciles to the volume's used space**, and the `statfs` volume bar remains the only reconcilable used-figure in the pane. Also ruled the same day: **the offered default root is the home directory**, not the volume root — 386.6 GB of the 494 GB container is on the Data volume while `/` proper is 16.2 GB and SIP-sealed, and the home directory bounds the first walk at a measured 73 s; any volume or directory can still be made the root. | Connor, ruled 2026-09-08 on the phase-13 discussion's flagged decisions (`phase-13-CONTEXT.md` D-11, D-14, D-16; measurements in its evidence block) |
| 2026-09-08 | §3.2, §3.4, §3.5, §5.10, §13.6, §14.6, §14.8 | **§14.6 is expanded in place before the phase is planned — the cost note DISK-05 requires, which this section did not have while §14.3 did.** The three things the note owes are now stated with the measurements behind them, all taken 2026-09-08 on the reference machine: **scan strategy** — nothing walks on open, a drill-down sizes exactly one level's children and discards every subtotal beneath them, for a memory reason (`/System/Volumes/Data` carries 4.9 M inodes against §13.7's 210 MB cap, and §14.3's much smaller scan already costs +252 MB), at the price of a re-walk on descent that measures 6.03 s cold and 1.78–1.81 s warm on `/Applications`; **scope limit** — a rectangle's area is its child's recursive size, so sizing one level *is* a full walk of that subtree by arithmetic (sizing the home directory's 32 children walked 2 799 301 entries in 73.07 s cold), and "never a whole-volume walk up front" is honoured by *when* rather than by how much, with the label saying what a walk is about to do before it starts; and **which size number** — written here as apparent per DISK-03, and **reversed to allocated the same day by the row above** once the 212× sparse case was weighed against the fact that a treemap's rectangle *is* its number; both keys are read either way, at no separable cost (§13.7.1). Two consequences are recorded rather than left implicit: **neither key reconciles to `df`'s used space**, which is why no such claim is made and the `statfs` volume bar is the pane's only reconcilable used-figure; and **DISK-03's disclosure line is a computed statement rather than boilerplate**, because the gap it describes runs both ways — `~/Library/Containers/com.docker.docker` 1.10 TB apparent against 5.19 GB allocated (212×), cloud-evicted placeholders at 0 B on disk, the home directory's children at 1.57 TB on a 494 GB volume, against `~/Documents` where allocated exceeds apparent by 3 % from 4 KB rounding over 183 063 files. Also here: `.skipHiddenVolumes` is specified rather than left to taste (unfiltered, this Mac reports fourteen volumes of which four share one 494 GB container total, so summing them triple-counts the disk); `volumeAvailableCapacity` is `Free` and the 12.0 GB purgeable gap against Finder's figure is named in a clause; the pane is read-only and outside §4.7 (§5.10's new row); §3.2's `PRO` paragraph, §3.4's menu row and paragraph, and §3.5's key table take **⌘D** — the first pane bound to a letter, the digits having run out at ⌘0; §13.6 gains seven cross-check rows with their tolerances before any code exists; §14.8's row reads DISK-01..05 / phase-13. §5.0.5 is not edited (this pane's failures are `FileManager` errors, not `kern_return_t`s), no threshold in §13.7 changes, and no recorded reading in §13.1 is edited. | phase-13 planning (SPEC first, gate 13; ROADMAP phase-13 criterion 1) |
| 2026-09-08 | §13.6, §14.6 | **Phase-13 closed (screen-independent half, 5.3a) — two wrong illustrative numbers corrected, both found by building the thing the section specifies rather than by review.** §14.6's disclosure paragraph cited `~/Documents` (3 812 725 259 B apparent / 3 925 614 592 B allocated) as its "allocated larger" worked example, but that pair is a 2.96 % gap — under the paragraph's own >10 % threshold, so it renders as the third disclosure form, not the second, and never illustrated the case it was cited for; 3.1 caught this while writing the fixture and shipped a scaled synthetic pair (3 000 000 000 / 3 500 000 000, 16.7 %) instead, kept the 10 % threshold as ruled (D-15), and the paragraph now says so. §13.6's browsable-volume-count row (`ls -1 /Volumes \| wc -l` plus the root) also reads wrong on this Mac — `/Volumes/Macintosh HD` is a symlink to `/`, so the literal command reads `2` against a correct `1` (F-9) — corrected to the instrument 2.3 actually ran and recorded. Neither correction changes any shipped code or threshold. | phase-13 execution (record, 5.3a) |
| 2026-09-08 | §13.6, §14.6 | **Phase-13's screen-dependent close (5.3b) found two reader defects by driving a `/` drill live; both fixed in one commit with the §14.6 sentence.** (1) A volume root beneath the node was walked: `/.nofollow` (a root-level alias of `/` on macOS 26) and `/System/Volumes/Data` each re-walk the whole disk, so a `/` drill ran minutes at 2.5 GB RSS and its rectangles double-counted. The reader now stops at any directory whose `isVolume` reads true — the `du -x` rule — and reads a top-level entry with the same key set as the recursion, because `isVolume` answers false for `/.nofollow` through a three-key `resourceValues` call and true through the full set (a Foundation quirk, recorded). (2) No autorelease drain inside the walk: `~`'s 2.8 M entries held 2 032 MB in the reader alone; one pool per directory brings it to 102 MB, and the hard-link set now admits only `linkCount > 1` files. Two §13.6 rows added. The allocated totals are unchanged — `~` against `du -k` 0.02 %, `/System`'s children exact. No threshold in §13.7 changes; no recorded reading in §13.1 is edited. | phase-13 execution (5.3b) |
| 2026-09-09 | §13.7 | **Gate 11's permitted-write list did not describe the app it gates.** It named `~/Library/Logs/GlowTop/` and `~/Applications/GlowTop.app` only, while the app has written its own preferences domain `~/Library/Preferences/com.glowtop.GlowTop.plist` through `UserDefaults` since phase-05 — theme selection and edited colours (§7.4), column widths (§8.2) — writes those sections themselves **require**. The gate has passed at every close since with that path uncovered, so the list was wrong rather than the code: it is corrected here to name the preferences domain, and the sentence about gate 12's scratch domains being held in memory (phase-08's fix) is stated alongside it so the two are not confused. No threshold changes and no recorded reading is edited. Found by the `/gsd:confidence` quality sweep, 2026-09-09, not by review. | confidence sweep (leg 2, warning 1) |
| 2026-09-04 | §13.6, §14.1 | **Phase-11 closed (screen-independent half, 5.2a) — two §13.6 rows and one §14.1 sentence.** §13.6 gains the two direction checks REG-02 was re-closed with (D-26), both run and recorded in `phase-11-PLAN.md`'s `## Cross-checks (recorded)`: per-cluster frequency under `--load` — P0 and P1 loaded medians **4512.0 MHz = 100 % of their 4512 maximum, PASS**; the E cluster's loaded median **2592.0 MHz = 100 % of its 2592 maximum**, rest median the same, so the "below its maximum by more than 10 %" criterion is **not met, recorded FAIL and not re-run** (the same run shows the E cluster in its top state `V6P0` for 100 % of its active time under load and 78.7 % at rest, 16.9 % `IDLE`: §5.9.1's active-state mean reads the top state whenever the cluster is active on this Mac) — and DRAM watts under a memory-bandwidth load, **rest 0.1 W → loaded 1.9 W → rest 0.1 W (n = 28 / 34 / 28), PASS**. §14.1 gains one sentence stating what shipped: the pane view lays out at most **three** column layer sets (`PowerFreqPaneView.columnCount`), while the provider, model and probe carry every cluster. Everything else in §14.1 shipped as written — the card height measured 260.0 pt at 1440 × 900 and 204.0 at 1100 × 700, D-11's per-column unavailable did **not** fire live (`voltage-states1-sram` decodes to 7 entries and pairs with the E cluster's 7 active states), and the E-cluster table the outline treated as uncertain exists on this Mac. | phase-11 execution (record, 5.2a) |
| 2026-09-04 | §3.2, §3.4, §3.5, §5.10, §13.6, §14.3, §14.5, §14.8 | **§14.5 and §14.3 are expanded in place before their panes are built.** §14.3's outline named `/System/Applications` as a third root and 'minimum system version' as a seventh column; neither survives into the implemented section — APPS-01/APPS-02 name two roots and six columns, `/System/Applications`'s bundles cannot be reclaimed by a size-sorted pane (nothing there is deletable), and the root is the one Pitfall 11 names for inconsistent TCC exposure. Both drops are recorded here rather than silently absent. | phase-12 planning (SPEC first, gate 13) |
| 2026-09-03 | §3.2, §3.4, §5.6.3, §5.9, §6.4, §14.1, §14.8 | **§14.1 is expanded in place before the pane is built, and one premise it rested on is corrected.** The ROADMAP's phase-11 criterion 2 and PWR-03 said the ANE channel had been dropped for want of an IOReport group; the 2026-09-03 channel dump (`glowtop-probe channels`, 10 427 channels, Mac16,7 / macOS 26.6.1) shows `Energy Model` carrying exact-name `CPU Energy`, `GPU`, `ANE` **and** `DRAM`, all `mJ`. What §5.6.4 records as absent is an ANE **residency** channel, not the ANE **energy** channel — which `EnergyProvider` has read as `aneWatts` since phase-03.1 and which was confirmed live under a Vision load (rest ≈ 0.001 W, loaded ≈ 2.37 W). §14.1's four-channel split therefore stands as written and is now marked confirmed rather than assumed. §14.1 gains its outline in §14.10's shape — three stacked full-width cards at equal thirds (frequency residency as one cumulative band per DVFS state with the cluster's average-frequency line on a per-column right axis, a DVFS histogram over §6.4's 60 s window, package power as four stacked bands with the 24 pt total), cluster identity and column order fixed at P0, P1, E from the `CPU Complex Performance States` channel list with the `*CPM*` channels excluded, the geometry fixed by the phase plan (12 pt gutter, `25 + rank/(N−1)×75` opacity ramp, 8 % idle band, 2 pt bar gap, 4 pt bar floor, 5 W axis floor, `(paneHeight − 32 − 24) / 3` per card), §4.8's states plus a per-column unavailable. §14.8's row reads PWR-01..05 / phase-11; §3.2's `PRO` paragraph and §3.4's View menu gain a sentence each and the menu gains the ⌘8 item; §5.6.3 gains `DRAM` as a fourth exact-name channel, drawn on §14.1's pane and excluded from the Energy tile's sum; §5.9.1 gains the per-cluster output and its by-kind, length-validated table pairing; §6.4 gains three buffer rows. §5.0.5 is not edited (its `"key not present"` already names the per-column condition), no threshold in §13.7 changes, and no recorded reading in §13.1 is edited. | phase-11 planning (SPEC first, gate 13) |
| 2026-09-02 | §14.10 | **Phase-10 closed — the Performance pane shipped on `ChartLayer`, and §14.10's one moved number is corrected.** The grid's cell width at the default window is 121.8 pt, not the 110.6 the outline derived from §3.2's 260 pt sidebar — the built sidebar measures ≈148 pt (a finding in the phase record; §3.2 is not amended here). Everything else in the outline shipped as written: three cards in one `CardChrome`, the cluster-grouped grid of `MeterLayer` cells with per-cell index and percentage, §4.4's two CPU series with no thermal axis, §4.5's stack at card height, one display link per visible pane, §4.8's states verified offscreen (five new gate-12 assertions, broken once first) and live for 30 minutes under gate 3's flag on this pane. No chart path was written; `ChartLayer.swift`, `MeterLayer.swift` and every script are untouched; `Sources/GlowTopCore/` changed by one enum case and one appended subset projection. Gates: gate 8 fps 120.00 (spread 1.00), separably above 114.0; gate 9 app 8.63 % (2.70) and PERF-02 rss 111.60 MB (3.40), both separably under their caps and neither separably different from phase-09's 10.03 % / 110.00 MB; gate 3 thirty minutes on the new pane under the flag at fps 120.00; gate 7 60 samples, 0 rows; gate 10 RSS −9.10 % over 30 min; gates 1, 2, 4 (292 tests), 5, 6, 11, 12 (thirteen assertions), 13 PASS. Arm B (fps 120.00 / 120.00, app 9.08 / 8.00 %, rss 105.30 / 106.20 MB over two clean rounds; three rounds void on a window that landed occluded after the launch move) is documented, not gated (§13.1.9). Three of arm B's five rounds voided on a window that landed occluded on screen 0 after the launch move — §6.2 pausing the link, diagnosed and recorded, not a defect. | phase-10 execution (record) |
| 2026-09-02 | §3.2, §3.4, §14.10 | **The Performance pane is specified before it is built.** §14.10 gains its outline — three stacked cards (per-core grid grouped by cluster with per-cell index and percentage, CPU history with §4.4's two CPU series and no thermal axis, memory history as §4.5's timeline at card height), the geometry fixed by the phase plan (48 pt minimum cell, 2 pt gutter, 157 pt card at 14 cores), §4.8's states, one display link; §3.2's row leaves the `PRO` block for second position and §3.4's View menu gains the ⌘2 item. The heading and §14.8's row landed first in `c7ff6a6` so gate 13 bracketed the outline. | phase-10 planning (SPEC first, gate 13) |
| 2026-09-02 | §6.5, §6.9, §13.1 (budget table), **new §13.1.13**, §13.7 gate 8, §14.8 | **The charts moved to the compositor, and gate 8 is met for the first time.** §6.5's "charts stay on the CPU" mandate is amended in its own established form: it was written before its measurement, phase-05's profile contradicted it (§13.1.11), and phase-09 measured the replacement — a `CAShapeLayer`/`CAGradientLayer` path, one `ChartLayer` container per plot rect, paths assigned on data and scroll ticks in disabled transactions, colour resolved once per theme change, one clock. New §13.1.13 records the spike: both paths in one binary, three 60 s rounds per arm interleaved on the unedited harness with a five-condition void rule and a decision rule committed before any reading; CoreGraphics **104.20 fps (spread 8.40, 86.8 %)**, composited **120.00 (spread 0.00, 100.0 %)**, `app` 25.37 → 9.97 %, `rss` 202.6 → 109.8 MB; pixel parity on the fixed §5.10 fixture at `maxdelta` ≤ 3 on all eight plot rects after gate 12's capture was found to be rasterizing the two paths at different scales and corrected; RENDER-06's ΔWS −3.10 visible / −0.15 minimized beside gate 9's 10.03 %. **One instrument finding, recorded and not applied:** the CoreGraphics control's 8.40 fps spread exceeds the 6.00 fps resolvability threshold the plan fixed in advance, so a sub-1 fps question cannot be answered on that path with three 60 s rounds — a longer window and more rounds are proposed for the day a reading needs it. §6.9's three chart rows read `CAShapeLayer` instead of `CPU draw(_:)`; the budget table's frame-rate row and gate 8's entry point at §13.1.13; §14.8 gains rows for RENDER-02..06, all SATISFIED. **The 95 % threshold is unchanged. No recorded reading in §13.1.2–§13.1.12 was edited.** | phase-09 execution (record) |
| 2026-09-01 | §3.3 | **§3.3's retention sentence corrected to what phase-08 shipped.** The normative paragraph still said panes are retained after selection, while `PaneHostView.show(_:)` has released the outgoing controller since phase-08's lever (§13.1.12) — the change was recorded in §13.1.12 and §14.8 but the section that specifies the behaviour was left contradicting the code, the same document-consistency shape the 2026-08-28 audit logged for §13.1. Found by the M01 close re-audit's integration check. No cap, gate, or requirement scope changes. | M01 close |
| 2026-09-01 | §5.2.2, §5.2.3 | **MemoryProvider's composition refused whenever purgeable memory exceeded the firmware carve-out.** Every raw field matched `vm_stat` one-to-one; the defect was the shape of the sum — `purgeable_count` was added as a fourth pool when `internal + external == active + inactive + speculative` exactly, so those pages were counted twice and the only headroom was the ~0.69 GiB `hw.memsize` counts and `vm_statistics64` never reports. Reclaimable is now `inactive + speculative`; purgeable stays in the payload, unsummed; the formula block also now states the `free_count − speculative_count` subtraction the code had carried since phase-02. The refuse-rather-than-fabricate guard is unchanged. A fixture test with purgeable above the carve-out fails on the old sum. | M01 close |
| 2026-09-01 | §13.1 (budget table), §13.1.12, §13.7 gate 9, §14.8 | **PERF-02's cap and scope ruled, and PERF-02 is satisfied for the first time.** Connor took **option 1** on the cap and **option A** on the scope, ruled independently. The cap is raised **120 MB → 210 MB**, derived exactly as §13.1.11 derived gate 9's 35 %: the highest median across phase-08's three independent readings (202.50) plus one full spread (4.40) = 206.90, rounded. `ps -o rss=` is retained as the instrument, so every RSS reading already in the record stays comparable — **option 3, switching to `phys_footprint`, was declined for exactly that reason** and is kept in §13.1.12 as the record of what was chosen over what, along with its measured 65–79 MB justification. The scope closes §13.1.10's defect one requirement over: PERF-02 named **no window size and no pane state**, and is now evaluated **Summary-only at 1440×900** on the same arm and instrument as gate 9, with the **seven-pane steady state (295.60 MB) recorded as documented-not-gated** — §13.1's own treatment of the whole-system idle-CPU row. **Verdict under the ruled cap: 202.40 MB (spread 0.70) against 210 MB, margin 7.60 = 10.9× the spread — separably under. PERF-02 SATISFIED.** The budget table gains the documented multi-pane row; gate 9's RSS half names the new cap and its scope. **No recorded reading in §13.1.2–§13.1.12 was edited.** | Connor, ruled 2026-09-01 |
| 2026-08-31 | §13.1 (budget table), **new §13.1.12**, §14.8 | **Phase-08 measured PERF-02 instead of arguing about it, and the 120 MB limit is untouched.** New §13.1.12 records the first allocation profile this project has ever taken: a 2×2 of `footprint`/`vmmap`/`heap` at two window sizes and two pane states, with five predictions and their kill conditions committed before the first reading. `CoreAnimation` is **72 % of the gated arm's footprint** and decomposes into **3.34 full-window compositor buffers plus 33.0 MB** of the per-layer surface set §4.4 specifies — which is why it tops the ranking and is still not a lever. The eight `RingBuffer` histories total **under 1 MB**, and the largest single allocation of any class is **352 KB**. One lever was kept: releasing the outgoing pane controller in `PaneHostView.show(_:)` instead of retaining it measured **−49.60 MB** on the seven-pane arm against a 1.50 spread, with no regression anywhere. It also showed that **§3.3's stated rationale overstates what retention buys** — delta baselines live in `MetricStore`, not in pane controllers, so only switch-back latency was ever traded. A second slot was left **empty** under the stopping rule. The floor is **202.40 MB** (spread 0.70) against 120 MB — **FAILS separably, 118× the spread** — and the architecture's lower bound was measured for the first time: **an empty SwiftUI window costs 80.90 MB**, leaving 39.10 MB for everything the app is. `ps -o rss=` and `phys_footprint` were measured to differ by **65–79 MB** of unmappable shared pages. §13.1.12 carries **two proposals — a cap and a scope — both awaiting a ruling and neither applied**; the budget table's limit cell is unchanged and gains only a pointer. | phase-08 execution (record) |
| 2026-08-31 | §9.2, §13.1 (budget table), §13.1.1, §6.9, §6.2, §3.3, §6.7, §13.7 gate 8, §14.8 | **Three rulings applied and two wording drifts closed.** §9.2's Frame rate row stops claiming to be current: it publishes Summary's **last** §6.7 reading labelled with its age (`99.9 fps · Summary, 14 s ago`), because §6.2 invalidates Summary's display link the moment this pane is showing and no live rate exists anywhere in the process — keeping a link alive on a hidden pane is precisely the cost §6.2 exists to avoid, and a stale number presented as current would be §4.8's violation. §13.1's budget table demotes the whole-system idle-CPU row to **documented, not gated** (M01.5 established in §13.1.9 that whole-system cost is not resolvable to gate precision on this hardware) and gains the **app-process row at ≤ 35 %** of one core that is actually gated (scope §13.1.10, derivation §13.1.11); the demoted row stays so the table still explains itself. §13.1.1 gains a scope paragraph saying the same, and explicitly leaves the `3.0 %` in its worked example as the historical figure the readings in §13.1.2–§13.1.9 were taken against — those records are not edited to match a later cap. §6.9's cost ceiling is brought into line (`≤ 3 %` whole system → `≤ 35 %` of one core, app process). §13.1's `Frame rate (Summary pane)` row takes gate 8's **≥ 95 % of the display's own refresh**, and gate 8 states that it governs **RENDER-02** — whose original ≥ 55 fps assumed a 60 Hz panel and predates gate 8's phase-01 rewrite; RENDER-02 is **unmet** (83.3–85.9 %) and carried to M02, recorded in §14.8. Two wording drifts phase-06 found and deliberately left for this commit: §6.2 and §13.1's occlusion rows named `NSApplication.occlusionState` where the code observes `NSWindow.didChangeOcclusionStateNotification` filtered to the app's window, and §3.3 said nothing about occlusion reaching the visible pane at all — it now states the hook and its no-op default. §6.7's opening sentence said "frames actually drawn", contradicting the paragraph directly beneath it that defines `fps` as ticks serviced and `draws` as ticks that produced pixels; it now names both. | Connor, ruled 2026-08-28; phase-07 execution (record) |
| 2026-08-27 | §3.2, §3.4, §7.2, §7.3, §7.4, §7.5, §12.1, §13.1 (new §13.1.11), §13.5, §13.7 gate 11, §2.8, §14.8 | **Phase-05 closed — the theme system shipped, gate 9 measured honestly for the first time, and the app packaged to `~/Applications`.** §3.2's long-open Performance-pane question is ruled: M02 owns it, the row moves into the `PRO` block disabled, ⌘2 stays reserved; §3.4 states the View menu's absence to match. §7.2 gains a third preset, **Amber Retro**, and a new token, `statusDegraded` — the status bar's 3+-unavailable colour had read through `accentThermal` for three phases, correct on screen and wrong in the model, because nothing could edit a token until this phase's editor shipped; the day it did, editing the Thermals accent would have silently repainted the status bar too. §7.3's rebuild-cost sentence is corrected to what was built: one invalidation of three caches as a unit (the resolved colour table, `MeterLayer`'s texture cache, the gradient cache), rebuilt lazily on the next draw, not a per-colour rebuild under 5 ms — the cost was not measured this phase and no figure is claimed. §7.4 states its two implied-but-unstated rules explicitly (an unknown preset name and a future schema version both yield Neon). §7.5 records the measured verdicts: `textTertiary`/`textDisabled` fail 4.5:1 against Neon's and Classic Green's own backgrounds (3.9:1/2.9:1, 3.7:1/2.3:1); Amber Retro's `textTertiary` was chosen to clear it (4.7:1), its `textDisabled` was not, on purpose (2.8:1). §12.1's correlation now resolves a job's `Program` through its symlinks before comparing, with the uniqueness guard counting resolved paths — the reference machine's own Homebrew-installed `redis` job went from `Unknown` (0/1 PID agreement with `launchctl`) to `Running` (1/1). Gate 11 (§13.7) names `~/Applications/GlowTop.app` as the packaging exception, written only by `scripts/package-app.sh`'s literal, assertion-guarded install path; §2.8 records the bundle as built (`com.glowtop.GlowTop`, `CFBundleExecutable` staying `GlowTopApp` because five gate instruments grep it, ad-hoc signed and verified). New §13.1.11 records the tuning campaign's honest result: a clean re-baseline (every prior reading was contaminated by a live agent session polling alongside it) measured **26.10 %** of one core, not the 18.40 % phase-04 recorded; the one structural lever tried (dirty-rect chart redraws) measured a −3.37-point effect that could not be separated from this environment's own run-to-run drift; a Time Profiler pass named no second lever — the top main-thread cost is CoreGraphics's own antialiased rasterization of exactly the geometry §4.4 specifies, not an inefficiency in this project's code; the floor came in at **29.70 %**, *higher* than the re-baseline, and gate 9 FAILed against the cap then in force. §13.1.11's cap-amendment proposal was **approved by Connor 2026-08-28 (option 1)**: gate 9's cap is raised 3.0 % → **35 %** of one core, derived as the highest of the phase's three medians (29.70 %) plus one full spread (5.15), fixed before the phase's final gate-9 reading was taken. PERF-02's 120 MB RSS cap is unchanged — not part of the approved proposal, no RSS lever attempted. §13.5 gains the phase-05 test floor (281 vs phase-04's 254). §14.8 gains the Performance/M02 row. | phase-05 execution |
| 2026-08-26 | §4.6.5, §8.5, §11.1, §10.1, §12.1, §9.2, §13.5, §13.6, §13.6.1 | **Phase-04 closed — two spec-versus-measurement corrections, both plausible-and-wrong in the way this project keeps finding before shipping them.** §11.1's `uid >= 500` filter admits `nobody` twice (`pw_uid` −2 through `uid_t` reads as `4294967294`, comfortably over the floor); the corrected filter is `500 <= uid < 0x7FFFFFFF` plus root, deduped on `(name, uid)` — measured on the reference machine as 266 raw entries, 4 passing the old filter, 3 real accounts. §8.5's own example line put a space before the `%` where §4.9's own rule (`4.2%`, no space) already governed it; the example is corrected, not the rule, and the closed `result=` vocabulary (`ok`/`blocked-guardrail`/`eperm`/`esrch`/`failed:<errno>`) plus the log's name-escaping rule are stated alongside it. Neither was found by review — both were found by building the thing the section specifies and comparing its output against the section's own text. Also this phase: §4.6.5 amended to headline-only per the locked decision (no chart, no §6.4 ring buffer); §10.1's login-items row corrected to name the BTM decode's outcome-B finding (a record with an identifier and no name, failing the section's own all-or-nothing rule); §12.1 gains the measured configured-vs-`launchctl` gap (30 against 531 labels, ratio ≈18×); §9.2 marks its two private-sourced rows; §13.5 gains the phase-04 floor (254 vs phase-03.1's 205); §13.6 gains the pane cross-check rows and §13.6.1 is widened to explain why they are value checks rather than direction checks. | phase-04 execution |
| 2026-08-26 | §13.7 gate 3, gate 8, gate 9, gate 10 | **Phase-03.1 closed; gate 3's flag half evaluated for the first time, and three regressions recorded, not tuned.** §13.7.3's blackout ran for a genuine 30 minutes (release build, screen 0, 120 Hz): the four private tiles stayed unavailable and the five public providers plus both sidecars kept reading throughout — the half of gate 3 phase-03 could not evaluate. In the same window, frame rate read **101.3 fps median against a 120 Hz display (84.4 %, below the 95 % floor)** and RSS **grew 18.3 % (167.6 → 198.3 MB)** — both against phase-03's clean PASSes (97.5 %, −33.8 %). Gate 9's overhead harness independently corroborates the frame-rate regression (102.2 fps median, same machine, private APIs live) and reads app CPU at **29.95 %** median against the 3.0 % cap, roughly double phase-03's already-failing 14.22 %. None of the three is tuned in response, per §14.8's rule; the phase record names the likely lever (the four newly-live tiles and the CPU chart's right axis redraw every sample now, where phase-03 held five permanently-`—` marks needing no redraw) and flags that this session's own continuous measurement activity is an uncontrolled confound phase-05 should re-run without. | phase-03.1 execution |
| 2026-08-26 | §5.0.5, §5.6.1, §5.6.3, §5.6.4, §5.6.7 (new), §4.3.3, §5.8.1, §13.5, §13.6, §14.8 | **Phase-03.1's amendments — the four private providers close out.** §5.0.5 gains `"private APIs disabled"` and corrects a drift: the code's own doc comment had diverged from this list (`"no readable sensor"` invented, three real reasons missing), fixed in the same commit as the string; `"provider not built"` confirmed retired with no call sites, as phase-03 predicted. §5.6.1 records that `/usr/lib/libIOReport.dylib` is dyld-shared-cache-only and why no `fileExists` precheck exists. §5.6.3 corrects "inferred from magnitude" — `IOReportChannelGetUnitLabel` states the unit in-band — and records the exact-name `GPU`/`GPU Energy` trap plus this phase's own IOPowerSources bound (package 0.51–1.30 W vs whole-system 11.70 W, ratio ≈ 17.6×, recorded rather than reinterpreted); the `powermetrics` constant stays an open blocker owned by Connor. §5.6.4 records IOReport's five actual groups on this Mac (no ANE group) and confirms path 2 fires, with Vision's inference verified landing on the ANE rather than the GPU. New §5.6.7 documents 1.4's outcome A: per-process GPU via `AGXDeviceUserClient`'s `AppUsage.accumulatedGPUTime`, PID-matched, nanosecond-confirmed; §4.3.3's GPU column text updated to match (real values for inspectable PIDs, `—` only for the ~40 % that refuse inspection, same as CPU/memory). §5.8.1 defers the SMC fallback as a stated decision (path 1 yields 52 sensors here) rather than a silent omission. §13.5 gains the phase-03.1 test floor (205 vs phase-03's 148). §13.6 gains eight cross-check rows and a new §13.6.1 explaining why they are direction checks, not value checks — no independent instrument runs unprivileged and continuously for any of these four providers. §14.8 gains rows for the force-unavailable flag and §5.6.7. | phase-03.1 execution |
| 2026-08-26 | §3.1, §13.7.12 | **Seven defects found by a visual review of the running pane; one spec note, six implementation fixes.** The screenshot-vs-§4 review (`phase-03-GAPS.md`) found every chart rendering beneath the opaque card chrome — `draws` read 10/s while nothing was visible — the CPU axis inverted by a `1 −` in the one mapping every chart shares, with the unit test asserting the inversion (§13.7.1's shape, in a test); headline text crossfading at 1 Hz; hex strings passed where §7.2 token names were wanted, leaving a fallback-colour glyph on the meters card; the process count styled as a 24 pt headline; and the two §4.1 arithmetic defects amended below. §3.1's title-bar row now names the mechanism: SwiftUI's `Window` scene re-asserts `titlebarAppearsTransparent` to false after any direct set, so the transparent strip is achieved with `.toolbarBackground(.hidden, for: .windowToolbar)` — under which SwiftUI sets the bit `true` itself, per the gate-9 geometry line. Gate 12 gains a pane arm: the Summary pane rendered offscreen over §5.10's construction, §4.8 asserted against pixels — five assertions, the fifth (chart pixels present in the CPU plot) being the one that would have caught the chrome defect; broken deliberately once before committing. | phase-03 execution |
| 2026-08-26 | §4.1, §4.5, §4.6.1, §5.0.5, §3.5, §13.5, §5.2.3, §14.8 | **Phase-03's planned amendments.** §4.1 names gaps-first column arithmetic — the ungapped ≈ 253 / 517 / 379 overflow the content width by 25 pt — and corrects its own total-height row: the printed terms add to 778, not 878, and a pane sized to the printed number carried 68 pt of dead space. §4.5's footer example tightened to §4.9's byte rule (`18.4` / `43.3`), and §5.2.3's prose quote of the same card brought along (`66.29` → `66.3` — §4.5 was corrected in phase-02, the prose quote was missed). §4.6.1's footer names the device count, not a volume: §5.3 sums every `IOBlockStorageDriver`, excludes `statfs`, and a volume name beside a multi-device total would be wrong rather than merely absent. `"provider not built"` joins §5.0.5's closed vocabulary, carried by §5.6–§5.9's marks until phase-03.1. §3.5's ⌘R row says delta providers re-warm and why. §13.5 gains the phase-03 floor; 148 tests shipped against phase-02's 93. §14.8 gains rows for §6.8's pause and read-only §7.2. | phase-03 execution |
| 2026-08-25 | §5.2.3, §5.2.4, §4.5, §13.6 | Memory is defined from named `vm_statistics64` fields summed in one function, not reverse-engineered from Activity Monitor. UI says "resident", not "used". Activity Monitor comparison downgraded from a ±1 GB tolerance test to a recorded observation. | Connor, phase-01 approval |
| 2026-08-25 | §12.1, §12.2 | Services pane is a "configured jobs" inventory built from plist directories and `SMAppService`; `launchctl` stdout parsing ruled out permanently. Coverage gap disclosed in a permanent on-pane footer. | Connor, phase-01 approval |
| 2026-08-25 | §2.9 | Reference machine memory corrected from 128 GB to 48 GB. The 128 GB figure was carried in from the TMOG screenshot used for §4.5's example values, not measured here. | phase-01 execution, `hw.memsize` |
| 2026-08-25 | §5.1.4, §4.3.2 | Per-core marks carry a P/E cluster caption in M01. Undifferentiated bars misreport load on asymmetric hardware; visual grouping stays M02, but labeling moves to M01 because labeling is what prevents the misread. | Connor, phase-01 approval |
| 2026-08-25 | §13.1, §13.1.1 | The idle-CPU gate is a CPU-time delta over a 40 s settled window, not `ps -o %cpu`. The `%cpu` column is a decaying average that charges the app for its own launch; it read 8.9 % on a process a `sample` showed to be idle. | phase-01 execution |
| 2026-08-25 | §6.7 | The FPS counter reports two numbers: display-link ticks serviced (the rate the view sustains) and redraws that actually produced new pixels. Counting only draws understated the frame rate once identical frames started being skipped. | phase-01 execution |
| 2026-08-25 | §6.9, §13.1.2 | Contradiction raised: §6.9's 4 ms frame and §13.1's 3 % idle cap looked like the same quantity disagreeing eightfold. Phase-01 measured 7.2 % after four optimization rounds. Three routes put to Connor. | phase-01 execution |
| 2026-08-25 | §6.5 | **CGContext mandate amended.** Quantized meters composite on the GPU as `CALayer` textures cropped by `contentsRect`; charts stay on the CPU. The mandate predated any measurement and measurement contradicted it. | Connor, Route 1 |
| 2026-08-25 | §6.9 | Not a contradiction after all — an unstated assumption. §6.9 is a **latency** ceiling, §13.1 a **cost** ceiling; they collided only because §6.9 assumed per-frame work lands on the CPU. Assumption stated and inverted; both numbers stand unchanged. | Connor, Route 1 |
| 2026-08-25 | §13.1, §13.1.1 | The idle gate is now **whole-system**: app running vs closed, over equal windows, with WindowServer measured separately. Compositing moves cost rather than deleting it, and a monitor that under-reports itself is the §5.2.3 failure again. | Connor, Route 1 condition 1 |
| 2026-08-25 | §13.7 | Gate 12 added: the layer-geometry self-check must print PASS. | phase-01 execution |
| 2026-08-25 | §13.7.8, §13.7.1 | Gate 8 rewritten against the display's actual refresh rate; all earlier 60.0 fps readings voided. New rule: every gate states what it measures and what would void the reading — three instruments were caught flattering the build in three phases. | Connor, phase-01 |
| 2026-08-26 | §14.8, §5.6.3, §3.2 | **Phase-03 split by discussion: pane first, private providers second.** Phase-03 builds §4 against the five providers that exist and the §3 shell with Summary as the only enabled row; the GPU, NPU, Energy, and Thermals tiles, the Clock/Temp/GPU meters, and the overlay chart's temperature series render §4.8's unavailable state, which meets §5.10's all-private-unavailable criterion by construction. §5.6–5.9 move to a decimal phase-03.1, numbered the way M01.5 was so phases 04 and 05 keep theirs. The §3 row moves from phase-04 to phase-03 (the pane needs a window). The Performance row is omitted from the sidebar and ⌘2 stays unbound until §3.2's ruling; ⌘3…⌘7 keep their numbers. §5.6.3's manual `powermetrics` cross-check now reads phase-03.1 and gains an unprivileged upper bound from IOPowerSources first. | Connor, discuss-phase |
| 2026-08-26 | §13.2, §5.5.4 | **Sampling cost measured per provider; the process name cache applied.** All five providers together cost **0.13 % of one core** — CPU 0.014, memory 0.001, disk 0.021, network 0.006, process 0.084 — so sampling is about a twentieth of the 3 % gate and is not where the idle budget goes. §5.5.4's pre-specified `proc_pidpath` cache was applied when gate 9 read 3.93 %, not because its own 25 ms trigger fired: two of the three per-PID calls only resolve a name that cannot change while the PID lives, and caching them took the enumeration from 11–19 ms to 5.4 ms measured through the probe and 0.837 ms warm. Its first eviction guard (`names.count > seen.count`) could never fire, since the cache holds only inspectable PIDs while `seen` holds every listed one — the cache would have grown for the life of the process. Caught by the test written for it. | phase-02 execution |
| 2026-08-25 | §5.5.1, §5.5.4, §5.5.5, §5.0.5, §13.2 | **Process provider built; two silent defects and one hardware limit recorded.** `proc_listallpids` returns a **PID count, not a byte count** in both its forms — sizing the buffer as `returned / MemoryLayout<Int32>.size` made it four times too small and the enumeration covered 202 processes where `ps -A` counted 851, with every individual row still correct and nothing erroring. Only §5.5.5's count cross-check caught it. Second: **about 40 % of PIDs refuse inspection** by an unprivileged process — 335 of 839 return `EPERM`, `kernel_task` refuses outright, and the omitted set includes `WindowServer`. Not fixable without privilege GlowTop will not ask for, so `ProcessSample` now reports `totalCount` and `inspectableCount` separately. §5.5.4's provisional 25 ms is replaced by the measurement: **11–19 ms for 838 processes**, budget stands, mitigation not needed. §5.5.5's `top` comparison is demoted from gate to sanity check: against a load pinned at exactly one core the provider read 100.0 and `top` read 81.8, so the ±10-point tolerance was measuring the target's burstiness. Replaced by two decisive checks — cumulative CPU against `ps -o time=` (107.146 s vs 107.15 s) and a pinned 100 % load. Process-count figures reconciled from ~1100/~1150 to the measured ~840. `"composition does not sum"` added to §5.0.5's fixed vocabulary, which §5.2.3 had been using since phase-01 without it being listed. | phase-02 execution |
| 2026-08-25 | §4.9, §4.5 | **Number formatting implemented; two rules tightened where they contradicted their own examples.** `128 GB` cannot come from "1 decimal at GB and above" unless a trailing `.0` is dropped, and `948 B/s` cannot come from "1 decimal" at all. Both examples were right and both rule texts were underspecified, so the rules now say so. §4.5's headline read `66.29 GB` — two decimals where §4.9 allows one — and is corrected to `66.3 GB`; §4.9 opens by saying no two panes format the same quantity differently, and it was one of them. Implemented as explicit string math rather than `NumberFormatter`, which is locale-sensitive: `18,4 GB` on one machine and `18.4 GB` on another is two presentations of one number. One test per row of the table (§13.5 item 7). | phase-02 execution |
| 2026-08-25 | §13.7.9, §13.1.10 | **Gate 9 ruled: app-process only.** Connor took §13.1.10's option 1. The gate read "≤ 3.0 % CPU and ≤ 120 MB RSS after 30 s idle" and named no scope, so it inherited whole-system from §13.1.1 — about 41 points with the window visible, unpassable by any amount of work on GlowTop, while PERF-01 already said "the GlowTop *process*". It now names the process, names `scripts/overhead-harness.sh` as its instrument, and carries §13.7.1's four-part statement. Compositor cost is **documented, not gated**: §13.1.5's +41.19 against +1.09 is its recorded magnitude and §13.1.9 is why no threshold sits on it. §13.1.10's three options are kept as the record of what was chosen over what. | Connor, ruled |
| 2026-08-25 | §13.1.9, §13.1.10, PERF-03 | **M01.5 closed: the compositor cost is not measurable to gate precision on this hardware.** Run 2, with Claude Code quit, returned a GPU spread of 53 mW against the 10 mW threshold — worse than run 1's 13 mW, and the wrong direction on the one variable run 1 was faulted for. All three channels have now failed twice, so the rule declared before run 2 fires and there is no run 3. The failure is not sensor noise: GPU reads exactly 0 mW at true rest (57 of 60 samples in window 4), and the spread comes from other applications' bursts — Obsidian and Notes were enough. A baseline that depends on which unrelated apps are open cannot be held constant, which is why §13.7.1 demoted ambient load from control to diagnostic. The compositor cost remains *measured* (§13.1.5: +41.19 visible against +1.09 minimized, 0.49-point control spread) and merely un-gateable at a few percent; the per-layer and fixed-per-window hypotheses stay unseparated. New §13.1.10 records the one thing the close does not resolve: gate 9 names no scope, reads whole-system by inheritance from §13.1.1, and in that reading can never pass. PERF-03 and M01's acceptance criteria amended to match. | Connor, ran; session, recorded |
| 2026-08-25 | §13.1.9, §13.7.1 | **Baseline run 1: CPU and combined closed as not separable; GPU missed by 3 mW on a run that broke its own protocol.** Spreads against a 10 mW threshold: CPU 301 mW, combined 362 mW, GPU 13 mW. The first two are thirty-fold over and no quieter machine closes that, so §13.7.1's "not separable" is their final output. The run also caught an instrument defect before any verdict was written: the script aggregated each window with a **mean**, which §13.7.1 forbids outright, and idle CPU power here is burst-distributed (11–20 of every 60 samples above twice the window median, peaks over 5000 mW), so the mean read 517 mW where the median read 246. Fixed to the median; the fixture now carries a burst sample per window so the regression fails `--selftest`. GPU gets exactly one more run because a Claude Code session was live and its close hook committed inside the window — visible in the data, not merely alleged: windows 3 and 4 are jointly elevated in both channels and the three clean windows give a GPU spread of 5 mW. Run 2's rule is fixed in the section before run 2 exists, and there is no run 3. | Connor, ran; session, recorded |
| 2026-08-25 | §3.2, §14.5, §14.6, §14.8 | **Reconciled the sidebar against the reference app's own.** Connor supplied the TMOG reference build and its sidebar; the PRO section was checked against it item by item rather than from memory. Three deltas: **Connections** was absent from this document entirely and is now §14.5 (socket table via `proc_pidfdinfo`, numeric addresses only, so gate 7 is untouched); **Disk Space** was sold as an M02 pane by the sidebar, the roadmap, and the traceability table while living as a bullet in "Later, unscheduled", and is now §14.6; and the PRO order put Benchmarks second where the reference puts it last. §14.5–14.7 renumbered to 14.7–14.9 to make room. Recorded unresolved: the **Performance** pane holds ⌘2 and a sidebar row with no specifying section — M01 scope, so it needs a ruling, not a reconciliation. | Connor, directed |
| 2026-08-25 | §13.1.9, §13.7.13 | **Three channels, a settle, and a threshold declared before the numbers.** A five-sample smoke run put all the noise in CPU (188–2238 mW across five idle seconds) and 14 mW in GPU, while the script summed them and reported only the total. `scripts/power-baseline.sh` now reports CPU, GPU, and combined separately (taking the first of the two `GPU Power:` lines per sample), discards a 20-sample settle, counts windows in samples rather than seconds, prints the confound block §13.1.9 promises, writes the log under `docs/measurements/`, and ships a committed fixture plus `--selftest`. §13.1.9's pass rule is predeclared: a channel is usable at a spread ≤ one third of the smallest effect to resolve, which is 10 mW against the current 30 mW prior. Gate 13 widened to `.planning`, `CLAUDE.md`, and `scripts/`. | Connor, directed |
| 2026-08-25 | §13.1.9 | Shaped, empty section for the M01.5 phase-1 package-power baseline: five-window table, median/spread row, named confound slots, marked awaiting the run. The planning `STATE.md` and the M01.5 context cited §13.1.9 before it existed — the §13.1.4 pattern one directory outside gate 13's scope (gate 13 widened, item 2). | Connor, directed |
| 2026-08-25 | §13.1, §13.1.7, §13.1.8, §13.7.13, §13.7.1 | **Phase-01 closed; tagged `v0.0.1-spike` with gate 13.1 failed-with-cause.** §13.1.7's per-object claim corrected: area-scaling is dead; per-layer and fixed-per-animating-window remain, and bar count separates them. Instrument changes first (package power, baseline spread only, `scripts/power-baseline.sh`); the gate splits into app-process and compositor budgets in M01.5. Animation switch not run. Gate 13 added: `scripts/check-spec-refs.sh` validates every citation and the §14.8 table. Phase finding recorded: five instruments read as authoritative while measuring nothing. | Connor, ruled |
| 2026-08-25 | §13.1.7, §13.7.1 | **Area test.** Quartering the window surface left WindowServer unmoved (medians 43.45 full vs 49.05 quarter; no paired round moved the predicted −29). The compositor cost is per-object, not per-pixel; the bars are back in scope. Window confirmed opaque and display confirmed unscaled by direct observation. Ambient-load covariate dropped from the gate, kept as a diagnostic column. WindowServer CPU-time spread recorded as an instrument finding: 15–34 points with the screen controlled. §13.1.4–13.1.6 backfilled from the phase record — the traceability rows below cited them before they were written. | Connor, ruled (test); phase-01 execution (record) |
| 2026-08-25 | §13.1.5 | Interleaved five-arm harness. **The compositor cost is GlowTop's**: minimizing takes WindowServer from +41.19 to +1.09. Refresh rate confirmed roughly linear. Ambient-load covariate declared unusable (baseline spread 196 points). | phase-01 execution |
| 2026-08-25 | §13.1.6 | Three removals applied — display link deleted from the running app, SwiftUI out of the sample path, text to 1 Hz. App floor 2.71 % → **1.07 %**; visible 4.10 % → 2.22 %; WindowServer unchanged at ~39. | Connor, ruled |
| 2026-08-25 | §13.1.4 | Bisection run. Candidate 3 (glow blending) falsified; candidate 2 (animation installs) worth ~1.5 points app-side; a 2.83 % app floor and a 42-point WindowServer delta both remain unexplained. Variant A confounded by a 60 Hz display. | phase-01 execution |
| 2026-08-25 | §13.1.3 | **Route 1 measured and failed the gate.** App cost fell 7.2 % → 4.4 %; WindowServer rose 5.5 % → 47.8 %; whole-system delta +46 % against a 3 % cap. The whole-system scope caught on its first run exactly what it was added for. Reported rather than optimized further, per the ruling's one-attempt condition. | phase-01 execution |

### 14.10 Performance pane (M02)

A second CPU-and-memory pane, selected from the sidebar's second row and by ⌘2 (§3.2, §3.4, §3.5). It adds no provider, no ring buffer and no chart-rendering code: every number on it is already sampled by `MetricStore` for the Summary pane (§6.3), already projected by §4's projection, and already drawn by the composited chart layer §6.5 specifies as amended in phase-09 (§13.1.13). It exists because §4.3.2's per-core strip is 6 pt tall and carries no per-core number — the state it was built to reveal, "a total that reads 7 % while one core sits at 100 %", is findable on Summary but not readable.

**Three stacked full-width cards** in §4.2's chrome, in this order, inside §4.1's 16 pt outer padding and 12 pt gaps:

| Card | Title | Headline | Footer | Content |
|---|---|---|---|---|
| 1 | `PER-CORE UTILIZATION` | Total CPU %, 24 pt, green | none | The per-core grid |
| 2 | `CPU HISTORY` | none | `Total 15.8% · System 3.0%` | §4.4's chart, two series |
| 3 | `MEMORY HISTORY` | `20 GB resident / 48 GB`, 24 pt, magenta | §4.5's footer | §4.5's stacked timeline |

Card 1 takes only the height its rows need; cards 2 and 3 split the remainder equally. The pane fills the detail area and **does not scroll**: at §3.1's minimum window (1100 × 700) the two history cards are ≈213 pt each, and cards shrink with the window rather than clipping. Card 1's height does not vary with the window — only with the core count and the card's width.

**The per-core grid.** One mark per logical core, each a horizontal segmented meter in §4.3.2's strip geometry (6 pt tall, §6.5's `contentsRect` crop, lit fraction = that core's utilization, green), laid out as a grid rather than a single row. Cores are **grouped by cluster** (§5.1.4): a block of rows for the performance cores under the caption `P · 10 cores`, then a block for the efficiency cores under `E · 4 cores`, SF Mono 9 pt in §4.3.2's own `#7A7A88` and `#57575F`. Counts come from `performanceCores`, never from the index order. The per-cell `P`/`E` caption §4.3.2 requires on Summary's strip is **dropped inside this grid**, because the block caption carries the cluster for every mark under it; §4.3.2's strip is unchanged. This is §14.7's "per-cluster core grouping" item, claimed for this grid only.

Each cell carries a label beneath it in SF Mono 9 pt — the logical core index and that core's utilization, formatted by §4.9's percentage rule (` 3  41.2%`). The index is what makes a pinned core reportable; the percentage is what §4.3.2's strip lacks.

Cells per row are derived from the card's width: a minimum cell width of 48 pt (the widest label §4.9 can produce at this size), a 2 pt gutter matching §4.3.2's, and a cap at the larger cluster's core count so **every cell in the grid is the same width**. Two clusters drawn at two cell widths would make an E core at 100 % look different from a P core at 100 % by *size* as well as by caption, which is the misreport §5.1.4 exists to prevent. At 14 cores and the 1440-point default window the grid is two rows — one per cluster — of 121.8 pt cells and the card is 157 pt tall (the built sidebar measures ≈148 pt, not §3.2's 260, so the content width is 1260; at §3.1's minimum window the cells are 87.8 pt and the card is still 157 pt).

**CPU history** (card 2) is §4.4's chart with **two** of its three series: utilization (green, 1.5 pt, gradient fill 22 % → 0) and kernel/system time (red, 1.0 pt), on the 0–100 % left axis with gridlines at 0/25/50/75/100 and their labels. **The temperature series and the right-hand 0–110 °C axis are both omitted** — §4.4 already requires a series and its axis to be omitted together, and this pane is about the CPU's own work, not the package's thermals, which §14.1's pane owns. Data is §6.4's 600-slot total and system buffers, the same two the Summary pane plots.

**Memory history** (card 3) is §4.5's stacked timeline unchanged — wired / active / compressed / cached as cumulative filled bands with no stroke, plus the unstacked swap line in `#FF453B` — at this card's height rather than §4.5's 90 pt. Free memory is the unfilled remainder to the top of the plot. The meter §4.5 places beside its timeline is Summary's and is not repeated here.

**Both charts scroll per §6.6:** the x-offset advances continuously between samples, each plotted point sits at its measured value, and the redraw fires when the offset crosses a whole backing pixel. The pane owns one display link under §6.2's rules — created when it has a window, invalidated when it does not, paused on occlusion and on §6.8's pause — and §3.3 releases the pane on a switch away, so exactly one link exists at a time across the app.

**States follow §4.8** with no additions. Warming shows `···` in `#5A5A68` on the two cards that carry a headline and an empty plot area on both charts; stalled dims the card to 35 %; unavailable shows `—` and omits the plot. CPU (§5.1) and memory (§5.2) are both **public** providers, so under §13.7's gate-3 flag nothing on this pane goes unavailable — the only states reachable live are warming, for the first sample interval after launch, and stalled. Unavailable is exercised by gate 12's offscreen construction (§5.10), against rendered pixels.

Requirements PPANE-01..05; built in phase-10.

### 14.11 Signed, shareable build (M03)

The build Connor can hand to another Mac without a Gatekeeper refusal: the same `GlowTop.app` §2.8 assembles, signed with a Developer ID Application identity under the hardened runtime, notarized, stapled, and shipped inside a DMG attached to a GitHub release. **Nothing in `Sources/` changes** — M03 is `scripts/`, the two version keys in `Resources/Info.plist`, `README.md` and the release process — so §13.7's gates stand on phase-14's readings except where this section says a gate is re-read, and why. Requirements SIGN-01..05 (phase-16) and REL-01..05 (phase-17); the recon behind every claim below is recorded verbatim in `phase-16-CONTEXT.md` and `phase-17-CONTEXT.md`.

**The baseline, measured 2026-09-08 on the reference Mac (§2.9).** The installed bundle reads `Signature=adhoc`, `flags=0x2(adhoc)`, `TeamIdentifier=not set`, `Format=app bundle with Mach-O thin (arm64)`, and `codesign -d --entitlements -` prints no entitlements. `spctl --assess -vv --type execute ~/Applications/GlowTop.app` prints `rejected` (exit 3). `security find-identity -v -p codesigning` prints `0 valid identities found`, and `security find-generic-password -s com.apple.gke.notary.tool -a glowtop-notary` finds no profile (exit 44) — Connor is enrolled in the Apple Developer Program; those two keychain items are his one-time setup, and the two commands are how a session detects them without touching a credential. `notarytool` 1.1.2 (41) and `stapler` resolve under Xcode 26.6; `codesign` is `/usr/bin/codesign`. That `rejected` is the reading this section exists to change, and it is recorded so phase-16's close compares against a number rather than an assumption.

**Signing.** `scripts/package-app.sh` selects the identity from `GLOWTOP_SIGN_IDENTITY`. Unset, it signs exactly as it has since phase-05 — `codesign --force --sign - --identifier com.glowtop.GlowTop` — so every gate instrument that runs against the installed bundle keeps its control unchanged, and the ad-hoc path is that control. Set to the string `security find-identity` prints (`Developer ID Application: <name> (<TEAM>)`), it signs with

```
codesign --force --options runtime --timestamp --sign "$GLOWTOP_SIGN_IDENTITY" --identifier com.glowtop.GlowTop build/GlowTop.app
```

and asserts, before anything is installed, that `codesign --verify --strict --verbose=2` passes, that `codesign -dv --verbose=2` carries `Authority=Developer ID Application:`, `TeamIdentifier=<TEAM>` and `flags=0x10000(runtime)`, and that `codesign -d --entitlements -` still prints nothing. `--identifier` stays `com.glowtop.GlowTop` (§2.8's `UserDefaults` reason) and `CFBundleExecutable` stays `GlowTopApp` (§2.8's five instruments). `CFBundleShortVersionString` becomes `1.1.0` and `CFBundleVersion` `2` before the signed build, so the notarized artifact is the release artifact and nothing is re-signed later.

**No entitlements file, and why that is a finding rather than an omission.** The hardened runtime (§2.3) restricts five classes of behaviour, and this app needs none of the exceptions: it allocates no executable memory and runs no JIT; it reads no `DYLD_*` variable; it is not debugged in the field (`get-task-allow` is refused by notarization in any case); it requests no TCC-protected resource (§2.3); and its two `dlopen` targets — `/usr/lib/libIOReport.dylib` and `/System/Library/Frameworks/IOKit.framework/IOKit`, the one site §5.0.5 and `PrivateLib` name — are Apple platform binaries in the dyld shared cache. **Library validation restricts loading code signed by neither Apple nor the app's own team**; Apple-signed system libraries are admitted by construction, so `com.apple.security.cs.disable-library-validation` is not needed and would weaken the runtime for nothing. The app's one `Process()` (§14.4's `/bin/launchctl`) is a spawn of a platform binary, which the runtime does not restrict. Phase-16 proves this rather than asserts it: the signed bundle, launched without §13.7's flag, must show the private tiles live (§4.7's status bar carrying no `providers unavailable` phrase). A private provider reading `—` under a Developer ID signature is a library-validation failure to be diagnosed, never an entitlement to be added as the first response.

**Notarization and stapling.** The unit of submission is a zip of the signed app — `ditto -c -k --keepParent build/GlowTop.app build/GlowTop.zip` — because the DMG does not exist until phase-17 and the ticket must live on the app, which is what a user drags out of the image and what Gatekeeper assesses offline. `xcrun notarytool submit build/GlowTop.zip --keychain-profile glowtop-notary --wait`, then `xcrun stapler staple build/GlowTop.app`; the zip is transport and is discarded. The `glowtop-notary` profile is created once by Connor (`xcrun notarytool store-credentials …`) and holds the Apple ID, team and app-specific password in his login keychain. **No session, script or file ever reads, prints or stores a credential** — the profile's name is the only token that appears in this repository. The secure timestamp and the notarization upload are the two network calls M03 makes, both from the script under `--notarize` and both `codesign`'s and `notarytool`'s; the app makes none (§2.5), and gate 7 is re-read once from the signed bundle to say so.

**The gate.** After stapling and before install, the script asserts `spctl --assess -vv --type execute build/GlowTop.app` prints `accepted` and `source=Notarized Developer ID`, and `xcrun stapler validate build/GlowTop.app` exits 0. Those two, with the `codesign -dv` fields above, become §13.6's new rows with phase-16's plan — value checks in §13.6.1's sense, exact, because `spctl` is the assessor Gatekeeper itself runs. Phase-16's close re-reads gate 3 once from the signed installed bundle (30 minutes under the flag; the hardened runtime is the one thing between phase-14's bundle and this one), gate 7 once, gate 12 once (`GLOWTOP_SELFCHECK=1` from the installed executable), and gates 1, 4, 6, 11 and 13 as always. Gates 8, 9 and 10 stand on phase-14's readings because `git diff --stat main..HEAD -- Sources/ Package.swift` prints nothing: REG-01's harness is unedited and REG-02 has no reader to re-check.

**The DMG (phase-17).** `scripts/make-dmg.sh`, literal and assertion-guarded in `package-app.sh`'s shape: it refuses to run unless `build/GlowTop.app` exists and passes `codesign --verify --strict`; stages a copy beside a symlink named `Applications` → `/Applications` in `build/dmg-staging/` (the only directory it removes, by its literal path); runs

```
hdiutil create -volname GlowTop -srcfolder build/dmg-staging -ov -format UDZO build/GlowTop-1.1.0.dmg
```

with the version read from `Info.plist` and never typed twice, then `hdiutil verify`. With an identity set it signs the image with the same Developer ID (`codesign --sign "$GLOWTOP_SIGN_IDENTITY" --timestamp`), submits it — `xcrun notarytool submit build/GlowTop-1.1.0.dmg --keychain-profile glowtop-notary --wait` — staples it, and asserts `spctl --assess -vv --type open --context context:primary-signature` prints `accepted`. Two submissions, then: the app's ticket is what a copied app validates against offline, the image's is what Gatekeeper reads when a quarantined download is opened; notarizing only the image would leave the app's verdict to an online lookup, and notarizing only the app would leave the image unassessed. `shasum -a 256` writes `build/GlowTop-1.1.0.dmg.sha256` beside it. No `create-dmg`, no background image, no window layout: a volume holding an app and a link is the whole product.

**The release, and what stays Connor's.** The public repository and every push are created by Connor, never by a session: `gh repo create`, `git remote add`, `git push`, the release tag and `gh release create` are written verbatim in the phase-17 plan with their directory, and until he runs them §13.7's gate 11 holds — `git remote -v` prints nothing at every session commit. The session prepares what those commands consume: the DMG, its `.sha256`, `README.md`, and a release-notes file drawn from `MILESTONES.md`'s v1.1 entry (the accomplishments, the carried findings, the two paths only a Finder launch exercises). The release tag is `v1.1.0` at M03's merged tip — the commit the DMG was built from, whose `Info.plist` reads `1.1.0` — leaving `v1.1` where STATE's merge command places it, on M02's close. `README.md` is rewritten for a reader who did not build the app: install, what it reads and why it cannot be sandboxed (§2.3), the private-API posture (§5.10, `GLOWTOP_DISABLE_PRIVATE=1`), permissions (no Full Disk Access; the one TCC case is a Disk Space drill into a protected folder, where Deny is safe and the node reads `Locked`, §14.6), the write actions and `actions.log` (§8.5, §14.4), the carried findings, and build-from-source.

**Published 2026-09-21 (amended).** Connor authorized the session to run that block once, for v1.1.1 rather than the never-published v1.1.0: the repository was created private, `main` and the tags were pushed, and the release carries `GlowTop-1.1.1.dmg`, its `.sha256` and `docs/release-notes-v1.1.1.md`. The rule above is otherwise unchanged — the authorization covered that publish and no other. *v1.1.2, the same day:* published the same way on a second explicit authorization, carrying `GlowTop-1.1.2.dmg`, its `.sha256` and `docs/release-notes-v1.1.2.md` — the notes file was renamed for it, so the `v1.1.1` path above no longer exists in the tree.

**Public 2026-09-21 (amended).** `origin` is the private archive `glowtop-dev`, which keeps the full history, every tag and the planning records. The public repository `UsernameTron/glowtop` is a fresh repository with fresh history, first published 2026-09-21 from an export of this tree that omits the planning records and task notes (the `.planning` and `tasks` directories); it carries the tag `v1.1.2` and the v1.1.2 release (DMG and checksum) and no earlier tag or release. Every push, to either repository, still needs Connor's explicit go.

**Moved 2026-09-21 (amended).** The public repository moved to Connor's personal account, `UsernameTron/glowtop`, the same day it was first published and before it was announced, so the project is not presented under his employer's account. It was published there fresh — one commit under that account's private GitHub address, tag and release `v1.2.0` — rather than transferred, because a transfer between personal accounts completes only when the receiving account accepts an emailed link; the first copy was made private.

**Fallback.** If no `Developer ID Application` identity exists when phase-17 is ready, both scripts run with `GLOWTOP_SIGN_IDENTITY` unset: the image carries the ad-hoc app, `make-dmg.sh` prints `UNSIGNED` where the `spctl` assertion would stand, and the README's unsigned-build section (right-click → Open, or `xattr -d com.apple.quarantine`) and the release notes say so. Whether to publish that or wait is Connor's ruling; phase-16 re-runs when the certificate exists and the release asset is replaced (`gh release upload --clobber`), the tag unmoved.

**Verification, end to end.** The pre-signing `rejected` and the post-stapling `accepted` recorded side by side in phase-16's record; a quarantine-flagged copy of the DMG (`xattr -w com.apple.quarantine`, the session's substitute for a download) mounts and its app launches with no Gatekeeper dialog on this Mac; the same check on a second user account is Connor's five-second item; the release page shows the DMG and its checksum, and the checksum matches a fresh download.

Requirements SIGN-01..05, REL-01..05; built in phases 16 and 17.

*End of specification. §14.2 and §14.7 remain outlines; every other section describes the app as shipped in v1.2.0.*
