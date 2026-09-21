import Darwin
import Foundation

/// Per-core CPU utilization from mach `host_processor_info`. SPEC.md §5.1.
///
/// Public, documented, and stable since NeXTSTEP; this is the same source Activity
/// Monitor's numbers ultimately derive from.
public struct CPUProvider: MetricProvider {
    public let id = ProviderID.cpu
    public let nominalInterval = SampleRate.hz10

    /// Per-core tick counters from the previous sample: [core][state]. Utilization is a
    /// delta, so the first sample only establishes this baseline. SPEC.md §5.0.3.
    private var previousTicks: [[UInt32]] = []
    private var previousAt: ContinuousClock.Instant?
    private var lastValue: CPUSample?

    private let topology: Topology

    struct Topology: Sendable {
        let logical: Int
        let performance: Int
        let efficiency: Int
    }

    public init() {
        let logical = Sysctl.integer("hw.logicalcpu") ?? 1
        // The perflevel keys exist only on Apple Silicon. On failure, report every core as
        // a performance core rather than failing the provider. SPEC.md §5.1.4.
        let performance = Sysctl.integer("hw.perflevel0.logicalcpu") ?? logical
        let efficiency = Sysctl.integer("hw.perflevel1.logicalcpu") ?? 0
        self.topology = Topology(logical: logical, performance: performance, efficiency: efficiency)
    }

    public mutating func sample() -> Snapshot<CPUSample> {
        guard let ticks = Self.readTicks() else {
            return .unavailable(reason: "kernel call failed: host_processor_info")
        }

        let now = ContinuousClock().now
        defer {
            previousTicks = ticks
            previousAt = now
        }

        guard let previousAt else { return .warming }

        switch SampleInterval.classify(from: previousAt, to: now) {
        case .toosoon:
            // Below 50 ms the tick delta approaches zero and the quotient is noise. This
            // is the specific bug that makes a CPU meter read 0 % or 900 % at random.
            if let lastValue { return .value(lastValue, timestamp: now) }
            return .warming
        case .stale:
            // A utilization computed across a sleep is not a measurement. SPEC.md §5.0.3.
            return .warming
        case .usable:
            break
        }

        guard let delta = Self.utilization(previous: previousTicks, current: ticks) else {
            // Counter wrap, a core-count change, or a zero-length interval. SPEC.md §5.0.4.
            if let lastValue, previousTicks.count == ticks.count {
                return .value(lastValue, timestamp: now)
            }
            return .warming
        }

        let sample = CPUSample(
            perCore: delta.perCore,
            total: delta.total,
            user: delta.user,
            system: delta.system,
            idle: delta.idle,
            nice: delta.nice,
            logicalCount: topology.logical,
            performanceCores: topology.performance,
            efficiencyCores: topology.efficiency
        )
        lastValue = sample
        return .value(sample, timestamp: now)
    }

    struct TickDelta: Equatable {
        let perCore: [Double]
        let total: Double
        let user: Double
        let system: Double
        let idle: Double
        let nice: Double
    }

    /// The tick arithmetic, separated from the syscall so tests can drive it with
    /// synthetic counters. SPEC.md §5.1.2 and §13.5 item 1.
    ///
    /// Returns nil when the sample is unusable: a core-count change, a wrapped counter,
    /// or a zero-length interval.
    static func utilization(previous: [[UInt32]], current: [[UInt32]]) -> TickDelta? {
        guard !current.isEmpty, previous.count == current.count else { return nil }

        var perCore: [Double] = []
        perCore.reserveCapacity(current.count)
        var busyTotal = 0.0
        var tickTotal = 0.0
        var userTotal = 0.0
        var systemTotal = 0.0
        var idleTotal = 0.0
        var niceTotal = 0.0

        for (index, core) in current.enumerated() {
            let before = previous[index]
            guard core.count == before.count, core.count == Int(CPU_STATE_MAX) else { return nil }

            // Counters are unsigned and do wrap. A decrease means a wrap or a reset;
            // reject the whole sample rather than emitting a huge or negative
            // utilization. SPEC.md §5.0.4.
            for state in 0..<core.count where core[state] < before[state] { return nil }

            let user = Double(core[Int(CPU_STATE_USER)] - before[Int(CPU_STATE_USER)])
            let system = Double(core[Int(CPU_STATE_SYSTEM)] - before[Int(CPU_STATE_SYSTEM)])
            let idle = Double(core[Int(CPU_STATE_IDLE)] - before[Int(CPU_STATE_IDLE)])
            let nice = Double(core[Int(CPU_STATE_NICE)] - before[Int(CPU_STATE_NICE)])

            let busy = user + system + nice
            let total = busy + idle
            perCore.append(total > 0 ? busy / total : 0)

            busyTotal += busy
            tickTotal += total
            userTotal += user
            systemTotal += system
            idleTotal += idle
            niceTotal += nice
        }

        guard tickTotal > 0 else { return nil }

        return TickDelta(
            perCore: perCore,
            // Tick-weighted, not the mean of perCore: on asymmetric P/E hardware those
            // differ and this is the one that matches `top`. SPEC.md §5.1.2.
            total: busyTotal / tickTotal,
            user: userTotal / tickTotal,
            system: systemTotal / tickTotal,
            idle: idleTotal / tickTotal,
            nice: niceTotal / tickTotal
        )
    }

    /// One `host_processor_info` call, returned as [core][state] tick counters.
    static func readTicks() -> [[UInt32]]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount
        )
        guard result == KERN_SUCCESS, let info else { return nil }

        // The buffer is vm-allocated and must be released with infoCount x stride --
        // using `count` here leaks on every sample and eventually faults. SPEC.md §5.1.1.
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let stride = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(Int(count))
        for core in 0..<Int(count) {
            var states = [UInt32](repeating: 0, count: stride)
            for state in 0..<stride {
                states[state] = UInt32(bitPattern: info[stride * core + state])
            }
            ticks.append(states)
        }
        return ticks
    }
}
