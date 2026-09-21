import Foundation

/// Identifies a provider in the status bar, the probe CLI, and logs. SPEC.md §5.0.1.
public enum ProviderID: String, Sendable, CaseIterable {
    case cpu
    case memory
    case disk
    case network
    case process
    // SPEC.md §5.6-5.9, built in phase-03.1. They are listed here from phase-03 because
    // §4.7's status phrase counts unavailable providers and §5.10's acceptance criterion is
    // that four tiles read "—" while the app runs correctly. A provider absent from this
    // enum is a provider the status bar cannot report as unavailable, which would let the
    // pane look healthier than it is.
    case gpu
    case npu
    case energy
    case thermal
    case frequency
}

/// One reading from a provider.
///
/// There is no `throws` anywhere in the provider contract. A provider that cannot read its
/// hardware returns `.unavailable(reason)`; the reason reaches the status-bar tooltip.
/// This is what makes SPEC.md §1.3's "never crash" structural rather than aspirational.
public enum Snapshot<Payload: Sendable>: Sendable {
    /// Provider is alive but a delta needs two samples and only one exists. SPEC.md §5.0.3.
    case warming
    /// Provider cannot read this hardware on this machine or OS. SPEC.md §5.0.5, whose
    /// vocabulary is closed: "unsupported on this Mac", "IOReport subscription failed",
    /// "no matching IOService", "key not present", "kernel call failed: <kern_return_t>",
    /// "permission denied", "composition does not sum", "provider not built", "private
    /// APIs disabled". A provider needing a new reason adds it to §5.0.5 rather than
    /// inventing one at the call site.
    case unavailable(reason: String)
    case value(Payload, timestamp: ContinuousClock.Instant)

    public var payload: Payload? {
        if case .value(let p, _) = self { return p }
        return nil
    }

    public var timestamp: ContinuousClock.Instant? {
        if case .value(_, let t) = self { return t }
        return nil
    }
}

/// SPEC.md §5.0.1. Providers hold their own delta state and are used from exactly one
/// actor, so they need no internal locking.
public protocol MetricProvider: Sendable {
    associatedtype Payload: Sendable

    var id: ProviderID { get }
    /// The sample interval this provider wants. SPEC.md §5.0.2.
    var nominalInterval: Duration { get }

    mutating func sample() -> Snapshot<Payload>
}

/// Delta-provider guard rails from SPEC.md §5.0.3. A sample taken too soon divides by a
/// near-zero denominator; one taken across a sleep is not a measurement of anything.
public enum SampleInterval {
    /// Below this, reuse the previous value rather than dividing by a near-zero denominator.
    public static let minimum = Duration.milliseconds(50)
    /// Above this, discard the delta baseline and re-warm.
    public static let staleAfter = Duration.seconds(5)

    public enum Verdict: Sendable, Equatable {
        case toosoon
        case usable(seconds: Double)
        case stale
    }

    public static func classify(
        from previous: ContinuousClock.Instant,
        to now: ContinuousClock.Instant
    ) -> Verdict {
        let elapsed = previous.duration(to: now)
        if elapsed < minimum { return .toosoon }
        if elapsed > staleAfter { return .stale }
        let (seconds, attoseconds) = elapsed.components
        return .usable(seconds: Double(seconds) + Double(attoseconds) * 1e-18)
    }
}

/// The §5.0.2 rate table, one definition per distinct rate. Providers read these for their
/// `nominalInterval` and `MetricStore` reads them for its timers, so a provider's declared
/// rate and the timer that actually drives it cannot drift apart.
///
/// Not to be confused with `SampleInterval` above, which is the §5.0.3 delta guard rail.
public enum SampleRate {
    /// CPU (§5.1) and memory (§5.2).
    public static let hz10 = Duration.milliseconds(100)
    /// Disk (§5.3) and network (§5.4).
    public static let hz4 = Duration.milliseconds(250)
    /// GPU (§5.6) and frequency (§5.9).
    public static let hz2 = Duration.milliseconds(500)
    /// Process table (§5.5), energy (§5.7), thermals (§5.8).
    public static let hz1 = Duration.seconds(1)
}

/// What a reader sees, as opposed to what a provider returns. It mirrors `Snapshot`'s three
/// cases and adds a fourth the provider cannot know about: `.stalled`, meaning no sample has
/// arrived in over 2 s (§4.8 — hold the last value, dimmed).
///
/// This is deliberately **not** nested inside `MetricStore.Frame`. A type nested in a generic
/// is parameterized by the outer generic even when none of its cases mention the payload, so
/// `Frame<CPUSample>.State` and `Frame<DiskSample>.State` would be unrelated types — and
/// §4.7's "N providers unavailable" status phrase, which must compare states across
/// providers, would be unwritable.
public enum MetricState: Sendable, Equatable {
    case warming
    case unavailable(reason: String)
    case live
    /// No sample in over 2 s. SPEC.md §4.8: hold the last value, dimmed.
    case stalled
}
