# DevOps handoff — GlowTop

## What this is

A local-only macOS desktop app, version 1.2.0 (released 2026-09-21). **No servers, no network calls from the app, no cloud resources, no CI pipeline.** The only credential is the maintainer's notarization keychain profile, used at release time. There is nothing deployed and nothing to page anyone about. This document exists so a second person can build, verify, and reason about the app without reading all of `SPEC.md`.

## Environment

| Item | Value |
|---|---|
| OS | macOS 14+ (verified on 26.6.2, build 25G83) |
| Arch | Apple Silicon (`arm64`) |
| Toolchain | Xcode 27.0 / Swift 6.4 (verified). Full Xcode is required — the Command Line Tools alone lack the SwiftUI macro plugin. `Package.swift` declares `swift-tools-version: 5.10` |
| Build system | SwiftPM (`Package.swift`) — no `.xcodeproj` in version control |
| Dependencies | None (first-party frameworks only) |
| Privileges | Unprivileged user. The app needs no root and never calls `powermetrics`; one measurement script does (see Measurement scripts) |
| Sandbox | Off, by design — the sandbox blocks `proc_listallpids` and process termination |

## Build

```bash
swift build              # must complete with zero warnings
swift build -c release   # release artifact
swift test               # 416 executed, 1 skipped, 0 failures at 1.2.0
```

## Verify a build

```bash
swift run glowtop-probe cpu | head -5            # per-core utilization, JSON lines
top -l 2 -n 0 | grep 'CPU usage' | tail -1       # cross-check: within +/-10 pts
sysctl -n hw.logicalcpu                          # must equal perCore array length
swift run GlowTopApp                             # window opens; FPS overlay (⇧⌘F) reads >= 95 % of the display's refresh (60 or 120 Hz)
ps -o rss,comm -p "$(pgrep -x GlowTopApp)"       # <= 215040 KB RSS (210 MB, SPEC §13.1)
scripts/overhead-harness.sh 3 baseline 1440x900  # CPU gate: app <= 35 % of one core (SPEC §13.1); needs `swift build -c release`; never `ps -o %cpu`
GLOWTOP_SELFCHECK=1 swift run GlowTopApp         # 65 assertions, ends `selfcheck: PASS`; the structural self-check (gate 12, SPEC §13.7) covers 9 of 12 pages
```

Every metric provider ships a `glowtop-probe` subcommand precisely so its numbers can be checked against a system tool (`top`, `ps`, `vm_stat`, `netstat`, `sysctl`) rather than trusted.

## Measurement scripts

- `scripts/overhead-harness.sh` — the gated CPU and RSS instrument (SPEC §13.1): interleaved arms, CPU-time deltas over a fixed window, median and spread.
- `scripts/pane-cost.sh` — diagnostic: CPU cost of one named page, minimized or visible. Drives the app through System Events, so the terminal needs Accessibility permission.
- `scripts/rss-profile.sh` — diagnostic: RSS, footprint and `vmmap` after a walk across several pages. Same Accessibility requirement.
- `scripts/power-baseline.sh` — package-power baseline from `powermetrics`. **Needs `sudo`, so it is the owner's to run.** `--parse FILE` and `--selftest` (on `scripts/fixtures/power-baseline.log`) need no root.
- `scripts/png-diff.swift` — pixel-by-pixel PNG comparison, gate 12's render-parity instrument.
- `scripts/check-spec-refs.sh` — gate 13: every `§` citation resolves to a heading in `SPEC.md`.

## Install

End users install the notarized DMG from the GitHub releases page (see `README.md`). From source: `scripts/package-app.sh` builds `GlowTop.app` and copies it to `~/Applications`, replacing any copy already there. Ad-hoc signed by default; with `GLOWTOP_SIGN_IDENTITY` set to a Developer ID Application identity it signs with the hardened runtime, and `scripts/package-app.sh --notarize` notarizes and staples the app through the `glowtop-notary` keychain profile (SPEC §14.11). `scripts/make-dmg.sh` then builds `build/GlowTop-<version>.dmg` and its `.sha256` from the result.

## Operational limits

- Private APIs (IOReport, and IOKit's IOHIDEventSystem thermal sensors) can change between macOS releases. Providers wrap them so failure returns `.unavailable` and the tile renders `—`. A macOS upgrade degrading the GPU/NPU/Thermals tiles is expected behavior, not a crash.
- Write actions against the OS (process kill, launch-agent disable, service stop) require a confirmation dialog and append to `~/Library/Logs/GlowTop/actions.log`.
- The app writes nothing to disk except `~/Library/Logs/GlowTop/` (created lazily) and its `UserDefaults` domain (`com.glowtop.GlowTop`).

## Repository rules

- Development happens in a private archive, `glowtop-dev`, which keeps the full history and the project's planning records. The public repository `UsernameTron/glowtop` is a fresh-history export of that tree without those records. Every push to either one, and every tag, release or visibility change, needs Connor's explicit go each time.
- Work happens on `feat/` `fix/` `chore/` branches cut from `main`; nothing is committed directly to `main`.

## Rollback / uninstall

1. Roll back: quit GlowTop and install the previous release — its DMG from the releases page, or from source check out the previous release tag and run `scripts/package-app.sh`. The current release is `v1.2.0`; `v1.1.2` was the first release in the public repository, and older tags live only in the private archive.
2. Uninstall: delete `GlowTop.app` from `/Applications` (or `~/Applications` for a source install).
3. Optional: `rm -rf ~/Library/Logs/GlowTop` and `defaults delete com.glowtop.GlowTop` — the only two things the app leaves behind.
