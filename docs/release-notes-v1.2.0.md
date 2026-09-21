GlowTop is a native macOS system monitor for Apple Silicon: a live dashboard of CPU, memory, disk, network, energy, GPU and thermals, plus pages for processes, startup items, services, connections, installed apps and disk usage. New here? Start with the [user guide](https://github.com/UsernameTron/glowtop/blob/main/docs/USER-GUIDE.md).

**The DMG is signed with a Developer ID, notarized by Apple and stapled.** `spctl` reads `accepted`, `source=Notarized Developer ID` on both the disk image and the app inside it. macOS may still show its standard "downloaded from the Internet" confirmation on first open.

## New in 1.2 — the dashboard in plain words

GlowTop now opens in **Simple mode**. Nothing was removed and no number changed; the words around the numbers did.

- **Plain labels everywhere.** `CPU OVERVIEW` is `PROCESSOR`, `NPU 0` is `AI CHIP`, `THERMALS` is `TEMPERATURE`, `20 GB resident / 48 GB` is `20 GB of 48 GB in use`, `Swap` is `Spilled to disk`, `PID` is `ID`.
- **A one-word verdict on each reading** — `Normal`, `Busy`, `Warm`, `Hot`, `Low on memory` — so you can tell at a glance whether 51.8 °C is fine. Power draw has none on purpose: watts are not good or bad, the heat they cause is, and the Temperature card already reports it. Where macOS publishes its own judgement (heat, memory pressure) GlowTop shows that judgement rather than inventing a threshold, and a card that has no live reading gets no verdict at all.
- **One sentence at the bottom** saying what your Mac is doing: *Your Mac is running normally.* · *Google Chrome is using most of the processor.* · *Your Mac is hot and is slowing itself down to cool off.*
- **Hover any card** for a sentence explaining what it shows.
- **`View › Use Technical Labels`** switches back to the engineering names and numbers, exactly as they were in 1.1.3. The choice is remembered.

## Fixed in 1.1.3

- **You can now click the volume bar on the Disk Space page to size that volume.** The page has always said "Select a volume or press ⌘D again for your home folder", but only the ⌘D half worked. Clicking the bar now starts the walk (a whole disk takes minutes; progress and `Stop` are on screen throughout, and a tooltip says so before you click).
- **The Summary page stays at the top of a tall window.** In a window taller than the dashboard, the cards used to sit at the bottom under a band of empty space; and in a window shorter than the dashboard the page opened scrolled to its bottom. Both now start at the top.
- The Services page footer no longer claims `ServiceManagement` as a source: it never contributed a row. Two unused functions were removed with it. No reading changed.

## New in 1.1.2

- **The Power card's `uncertain` label is gone.** Its wattage readings were checked second by second against Apple's `powermetrics` tool and agree (GPU within 4 %; CPU matching on every quiet second), so the footer no longer hedges. The readings still come from a private Apple interface, and the tooltip says so.

## Also in this release (fixed in 1.1.1)

- **Greyed-out menu items now stay greyed out.** In right-click menus, items the app locks on purpose — `Enable`/`Disable` and `Start`/`Stop` on system-owned jobs — showed the right tooltip but still highlighted and could be clicked. The same flaw sat in the other three right-click menus, including the lock on `Quit Process` for `kernel_task` and `launchd`, where it was latent: those two processes are not listed for a normal user. Clicking did nothing, because a second safety check refused every time, so nothing unsafe was ever reachable; the control simply looked live when it was not. Found by driving the real menus by hand, and now covered by the app's structural self-check so it cannot come back unnoticed.
- Three on-screen strings that were out of date are gone: the greyed-out `Benchmarks` and `Settings` sidebar rows now show a `Not in this version` tooltip (the old one promised a future version that had already shipped, and because of a second small bug never actually appeared), and the Startup Apps footer explains plainly why login items are not listed.

1.1.2 was the first public release; 1.2.0 carries everything below.

## What is in the 1.1 line

- **120 fps reached** — the charts moved to Core Animation, cutting app CPU roughly in half and memory use by nearly half on the same Summary page.
- **Five new pages** — Performance (⌘2), Power & Freq (⌘8), Connections (⌘9), Installed Apps (⌘0), and Disk Space (⌘D, a drillable treemap of volume usage).
- **Write actions** — enabling/disabling Startup Apps and starting/stopping Services, each behind a confirmation sheet and logged to `actions.log`.
- **Every reading cross-checked** against a system tool (`top`, `ps`, `vm_stat`, `lsof`, `du`, `powermetrics`) before it shipped, under a fixed set of release checks: warning-free build, 416 tests, no network sockets, frame-rate and overhead budgets.
- **Two real bugs found by driving the largest input live** — a Disk Space walk that treated a volume root as a plain directory, and a memory leak in that same walk; both fixed.
- **The release process itself** — Developer ID signing, notarization, stapling, and this DMG.

## What to know

- The GPU, NPU, Energy, Thermals, and Frequency readings use private Apple APIs, loaded read-only; if one is unavailable on your macOS release, its tile shows `—` instead of guessing.
- GlowTop asks for no Full Disk Access and shows no permission prompt in normal use. The one exception: walking into a folder macOS protects from the Disk Space page may prompt once; denying it is safe and the folder shows as locked.
- The only actions GlowTop takes against the system — quitting a process, and enabling/disabling your own user-level Startup Apps and Services — each require a confirmation sheet and are logged to `~/Library/Logs/GlowTop/actions.log`.

## Known limitations

- Sizing a large folder on the Disk Space page is throughput-bound by design: it reads every file beneath it, so a whole-disk walk takes minutes. It runs at utility priority so the rest of the app stays responsive, shows its progress, and can be stopped at any time with everything already measured kept.
- The macOS permission prompt for a protected folder has not been triggered on a live system; the locked-folder display it leads to is covered by unit tests and the app's automated self-check.
- `Benchmarks` and `Settings` appear greyed out in the sidebar: not in this version. The `PRO` heading in the sidebar is only a section label — there is no paid tier and no payment anything.

## Requirements

macOS 14 or later, Apple Silicon. No Intel build.

## Verifying the download

```bash
shasum -a 256 -c GlowTop-1.2.0.dmg.sha256
```
