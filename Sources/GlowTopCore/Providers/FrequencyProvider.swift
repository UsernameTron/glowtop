import Foundation
import IOKit

/// SPEC.md §5.9. IOReport `CPU Stats | CPU Complex Performance States` for the P-cluster's
/// residency-weighted mean, the IOKit device tree for the state frequency table, `sysctl`
/// for the maximum-frequency fallback.
///
/// **Deviation from the plan's literal channel rule, recorded here rather than left implicit:**
/// this Mac's dual-P-cluster M4 Pro exposes not two but six channels whose name begins with
/// `P` -- `PCPU`/`PCPU1` (the busy/idle residency table) and `PCPM`/`PCPM1` plus
/// `PCPM_IDLE`/`PCPM1_IDLE` (a second, differently-bucketed accounting of the same two
/// clusters, confirmed by their identical `DOWN` residencies). Summing all six per the plan's
/// literal "begins with P" would double- or triple-count each physical cluster. This provider
/// selects channels whose name begins with `PCPU` specifically -- `PCPU` and `PCPU1` on this
/// Mac, generalizing to a single `PCPU` on a single-P-cluster SoC -- and sums those elementwise.
/// The E-cluster (`ECPU`) is never selected either way.
public struct FrequencyProvider: MetricProvider {
    public let id = ProviderID.frequency
    public let nominalInterval = SampleRate.hz2

    /// §5.9.1's "and siblings", in the order tried -- named here so `tableSource` records
    /// which one actually answered.
    static let deviceTreeKeys = ["voltage-states5-sram", "voltage-states5", "voltage-states1-sram", "voltage-states1"]

    private var subscription: IOReportSubscription?
    private var subscriptionInitialized = false
    private var frequencyTableMHz: [Double]?
    private var maxMegahertz: Double?
    private var tableSource = "none"
    private var deviceTreeResolved = false
    private var lastValue: FrequencySample?
    /// §14.1's core counts by cluster channel name, read once beside the device tree.
    private var coreCountsByCluster: [String: Int] = [:]
    /// §14.1's per-key table cache: one decode per key per process, not one per sample.
    /// `resolveDeviceTree()` is deliberately not routed through it (D-10).
    private var tableCache: [String: [Double]?] = [:]

    public init() {}

    public mutating func sample() -> Snapshot<FrequencySample> {
        guard !PrivateAPI.disabled else { return .unavailable(reason: PrivateAPI.disabledReason) }

        if !subscriptionInitialized {
            subscriptionInitialized = true
            subscription = IOReportSubscription(group: "CPU Stats", subGroup: "CPU Complex Performance States")
        }
        guard let subscription else { return .unavailable(reason: "IOReport subscription failed") }

        if !deviceTreeResolved {
            deviceTreeResolved = true
            resolveDeviceTree()
            coreCountsByCluster = Self.readCoreCounts()
        }
        guard let maxMegahertz else { return .unavailable(reason: "key not present") }

        let now = ContinuousClock().now
        guard let channels = subscription.sampleDelta() else { return .warming }

        guard let summed = Self.sumPClusterStates(channels: channels) else {
            return .unavailable(reason: "key not present")
        }
        let active = Self.activeStates(summed)

        // Without a per-state frequency table there is no way to pair a residency array
        // against anything, regardless of whether `maxMegahertz` came from the table or the
        // `sysctl` fallback -- §5.9.1's current-frequency reading needs the table itself.
        guard let table = frequencyTableMHz, active.count == table.count else {
            return .unavailable(reason: "key not present")
        }

        let residencies = active.map { Int64(clamping: $0.residency) }
        guard let mean = Self.weightedMean(residencies: residencies, frequenciesMHz: table) else {
            if let lastValue { return .value(lastValue, timestamp: now) }
            return .warming
        }

        let fraction = min(1, max(0, mean / maxMegahertz))
        let sample = FrequencySample(
            performanceMegahertz: mean, maxMegahertz: maxMegahertz, fraction: fraction,
            stateCount: active.count, tableSource: tableSource,
            clusters: Self.buildClusters(channels: channels, coreCounts: coreCountsByCluster,
                                         tableFor: { self.table(forKey: $0) })
        )
        lastValue = sample
        return .value(sample, timestamp: now)
    }

    /// §5.9.1's table and §5.9.2's maximum, resolved once. Device-tree keys tried in
    /// `deviceTreeKeys`' order; `sysctl`'s `hw.cpufrequency_max` only ever supplies the
    /// maximum on its own, which this provider cannot pair with a residency table, so a
    /// `sysctl`-only answer is recorded but does not by itself make a live reading possible.
    private mutating func resolveDeviceTree() {
        for key in Self.deviceTreeKeys {
            guard let data = Self.readDeviceTreeProperty(key), let table = Self.decodeVoltageStates(data)
            else { continue }
            frequencyTableMHz = table
            maxMegahertz = table.max()
            tableSource = "device-tree:\(key)"
            return
        }
        guard let sysctlHz = Sysctl.uint64("hw.cpufrequency_max"), sysctlHz > 0 else {
            tableSource = "none"
            return
        }
        maxMegahertz = Double(sysctlHz) / 1_000_000
        tableSource = "sysctl"
    }

    /// `IODeviceTree:/arm-io/pmgr`'s `key` property as raw bytes. The registry entry is
    /// released on every path out.
    private static func readDeviceTreeProperty(_ key: String) -> Data? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/pmgr")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
    }

    /// Consecutive 8-byte records: a little-endian `UInt32` frequency, then a little-endian
    /// `UInt32` voltage in mV (not read). Returns MHz, dropping zero-frequency entries.
    /// Odd-length data, no data, or every entry zero-frequency -> `nil`.
    ///
    /// **Deviation from the plan's stated unit, confirmed against this Mac:** the plan
    /// describes the frequency field as Hz. Read live from `voltage-states5-sram`, the raw
    /// values are `1260000...4512000` -- Hz would put the P-cluster's ceiling at 4.512 MHz,
    /// three orders of magnitude below any Apple Silicon core; **kHz** puts it at 4512 MHz
    /// (4.512 GHz), matching the M4 Pro's published boost clock. The field is kHz, not Hz.
    static func decodeVoltageStates(_ data: Data) -> [Double]? {
        guard !data.isEmpty, data.count % 8 == 0 else { return nil }
        var frequenciesMHz: [Double] = []
        var index = data.startIndex
        while index < data.endIndex {
            let hostOrder = data[index..<(index + 4)].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let freqKHz = UInt32(littleEndian: hostOrder)
            index += 8 // the paired voltage field is not read
            if freqKHz > 0 {
                frequenciesMHz.append(Double(freqKHz) / 1_000)
            }
        }
        return frequenciesMHz.isEmpty ? nil : frequenciesMHz
    }

    /// The channel naming rule this provider actually uses -- see the deviation note above.
    static func isPClusterChannel(name: String) -> Bool {
        name.uppercased().hasPrefix("PCPU")
    }

    /// Every `PCPU*` channel's state residencies, summed elementwise. `nil` if none matched,
    /// or if the matched channels' state tables disagree in length (alignment cannot be
    /// trusted across mismatched tables).
    static func sumPClusterStates(channels: [IOReportChannel]) -> [(name: String, residency: UInt64)]? {
        let matched = channels.filter { isPClusterChannel(name: $0.name) }
        guard let first = matched.first else { return nil }
        guard matched.allSatisfy({ $0.states.count == first.states.count }) else { return nil }

        var summed = first.states
        for channel in matched.dropFirst() {
            for index in summed.indices {
                summed[index].residency += channel.states[index].residency
            }
        }
        return summed
    }

    /// Drops `DOWN` and `IDLE` -- power-gated states with no entry in the frequency table,
    /// not DVFS states themselves -- leaving exactly the states the device tree's table
    /// pairs against, in the same order.
    static func activeStates(
        _ states: [(name: String, residency: UInt64)]
    ) -> [(name: String, residency: UInt64)] {
        states.filter { $0.name.uppercased() != "DOWN" && $0.name.uppercased() != "IDLE" }
    }

    /// §5.9.1: `Σ(residency_s x frequency_s) / Σ residency_s`. Zero total residency -> `nil`
    /// (caller returns the previous value or `.warming`); any negative residency -> `nil`
    /// (§5.0.4). Pure and static: testable from fixture arrays with no hardware.
    static func weightedMean(residencies: [Int64], frequenciesMHz: [Double]) -> Double? {
        guard residencies.count == frequenciesMHz.count, !residencies.isEmpty else { return nil }
        guard residencies.allSatisfy({ $0 >= 0 }) else { return nil }
        let total = residencies.reduce(Int64(0), +)
        guard total > 0 else { return nil }
        let weighted = zip(residencies, frequenciesMHz).reduce(0.0) { $0 + Double($1.0) * $1.1 }
        return weighted / Double(total)
    }

    // MARK: - §14.1's per-cluster output (phase-11), beside the summed path above

    /// §14.1's cluster rule. A cluster channel is `ECPU`/`PCPU` followed by nothing or by
    /// **exactly one** digit. This excludes every `*CPM*` accounting channel (they carry
    /// `CPM`, not `CPU` -- the deviation recorded above), and it excludes the three-digit
    /// per-core names in `CPU Core Performance States` (`PCPU140`, `ECPU000`), which matter
    /// because `coreCounts(from:)` one function below is handed exactly that list.
    static func isClusterChannel(name: String) -> Bool {
        let upper = name.uppercased()
        for prefix in ["ECPU", "PCPU"] where upper.hasPrefix(prefix) {
            let suffix = upper.dropFirst(prefix.count)
            return suffix.isEmpty || (suffix.count == 1 && suffix.allSatisfy(\.isNumber))
        }
        return false
    }

    /// `PCPU` -> `P0`, `PCPU1` -> `P1`, `ECPU` -> `E`, `ECPU1` -> `E1` (§14.1's table).
    /// The asymmetry is §14.1's: there are two P clusters to tell apart and one E cluster.
    static func clusterLabel(for name: String) -> String {
        let upper = name.uppercased()
        let isEfficiency = upper.hasPrefix("ECPU")
        let suffix = upper.dropFirst(4)
        if isEfficiency { return suffix.isEmpty ? "E" : "E\(suffix)" }
        return suffix.isEmpty ? "P0" : "P\(suffix)"
    }

    /// `"ECPU"`/`"PCPU"` -> the E/P key lists, in the order tried. §5.9's `deviceTreeKeys`
    /// split by kind; the union of these two lists is `deviceTreeKeys` unchanged.
    static func tableKeys(forCluster name: String) -> [String] {
        name.uppercased().hasPrefix("E")
            ? ["voltage-states1-sram", "voltage-states1"]
            : ["voltage-states5-sram", "voltage-states5"]
    }

    /// Core counts per cluster from `CPU Core Performance States`' names. The format is
    /// `{E|P}CPU{clusterDigit}{coreDigit}{0}` -- three digits, the first being the cluster
    /// index -- so `PCPU140` belongs to `PCPU1` and `PCPU040` to `PCPU`. Confirmed against
    /// the 2026-09-03 dump: `ECPU0xx` 4, `PCPU0xx` 5, `PCPU1xx` 5.
    static func coreCounts(from coreChannelNames: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for raw in coreChannelNames {
            let upper = raw.uppercased()
            guard let prefix = ["ECPU", "PCPU"].first(where: { upper.hasPrefix($0) }) else { continue }
            let digits = upper.dropFirst(prefix.count)
            guard digits.count == 3, digits.allSatisfy(\.isNumber), let clusterDigit = digits.first else { continue }
            let cluster = clusterDigit == "0" ? prefix : prefix + String(clusterDigit)
            counts[cluster, default: 0] += 1
        }
        return counts
    }

    /// One `ClusterFrequency` per cluster channel, ordered `P0`, `P1`, `E` so the pane's
    /// column order does not depend on IOReport's enumeration order (§14.1). `tableFor` is
    /// the device-tree lookup, injected so this is testable: it is handed a key and returns
    /// that key's decoded MHz table, or `nil`. A key pairs only when its length equals this
    /// cluster's own active-state count -- `sample()`'s guard, applied per cluster (D-11).
    static func buildClusters(
        channels: [IOReportChannel],
        coreCounts: [String: Int],
        tableFor: (String) -> [Double]?
    ) -> [ClusterFrequency] {
        var clusters: [ClusterFrequency] = []
        for channel in channels where isClusterChannel(name: channel.name) {
            let active = activeStates(channel.states)
            let activeNames = Set(active.map(\.name))
            let idle = channel.states.filter { !activeNames.contains($0.name) }

            let keys = tableKeys(forCluster: channel.name)
            var table: [Double]?
            var tableSource: String?
            for key in keys {
                guard let candidate = tableFor(key), candidate.count == active.count else { continue }
                table = candidate
                tableSource = "device-tree:\(key)"
                break
            }

            let total = (idle + active).reduce(UInt64(0)) { $0 + $1.residency }
            func fraction(_ residency: UInt64) -> Double { total == 0 ? 0 : Double(residency) / Double(total) }
            var states = idle.map {
                ClusterFrequency.State(name: $0.name, megahertz: nil, residencyFraction: fraction($0.residency), isIdle: true)
            }
            for (index, state) in active.enumerated() {
                states.append(ClusterFrequency.State(
                    name: state.name, megahertz: table?[index], residencyFraction: fraction(state.residency), isIdle: false
                ))
            }

            let residencies = active.map { Int64(clamping: $0.residency) }
            clusters.append(ClusterFrequency(
                name: channel.name, label: clusterLabel(for: channel.name),
                coreCount: coreCounts[channel.name] ?? 0, states: states,
                averageMegahertz: table.flatMap { weightedMean(residencies: residencies, frequenciesMHz: $0) },
                maxMegahertz: table?.max(),
                tableSource: tableSource, missingTableKey: tableSource == nil ? keys.first : nil
            ))
        }
        return clusters.sorted { rank($0.label) < rank($1.label) }
    }

    /// `P{n}` -> `n`, `E{n}` -> `1000 + n`: the fixed column order.
    private static func rank(_ label: String) -> Int {
        (label.hasPrefix("E") ? 1000 : 0) + (Int(label.dropFirst()) ?? 0)
    }

    /// §14.1's core counts, read **once**, from one `IOReportCopyChannelsInGroup` rather
    /// than a second live subscription -- a subscription holds two CF objects for the
    /// process's life for a number that cannot change while the machine is running.
    /// The caller owns the result and releases it on every path out.
    private static func readCoreCounts() -> [String: Int] {
        guard let raw = IOReport.copyChannelsInGroup("CPU Stats", "CPU Core Performance States")
        else { return [:] }
        defer { IOReport.releaseRaw(raw) }
        return coreCounts(from: IOReport.decodeChannels(raw).map(\.name))
    }

    /// Memoised device-tree lookup for `buildClusters`' `tableFor`.
    private mutating func table(forKey key: String) -> [Double]? {
        if let cached = tableCache[key] { return cached }
        let decoded = Self.readDeviceTreeProperty(key).flatMap(Self.decodeVoltageStates)
        tableCache.updateValue(decoded, forKey: key)
        return decoded
    }
}
