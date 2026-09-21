import Foundation

/// SPEC.md §5.1.3.
public struct CPUSample: Sendable, Codable, Equatable {
    /// Utilization 0.0-1.0 per logical core, in kernel index order.
    public let perCore: [Double]
    /// Tick-weighted aggregate across all cores, 0.0-1.0. Not the mean of `perCore`:
    /// on asymmetric P/E hardware those differ, and the tick-weighted figure is the one
    /// that matches `top`. SPEC.md §5.1.2.
    public let total: Double
    public let user: Double
    public let system: Double
    public let idle: Double
    public let nice: Double
    public let logicalCount: Int
    public let performanceCores: Int
    public let efficiencyCores: Int

    public init(
        perCore: [Double], total: Double, user: Double, system: Double, idle: Double,
        nice: Double, logicalCount: Int, performanceCores: Int, efficiencyCores: Int
    ) {
        self.perCore = perCore
        self.total = total
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
        self.logicalCount = logicalCount
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
    }
}

/// SPEC.md §5.2.3. Every field here is defined from named `vm_statistics64` fields; none
/// of it reproduces Activity Monitor's "Memory Used", which is undocumented.
public struct MemorySample: Sendable, Codable, Equatable {
    /// (active + wired + compressor) x pageSize
    public let resident: UInt64
    /// (inactive + speculative) x pageSize
    public let reclaimable: UInt64
    /// (free_count − speculative_count) x pageSize
    public let free: UInt64
    /// sysctl hw.memsize
    public let total: UInt64

    public let active: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let swapUsed: UInt64
    public let pageSize: UInt64

    /// §4.5's timeline stacks four series — Wired, Active, Compressed, **Cached/inactive** —
    /// and its footer names Reclaimable separately. The aggregates above cannot supply the
    /// fourth band, so these terms are exposed individually. `purgeable` is an overlay on the
    /// active/inactive/speculative queues, not a fourth pool: it is reported here and never
    /// summed into `reclaimable`. SPEC.md §5.2.3.
    public let inactive: UInt64
    public let purgeable: UInt64
    public let speculative: UInt64
    /// `external_page_count` × pageSize — §5.2.2's "file-backed, the cached figure". Named in
    /// §5.2.2's list of eight fields but not read until phase-02.
    public let cached: UInt64
    /// `kern.memorystatus_vm_pressure_level` -- 1 normal, 2 warning, 4 critical: the kernel's
    /// own memory-pressure verdict (**public** sysctl). Read for §4.10's Simple-mode verdict
    /// only; no reading in §4.5 derives from it. `nil` when the sysctl is unreadable.
    public let pressureLevel: Int?

    public init(
        resident: UInt64, reclaimable: UInt64, free: UInt64, total: UInt64,
        active: UInt64, wired: UInt64, compressed: UInt64, swapUsed: UInt64, pageSize: UInt64,
        inactive: UInt64, purgeable: UInt64, speculative: UInt64, cached: UInt64,
        pressureLevel: Int? = nil
    ) {
        self.pressureLevel = pressureLevel
        self.resident = resident
        self.reclaimable = reclaimable
        self.free = free
        self.total = total
        self.active = active
        self.wired = wired
        self.compressed = compressed
        self.swapUsed = swapUsed
        self.pageSize = pageSize
        self.inactive = inactive
        self.purgeable = purgeable
        self.speculative = speculative
        self.cached = cached
    }

    /// SPEC.md §5.2.3: pressure is GlowTop's own quantity, not a reproduction of the
    /// macOS pressure indicator.
    public var pressure: Double {
        total > 0 ? Double(wired + compressed) / Double(total) : 0
    }
}

/// SPEC.md §5.4. Rates are summed across non-loopback interfaces; the `primary` fields name
/// the busiest one for the footer (§4.6.2) and are what §5.4.4's `netstat -ib` cross-check
/// compares against, since `netstat` reports per interface.
///
/// Deliberately flat — no arrays. §6.4 stores 60 s of these in a `RingBuffer`, and a payload
/// carrying a per-interface array would be 240 heap allocations a minute for data §4.6.2
/// never displays.
public struct NetworkSample: Sendable, Codable, Equatable {
    public let bytesInPerSecond: Double
    public let bytesOutPerSecond: Double
    public let packetsInPerSecond: Double
    public let packetsOutPerSecond: Double

    /// Cumulative since boot, summed across non-loopback interfaces.
    public let totalBytesIn: UInt64
    public let totalBytesOut: UInt64
    public let errorsIn: UInt64
    public let errorsOut: UInt64

    /// The non-loopback interface with the highest cumulative byte total (§5.4.2 — a
    /// heuristic, tagged **uncertain**, correct on any machine with one active path).
    public let primaryInterface: String
    public let primaryAddress: String?
    public let primaryBytesIn: UInt64
    public let primaryBytesOut: UInt64

    public init(
        bytesInPerSecond: Double, bytesOutPerSecond: Double,
        packetsInPerSecond: Double, packetsOutPerSecond: Double,
        totalBytesIn: UInt64, totalBytesOut: UInt64, errorsIn: UInt64, errorsOut: UInt64,
        primaryInterface: String, primaryAddress: String?,
        primaryBytesIn: UInt64, primaryBytesOut: UInt64
    ) {
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
        self.packetsInPerSecond = packetsInPerSecond
        self.packetsOutPerSecond = packetsOutPerSecond
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
        self.errorsIn = errorsIn
        self.errorsOut = errorsOut
        self.primaryInterface = primaryInterface
        self.primaryAddress = primaryAddress
        self.primaryBytesIn = primaryBytesIn
        self.primaryBytesOut = primaryBytesOut
    }
}

/// SPEC.md §5.3. Throughput and busy percentage, summed across every `IOBlockStorageDriver`.
/// Not capacity — §5.3 has no `statfs` and volume sizes are not part of this provider.
///
/// Flat for the same reason as `NetworkSample`: §4.6.1 displays a combined figure, and a
/// per-device array would land 240 heap allocations a minute in the ring buffer.
public struct DiskSample: Sendable, Codable, Equatable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public let readOpsPerSecond: Double
    public let writeOpsPerSecond: Double

    /// 0–100, clamped. A device servicing overlapping requests can exceed 100 % of wall
    /// time, and §5.3.2 calls clamping the honest presentation at this resolution.
    /// Reads 0 when the `Total Time` keys are absent (§5.3.3) — that costs the busy figure,
    /// not the throughput numbers.
    public let busyPercent: Double

    /// Cumulative since boot, summed across devices.
    public let totalBytesRead: UInt64
    public let totalBytesWritten: UInt64
    /// How many `IOBlockStorageDriver` services were summed, so a reading that silently
    /// covers fewer disks than expected is visible rather than merely lower.
    public let deviceCount: Int

    public init(
        readBytesPerSecond: Double, writeBytesPerSecond: Double,
        readOpsPerSecond: Double, writeOpsPerSecond: Double, busyPercent: Double,
        totalBytesRead: UInt64, totalBytesWritten: UInt64, deviceCount: Int
    ) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOpsPerSecond = readOpsPerSecond
        self.writeOpsPerSecond = writeOpsPerSecond
        self.busyPercent = busyPercent
        self.totalBytesRead = totalBytesRead
        self.totalBytesWritten = totalBytesWritten
        self.deviceCount = deviceCount
    }
}

/// One row of §4.3.3's card and, later, §8's Processes pane.
public struct ProcessRow: Sendable, Codable, Equatable {
    public let pid: Int32
    public let name: String
    /// `nil` on a process's first appearance, when there is no baseline to difference
    /// against — §5.5.2 says that shows `—` for CPU and a real value for memory, with a
    /// number arriving on the next sample.
    ///
    /// Points, not a fraction, and **not clamped**: a single busy thread reads 100 and a
    /// process saturating all 14 cores reads 1400, the same convention as `top` and `ps`.
    public let cpuPercent: Double?
    public let residentBytes: UInt64
    public let threadCount: Int
    /// §4.3.3's GPU column, phase-03.1's 1.4 outcome A (SPEC.md gains its own §5.6.7 subsection in a later sub-step). Source: `AGXDeviceUserClient`
    /// entries under `IOAccelerator`'s `AppUsage.accumulatedGPUTime`, nanosecond-denominated
    /// (measured, not assumed), matched to this row by PID -- never by `IOUserClientCreator`'s
    /// truncated name. **Uncertain**: no per-process GPU channel is documented, and summing
    /// `AppUsage`'s array is itself an assumption. `nil` when the PID has no matching client
    /// (roughly 40 % of rows are also non-inspectable, per §5.5.1, and keep the caveat
    /// regardless) or on a process's first appearance, with a real value arriving next sample.
    public let gpuPercent: Double?

    /// SPEC.md §8.2's four columns phase-02 had no source for. All six fields below are
    /// optional throughout (§5.5.1): a PID that refuses inspection is skipped or left `nil`,
    /// never defaulted to zero or an empty string -- roughly 40 % of PIDs refuse unprivileged.
    public let uid: uid_t?
    public let user: String?
    public let path: String?
    /// §8.2's Energy column: `ri_energy_nj` delta since the previous sample, expressed as a
    /// relative 0-100 impact within *this* snapshot (§8.2's own wording -- not an absolute
    /// unit). `nil` without a baseline, while the Processes pane is not visible (§3.3 gates
    /// the syscall this reads), or when every process's delta in the snapshot is zero.
    public let energyImpact: Double?
    public let parentPID: Int32?
    public let startedAt: Date?

    public init(
        pid: Int32, name: String, cpuPercent: Double?,
        residentBytes: UInt64, threadCount: Int, gpuPercent: Double? = nil,
        uid: uid_t? = nil, user: String? = nil, path: String? = nil,
        energyImpact: Double? = nil, parentPID: Int32? = nil, startedAt: Date? = nil
    ) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.residentBytes = residentBytes
        self.threadCount = threadCount
        self.gpuPercent = gpuPercent
        self.uid = uid
        self.user = user
        self.path = path
        self.energyImpact = energyImpact
        self.parentPID = parentPID
        self.startedAt = startedAt
    }
}

/// SPEC.md §5.6.1, §5.6.2. Utilization is `1 - idle-state residency share` from IOReport's
/// `GPU Stats | GPU Performance States`, or the `IOAccelerator` registry fallback.
///
/// `source` is carried on **every** sample, not just when the fallback fires -- §5.6.2 says
/// a fallback firing must be visible rather than inferred, and a tooltip that always reads
/// "IOReport" while quietly substituting the registry number is the failure this field exists
/// to prevent.
public struct GPUSample: Sendable, Codable, Equatable {
    /// 0.0-1.0. §5.6.5's range check clamps this and sets `uncertain` rather than rejecting
    /// the sample outright.
    public let utilization: Double
    /// `"IOReport"` or `"IOAccelerator"` -- which path produced this sample.
    public let source: String
    /// `true` when §5.6.5's clamp fired.
    public let uncertain: Bool
    /// §5.6.6. `nil` when the identifying sysctl or IOKit property is absent -- omitted
    /// rather than guessed.
    public let chipName: String?
    public let coreCount: Int?
    /// The IOReport state name matched as "idle" (§5.6.2's naming rule), so the choice is
    /// auditable rather than assumed. `nil` when the `IOAccelerator` fallback produced this
    /// sample -- that path has no state table to name one from.
    public let idleStateName: String?

    public init(
        utilization: Double, source: String, uncertain: Bool,
        chipName: String?, coreCount: Int?, idleStateName: String?
    ) {
        self.utilization = utilization
        self.source = source
        self.uncertain = uncertain
        self.chipName = chipName
        self.coreCount = coreCount
        self.idleStateName = idleStateName
    }
}

/// SPEC.md §5.6.3 (package power) and §5.6.4 (the ANE), from one IOReport `Energy Model`
/// subscription. `contributingChannels` is §5.6.3's tooltip: every target channel this
/// sample actually used, so a wrong unit becomes visible there rather than shipping a
/// plausible wrong wattage silently. A channel selected but carrying an unrecognised unit
/// label is named with a `" (unit ?)"` suffix instead of being silently dropped.
public struct EnergySample: Sendable, Codable, Equatable {
    /// The Energy tile's headline: the sum of whichever of `cpuWatts`, `gpuWatts`, `aneWatts`
    /// converted successfully.
    public let watts: Double
    public let cpuWatts: Double?
    public let gpuWatts: Double?
    public let aneWatts: Double?
    /// §14.1's fourth power band. Read from the same `Energy Model` subscription by exact
    /// name, and deliberately **not** part of `watts`: §4.6.3's tile headline stays
    /// `CPU Energy + GPU + ANE` so every RSS and CPU reading recorded against §13.1 stays
    /// comparable (phase-11 D-07). Nothing on the Summary pane reads this.
    public let dramWatts: Double?
    public let contributingChannels: [String]
    /// §5.6.4's NPU tile. `nil` when neither ANE path produced a number.
    public let aneUtilization: Double?
    /// `"residency"` (path 1, a residency channel — not present on this Mac) or `"power/8W"`
    /// (path 2, the provisional ceiling). Named on every sample, per §5.6.2's rule that a
    /// fallback firing must be visible rather than inferred.
    public let aneSource: String

    public init(
        watts: Double, cpuWatts: Double?, gpuWatts: Double?, aneWatts: Double?,
        contributingChannels: [String], aneUtilization: Double?, aneSource: String,
        dramWatts: Double? = nil
    ) {
        self.watts = watts
        self.cpuWatts = cpuWatts
        self.gpuWatts = gpuWatts
        self.aneWatts = aneWatts
        self.dramWatts = dramWatts
        self.contributingChannels = contributingChannels
        self.aneUtilization = aneUtilization
        self.aneSource = aneSource
    }
}

/// SPEC.md §5.8.1, §5.8.2. `sensors` is every sensor that passed the 0-120 °C filter, sorted
/// hottest first; `rejected` is every matched sensor the filter dropped, with its raw value,
/// so a garbage sensor is visible in the probe rather than silently removed.
public struct ThermalSample: Sendable, Codable, Equatable {
    public struct Sensor: Sendable, Codable, Equatable {
        /// The raw sensor name, never truncated here -- §5.8.2 truncates to 12 characters
        /// for **display only**, in `SummaryModel`; matching is never done on a truncated
        /// string.
        public let name: String
        public let celsius: Double

        public init(name: String, celsius: Double) {
            self.name = name
            self.celsius = celsius
        }
    }

    /// Hottest first (§5.8.2's Thermals chart: the four hottest sensors as separate lines).
    public let sensors: [Sensor]
    /// The Temp meter and Thermals headline (§5.8.2): the maximum across `sensors`.
    public let maxCelsius: Double
    public let rejected: [Sensor]

    public init(sensors: [Sensor], maxCelsius: Double, rejected: [Sensor]) {
        self.sensors = sensors
        self.maxCelsius = maxCelsius
        self.rejected = rejected
    }
}

/// One physical CPU cluster's DVFS picture for §14.1's pane. Emitted **beside** the
/// summed reading §4.3.1's Clock meter draws, never instead of it.
public struct ClusterFrequency: Sendable, Codable, Equatable {
    public struct State: Sendable, Codable, Equatable {
        /// IOReport's own state name, e.g. `DOWN`, `IDLE`, `V0P18`.
        public let name: String
        /// `nil` for a power-gated state (`DOWN`/`IDLE`), which has no table entry.
        public let megahertz: Double?
        /// This state's share of the sample interval, 0...1. Every state's share in one
        /// cluster sums to 1, which is what lets §14.1's histogram be a mean.
        public let residencyFraction: Double
        public let isIdle: Bool

        public init(name: String, megahertz: Double?, residencyFraction: Double, isIdle: Bool) {
            self.name = name
            self.megahertz = megahertz
            self.residencyFraction = residencyFraction
            self.isIdle = isIdle
        }
    }

    /// The IOReport channel name, e.g. `PCPU1`.
    public let name: String
    /// §14.1's display label, e.g. `P1`.
    public let label: String
    /// From `CPU Core Performance States`' name prefixes, read once (§14.1).
    public let coreCount: Int
    /// Idle states first, then active states ascending by frequency.
    public let states: [State]
    /// §5.9.1's weighted mean over this cluster's **active** states only. `nil` when the
    /// table did not pair.
    public let averageMegahertz: Double?
    /// This cluster's own table maximum -- §14.1's per-column right axis.
    public let maxMegahertz: Double?
    /// `"device-tree:<key>"` when a table paired; `nil` when none did.
    public let tableSource: String?
    /// The key this cluster wanted when `tableSource` is `nil` -- §14.1's
    /// `No {tableKey} table`. `nil` when the table paired.
    public let missingTableKey: String?

    public init(
        name: String, label: String, coreCount: Int, states: [State],
        averageMegahertz: Double?, maxMegahertz: Double?,
        tableSource: String?, missingTableKey: String?
    ) {
        self.name = name
        self.label = label
        self.coreCount = coreCount
        self.states = states
        self.averageMegahertz = averageMegahertz
        self.maxMegahertz = maxMegahertz
        self.tableSource = tableSource
        self.missingTableKey = missingTableKey
    }
}

/// SPEC.md §5.9. Feeds the Clock meter (§4.3.1, §5.9.3). `performanceMegahertz` is the
/// P-cluster's residency-weighted mean over the sample delta (§5.9.1); `maxMegahertz` is the
/// highest entry in its state table, or the `hw.cpufrequency_max` fallback (§5.9.2).
public struct FrequencySample: Sendable, Codable, Equatable {
    public let performanceMegahertz: Double
    public let maxMegahertz: Double
    /// `performanceMegahertz / maxMegahertz`, clamped 0...1 -- the Clock meter's fill.
    public let fraction: Double
    /// How many DVFS states contributed to the weighted mean, so a reading built from a
    /// suspiciously short table is auditable rather than just a number.
    public let stateCount: Int
    /// `"device-tree:<key>"`, `"sysctl"`, or `"none"` -- which source answered §5.9.1's table
    /// and §5.9.2's maximum, named on every sample per this codebase's rule that a fallback
    /// firing must be visible rather than inferred.
    public let tableSource: String
    /// §14.1's per-cluster output. Empty on hardware whose channel list names no cluster,
    /// and empty in every fixture written before phase-11 -- the default is what keeps
    /// this an addition rather than a migration.
    public let clusters: [ClusterFrequency]

    public init(
        performanceMegahertz: Double, maxMegahertz: Double, fraction: Double,
        stateCount: Int, tableSource: String, clusters: [ClusterFrequency] = []
    ) {
        self.performanceMegahertz = performanceMegahertz
        self.maxMegahertz = maxMegahertz
        self.fraction = fraction
        self.stateCount = stateCount
        self.tableSource = tableSource
        self.clusters = clusters
    }
}

/// SPEC.md §5.5. Rows are sorted by CPU descending, so §4.3.3's top-12 card is `prefix(12)`.
public struct ProcessSample: Sendable, Codable, Equatable {
    public let rows: [ProcessRow]
    /// Every PID the kernel listed — §4.3.3's header, e.g. `1138 total`, and the figure
    /// §5.5.5 compares against `ps -A | wc -l`.
    public let totalCount: Int
    /// How many of those this process could actually read task info for, which is
    /// `rows.count`. On a normal user account it is well under `totalCount`: `proc_pidinfo`
    /// refuses processes owned by other users, so root-owned ones — `kernel_task`,
    /// `WindowServer`, most daemons — list but do not inspect. Surfaced as its own number
    /// because a table quietly covering a fraction of the machine looks identical to a quiet
    /// machine.
    public let inspectableCount: Int
    /// How long the full enumeration took. §5.5.4 sets a 25 ms budget and asks for this to
    /// be measured rather than assumed, so the provider reports it on every sample.
    public let enumerationMilliseconds: Double

    public init(rows: [ProcessRow], totalCount: Int, inspectableCount: Int, enumerationMilliseconds: Double) {
        self.rows = rows
        self.totalCount = totalCount
        self.inspectableCount = inspectableCount
        self.enumerationMilliseconds = enumerationMilliseconds
    }
}

/// SPEC.md §14.5's one row. Every string field is `inet_ntop` output alone -- no bracket,
/// no port, no scope suffix; `ConnectionsModel` (Core, §7.1's boundary) builds the display
/// form so the probe JSON stays the raw fields §13.6's cross-check reads.
public struct SocketRow: Sendable, Codable, Equatable {
    public enum Transport: String, Sendable, Codable { case tcp, udp }
    public let pid: Int32
    public let fd: Int32
    public let processName: String
    public let transport: Transport
    public let isIPv6: Bool
    public let localAddress: String
    public let localPort: Int
    public let remoteAddress: String
    public let remotePort: Int
    /// XNU's `TSI_S_*`, 0...11. `nil` for UDP -- there is no TCP state to report.
    public let tcpState: Int?
    /// The link-local scope, from `in6_ifindex` -- empty when not applicable.
    public let scopeInterface: String

    public init(
        pid: Int32, fd: Int32, processName: String, transport: Transport, isIPv6: Bool,
        localAddress: String, localPort: Int, remoteAddress: String, remotePort: Int,
        tcpState: Int?, scopeInterface: String
    ) {
        self.pid = pid
        self.fd = fd
        self.processName = processName
        self.transport = transport
        self.isIPv6 = isIPv6
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.tcpState = tcpState
        self.scopeInterface = scopeInterface
    }
}

/// SPEC.md §14.5. CONN-04's two counts sit beside the rows, never folded into them.
public struct ConnectionsSample: Sendable, Codable, Equatable {
    public let rows: [SocketRow]
    /// Every PID `proc_listallpids` returned -- §5.5.1's convention, repeated here.
    public let pidCount: Int
    /// PIDs whose `PROC_PIDLISTFDS` call succeeded (CONN-04: counted, not dropped).
    public let inspectedPIDCount: Int
    public let enumerationMilliseconds: Double

    public init(rows: [SocketRow], pidCount: Int, inspectedPIDCount: Int, enumerationMilliseconds: Double) {
        self.rows = rows
        self.pidCount = pidCount
        self.inspectedPIDCount = inspectedPIDCount
        self.enumerationMilliseconds = enumerationMilliseconds
    }
}
