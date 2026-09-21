import Darwin
import Foundation

/// Memory composition from mach `host_statistics64`. SPEC.md §5.2.
///
/// GlowTop does not reconstruct Activity Monitor's "Memory Used" -- that formula is
/// undocumented, and a value defined by matching a black box goes wrong on another Mac or
/// at the next point release. Everything here is defined from named `vm_statistics64`
/// fields, summed in exactly one place: `compose`. SPEC.md §5.2.3.
public struct MemoryProvider: MetricProvider {
    public let id = ProviderID.memory
    public let nominalInterval = SampleRate.hz10

    private let total: UInt64
    private let pageSize: UInt64

    public init() {
        var size: vm_size_t = 0
        // Read the page size; it is 16384 on Apple Silicon but hardcoding it is how this
        // breaks on hardware nobody tested. SPEC.md §5.2.1.
        let pageSize = host_page_size(mach_host_self(), &size) == KERN_SUCCESS
            ? UInt64(size)
            : UInt64(Sysctl.integer("hw.pagesize") ?? 16384)
        self.init(total: Sysctl.uint64("hw.memsize") ?? 0, pageSize: pageSize)
    }

    /// Fixture seam: lets a test drive `compose` against a known total and page size, so the
    /// composition can be checked on a machine state this machine may not be in.
    init(total: UInt64, pageSize: UInt64) {
        self.total = total
        self.pageSize = pageSize
    }

    public mutating func sample() -> Snapshot<MemorySample> {
        guard total > 0 else {
            return .unavailable(reason: "key not present: hw.memsize")
        }
        guard let stats = Self.readVMStatistics() else {
            return .unavailable(reason: "kernel call failed: host_statistics64")
        }

        guard let sample = compose(stats) else {
            return .unavailable(reason: "composition does not sum")
        }
        return .value(sample, timestamp: ContinuousClock().now)
    }

    /// The single place memory is summed. Field names are here so the definition and the
    /// arithmetic cannot drift apart. SPEC.md §5.2.3.
    func compose(_ stats: vm_statistics64) -> MemorySample? {
        let active = UInt64(stats.active_count) * pageSize          // active_count
        let wired = UInt64(stats.wire_count) * pageSize             // wire_count
        let compressed = UInt64(stats.compressor_page_count) * pageSize  // compressor_page_count
        let inactive = UInt64(stats.inactive_count) * pageSize      // inactive_count
        let purgeable = UInt64(stats.purgeable_count) * pageSize    // purgeable_count
        let speculative = UInt64(stats.speculative_count) * pageSize // speculative_count
        let free = UInt64(stats.free_count) * pageSize              // free_count
        let cached = UInt64(stats.external_page_count) * pageSize   // external_page_count

        let resident = active + wired + compressed
        // purgeable_count is an overlay on the active/inactive/speculative queues, not a
        // fourth pool -- internal + external == active + inactive + speculative. SPEC.md §5.2.3.
        let reclaimable = inactive + speculative

        // free_count includes speculative pages, so the three terms overlap by exactly
        // that much; subtract it once rather than double-counting.
        let countedFree = free > speculative ? free - speculative : 0

        // If the parts cannot account for the whole within a page per term, a field was
        // double-counted. Return nothing rather than a number that cannot be justified.
        let summed = resident + reclaimable + countedFree
        let slack = pageSize * 8
        guard summed <= total + slack else { return nil }

        return MemorySample(
            resident: resident,
            reclaimable: reclaimable,
            free: countedFree,
            total: total,
            active: active,
            wired: wired,
            compressed: compressed,
            swapUsed: Self.readSwapUsed(),
            pageSize: pageSize,
            inactive: inactive,
            purgeable: purgeable,
            speculative: speculative,
            cached: cached,
            pressureLevel: Sysctl.integer("kern.memorystatus_vm_pressure_level")
        )
    }

    static func readVMStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    /// `vm.swapusage` returns `xsw_usage`. SPEC.md §5.2.3 -- public.
    static func readSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }
}
