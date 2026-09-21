import Foundation

/// SPEC.md §5.6.3 (package power) and §5.6.4 (the ANE), one IOReport `Energy Model`
/// subscription serving both the Energy and NPU tiles (§6.3's discretion: one subscription,
/// two tiles, so one number cannot disagree with its own copy).
public struct EnergyProvider: MetricProvider {
    public let id = ProviderID.energy
    public let nominalInterval = SampleRate.hz1

    /// §5.6.4's provisional ceiling -- named and cited so it reads as a stated assumption,
    /// not a magic number.
    public static let provisionalANECeilingWatts = 8.0

    private var subscription: IOReportSubscription?
    private var subscriptionInitialized = false
    private var previousAt: ContinuousClock.Instant?
    private var lastValue: EnergySample?

    public init() {}

    public mutating func sample() -> Snapshot<EnergySample> {
        guard !PrivateAPI.disabled else { return .unavailable(reason: PrivateAPI.disabledReason) }

        if !subscriptionInitialized {
            subscriptionInitialized = true
            subscription = IOReportSubscription(group: "Energy Model", subGroup: nil)
        }
        guard let subscription else { return .unavailable(reason: "IOReport subscription failed") }

        let now = ContinuousClock().now
        defer { previousAt = now }

        guard let channels = subscription.sampleDelta() else { return .warming }
        guard let previousAt else { return .warming }

        switch SampleInterval.classify(from: previousAt, to: now) {
        case .toosoon:
            if let lastValue { return .value(lastValue, timestamp: now) }
            return .warming
        case .stale:
            return .warming
        case .usable(let seconds):
            guard let composed = Self.compose(channels: channels, seconds: seconds) else { return .warming }
            // §5.6.5: power outside 0...200 W rejects the sample outright -- the one range
            // check that does not clamp.
            guard Self.isWithinPowerRange(composed.watts) else {
                return .unavailable(reason: "value out of range")
            }
            let ane = Self.aneUtilization(channels: channels, aneWatts: composed.aneWatts)
            let sample = EnergySample(
                watts: composed.watts, cpuWatts: composed.cpuWatts, gpuWatts: composed.gpuWatts,
                aneWatts: composed.aneWatts, contributingChannels: composed.contributingChannels,
                aneUtilization: ane.utilization, aneSource: ane.source,
                dramWatts: composed.dramWatts
            )
            lastValue = sample
            return .value(sample, timestamp: now)
        }
    }

    struct Composition: Equatable {
        let watts: Double
        let cpuWatts: Double?
        let gpuWatts: Double?
        let aneWatts: Double?
        let dramWatts: Double?
        let contributingChannels: [String]
    }

    /// §5.6.3's headline set. Unchanged by phase-11: `DRAM` is read beside these three and
    /// is not summed into the tile.
    static let headlineTargets = ["CPU Energy", "GPU", "ANE"]
    /// §14.1's fourth band only.
    static let paneOnlyTargets = ["DRAM"]

    /// §5.6.3's headline: `CPU Energy`, `GPU`, `ANE`, selected by **exact name** -- never
    /// `GPU Energy` or `GPU SRAM`, the group's other two GPU-adjacent channels, a million
    /// units and one order of magnitude away respectively from what this sums. Pure and
    /// static: testable from fixture channels with no hardware.
    static func compose(channels: [IOReportChannel], seconds: Double) -> Composition? {
        guard seconds > 0 else { return nil }
        var contributing: [String] = []
        var wattsByName: [String: Double] = [:]

        for name in headlineTargets + paneOnlyTargets {
            guard let channel = channels.first(where: { $0.name == name }) else { continue }
            // §5.0.4: a negative delta (a reset or wrapped counter) warms the whole sample
            // rather than silently excluding one channel from the sum.
            guard channel.value >= 0 else { return nil }
            let isHeadline = headlineTargets.contains(name)
            if let joules = joules(channel.value, unit: channel.unit) {
                // D-07: §4.6.3's tooltip lists the tile's channels only; DRAM is not in that tile.
                if isHeadline { contributing.append(name) }
                wattsByName[name] = joules / seconds
            } else if isHeadline {
                contributing.append("\(name) (unit ?)")
            }
        }

        // Spelled as a sum over the headline slice, not `values.reduce`, so a fifth pane-only
        // channel cannot silently join §4.6.3's tile (D-07).
        let headlineWatts = headlineTargets.compactMap { wattsByName[$0] }
        guard !headlineWatts.isEmpty else { return nil }
        return Composition(
            watts: headlineWatts.reduce(0, +),
            cpuWatts: wattsByName["CPU Energy"], gpuWatts: wattsByName["GPU"], aneWatts: wattsByName["ANE"],
            dramWatts: wattsByName["DRAM"],
            contributingChannels: contributing
        )
    }

    /// `raw` is IOReport's own cumulative-energy delta over the sample interval, in `unit`.
    /// The `/1000` (and its siblings) live here, not in the rate expression, so a unit
    /// change cannot leave a bare `/1000` behind that quietly stops being right.
    static func joules(_ raw: Int64, unit: String) -> Double? {
        switch unit {
        case "J": return Double(raw)
        case "mJ": return Double(raw) / 1_000
        case "uJ": return Double(raw) / 1_000_000
        case "nJ": return Double(raw) / 1_000_000_000
        default: return nil
        }
    }

    static func isWithinPowerRange(_ watts: Double) -> Bool {
        (0...200).contains(watts)
    }

    /// §5.6.4's two ANE paths. Path 1 -- a residency channel -- is implemented so this lights
    /// up on hardware that has one; on this Mac IOReport carries no ANE group and no
    /// residency channel, so path 2 (power over the provisional ceiling) is what ships.
    static func aneUtilization(
        channels: [IOReportChannel], aneWatts: Double?
    ) -> (utilization: Double?, source: String) {
        if let residency = channels.first(where: { $0.name.uppercased().contains("ANE") && !$0.states.isEmpty }),
           let value = residencyUtilization(states: residency.states) {
            return (value, "residency")
        }
        guard let aneWatts else { return (nil, "power/8W") }
        return (min(1, max(0, aneWatts / provisionalANECeilingWatts)), "power/8W")
    }

    /// 1 - idle share, over a residency channel this Mac does not carry for the ANE --
    /// implemented for the hardware that does, not exercised by any cross-check here.
    private static func residencyUtilization(states: [(name: String, residency: UInt64)]) -> Double? {
        guard !states.isEmpty else { return nil }
        let idleIndex = states.firstIndex { $0.name.uppercased().contains("IDLE") || $0.name.uppercased() == "OFF" } ?? 0
        let idle = states[idleIndex].residency
        let total = states.reduce(UInt64(0)) { $0 + $1.residency }
        guard total > 0, idle <= total else { return nil }
        return 1.0 - Double(idle) / Double(total)
    }
}
