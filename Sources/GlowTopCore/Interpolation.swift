/// Frame interpolation from SPEC.md §6.6.
///
/// Wall-clock, not frame count: interpolating by frame index breaks the moment a frame is
/// dropped or the display refresh is not 60 Hz. Clamped at 1.0: a late sample holds the
/// current value rather than extrapolating, because extrapolation invents data.
public enum Interpolation {
    public static func fraction(
        now: ContinuousClock.Instant,
        sampledAt: ContinuousClock.Instant,
        interval: Duration
    ) -> Double {
        let (intervalSeconds, intervalAttos) = interval.components
        let intervalDouble = Double(intervalSeconds) + Double(intervalAttos) * 1e-18
        guard intervalDouble > 0 else { return 1 }

        let (elapsedSeconds, elapsedAttos) = sampledAt.duration(to: now).components
        let elapsed = Double(elapsedSeconds) + Double(elapsedAttos) * 1e-18

        return min(max(elapsed / intervalDouble, 0), 1)
    }

    public static func value(from previous: Double, to current: Double, fraction: Double) -> Double {
        previous + (current - previous) * min(max(fraction, 0), 1)
    }
}
