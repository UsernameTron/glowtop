#!/bin/bash
# Per-pane cost, minimized or visible — phase-06's own check, and a **diagnostic** instrument
# only. The gate-9 instrument is scripts/overhead-harness.sh, and it is deliberately neither
# edited nor extended here: an instrument changed inside the phase that reads it is the
# mistake the project's lessons log records this project making twice.
#
# What it measures: the CPU-time delta of the GlowTop process over WINDOW seconds, with a
# named pane selected and the window either minimized or visible. Never `ps -o %cpu`
# (SPEC.md §13.1.1) — that column is a decaying average that charges the app for its launch.
#
# What would make the reading meaningless: the ⌘-digit landing before the window is key, so
# the arm measures whichever pane was already showing (Summary, by AppState's default) while
# reporting the pane it asked for. Every arm therefore verifies its own pane through AX before
# the measurement window opens, and refuses the reading if it cannot: the detail area's scroll
# area has a distinct child-role signature per pane, measured 2026-08-29 —
#   Summary      AXScrollBar
#   Processes    AXTable, AXScrollBar
#   Users        AXStaticText, AXTable, AXStaticText, AXTable, AXScrollBar
#   System Info  AXStaticText × many
# The check runs after the keystroke and before the minimize, so it costs nothing inside the
# window. Each arm's log also carries the app's own `window on screen ... occluded=` line.
#
# Its confounds, recorded in context.txt: power source, macOS version, arms, rounds, windows.
# Which display and what geometry are pinned by GLOWTOP_SCREEN / GLOWTOP_WINDOW_SIZE, the
# same hooks the harness uses (SPEC.md §13.1.5). Ambient load is not a control (§13.7.1);
# arms rotate per round, and the result is a median and a spread, never a mean.
#
#   scripts/pane-cost.sh <rounds> <arm>...
#     arm = <cmd-digit>:<min|vis>    ⌘1 Summary, ⌘3 Processes, ⌘4 System Info,
#                                    ⌘5 Startup apps, ⌘6 Users, ⌘7 Services
#   env: SETTLE (s after the pane is set, default 20), WINDOW (s, default 20), OUT (dir)
#
#   scripts/pane-cost.sh 3 1:min 3:min 6:min 3:vis
set -u
cd "$(dirname "$0")/.." || exit 1
APP=.build/release/GlowTopApp
ROUNDS=${1:-3}; shift
ARMS=("$@")
SETTLE=${SETTLE:-20}
WINDOW=${WINDOW:-20}
OUT=${OUT:-pane-cost-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# CPU seconds for one pid. ps prints M:SS.cc or H:MM:SS.cc. Lifted from overhead-harness.sh
# rather than shared, so that file stays untouched this phase.
cpu() {
    ps -o time= -p "$1" \
        | awk -F: '{ if (NF == 3) s += $1 * 3600 + $2 * 60 + $3; else s += $1 * 60 + $2 }
                   END { printf "%.2f", s }'
}

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

reading() {
    local arm=$1 round=$2 key=${1%%:*} mode=${1##*:} log pid
    log="$OUT/${arm/:/-}-r$round.log"
    GLOWTOP_SCREEN=0 GLOWTOP_WINDOW_SIZE=1440x900 "$APP" > "$log" 2>&1 &
    pid=$!
    # The window has to exist and be key before ⌘N reaches it; applyMeasurementHooks sets the
    # frame at +2 s, so 4 s is that plus slack. GLOWTOP_MINIMIZE is not used: it fires from
    # that same +2 s dispatch, before any pane can be selected.
    sleep 4
    osascript -e 'tell application "System Events" to tell process "GlowTopApp"' \
              -e 'set frontmost to true' \
              -e "keystroke \"$key\" using command down" \
              -e 'end tell' >> "$log" 2>&1
    sleep 1
    # Verify the pane before the window closes over it. A reading whose pane cannot be
    # confirmed is discarded, not corrected — this is the one confound that produces a
    # confident number for the wrong subject.
    local sig got want
    sig=$(pane_signature); got=$(pane_name "$sig"); want=$(expected_pane "$key")
    echo "pane check: cmd-$key expected=$want got=$got sig=[$sig]" >> "$log"
    if [ "$got" != "$want" ]; then
        printf '%s\tround=%d\tapp=SKIP\tpane check FAILED: expected %s, got %s [%s]\n' \
            "$arm" "$round" "$want" "$got" "$sig" | tee -a "$OUT/readings.tsv"
        kill "$pid"; wait "$pid" 2>/dev/null
        sleep 3
        return
    fi
    if [ "$mode" = min ]; then
        osascript -e 'tell application "System Events" to tell process "GlowTopApp" to set value of attribute "AXMinimized" of window 1 to true' >> "$log" 2>&1
    fi
    sleep "$SETTLE"
    local a0 a1 r0 r1 geom
    a0=$(cpu "$pid"); r0=$(rss "$pid")
    sleep "$WINDOW"
    a1=$(cpu "$pid"); r1=$(rss "$pid")
    geom=$(grep -m1 'window on screen' "$log")
    kill "$pid"; wait "$pid" 2>/dev/null
    awk -v arm="$arm" -v r="$round" -v a0="$a0" -v a1="$a1" -v r0="$r0" -v r1="$r1" \
        -v win="$WINDOW" -v geom="$geom" 'BEGIN {
        printf "%s\tround=%d\tapp=%.2f\trss=%.1f\trssgrow=%.1f\t%s\n",
            arm, r, (a1 - a0) / win * 100, r1 / 1024,
            (r0 > 0 ? (r1 - r0) / r0 * 100 : 0), geom
    }' | tee -a "$OUT/readings.tsv"
    sleep 3
}

echo "power: $(pmset -g batt | head -1)" | tee "$OUT/context.txt"
echo "macOS: $(sw_vers -productVersion)  arms: ${ARMS[*]}  rounds: $ROUNDS  settle: ${SETTLE}s  window: ${WINDOW}s" | tee -a "$OUT/context.txt"

n=${#ARMS[@]}
for ((round = 1; round <= ROUNDS; round++)); do
    # Rotate the start each round so no arm always runs first or last.
    for ((i = 0; i < n; i++)); do reading "${ARMS[$(( (i + round - 1) % n ))]}" "$round"; done
done

echo; echo "summary (median / spread = max - min):" | tee -a "$OUT/readings.tsv"
for arm in "${ARMS[@]}"; do
    for col in app rss rssgrow; do
        grep "^$arm	" "$OUT/readings.tsv" | tr '\t' '\n' | grep "^$col=" | cut -d= -f2 \
            | sort -n | awk -v arm="$arm" -v col="$col" '{ a[NR] = $1 }
              END { if (NR) printf "%s\t%s\tmedian=%.2f\tspread=%.2f\tn=%d\n",
                    arm, col, a[int((NR + 1) / 2)], a[NR] - a[1], NR }'
    done
done | tee -a "$OUT/readings.tsv"
