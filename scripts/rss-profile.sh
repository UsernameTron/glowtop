#!/bin/bash
# Cumulative-pane RSS, footprint and vmmap — phase-08's own instrument, and a **diagnostic**
# one only. The gate-9/PERF-02 instrument is scripts/overhead-harness.sh, and it is deliberately
# neither edited nor extended here; scripts/pane-cost.sh is likewise untouched. An instrument
# changed inside the phase that reads it is the mistake the project's lessons log records this
# project making twice. Phase-06 wrote pane-cost.sh fresh and read it in the same phase for the
# same reason, and this script follows that precedent exactly.
#
# What it measures, and why neither existing script can: the app's RSS after a **cumulative**
# walk across panes, plus footprint/vmmap category breakdowns at the end of the walk.
# overhead-harness.sh only ever shows Summary and never drives a pane. pane-cost.sh drives
# exactly ONE pane per launch (`<digit>:<min|vis>`), so it cannot express "visit all seven and
# then measure" — the arm that produced the M01 audit's 258.1 MB.
#
#   scripts/rss-profile.sh <rounds> <arm>...
#     arm = <WxH>:<walk>      walk = '-'-separated steps
#     steps: 1 Summary, 3 Processes, 4 System Info, 5 Startup apps, 6 Users, 7 Services,
#            C Colors (menu item, NOT a cmd-digit — Commands.swift)
#   env: SETTLE (s after launch before the walk, default 20)
#        STEP   (s after each pane switch, default 10)
#        WINDOW (s after the walk before the scored reading, default 20)
#        OUT    (output dir)
#
#   scripts/rss-profile.sh 3 1440x900:1 1100x732:1 1440x900:1-3-4-5-6-7-C-1
#
# Six refusals, and every one of them REFUSES rather than corrects (phase-06's recorded lesson:
# build the "am I measuring the right subject" assertion INTO the instrument and make it refuse).
# A refused arm writes a SKIP row naming the reason and publishes no number:
#   1 dirty tree      2 wrong/stale binary   3 wrong geometry
#   4 wrong pane AT EVERY STEP               5 dead pid       6 wrong timepoint
#
# Refusal 5 exists because a reaped pid produces a beautiful 0.0 MB: `ps -o rss=` prints nothing,
# awk reads zero records, rss() returns the EMPTY STRING, and the caller's `awk -v r1=` coerces
# it to 0. The defect is caller-side, so the guard is caller-side and rss() stays byte-identical
# to the copied block.
set -u
cd "$(dirname "$0")/.." || exit 1
APP=.build/release/GlowTopApp
ROUNDS=${1:-3}; shift
ARMS=("$@")
SETTLE=${SETTLE:-20}
STEP=${STEP:-10}
WINDOW=${WINDOW:-20}
OUT=${OUT:-rss-profile-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# Copied VERBATIM from scripts/pane-cost.sh:52-80 so that file stays untouched this phase.
# Lifted rather than shared: pane-cost.sh has a top-level `cd`, `set -u` and a run loop, so
# sourcing it would execute it. `diff` against the source range proves the copy.
# ---------------------------------------------------------------------------
rss() { ps -o rss= -p "$1" 2>/dev/null | awk '{ print $1 + 0 }'; }

# The detail area's scroll-area child roles — the per-pane signature the header table lists.
pane_signature() {
    osascript -e 'tell application "System Events" to tell process "GlowTopApp" to return role of every UI element of scroll area 1 of group 2 of splitter group 1 of group 1 of window 1' 2>&1
}

# Which pane that signature names. `unknown` is a refusal, not a guess.
pane_name() {
    case "$1" in
        AXScrollBar)                                        echo summary ;;
        AXTable,\ AXScrollBar)                              echo processes ;;
        AXStaticText,\ AXTable,\ AXStaticText,\ AXTable,\ AXScrollBar) echo users ;;
        AXTextField*)                                       echo colors ;;
        AXStaticText,\ AXStaticText*)                       echo staticreader ;;
        *)                                                  echo unknown ;;
    esac
}

# The pane each ⌘-digit is supposed to select (SPEC.md §3.4, Commands.swift).
expected_pane() {
    case "$1" in
        1) echo summary ;;
        3) echo processes ;;
        6) echo users ;;
        4|5|7) echo staticreader ;;
        *) echo unknown ;;
    esac
}
# ---------------------------------------------------------------------------
# End of the copied block. Everything below is this script's own.
# ---------------------------------------------------------------------------

# Colors has no cmd-digit (Commands.swift — `Edit Colors…`, menu only), so it is not in the
# copied expected_pane(). Wrapped rather than edited, so the block above stays byte-identical
# to pane-cost.sh:52-80 and a diff proves it.
expected_step() { if [ "$1" = C ]; then echo colors; else expected_pane "$1"; fi; }

# --- Pane identity, measured rather than assumed -----------------------------------------
#
# The copied pane_name()/expected_pane() pair is not sufficient for a seven-pane walk, and this
# was established by DRIVING the app on 2026-08-31 rather than by reading the header table.
# pane-cost.sh's own header claims "a distinct child-role signature per pane" but its table only
# ever lists four panes, and it only ever drove arms 1, 3 and 6 — which are genuinely distinct,
# so phase-06's readings stand. The full survey:
#
#   cmd-1 Summary       [AXScrollBar]
#   cmd-3 Processes     [AXTable, AXScrollBar]
#   cmd-4 System Info   [AXStaticText × 50, AXScrollBar]
#   cmd-5 Startup apps  [AXTable, AXScrollBar]        <-- IDENTICAL to Processes
#   cmd-6 Users         [AXStaticText, AXTable, AXStaticText, AXTable, AXScrollBar]
#   cmd-7 Services      [AXTable, AXScrollBar]        <-- IDENTICAL to Processes
#   Colors              [AXStaticText, AXTextField, … , AXScrollBar]
#
# Two consequences. expected_pane() maps 5 and 7 to `staticreader`, which is simply wrong — both
# render tables. And Processes, Startup apps and Services are MUTUALLY INDISTINGUISHABLE by
# detail-area child roles; no amount of pattern-matching separates them. Column headers do not
# help either (all report the generic description `column`; counts are 8/7/7).
#
# So the check is built from what CAN be established: the signature's class, plus the fact that
# it CHANGED since the previous step. In this phase's walk every adjacent pair differs in class
# (summary -> table -> staticreader -> table -> users -> table -> colors -> summary), so a
# keystroke that fails to land always leaves the class equal to the previous step's and always
# refuses. `assert_walk_alternates` below refuses any walk for which that is not true, so the
# change-check can never be silently relied on where it does not hold.
#
# The copied block stays byte-identical and unused for classification; this is a strictly
# stronger check layered above it.

sig_class() {
    case "$1" in
        AXScrollBar)                                                    echo summary ;;
        *AXTextField*)                                                  echo colors ;;
        AXStaticText,\ AXTable,\ AXStaticText,\ AXTable,\ AXScrollBar)  echo users ;;
        AXTable,\ AXScrollBar)                                          echo table ;;
        AXStaticText,\ AXStaticText*)                                   echo staticreader ;;
        *)                                                              echo unknown ;;
    esac
}

# What each step is EXPECTED to produce, from the survey above and not from expected_pane().
step_class() {
    case "$1" in
        1)     echo summary ;;
        3|5|7) echo table ;;
        4)     echo staticreader ;;
        6)     echo users ;;
        C)     echo colors ;;
        *)     echo unknown ;;
    esac
}

# Refuse any walk in which two adjacent steps share a class -- the change-check would be
# vacuous there, and a keystroke that failed to land would pass unnoticed.
assert_walk_alternates() {
    local walk=$1 prev="" c
    local -a st
    IFS='-' read -r -a st <<< "$walk"
    for c in "${st[@]}"; do
        local cls; cls=$(step_class "$c")
        if [ "$cls" = unknown ]; then
            echo "REFUSED: walk '$walk' contains unknown step '$c'"; return 1
        fi
        if [ "$cls" = "$prev" ]; then
            echo "REFUSED: walk '$walk' has adjacent steps of the same class ($cls) --" \
                 "the change-check cannot verify it"; return 1
        fi
        prev=$cls
    done
    return 0
}

# Drive one step. Colors goes through the menu; everything else is its cmd-digit.
select_step() {
    local step=$1 log=$2
    if [ "$step" = C ]; then
        osascript -e 'tell application "System Events" to tell process "GlowTopApp"' \
                  -e 'set frontmost to true' \
                  -e 'click menu item "Edit Colors…" of menu 1 of menu bar item "Colors" of menu bar 1' \
                  -e 'end tell' >> "$log" 2>&1
    else
        osascript -e 'tell application "System Events" to tell process "GlowTopApp"' \
                  -e 'set frontmost to true' \
                  -e "keystroke \"$step\" using command down" \
                  -e 'end tell' >> "$log" 2>&1
    fi
}

skip() {
    printf '%s\tround=%d\tarm=SKIP\t%s\n' "$1" "$2" "$3" | tee -a "$OUT/readings.tsv"
}

# Refusal 1 — dirty tree. A reading whose tree is not the tree the record names is a reading of
# nothing. Checked once, before the first launch, and it refuses the whole run.
if [ -n "$(git status --porcelain Sources scripts Package.swift)" ]; then
    echo "REFUSED: working tree dirty under Sources/, scripts/ or Package.swift" | tee -a "$OUT/readings.tsv"
    git status --porcelain Sources scripts Package.swift | tee -a "$OUT/readings.tsv"
    exit 1
fi

# Refusal 2 — wrong or stale binary. A stale release build measured against a changed tree is
# the classic; `swift build` is never run from inside this script, so the check is the guard.
if [ ! -x "$APP" ]; then
    echo "REFUSED: $APP missing or not executable" | tee -a "$OUT/readings.tsv"; exit 1
fi
if [ -n "$(find Sources -name '*.swift' -newer "$APP" -print -quit)" ]; then
    echo "REFUSED: $APP is older than a file under Sources/ — run swift build -c release" \
        | tee -a "$OUT/readings.tsv"
    find Sources -name '*.swift' -newer "$APP" -print | tee -a "$OUT/readings.tsv"
    exit 1
fi

reading() {
    local arm=$1 round=$2
    local geom_want=${arm%%:*} walk=${arm##*:}
    local log="$OUT/${arm//:/-}-r$round.log"
    local tag="${arm//:/-}-r$round"
    local launched pid sig got want elapsed step_start i step prev_sig=""

    GLOWTOP_SCREEN=0 GLOWTOP_WINDOW_SIZE="$geom_want" GLOWTOP_LOG_GEOM=1 "$APP" > "$log" 2>&1 &
    pid=$!
    launched=$(date +%s)
    # applyMeasurementHooks sets the frame at +2 s; 4 s is that plus slack, and the window has
    # to exist and be key before any cmd-N or menu click reaches it.
    sleep 4

    # Refusal 5 — dead pid, checked before anything is believed.
    if ! kill -0 "$pid" 2>/dev/null; then skip "$arm" "$round" "dead pid before walk"; return; fi

    # Refusal 3 — wrong geometry. GLOWTOP_WINDOW_SIZE silently does nothing without
    # GLOWTOP_SCREEN (GlowTopApp.swift:72-84 nests the size parse inside the screen guard), so a
    # size-only launch restores the autosaved frame — which is the exact variable under test.
    # The app's own log line is the only reliable detector.
    local geom_got
    geom_got=$(grep -m1 -o 'frame=[0-9]*x[0-9]*' "$log" | cut -d= -f2)
    if [ "$geom_got" != "$geom_want" ]; then
        skip "$arm" "$round" "geometry: wanted $geom_want got ${geom_got:-none}"
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 3; return
    fi

    sleep "$SETTLE"

    i=0
    IFS='-' read -r -a STEPS <<< "$walk"
    for step in "${STEPS[@]}"; do
        i=$((i + 1))
        select_step "$step" "$log"
        # Refusal 4 — wrong pane, AT EVERY STEP and not only the last. A walk that misses step 4
        # and lands right at step 8 still reports a plausible cumulative curve, wrong in the
        # middle where nobody looks.
        #
        # The wait is a BOUNDED POLL, not a fixed sleep, and the distinction is the whole
        # correctness of this check. A pane switch is asynchronous: `state.selectedPane` is
        # written, SwiftUI re-renders on its NEXT pass, and PaneHostView.show(_:) then constructs
        # the controller on first visit -- which for Processes means building a table of ~700
        # rows. Measured 2026-08-31: a flat `sleep 1` refused every walk arm at step 2, and round
        # 3 refused at step 4 reporting `got=processes` while expecting `staticreader` -- lagging
        # exactly one step, which is the signature of a check that is early rather than a
        # keystroke that never landed.
        #
        # The poll does NOT weaken the refusal: a pane that never switches still exhausts the
        # timeout and still refuses, with its last signature recorded. It only stops the check
        # firing before the pane it is asking about can exist.
        want=$(step_class "$step")
        local waited=0
        while [ "$waited" -lt 20 ]; do
            sig=$(pane_signature); got=$(sig_class "$sig")
            # Both conditions, together: the class is what this step should produce, AND the
            # signature actually moved off the previous step's. Either alone is insufficient --
            # three panes share the `table` class, so class-match alone would accept a keystroke
            # that never landed while sitting on one of the other two.
            if [ "$got" = "$want" ] && [ "$sig" != "$prev_sig" ]; then break; fi
            sleep 0.5
            waited=$((waited + 1))
        done
        echo "pane check: step=$i key=$step expected=$want got=$got changed=$([ "$sig" != "$prev_sig" ] && echo yes || echo no) sig=[$sig]" >> "$log"
        if [ "$got" != "$want" ]; then
            skip "$arm" "$round" "pane step=$i key=$step expected=$want got=$got sig=[$sig]"
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 3; return
        fi
        if [ "$sig" = "$prev_sig" ]; then
            skip "$arm" "$round" "pane step=$i key=$step did not change signature (class=$got) -- keystroke did not land"
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 3; return
        fi
        prev_sig=$sig
        step_start=$(date +%s)
        sleep "$STEP"
        if ! kill -0 "$pid" 2>/dev/null; then skip "$arm" "$round" "dead pid at step=$i"; return; fi
        local r; r=$(rss "$pid")
        if [ -z "$r" ] || [ "$r" = 0 ]; then
            skip "$arm" "$round" "no rss at step=$i"
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 3; return
        fi
        # Refusal 6 — wrong timepoint, measured from the clock rather than assumed from sleeps.
        # Phase-07's gate 3 measured 1801 s of sleeps and 28 minutes of clock.
        elapsed=$(( $(date +%s) - step_start ))
        if [ "$elapsed" -lt "$STEP" ]; then
            skip "$arm" "$round" "timepoint: step=$i elapsed ${elapsed}s < STEP ${STEP}s"
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 3; return
        fi
        awk -v arm="$arm" -v rd="$round" -v i="$i" -v k="$step" -v r="$r" \
            -v t="$(( $(date +%s) - launched ))" 'BEGIN {
            printf "%s\tround=%d\tstep=%d\tkey=%s\trss=%.1f\tt=%ss\n", arm, rd, i, k, r/1024, t }' \
            | tee -a "$OUT/readings.tsv"
    done

    # The scored reading: WINDOW after the walk ends.
    sleep "$WINDOW"
    if ! kill -0 "$pid" 2>/dev/null; then skip "$arm" "$round" "dead pid before scored reading"; return; fi
    local rs; rs=$(rss "$pid")
    if [ -z "$rs" ] || [ "$rs" = 0 ]; then
        skip "$arm" "$round" "no rss at scored reading"
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; sleep 3; return
    fi
    elapsed=$(( $(date +%s) - launched ))
    awk -v arm="$arm" -v rd="$round" -v r="$rs" -v t="$elapsed" 'BEGIN {
        printf "%s\tround=%d\tstep=scored\tkey=-\trss=%.1f\tt=%ss\n", arm, rd, r/1024, t }' \
        | tee -a "$OUT/readings.tsv"

    # footprint and vmmap AFTER the scored window closes, never inside it — both walk the
    # target's address space with the task briefly suspended. `ps` on both sides turns "these
    # might perturb the process" into a recorded number instead of a worry.
    local pre post
    pre=$(rss "$pid")
    footprint -p "$pid"    > "$OUT/$tag-footprint.txt" 2>&1
    vmmap --summary "$pid" > "$OUT/$tag-vmmap.txt"     2>&1
    post=$(rss "$pid")
    printf 'perturbation\t%s\tpre=%s\tpost=%s\tdelta_kb=%s\n' \
        "$tag" "$pre" "$post" "$(( ${post:-0} - ${pre:-0} ))" | tee -a "$OUT/readings.tsv"

    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    sleep 3
}

{
    echo "power: $(pmset -g batt | head -1)"
    echo "macOS: $(sw_vers -productVersion)  arms: ${ARMS[*]}  rounds: $ROUNDS  settle: ${SETTLE}s  step: ${STEP}s  window: ${WINDOW}s"
    echo "subject: $APP  sha256: $(shasum -a 256 "$APP" | cut -d' ' -f1)"
    echo "commit: $(git rev-parse --short HEAD)"
    # Theme is a CONFOUND COLUMN, recorded and never normalised — it is MeterLayer.textureCache's
    # key space, and normalising it would be a write against the operator's machine.
    echo "theme(GlowTopApp): $(defaults read GlowTopApp theme.presetName 2>/dev/null || echo unset)"
    echo "theme(com.glowtop.GlowTop): $(defaults read com.glowtop.GlowTop theme.presetName 2>/dev/null || echo unset)"
} | tee "$OUT/context.txt"

# Every walk is checked for alternation BEFORE any launch: the change-check that makes the
# three table panes verifiable is only valid where adjacent steps differ in class.
for arm in "${ARMS[@]}"; do
    if ! assert_walk_alternates "${arm##*:}"; then
        echo "REFUSED: arm '$arm'" | tee -a "$OUT/readings.tsv"; exit 1
    fi
done

n=${#ARMS[@]}
for ((round = 1; round <= ROUNDS; round++)); do
    # Rotate the start each round so no arm always runs first or last.
    for ((i = 0; i < n; i++)); do reading "${ARMS[$(( (i + round - 1) % n ))]}" "$round"; done
done

echo; echo "summary (median / spread = max - min):" | tee -a "$OUT/readings.tsv"
for arm in "${ARMS[@]}"; do
    for st in $(grep "^$arm	" "$OUT/readings.tsv" | grep -o 'step=[^	]*' | cut -d= -f2 | sort -u); do
        grep "^$arm	" "$OUT/readings.tsv" | grep "step=$st	" | grep -o 'rss=[0-9.]*' | cut -d= -f2 \
            | sort -n | awk -v arm="$arm" -v st="$st" '{ a[NR] = $1 }
              END { if (NR) printf "%s\tstep=%s\trss\tmedian=%.2f\tspread=%.2f\tn=%d\n",
                    arm, st, a[int((NR + 1) / 2)], a[NR] - a[1], NR }'
    done
done | tee -a "$OUT/readings.tsv"
