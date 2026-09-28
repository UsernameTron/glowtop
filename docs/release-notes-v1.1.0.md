# GlowTop v1.1.0

**This release's DMG is signed with a Developer ID, notarized by Apple and stapled** — it opens on first launch with no Gatekeeper dialog. `spctl` reads `accepted`, `source=Notarized Developer ID` on both the disk image and the app inside it.

## What shipped

- **120 fps met for the first time** — the charts moved to Core Animation, cutting app CPU roughly in half and RSS by nearly half on the same Summary pane.
- **Five new panes** — Performance (⌘2), Power & Freq (⌘8), Connections (⌘9), Installed Apps (⌘0), and Disk Space (⌘D, a drillable treemap of volume usage).
- **Write actions** — enabling/disabling Startup Apps and starting/stopping Services, each behind a confirmation sheet and logged to `actions.log`.
- **Every phase closed its full gate set** — thirteen gates each time, with a live keystroke walk and a cross-check against a system tool (`top`, `ps`, `vm_stat`) on every reading.
- **Two real bugs found by driving the largest input live** — a Disk Space walk that treated a volume root as a plain directory, and a memory leak in that same walk; both fixed.
- **The release process itself** — Developer ID signing, notarization, stapling, and this DMG.

## What to know

- The GPU, NPU, Energy, Thermals, and Frequency readings use private Apple APIs, loaded read-only; if one is unavailable on your macOS release, its tile shows `—` instead of guessing.
- GlowTop asks for no Full Disk Access and shows no permission prompt in normal use. The one exception: drilling into a TCC-protected folder from the Disk Space pane may prompt once; denying it is safe and the folder shows as locked.
- New to GlowTop? A plain-English guide to every page is in the repository at `docs/USER-GUIDE.md`.
- The only actions GlowTop takes against the system — quitting a process, and enabling/disabling your own user-level Startup Apps and Services — each require a confirmation sheet and are logged to `~/Library/Logs/GlowTop/actions.log`.

## Known findings

- The locked-folder TCC prompt and the `Stop` action on an active Disk Space drill have been verified structurally rather than by driving them live; both behave as documented.
- A handful of stray `com.glowtop.selfcheck.theme.*.plist` files are artifacts of the reference Mac's own test runs, not of this build.

## Requirements

macOS 14 or later, Apple Silicon. No Intel build.

## Verifying the download

```bash
shasum -a 256 -c GlowTop-1.1.0.dmg.sha256
```
