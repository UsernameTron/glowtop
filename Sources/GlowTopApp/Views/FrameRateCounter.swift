import AppKit
import Foundation

/// §6.7's two numbers — frames serviced and frames that produced new pixels — counted per
/// whole second, with the `GLOWTOP_LOG_FPS` line the harness parses.
///
/// Moved out of `SummaryPaneView` in phase-10 (sub-step 2.1): §6.2 kills Summary's display
/// link when another pane shows, so a pane that wants an `fps` reading of its own must count
/// its own ticks through this same counter rather than a copy of it.
@MainActor
final class FrameRateCounter {
    private var ticksThisSecond = 0
    private var drawsThisSecond = 0
    private var rateWindowStart = Date()
    private(set) var fps: Double = 0
    private(set) var draws: Double = 0
    /// §9.2's Frame rate row. The last whole-second reading and the instant it was taken,
    /// captured together so they freeze together: `updateLinkState()` kills the link when this
    /// view loses its window, and System Info is showing exactly when that has happened. The
    /// age the row displays has to be the reading's own, not the poll's.
    private(set) var frameRate: (fps: Double, at: Date)?

    /// The counter window has to start over with the link. Without this the first `fps`
    /// after the pane is shown again divides one second of ticks by the whole interval the
    /// link was dead — `0.03 fps` after a minute away — and §9.2's Frame rate row then
    /// publishes and freezes exactly that value onto another pane.
    func reset() {
        ticksThisSecond = 0
        drawsThisSecond = 0
        rateWindowStart = Date()
    }

    /// §6.7's second number is counted where new pixels are actually produced.
    func countDraw() {
        drawsThisSecond += 1
    }

    /// One display-link tick. Returns `true` when a whole second closed and `fps` / `draws`
    /// were republished. `window` is read only then, for the display's refresh rate and the
    /// occlusion state the log line carries.
    func tick(window: NSWindow?, logFPS: Bool) -> Bool {
        ticksThisSecond += 1

        let elapsed = Date().timeIntervalSince(rateWindowStart)
        guard elapsed >= 1 else { return false }
        fps = Double(ticksThisSecond) / elapsed
        draws = Double(drawsThisSecond) / elapsed
        ticksThisSecond = 0
        drawsThisSecond = 0
        rateWindowStart = Date()
        // Stamped with the end of the window it averages — which is `rateWindowStart`, the
        // instant just taken — not with the time some later poll happened to read it. The pair
        // is assigned together so it freezes together when the link dies (§9.2).
        frameRate = (fps, rateWindowStart)

        let refresh = window?.screen?.maximumFramesPerSecond ?? 0
        let served = refresh > 0 ? fps / Double(refresh) * 100 : 0
        let visible = window?.occlusionState.contains(.visible) ?? false

        guard logFPS else { return true }
        // Field 1 stays the literal `fps` and field 2 stays the bare number:
        // `scripts/overhead-harness.sh` parses `grep '^fps' | awk '{ print $2 }'`, and gate 9
        // reads through that script in this same phase. `draws` is appended, never
        // substituted — changing an instrument's parser in the phase that takes its reading
        // is the move the project's lessons log records twice.
        print(String(format: "fps %.1f draws %.1f display %d served %.1f%% visible %@",
                     fps, draws, refresh, served, visible ? "yes" : "no"))
        fflush(stdout)
        return true
    }
}
