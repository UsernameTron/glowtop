# GlowTop v1.1.1

**This release's DMG is signed with a Developer ID, notarized by Apple and stapled** — it opens on first launch with no Gatekeeper dialog. `spctl` reads `accepted`, `source=Notarized Developer ID` on both the disk image and the app inside it.

## Fixed in 1.1.1

- **Greyed-out menu items now stay greyed out.** In right-click menus, items the app locks on purpose — `Enable`/`Disable` and `Start`/`Stop` on system-owned jobs — showed the right tooltip but still highlighted and could be clicked. The same flaw sat in the other three right-click menus, including the lock on `Quit Process` for `kernel_task` and `launchd`, where it was latent: those two processes are not listed for a normal user. Clicking did nothing, because a second safety check refused every time, so nothing unsafe was ever reachable; the control simply looked live when it was not. Found by driving the real menus by hand, and now covered by the app's structural self-check so it cannot come back unnoticed.
- Three on-screen strings that had outlived their milestone are gone: the greyed-out `Benchmarks` and `Settings` sidebar rows now show a `Not in this version` tooltip (the old one promised a milestone that had passed, and because of a second small bug never actually appeared), and the Startup Apps footer explains plainly why login items are not listed.

1.1.0 was built, signed and notarized on 2026-09-08 but never published; 1.1.1 is the first public release and carries everything below.

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

- The `Stop` action on an active Disk Space drill was driven live on 2026-09-21 and behaves as documented (finished rectangles kept, footer `Sizing stopped at n of N items.`). The locked-folder TCC prompt has still only been verified structurally.
- A handful of stray `com.glowtop.selfcheck.theme.*.plist` files are artifacts of the reference Mac's own test runs, not of this build.

## Requirements

macOS 14 or later, Apple Silicon. No Intel build.

## Verifying the download

```bash
shasum -a 256 -c GlowTop-1.1.1.dmg.sha256
```
