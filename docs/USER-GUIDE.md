# GlowTop User Guide

GlowTop is a live dashboard for your Mac. It shows, in real time, how hard the
processor is working, how much memory is in use, what the disk and network are
doing, how warm the chip is, and which apps are responsible. Think of it as the
instrument cluster in a car: a glance tells you whether everything is fine, and
when it is not, it tells you where to look.

This guide uses everyday language. If you want the engineering detail behind any
screen, it lives in `SPEC.md`.

---

## 1. Getting started

**What you need.** A Mac with an Apple chip (M1 or newer) running macOS 14 or
later. GlowTop does not run on Intel Macs.

**Installing.** Open the downloaded `GlowTop-<version>.dmg`, then drag
`GlowTop.app` onto the `Applications` link in the same window. Eject the disk
image and open GlowTop from your Applications folder.

**If macOS asks before opening it.** An official release is signed and checked
by Apple, so macOS will not block it. The first time you open it, macOS may ask
once whether you want to open an app downloaded from the internet; click `Open`.
A copy that somebody else built and sent to you is different: macOS blocks it
the first time. Try to open it once, dismiss the warning, then go to System
Settings → Privacy & Security and click `Open Anyway`. (On macOS 14,
right-clicking the app and choosing `Open` also works.) You only have to do
this once. A copy you built yourself opens normally on the Mac that built it.

**Permissions.** GlowTop never asks for Full Disk Access and shows no permission
prompt in normal use. The one exception is described in the Disk Space section:
sizing a protected folder may trigger a single macOS question, and answering
"Don't Allow" is perfectly safe.

**Quitting.** Closing the window quits the app. There is no background mode and
no menu-bar icon.

---

## 2. The window at a glance

The window is always dark. That is by design: the bright neon marks are built to
be read against a near-black background, and there is no light mode.

**Left side: the sidebar.** A list of pages. Click one, or press its keyboard
shortcut, to show it on the right.

| Page | Shortcut | What it is for |
|---|---|---|
| Summary | ⌘1 | The main dashboard. Start here. |
| Performance | ⌘2 | Every processor core, one by one, plus history |
| Processes | ⌘3 | Everything running, sortable and searchable |
| System Info | ⌘4 | Facts about this Mac |
| Startup apps | ⌘5 | What launches automatically when you log in |
| Users | ⌘6 | Accounts on this Mac and who is logged in |
| Services | ⌘7 | Background jobs configured on this Mac |
| Power & Freq | ⌘8 | Chip speed and power draw in detail |
| Connections | ⌘9 | Which programs have network connections open |
| Installed Apps | ⌘0 | Your apps, sorted by how much disk they take |
| Disk Space | ⌘D | A map of what is filling your disk |
| Colors | – | Change the dashboard's color scheme |

Two sidebar rows, `Benchmarks` and `Settings`, are greyed out. They are
placeholders and do nothing; hover over one and it says `Not in this version`.

The `PRO` label in the sidebar is only a section heading carried over from the
layout GlowTop is modeled on. Every page is included; there is no paid tier.

**Bottom strip: the status bar.** Always visible. Reads something like:

```
Native providers healthy · 1138 processes · Generation 4218        14:32:07
```

In Simple mode the left side is one sentence: `Your Mac is running normally.`,
or what is happening instead — `Google Chrome is using most of the processor.`,
`Memory is nearly full — closing an app or two will help.`, `Your Mac is hot and
is slowing itself down to cool off.` If sampling stops or a reading is
unavailable, it says that instead, because those matter more.

In Technical mode the same strip reads like this:

- **Native providers healthy** means every gauge is getting real data. If a few
  readings are unavailable on your Mac, this changes to `2 providers unavailable`
  in yellow. Hover over it to see which ones and why.
- **1138 processes** is how many programs are running right now, including the
  hundreds macOS runs for you in the background.
- **Generation 4218** is a counter that ticks up ten times a second. If it ever
  stops moving, the dashboard has frozen and its numbers are stale. It is the
  quickest honesty check on the whole screen.
- **Sampling stalled** in red means exactly that. Switch to the Summary page
  (⌘1) and press ⌘R to force a fresh reading.
- The clock on the right is just the time.

---

### Simple and Technical

GlowTop opens in **Simple mode**: plain labels, a one-word verdict on each card,
a hover explanation, and a sentence at the bottom of the window saying what your
Mac is doing. This guide describes Simple mode and gives the Technical names in
parentheses.

`View › Use Technical Labels` switches to the engineering names and numbers —
`CPU OVERVIEW` instead of `PROCESSOR`, `20 GB resident / 48 GB` instead of
`20 GB of 48 GB in use`, and the status bar's `Native providers healthy · 1138
processes · Generation 4218` instead of a sentence. The readings themselves are
identical in both modes; only the words change. GlowTop remembers your choice.

| Simple | Technical |
|---|---|
| PROCESSOR | CPU OVERVIEW |
| BUSIEST APPS | TOP CPU PROCESSES |
| MEMORY, "20 GB of 48 GB in use" | MEMORY UTILIZATION, "20 GB resident / 48 GB" |
| POWER DRAW · GRAPHICS · AI CHIP · TEMPERATURE | ENERGY · GPU 0 · NPU 0 · THERMALS |
| Spilled to disk | Swap |
| ID, CPU use, Battery use, Location (Processes table) | PID, CPU %, Energy, Path |

---

## 3. Reading the Summary page

The Summary page is a fixed grid of cards. Nothing moves around or hides when
you resize the window; if the window is short, the page scrolls.

Every card follows the same pattern: a small grey title in the top-left, one
big colored number (the headline), a chart or meter in the middle, and a line
of small grey detail at the bottom (the footer). Most cards also carry a
one-word verdict on the right of that line: `Normal`, `Busy`, `Warm`, `Hot`,
`Low on memory`. The verdict is the fastest way to read the page. Three cards
have none on purpose: the four meters, BUSIEST APPS (a list, not a reading),
and POWER DRAW (watts are not good or bad; the heat they cause is, and
TEMPERATURE already says so). A card with no live reading shows no verdict at
all. Hover any card for a sentence explaining what it shows. Colors are consistent across
the whole app: **green is the processor, magenta is memory, blue is graphics
and network, yellow is energy, orange is heat, red is a warning or a limit.**

### 3.1 The four vertical meters (top-left)

Four thin columns of 40 small bars that light up from the bottom, like a level
meter on a stereo.

| Meter | Color | What it shows | Reading it |
|---|---|---|---|
| CPU | green | How busy the processor is overall | Idle Macs sit under 10%. Sustained 80%+ means something heavy is running. |
| SPEED | red | How fast the processor is running compared to its top speed | Label reads `Auto` because macOS controls this itself. Rises under load, drops at idle. |
| TEMP | orange | The hottest sensor on the chip | Room-temperature idle is 30–45 °C. 90 °C+ under load is normal for a laptop; the Mac slows itself down before harm. |
| GRAPHICS | blue | How busy the graphics processor is | Near zero unless you are gaming, editing video, or running a local AI model. |

(In Technical mode these read `CPU`, `CLOCK`, `TEMP` and `GPU`.)

### 3.2 PROCESSOR (top-center)

(Technical: CPU OVERVIEW.) The big green number is total processor use.
Directly under it is a row of tiny horizontal bars, one per core, each tagged
`F` (fast core) or `E` (efficient core) — `P` and `E` in Technical mode. This row is the most useful thing on the page: a total of
7% looks calm, but if one bar is fully lit, a single program has pinned one
core. The total hides that. The row shows it.

Below the bars is a chart of the last 60 seconds, newest at the right edge,
scrolling left continuously:

- **Green line, shaded underneath** – total processor use (0–100%, left axis).
- **Orange line** – chip temperature (right axis, in °C).
- **Red line** – the share of processor time spent inside macOS itself rather
  than in your apps. If the red line is close to the green line, the system is
  doing the work (disk indexing, backups, a driver). If there is a big gap, an
  app is doing it.

The footer names how many cores the chip has, for example `10 fast cores · 4
efficient cores`.

### 3.3 BUSIEST APPS (top-right)

(Technical: TOP CPU PROCESSES.) The twelve programs using the most processor right now, refreshed once a
second. Columns are the process number (PID), its name, its processor use, its
graphics use, and its memory. Rows slide into their new order rather than
jumping, so you can follow one with your eye.

- To inspect or quit one of these programs, press ⌘3 and find it on the
  Processes page.
- A `—` in the GPU column means macOS would not let GlowTop inspect that
  particular program. It is not a zero.

### 3.4 MEMORY (second row, full width)

(Technical: MEMORY UTILIZATION.) The magenta headline reads like `20.3 GB of
48 GB in use` — `20.3 GB resident / 48 GB` in Technical mode. It is the
memory currently occupied. It is GlowTop's own measurement and it will not
match Activity Monitor's "Memory Used" figure exactly. Both are right; they
count slightly different things.

The horizontal meter on the left is the same number as a fill level. The chart
on the right is 60 seconds of history, stacked in layers from the bottom:

1. **Brightest magenta** – memory macOS cannot move (wired).
2. **Medium magenta** – memory apps are actively using.
3. **Purple** – memory macOS has squeezed to fit more in.
4. **Dim purple** – recently used memory macOS keeps around in case it is
   needed again. This layer gives itself up first when something new needs room.

The unfilled space at the top is free memory. A thin **red line** that appears
above the stack is swap: memory that has spilled onto the disk because there
was no room. A little swap is fine. A rising red line while the Mac feels
sluggish is the classic sign of too many apps open for the memory installed.

The footer spells out, in gigabytes, how much can be freed, how much is
free, and how much has spilled to disk (Technical: Reclaimable, Free, Swap).
The verdict comes from macOS's own memory-pressure signal: `Normal`,
`Getting full`, or `Low on memory`.

### 3.5 The six small tiles (bottom two rows)

| Tile | Headline | Chart | Footer | Notes |
|---|---|---|---|---|
| DISKS (green) | Read and write speed, e.g. `R 12.4 · W 3.1 MB/s` | Solid line reads, dashed line writes | `R reading · W writing · 4 drives` | Includes every drive attached, not just the boot disk. |
| NETWORK (blue) | Data coming in and going out, e.g. `↓ 148.2 · ↑ 22.6 KB/s` | Solid line received, dashed line sent | The active network interface and its address | Units scale automatically from bytes to megabytes. |
| POWER DRAW (yellow) | Power the chip is drawing right now, in watts | 60 seconds of history | `Plugged in` or `Running on battery` | Idle is a few watts. Heavy work on a laptop can be 30–60 W. No verdict, on purpose. |
| GRAPHICS (blue) | Graphics processor use | 60 seconds of history | Chip name and graphics core count | |
| AI CHIP (red) | Neural Engine use | **No chart, on purpose** | Neural Engine core count | The Neural Engine is the hardest part of the chip to read. When it is busy, usually a local AI model is running. Often reads `—`, and that is honest, not broken. |
| TEMPERATURE (orange) | Hottest sensor | Up to four sensors, brightest is hottest | `Cooling is keeping up`, `Warming up — still at full speed`, `macOS is slowing things down to cool off`, or `macOS is slowing down sharply to cool off` | The last two mean macOS is throttling to stay cool. The verdict follows the same signal: `Normal`, `Warm`, `Hot`, `Critical`. |

### 3.6 The three "not a number" states

A dashboard that fakes a value is worse than one that says nothing. GlowTop
uses three distinct looks, and it is worth learning them:

| You see | It means | What to do |
|---|---|---|
| `···` (three grey dots), empty meter | **Warming up.** The reading needs two measurements and only has one so far. | Wait a second. It appears right after launch, after ⌘R, and after un-pausing. |
| `—` (a dash), and the card says `Unavailable on this Mac` | **Cannot read this on your Mac.** Usually a private Apple interface that changed with a macOS update. | Nothing. The rest of the app is unaffected. Hover the status bar's health phrase to see the reason. |
| Everything dimmed to a third of its brightness | **Stalled.** The reading has not updated in over two seconds. | Press ⌘R. If it keeps happening, quit and reopen GlowTop. |

---

## 4. The other pages

### Performance (⌘2)

The same processor and memory data as Summary, but bigger and per core. The
top card shows every core as its own bar with its own percentage, grouped as
`Fast` and `Efficient` cores (`P` and `E` in Technical mode). Use it when Summary's tiny core strip
shows one bar lit and you want to know which core and how much. Below are 60
seconds of processor history and 60 seconds of memory history at full height.

### Processes (⌘3)

Everything running on the Mac, one row each, refreshed once a second.

- **Search** (⌘F) filters by name, path, or process number as you type. Esc
  clears it.
- **Click a column heading** to sort by it; click again to reverse. Default is
  busiest first. Rows keep their place while you scroll; the list never jumps
  back to the top on refresh.
- **Columns:** ID (the process number), Name, CPU use, Memory, Threads, User
  (who owns it), Battery use (relative impact, 0–100), Location (where the
  program lives). In Technical mode these read PID, CPU %, Energy and Path.
- **Double-click** a row, or press ⌘I, to open an inspector with the full path,
  how long it has run, its parent, and its lifetime totals.

**Quitting a program.** Select a row and press Delete (or right-click and
choose `Quit Process`). A confirmation sheet names the program, its process
number, its user, and how much it is using, and warns that unsaved work may be
lost.

- `Quit` asks the program to close politely. This is the default. If the
  program has not gone within five seconds, a second sheet offers `Force Quit`
  or `Leave it`.
- `Force Quit` terminates it immediately, no questions asked to the program.
  Use it only when `Quit` did not work.
- `Cancel` or Esc backs out. Nothing is recorded.

GlowTop will refuse to quit the two processes that *are* macOS (`kernel_task`
and `launchd`), and it adds an extra warning line to the sheet for any process
owned by the system. If you do not own a process, the sheet says `Not
permitted` and nothing happens.

Every quit GlowTop actually attempts, successful or not, is written to a log at
`~/Library/Logs/GlowTop/actions.log`. If you ever wonder "what happened to that
program", that file has the answer.

### System Info (⌘4)

A plain list of facts, grouped: hardware (model, chip, cores, memory, serial
number), software (macOS version, uptime, boot disk), memory and storage, and a
final group about GlowTop itself showing how much processor and memory GlowTop
is using so it can never quietly become the problem it is meant to spot.

The serial number and hardware ID are shown but deliberately not copied by a
single click; right-click one to copy it. The "Frame rate" row shows the last
reading taken on the Summary page and how long ago, because no frame rate
exists while a different page is showing.

### Startup apps (⌘5)

Things configured to launch automatically, read from the three folders macOS
uses for them. Columns show whether each is enabled, its name, type, the
program it runs, and its file path. Right-click any row for `Reveal in Finder`.

For entries in your own user folder, right-click also offers `Enable` and
`Disable`. Each shows a confirmation sheet first and is written to the same
actions log as quitting a process. System-wide entries are read-only; the
tooltip says why.

Not listed: apps you added under System Settings → General → Login Items.
macOS offers no reliable way to read that list, so rather than show a partial
one, GlowTop says so in the page footer.

### Users (⌘6)

Two lists. **Accounts** is every real user account on this Mac, with home
folder, shell, and whether it is an administrator. **Sessions** is who is
logged in right now and how: at the screen, in a Terminal window, or remotely
over the network. The Sessions list is the one worth a glance now and then: a
remote session you do not recognize is something you want to know about.

Entirely read-only. Adding or removing users is System Settings' job.

### Services (⌘7)

Background jobs that are *configured* on this Mac, with a status dot: green
`Running` (GlowTop found the matching process), grey `Configured` (set up but
not currently running), or hollow `Unknown` (could not tell). Right-click for
`Reveal in Finder` or `Show Process`, which jumps to that job on the Processes
page.

For jobs in your own user folder, right-click also offers `Start` and `Stop`,
each with a confirmation sheet and a log entry.

The page footer explains, permanently, that this list is partial: macOS runs
far more background jobs than have a file on disk, and GlowTop only lists the
ones it can read reliably. A short honest list beats a long guessed one.

### Power & Freq (⌘8)

The chip in detail, in three stacked cards.

1. **Frequency Residency.** One column per group of cores (`P0`, `P1`, `E`).
   Each column is a stack of bands showing how much of the last 60 seconds the
   cores spent at each speed step. Brighter means faster; the dim band at the
   bottom is time spent asleep. A thin line traces the average speed. The
   caption gives the live average in GHz.
2. **DVFS States.** The same information as a bar chart: one bar per speed
   step, height is the share of time spent there. Mostly tall bars on the left
   means the chip has been idling; tall bars on the right mean sustained load.
3. **Package Power.** Total watts, split into layers for processor, graphics,
   Neural Engine, and memory. The processor and graphics numbers were checked
   against Apple's own `powermetrics` tool in September 2026 and agree.

### Connections (⌘9)

Every open network connection, one row each: the program, its process number,
protocol (TCP or UDP), the local address and port, the remote address and
port, and the connection state (`ESTABLISHED`, `LISTEN`, and so on). Sort and
search work exactly as on the Processes page.

Addresses are shown as numbers only. GlowTop never looks up names, because
that would itself be a network request, and GlowTop makes none. The footer
states how many programs it was allowed to inspect; connections belonging to
the others are not listed.

### Installed Apps (⌘0)

Every app in your Applications folders, sorted by disk size (largest first),
with version, identifier, who signed it, and whether it is built for Apple
silicon, Intel, or both. Measuring sizes means walking every file inside every
app, so the scan runs in the background with a progress count. `Rescan` starts
over; `Stop Scan` keeps what it has found so far.

### Disk Space (⌘D)

Two halves.

**Top: your volumes.** A bar per disk showing capacity, used, and free, read
instantly. If macOS is holding extra purgeable space (old snapshots, caches),
a note says how much more could be freed. This is why Finder's free-space
number and GlowTop's can differ; GlowTop shows the conservative one and names
the gap.

**Bottom: the map.** A treemap, where every folder is a rectangle sized by how
much disk it occupies. Bigger rectangle, more space. Nothing is measured until
you ask, because measuring means reading every file underneath, and that takes
real time. Press ⌘D a second time to start with your home folder, or click the
volume bar at the top to size the whole disk. Either way the page tells you
before it starts: `Sizing 32 items in ~ — this walks every file beneath
them.` Expect about a minute for a home folder; a whole disk takes several.

- Rectangles appear as each folder finishes. A progress count and a `Stop`
  button are always visible; stopping keeps what has been measured.
- **Click** a rectangle, or select it and press Return, to go inside it.
  **Delete** goes back up. Arrow keys move the selection. The breadcrumb trail
  above the map jumps straight to any parent.
- A **small grey rectangle with a dash** is a folder macOS would not let
  GlowTop read. It is drawn small on purpose rather than at a guessed size.
  Entering such a folder may trigger a one-time macOS permission question;
  choosing "Don't Allow" is safe and the folder simply stays locked.
- Sizes are **on-disk** sizes, which is the number that matters for "what
  would deleting this give back". A note under the map explains when on-disk
  and logical sizes differ a lot, which is common with cloud-synced folders,
  disk images, and duplicated files.

This page only looks. It cannot delete, move, or trash anything.

### Colors

Three ready-made schemes: `Neon` (the default), `Classic Green`, and
`Amber Retro`. Pick one from the `Colors` menu, or open the Colors page to
edit any of the 22 individual colors. Changes apply instantly to the live
dashboard. ⌘Z undoes an edit; `Reset to preset` puts everything back. If an
edit would make text too faint to read, the row shows a contrast warning.

---

## 5. Keyboard shortcuts worth memorizing

| Key | Does |
|---|---|
| **Space** | Pause the dashboard. Everything freezes so you can read a spike before it scrolls away. Press again to resume. The status bar reads `Paused` while frozen. (If a search box has the cursor, Space types a space instead.) Works on the Summary, Performance and Power & Freq pages. |
| ⌘R | Force a fresh reading right now. Works on the same three pages as Space. |
| ⌘1 … ⌘0, ⌘D | Switch pages (see the table in section 2) |
| ⌘F | Jump to the search box on the Processes, Connections and Installed Apps pages |
| Delete | Quit the selected process (with confirmation) |
| ⌘I | Inspect the selected process |
| Esc | Close any sheet or clear the search box |
| ⇧⌘F | Show or hide a tiny frame-rate counter in the corner (a developer aid; safe to ignore) |
| ⌘Q | Quit GlowTop |

---

## 6. What GlowTop will never do

- **It never connects to the internet.** No update checks, no analytics, no
  crash reports, nothing. The Connections page reads the list of connections;
  it does not make any.
- **It never asks for your password** or administrator rights.
- **It never changes a setting on your Mac.** The complete list of things it
  can do to the system is: quit a process, and enable, disable, start, or stop
  a background job in your own user folder. Every one of those shows a
  confirmation first and is written to `~/Library/Logs/GlowTop/actions.log`.
- **It never deletes a file.** The Disk Space page is a map, not a cleaner.
- **It never guesses.** A reading it cannot take shows `—`, not a made-up
  number.

---

## 7. Common questions

**A tile shows `—` and says "Unavailable on this Mac." Is something broken?**
No. Some readings (graphics, Neural Engine, energy, temperatures, clock speed)
come from parts of macOS that Apple does not document. When a macOS update
changes one, that tile goes dark instead of showing a wrong number. Everything
else keeps working.

**Why does the memory number differ from Activity Monitor?**
They measure slightly different things. GlowTop's "resident" figure is the
memory actually occupied right now. Activity Monitor's "Memory Used" adds some
categories and subtracts others. Neither is wrong.

**Why does free disk space differ from Finder?**
Finder counts space macOS could free by throwing away snapshots and caches.
GlowTop shows the space that is free right now and notes how much more is
purgeable.

**My Mac feels slow. Where do I look?**
Summary first. If the CPU meter is high, check the Top CPU Processes card for
the name. If the memory chart has a rising red swap line, you have more open
than the memory can hold; close something. If the Thermals footer says
anything other than nominal, the Mac is slowing itself to cool down; give it
airflow and a minute.

**The numbers are frozen.**
Check the status bar. If it says `Paused`, switch to the Summary page (⌘1) and
press Space. If it says `Sampling stalled`, press ⌘R there. If the Generation
counter is not moving and neither helps, quit and reopen GlowTop.

**Can I run it on an Intel Mac?**
No. GlowTop reads Apple-silicon-specific hardware and there is no Intel build.

**Where is the log of what GlowTop did?**
`~/Library/Logs/GlowTop/actions.log`. In Finder, choose Go → Go to Folder and
paste that path. One line per action, oldest first.
