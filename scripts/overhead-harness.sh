#!/bin/bash
# Overhead harness — the instrument behind SPEC.md §13.1.1 and §13.7.1.
#
# Interleaved arms, CPU-time deltas over a fixed window, median and spread per arm. Also
# reports the app's RSS in MB and its growth across the window — PERF-02 and gate 10 need
# that number and nothing measured it until 2026-08-25.
#
# Gate 9 is app-process scope (SPEC.md §13.1.10, ruled 2026-08-25): the `app` and `rss`
# columns are the gated ones. `ws` and `machine` are diagnostic — the compositor cost is
# documented, not gated (§13.1.9). Whole-machine is diagnostic for a second reason too: a
# sum of `ps` cputime loses processes that exit mid-window, and the measuring session is
# itself the load (§13.7.1).
#
#   scripts/overhead-harness.sh <rounds> <arm>...
#     arm = baseline | WxH   (window frame size; pinned to screen 0 at a fixed origin)
#   env: SETTLE (s after launch, default 20), WINDOW (s, default 60), OUT (dir)
#
#   scripts/overhead-harness.sh 5 baseline 900x400 450x200
set -u
cd "$(dirname "$0")/.." || exit 1
APP=.build/release/GlowTopApp
ROUNDS=${1:-5}; shift
ARMS=("$@")
SETTLE=${SETTLE:-20}
WINDOW=${WINDOW:-60}
OUT=${OUT:-harness-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

# CPU seconds for one pid, or for every process ('all'). ps prints M:SS.cc or H:MM:SS.cc.
cpu() {
    if [ "$1" = all ]; then ps -axo time=; else ps -o time= -p "$1"; fi \
        | awk -F: '{ if (NF == 3) s += $1 * 3600 + $2 * 60 + $3; else s += $1 * 60 + $2 }
                   END { printf "%.2f", s }'
}

# Resident set size for one pid, in KB. PERF-02 and gate 10 both need it and nothing
# measured it before; `ps -o rss=` is the same number Activity Monitor's Memory column shows.
rss() { ps -o rss= -p "$1" 2>/dev/null | awk '{ print $1 + 0 }'; }

median() { sort -n | awk '{ a[NR] = $1 } END { if (NR) print a[int((NR + 1) / 2)] }'; }

reading() {
    local arm=$1 round=$2 pid="" log ws
    log="$OUT/$arm-r$round.log"
    ws=$(pgrep -x WindowServer)
    if [ "$arm" != baseline ]; then
        GLOWTOP_SCREEN=0 GLOWTOP_LOG_FPS=1 GLOWTOP_WINDOW_SIZE=$arm "$APP" > "$log" 2>&1 &
        pid=$!
        sleep "$SETTLE"
    fi
    local a0=0 a1=0 w0 w1 m0 m1 geom="" fps="" r0=0 r1=0
    [ -n "$pid" ] && { a0=$(cpu "$pid"); r0=$(rss "$pid"); }
    w0=$(cpu "$ws"); m0=$(cpu all)
    sleep "$WINDOW"
    [ -n "$pid" ] && { a1=$(cpu "$pid"); r1=$(rss "$pid"); }
    w1=$(cpu "$ws"); m1=$(cpu all)
    if [ -n "$pid" ]; then
        geom=$(grep -m1 'window on screen' "$log")
        fps=$(grep '^fps' "$log" | tail -n "+$SETTLE" | awk '{ print $2 }' | median)
        kill "$pid"; wait "$pid" 2>/dev/null
    fi
    awk -v arm="$arm" -v r="$round" -v a0="$a0" -v a1="$a1" -v w0="$w0" -v w1="$w1" \
        -v m0="$m0" -v m1="$m1" -v win="$WINDOW" -v fps="$fps" -v geom="$geom" \
        -v r0="$r0" -v r1="$r1" 'BEGIN {
        printf "%s\tround=%d\tapp=%.2f\tws=%.2f\tmachine=%.2f\trss=%.1f\trssgrow=%.1f\tfps=%s\t%s\n",
            arm, r, (a1 - a0) / win * 100, (w1 - w0) / win * 100, (m1 - m0) / win * 100,
            r1 / 1024, (r0 > 0 ? (r1 - r0) / r0 * 100 : 0), fps, geom
    }' | tee -a "$OUT/readings.tsv"
    sleep 5
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
    for col in app ws machine rss rssgrow; do
        grep "^$arm	" "$OUT/readings.tsv" | tr '\t' '\n' | grep "^$col=" | cut -d= -f2 \
            | sort -n | awk -v arm="$arm" -v col="$col" '{ a[NR] = $1 }
              END { if (NR) printf "%s\t%s\tmedian=%.2f\tspread=%.2f\tn=%d\n",
                    arm, col, a[int((NR + 1) / 2)], a[NR] - a[1], NR }'
    done
done | tee -a "$OUT/readings.tsv"
