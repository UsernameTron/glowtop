#!/bin/bash
# Package-power baseline: the candidate instrument for the compositor budget (SPEC.md §13.1.8, §13.1.9).
#
# powermetrics needs root, so the maintainer runs this. Sessions never run it and the app never
# calls it (CLAUDE.md safety rules). Three channels are reported separately — CPU, GPU, and
# combined (CPU + GPU + ANE) — because the first smoke run put all of the noise in CPU
# (188–2238 mW across five idle seconds) and 14 mW in GPU; a sum hides which one moved.
#
# The per-window statistic is the MEDIAN, per §13.7.1's "report the median and the spread,
# never a mean". Run 1 (§13.1.9) is why: idle CPU power on this machine is burst-distributed
# — a third of samples land above twice the window median, with peaks over 5000 mW — so the
# window mean read 517 mW where the median read 246. The mean measures the bursts. The
# window mean is still printed, as a diagnostic for how burst-heavy the window was.
#
# A window is SAMPLES, not seconds: powermetrics at -i 1000 takes ~1.02 s per sample on this
# machine. The first SETTLE_SAMPLES samples (the sudo prompt, the terminal) are discarded,
# matching overhead-harness.sh's 20 s settle.
#
#   sudo scripts/power-baseline.sh [windows=5] [samples=60]   # live run; raw log under docs/measurements/
#   scripts/power-baseline.sh --parse FILE [samples=60]       # summarize a saved log
#   scripts/power-baseline.sh --selftest                      # parse the fixture, assert median and spread per channel
set -u
cd "$(dirname "$0")/.." || exit 1
SETTLE_SAMPLES=20

# Reads a powermetrics log on stdin. "GPU Power:" is printed twice per sample (processor
# block, then GPU block); only the first is taken, or the windows desynchronize.
summarize() {
    awk -v S="$1" -v SETTLE="$SETTLE_SAMPLES" '
        function med(a, n,   i, j, x, s) {
            for (i = 1; i <= n; i++) s[i] = a[i]
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (s[j] < s[i]) { x = s[i]; s[i] = s[j]; s[j] = x }
            return s[int((n + 1) / 2)]
        }
        function spread(a, n,   i, j, x, s) {
            for (i = 1; i <= n; i++) s[i] = a[i]
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (s[j] < s[i]) { x = s[i]; s[i] = s[j]; s[j] = x }
            return s[n] - s[1]
        }
        /^confound: / || /^Machine model:/ || /^OS version:/ { print; next }
        /^\*\*\* Sampled system activity/ { gpu_seen = 0 }
        /^CPU Power:/ { cpu = $3 }
        /^GPU Power:/ { if (!gpu_seen) { gpu = $3; gpu_seen = 1 } }
        /^Combined Power/ {
            n++; if (n <= SETTLE) next
            k++; i = (k - 1) % S + 1
            cv[i] = cpu; gv[i] = gpu; tv[i] = $(NF - 1)
            sc += cpu; sg += gpu; stt += $(NF - 1)
            if (k % S == 0) {
                w++
                mc[w] = med(cv, S); mg[w] = med(gv, S); mt[w] = med(tv, S)
                ac[w] = sc / S; ag[w] = sg / S; at[w] = stt / S
                sc = sg = stt = 0
            }
        }
        END {
            if (!w) { printf "no complete window: %d samples after the %d-sample settle, window is %d samples\n", k, SETTLE, S; exit 1 }
            for (i = 1; i <= w; i++)
                printf "window %d (%d samples): CPU %.0f mW  GPU %.0f mW  combined %.0f mW   (means: %.0f / %.0f / %.0f)\n",
                    i, S, mc[i], mg[i], mt[i], ac[i], ag[i], at[i]
            printf "CPU       median %.0f mW  spread %.0f mW  n=%d\n", med(mc, w), spread(mc, w), w
            printf "GPU       median %.0f mW  spread %.0f mW  n=%d\n", med(mg, w), spread(mg, w), w
            printf "combined  median %.0f mW  spread %.0f mW  n=%d\n", med(mt, w), spread(mt, w), w
            printf "per-window statistic is the median (§13.7.1); window means shown for burstiness only\n"
            printf "settle: %d samples discarded; window = %d samples (~1.02 s each); %d trailing samples unused\n", SETTLE, S, k % S
        }'
}

if [ "${1:-}" = --selftest ]; then
    out=$(summarize 3 < scripts/fixtures/power-baseline.log)
    # The fixture's third sample per window is a burst an order of magnitude up: a parser that
    # averaged the window instead of taking its median cannot produce these numbers.
    for want in "CPU       median 160 mW  spread 100 mW  n=3" \
                "GPU       median 20 mW  spread 20 mW  n=3" \
                "combined  median 180 mW  spread 120 mW  n=3"; do
        grep -qF -- "$want" <<< "$out" || { echo "selftest: FAIL — expected: $want"; echo "$out"; exit 1; }
    done
    echo "selftest: PASS"
    exit
fi
if [ "${1:-}" = --parse ]; then
    summarize "${3:-60}" < "$2"
    exit
fi

WINDOWS=${1:-5}
SAMPLES_PER=${2:-60}
[ "$(id -u)" -eq 0 ] || { echo "powermetrics needs root: sudo $0 $*" >&2; exit 1; }
user=${SUDO_USER:-$USER}
mkdir -p docs/measurements
log="docs/measurements/power-baseline-$(date +%Y%m%d-%H%M%S).log"

# Confound block (§13.1.9): written to the log and the terminal; --parse replays it. The
# display/census probe runs as the invoking user so it sees that user's WindowServer session.
{
    echo "confound: date: $(date)"
    echo "confound: power source: $(pmset -g batt | head -1)"
    echo "confound: macOS: $(sw_vers -productVersion)"
    sudo -u "$user" swift -e '
        import AppKit
        for s in NSScreen.screens { print("confound: display: \(s.localizedName) \(Int(s.frame.width))x\(Int(s.frame.height)) @ \(s.maximumFramesPerSecond) Hz\(s == NSScreen.main ? " (main)" : "")") }
        let wins = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in wins where (w[kCGWindowLayer as String] as? Int) == 0 {
            let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            print("confound: window: \(w[kCGWindowOwnerName as String] ?? "?") \(b["Width"] ?? 0)x\(b["Height"] ?? 0) at \(b["X"] ?? 0),\(b["Y"] ?? 0)")
        }' 2>/dev/null || echo "confound: display/census: unavailable"
    echo "confound: settle: $SETTLE_SAMPLES samples discarded; windows: $WINDOWS x $SAMPLES_PER samples"
    echo "confound: raw log: $log"
} | tee "$log"

powermetrics --samplers cpu_power,gpu_power -i 1000 -n $((SETTLE_SAMPLES + WINDOWS * SAMPLES_PER)) \
    | tee -a "$log" | summarize "$SAMPLES_PER"
echo "raw log: $log is owned by root — run: sudo chown $user $log" >&2
