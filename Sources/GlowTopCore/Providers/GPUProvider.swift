import Foundation
import IOKit

/// SPEC.md §5.6.1, §5.6.2, §5.6.5, §5.6.6. Primary path: IOReport's `GPU Stats | GPU
/// Performance States`, whose residency-delta gives idle-state share directly (§5.6.1 says
/// IOReport first, registry second). Fallback: the `IOAccelerator` registry's `Device
/// Utilization %`, per the discretion table -- first entry carrying both a
/// `PerformanceStatistics` dictionary and that key, preferred over `Renderer Utilization %`
/// (one engine's share, not the device's).
public struct GPUProvider: MetricProvider {
    public let id = ProviderID.gpu
    public let nominalInterval = SampleRate.hz2

    private var subscription: IOReportSubscription?
    private var subscriptionInitialized = false
    private var chipName: String?
    private var chipNameResolved = false
    private var lastValue: GPUSample?

    public init() {}

    public mutating func sample() -> Snapshot<GPUSample> {
        guard !PrivateAPI.disabled else { return .unavailable(reason: PrivateAPI.disabledReason) }

        if !chipNameResolved {
            chipNameResolved = true
            chipName = Sysctl.string("machdep.cpu.brand_string")
        }
        if !subscriptionInitialized {
            subscriptionInitialized = true
            subscription = IOReportSubscription(group: "GPU Stats", subGroup: "GPU Performance States")
        }

        let now = ContinuousClock().now

        if let subscription {
            guard let channels = subscription.sampleDelta() else {
                return .warming // no baseline yet -- §5.0.3, not a failure worth falling back for
            }
            if let channel = channels.first(where: { !$0.states.isEmpty }),
               let result = Self.gpuUtilization(states: channel.states) {
                let sample = GPUSample(
                    utilization: result.value, source: "IOReport", uncertain: result.uncertain,
                    chipName: chipName, coreCount: Self.readIOAccelerator()?.coreCount,
                    idleStateName: result.idleStateName
                )
                lastValue = sample
                return .value(sample, timestamp: now)
            }
        }

        // Subscription creation failed, or its delta carried no usable state channel --
        // §5.6.1's registry fallback.
        if let fallback = Self.readIOAccelerator() {
            let sample = GPUSample(
                utilization: fallback.utilization, source: "IOAccelerator", uncertain: false,
                chipName: chipName, coreCount: fallback.coreCount, idleStateName: nil
            )
            lastValue = sample
            return .value(sample, timestamp: now)
        }

        // Both paths produced nothing usable this tick (§5.6.5's zero/negative-delta case).
        // Hold the last good reading rather than flicker to unavailable on a single bad tick.
        if let lastValue { return .value(lastValue, timestamp: now) }
        return .unavailable(reason: "IOReport subscription failed")
    }

    /// The state whose upper-cased name contains `IDLE` or equals `OFF`; index `0` if none
    /// match. Written as its own pure function -- and tested as one -- rather than folded
    /// into `gpuUtilization`, because a hardcoded index silently reads 100 % idle-share wrong
    /// the moment a SoC's state table starts with something other than idle.
    static func idleStateIndex(names: [String]) -> Int {
        names.firstIndex { $0.uppercased().contains("IDLE") || $0.uppercased() == "OFF" } ?? 0
    }

    /// §5.6.2's utilization arithmetic plus §5.6.5's range check, over a decoded state array.
    /// Pure and static: testable from fixture tuples with no GPU.
    static func gpuUtilization(
        states: [(name: String, residency: UInt64)]
    ) -> (value: Double, uncertain: Bool, idleStateName: String)? {
        guard !states.isEmpty else { return nil }
        let idleIndex = idleStateIndex(names: states.map(\.name))
        let idleResidency = states[idleIndex].residency
        let total = states.reduce(UInt64(0)) { $0 + $1.residency }
        guard let result = utilization(
            idleResidencyDelta: Int64(clamping: idleResidency), totalResidencyDelta: Int64(clamping: total)
        ) else { return nil }
        return (result.value, result.uncertain, states[idleIndex].name)
    }

    /// `1 - idle/total`, §5.6.5's range check. Zero total → `nil` (caller returns the previous
    /// value or `.warming`). Any negative delta → `nil` (a wrapped or reset counter; caller
    /// treats it the same as zero). Outside `0...1` → clamped, `uncertain = true`.
    static func utilization(
        idleResidencyDelta: Int64, totalResidencyDelta: Int64
    ) -> (value: Double, uncertain: Bool)? {
        guard idleResidencyDelta >= 0, totalResidencyDelta >= 0 else { return nil }
        guard totalResidencyDelta != 0 else { return nil }
        let raw = 1.0 - Double(idleResidencyDelta) / Double(totalResidencyDelta)
        guard (0...1).contains(raw) else { return (min(1, max(0, raw)), true) }
        return (raw, false)
    }

    /// `IOAccelerator`'s `PerformanceStatistics` dictionary, first entry carrying both it and
    /// `Device Utilization %` (§5.6.1's fallback path, verified live on this Mac at plan time).
    /// Every matched service and the iterator released on every path out, `defer`-placed so an
    /// early `continue` cannot skip one -- `DiskProvider.readCounters()`'s pattern.
    static func readIOAccelerator() -> (utilization: Double, coreCount: Int?)? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(
                service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }
            guard let deviceUtil = stats["Device Utilization %"] as? NSNumber else { continue }

            let coreCount = (IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? NSNumber)?.intValue
            return (min(1, max(0, deviceUtil.doubleValue / 100)), coreCount)
        }
        return nil
    }
}
