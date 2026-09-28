# Contributing to GlowTop

Thanks for taking a look. GlowTop is a small, spec-first project, so the rules are short.

## Build and test

You need macOS 14 or later on Apple Silicon and full Xcode (the Command Line Tools alone lack the SwiftUI macro plugin).

```bash
swift build        # must finish with zero warnings
swift test         # every test must pass
swift run GlowTopApp
```

## Ground rules

- **Spec first.** Every shipped feature traces to a section of [`SPEC.md`](SPEC.md). A change in behaviour starts as a change to the spec.
- **Layering.** `Sources/GlowTopCore` holds providers and pure logic, with no AppKit or SwiftUI. UI code lives in `Sources/GlowTopApp`.
- **Never crash on missing hardware.** A provider that cannot read something returns `.unavailable` and the tile shows `—`.
- **No network access in the app**, no root, no `powermetrics`, and no third-party dependencies.
- **Check numbers against the system.** A new reading ships with a `glowtop-probe` subcommand and a cross-check against `top`, `ps`, `vm_stat` or `sysctl`.

## Pull requests

Keep each pull request to one change, say which SPEC.md section it touches, and confirm the build is warning-free and `swift test` passes. CI runs both on every pull request.
