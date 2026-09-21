# GlowTop — project instructions

Native macOS system monitor (layout modeled on TMOG, a closed-source monitor; independent implementation, see README). Swift, SwiftUI + AppKit, SwiftPM, non-sandboxed, zero third-party dependencies.

## Commands

```bash
swift build                    # debug build, must be warning-free
swift build -c release         # release build
swift run glowtop-probe cpu    # CLI smoke: JSON lines, 10/s, until Ctrl-C
swift run GlowTopApp           # launch the app window
swift test                     # unit tests
```

Packaging and distribution (shipped 2026-09-08):

```bash
scripts/package-app.sh                          # ad-hoc build → ~/Applications/GlowTop.app
GLOWTOP_SIGN_IDENTITY="Developer ID Application: …" \
  scripts/package-app.sh --notarize             # signed, notarized, stapled
scripts/make-dmg.sh                             # build/GlowTop-<version>.dmg + .sha256
make build | package | install | run | dmg      # the same, through the Makefile
```

With `GLOWTOP_SIGN_IDENTITY` unset both scripts produce the ad-hoc artifact they always
did (`package-app.sh` prints `signing (ad-hoc)`, `make-dmg.sh` prints `UNSIGNED`) — the signed path is additive, never required to build. Signing
uses the hardened runtime with no entitlements; the two `dlopen` targets are Apple-signed
system binaries, which library validation admits (SPEC §14.11).

## MetricProvider contract

- `sample() -> Snapshot`; providers are sampled at 10 Hz by `MetricStore` (actor).
- **Never throw and never crash on unavailable hardware** — return `.unavailable`; the UI tile shows `—`.
- First sample of a delta-based provider returns `.warming`.
- Providers are `Sendable`; all mutable state lives inside `MetricStore`.
- Rendering runs at the display's refresh rate (60 or 120 Hz) via display-link views, interpolating between the last two 10 Hz samples by wall-clock time.

## Layering (enforced)

- `Sources/GlowTopCore/` — providers and pure logic only. **No AppKit, no SwiftUI.**
- `Sources/GlowTopApp/` — AppKit/SwiftUI only. Imports `GlowTopCore`.
- `Sources/glowtop-probe/` — CLI over `GlowTopCore`; no UI frameworks.
- `Tests/GlowTopCoreTests/` — exercises providers without a window.

Every provider ships a `glowtop-probe` subcommand whose numbers are cross-checked against `top` / `ps` / `sysctl` before the phase advances.

## Safety rules

- **Two repositories, and no push without Connor's go.** In the maintainer's working copy, `origin` is the private development archive `glowtop-dev` (full history, planning records). The public repository `UsernameTron/glowtop` is published from an export of this tree that omits `.planning/` and `tasks/`, with its own fresh history (first published 2026-09-21, MIT). Never push, tag, release, change a repository's visibility or add a remote without Connor's explicit go for that specific action, and never push this repository's history to the public one.
- **Notarization is the one sanctioned network call**, made by `xcrun notarytool` through the `glowtop-notary` keychain profile — never by the app, and never with a credential passed on a command line or written to a file.
- Never `rm` anything outside this repository.
- Confirm with Connor before any write action against the OS (process kill, `launchctl`, file writes outside the repo).
- No root, no `sudo`. The app never calls `powermetrics`. The one permitted use is `scripts/power-baseline.sh` as a measurement instrument (SPEC §13.1.8), run by Connor under `sudo` — never by a session.
- No network access anywhere in the app — shipping gate 7 (SPEC §13.7) re-checks it every release (`lsof -nP -i -a -p <pid>` empty over ten minutes).
- Private APIs (IOReport, IOHIDEventSystem via IOKit) are read-only and wrapped so failure returns `.unavailable`.

## Planning

Spec-first. The spec is `SPEC.md`; every shipped feature traces to a SPEC.md section, and its amendment log (§14.9) records what changed and why. Day-to-day planning records live in the private archive's `.planning/` and are not part of the public tree.
