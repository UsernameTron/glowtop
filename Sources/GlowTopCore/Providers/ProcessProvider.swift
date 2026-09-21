import Darwin
import Foundation
import IOKit

/// SPEC.md §5.5. `libproc`, tagged **public (with caveats)**: the headers ship in the SDK but
/// are documented thinly, and the behaviour for a process the caller cannot inspect is to
/// return nonzero and leave the buffer untouched. So every return value is checked and a
/// failing PID is **skipped, never defaulted to zero** (§5.5.1) — a process charged 0 % CPU
/// because the call failed is a lie the table cannot distinguish from an idle process.
///
/// Fallback: `.unavailable`, and §8 shows an empty pane with an explanatory row (§5.10).
///
/// `proc_pid_rusage` is named by §5.5.1 as a source and lands in 2.1, gated on `detail` so it
/// is paid only while the Processes pane is visible (§3.3) — a fourth syscall across ~1150
/// PIDs every second otherwise, against §5.5.4's budget.
public struct ProcessProvider: MetricProvider {
    public let id = ProviderID.process
    public let nominalInterval = SampleRate.hz1

    /// Cumulative CPU nanoseconds per PID, the baseline the next sample differences against.
    private var previous: [Int32: UInt64] = [:]
    private var previousAt: ContinuousClock.Instant?
    /// 1.4 outcome A: cumulative GPU-busy nanoseconds per PID, the baseline
    /// `gpuPercent` differences against -- the same shape as `previous`, one map per source.
    private var previousGPUTimes: [Int32: UInt64] = [:]
    /// 2.1: cumulative `ri_energy_nj` per PID, the baseline §8.2's Energy column differences
    /// against. Reset to empty whenever `detail` is off (nothing is read to populate it), so
    /// turning the pane back on re-warms exactly like every other delta baseline (§5.0.3).
    private var previousEnergy: [Int32: UInt64] = [:]

    /// §5.5.4's pre-specified mitigation, widened in 2.1 from a name-only cache to a full
    /// identity cache: name, path, uid, user, parent PID and start time. None of the six can
    /// change while a PID lives, so all are resolved once per PID and reused -- the same
    /// argument §5.5.4 already made for the name alone, at the same cache lifetime and with
    /// the same unconditional eviction.
    ///
    /// Applied in phase-02 because gate 9 failed at 3.93 % against 3.0 %, not because §5.5.4's
    /// own 25 ms trigger fired — enumeration was 11–19 ms. Same remedy, different trigger.
    private var identities: [Int32: Identity] = [:]
    /// `getpwuid` cached by uid: a machine has single digits of distinct uids and hundreds of
    /// processes, so this saves the call for every process after the first at each uid.
    private var userNames: [uid_t: String] = [:]

    /// §3.3's per-pane sampling rule, wired by `MetricStore.slowLoop()` from `activePane`.
    /// When true, `sample()` pays the extra `proc_pid_rusage` call §8.2's Energy column reads.
    public var detail: Bool = false

    public init() {}

    public mutating func sample() -> Snapshot<ProcessSample> {
        let started = ContinuousClock().now
        guard let enumeration = Self.enumerate(identities: &identities, userNames: &userNames) else {
            return .unavailable(reason: "kernel call failed: proc_listallpids")
        }
        let raw = enumeration.entries
        let now = ContinuousClock().now

        var current: [Int32: UInt64] = [:]
        current.reserveCapacity(raw.count)
        for entry in raw { current[entry.pid] = entry.cpuNanoseconds }

        // 1.4 outcome A: ~1 ms measured, well under §5.5.4's 25 ms budget and this
        // sub-step's own 20 ms trigger, so it rides this loop rather than needing its own.
        let currentGPUTimes = Self.readGPUTimes()

        // 2.1: the fourth per-PID call, paid only while the Processes pane is visible. Off by
        // default so a probe run with no `--detail` flag pays nothing extra.
        var currentEnergy: [Int32: UInt64] = [:]
        if detail {
            currentEnergy.reserveCapacity(raw.count)
            for entry in raw {
                if let nanojoules = Self.readEnergyNanojoules(pid: entry.pid) {
                    currentEnergy[entry.pid] = nanojoules
                }
            }
        }

        // Elapsed wall time is the denominator for every row, so it is classified once
        // rather than per process.
        var elapsedSeconds: Double?
        if let previousAt {
            switch SampleInterval.classify(from: previousAt, to: now) {
            case .usable(let seconds): elapsedSeconds = seconds
            case .toosoon, .stale: elapsedSeconds = nil
            }
        }

        defer {
            previous = current; previousAt = now; previousGPUTimes = currentGPUTimes
            previousEnergy = currentEnergy
        }

        var energyDeltas: [Int32: UInt64] = [:]
        if detail {
            for (pid, energyNow) in currentEnergy {
                if let before = previousEnergy[pid], energyNow >= before {
                    energyDeltas[pid] = energyNow - before
                }
            }
        }
        // §8.2's Energy column: relative to this snapshot's busiest process, never an
        // absolute unit -- defined once, here, as a pure function (2.2 and its tests read it
        // the same way `ProcessesModel` will).
        let energyImpacts = Self.energyImpact(deltas: energyDeltas)

        var rows: [ProcessRow] = []
        rows.reserveCapacity(raw.count)
        for entry in raw {
            var cpuPercent: Double?
            if let seconds = elapsedSeconds, let before = previous[entry.pid],
               entry.cpuNanoseconds >= before {
                // §5.5.2. Points, matching top and ps: one busy thread is 100, all 14 cores
                // is 1400. A PID reused by a new process reads lower than its baseline and
                // is caught by the >= guard above, which reports nil rather than a negative.
                cpuPercent = Double(entry.cpuNanoseconds - before) / (seconds * 1_000_000_000) * 100
            }
            var gpuPercent: Double?
            if let seconds = elapsedSeconds, let currentTime = currentGPUTimes[entry.pid],
               let beforeTime = previousGPUTimes[entry.pid], currentTime >= beforeTime {
                // Same convention as `cpuPercent`: points, unclamped (§5.5.2). Most rows have
                // no matching `AGXDeviceUserClient` at all and stay `nil` -- §4.3.3 renders
                // that as `—`, not `0.0%`, which would claim a GPU measurement never taken.
                gpuPercent = Double(currentTime - beforeTime) / (seconds * 1_000_000_000) * 100
            }
            rows.append(ProcessRow(
                pid: entry.pid,
                name: entry.name,
                cpuPercent: cpuPercent,
                residentBytes: entry.residentBytes,
                threadCount: entry.threadCount,
                gpuPercent: gpuPercent,
                uid: entry.uid,
                user: entry.user,
                path: entry.path,
                energyImpact: energyImpacts[entry.pid],
                parentPID: entry.parentPID,
                startedAt: entry.startedAt
            ))
        }

        // §4.3.3 sorts by CPU descending; doing it here makes the top-12 card a prefix.
        // Unknown CPU sorts last — a process with no baseline yet is not the busiest.
        rows.sort { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }

        let sample = ProcessSample(
            rows: rows,
            totalCount: enumeration.listedCount,
            inspectableCount: rows.count,
            enumerationMilliseconds: Self.milliseconds(from: started, to: now)
        )

        // A first pass has no baseline, so every row's CPU is nil; §5.0.3 calls that warming.
        guard elapsedSeconds != nil else { return .warming }
        return .value(sample, timestamp: now)
    }

    /// What §8.2 needs about one PID that cannot change while it lives: name, executable
    /// path, owning uid, its resolved user name, parent PID and start time. `uid`, `user`,
    /// `parentPID` and `startedAt` are `nil` together when the one extra `proc_pidinfo`
    /// call (`PROC_PIDTBSDINFO`) this resolution costs fails for a PID this process cannot
    /// inspect -- `name` and `path` still resolve independently, from the same fallback
    /// chain phase-02 already used (§5.5.1: skipped fields stay `nil`, never zero).
    struct Identity: Sendable, Equatable {
        let name: String
        let path: String?
        let uid: uid_t?
        let user: String?
        let parentPID: Int32?
        let startedAt: Date?
    }

    /// What one PID contributes, before any differencing.
    struct Entry: Sendable, Equatable {
        let pid: Int32
        let name: String
        let cpuNanoseconds: UInt64
        let residentBytes: UInt64
        let threadCount: Int
        let path: String?
        let uid: uid_t?
        let user: String?
        let parentPID: Int32?
        let startedAt: Date?
    }

    /// What one enumeration found: how many PIDs the kernel listed, and the subset this
    /// process was able to inspect. The two differ and the difference is not an error — see
    /// `inspectable` below.
    struct Enumeration: Sendable {
        let listedCount: Int
        let entries: [Entry]
    }

    /// One `proc_listallpids` plus three calls per PID (§5.5.4), plus a fourth
    /// (`PROC_PIDTBSDINFO`, 2.1) the first time each PID is seen. Runs on whatever thread
    /// calls it — `MetricStore` calls it from a detached task, never from the actor, because
    /// §5.5.4 requires this off the main actor and a 25 ms hitch is 1.5 dropped frames.
    ///
    /// **`proc_listallpids` returns a PID count, not a byte count**, in both its sizing form
    /// and its filling form. Sizing a buffer as `returned / MemoryLayout<Int32>.size` makes
    /// it four times too small, and the enumeration then silently covers a quarter of the
    /// machine — 202 processes where `ps -A` counts 851 — with no error anywhere.
    static func enumerate(
        identities: inout [Int32: Identity], userNames: inout [uid_t: String]
    ) -> Enumeration? {
        let listed = proc_listallpids(nil, 0)
        guard listed > 0 else { return nil }
        // Headroom: processes start between the sizing call and the fill.
        var pids = [Int32](repeating: 0, count: Int(listed) + 128)
        let filled = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
        guard filled > 0 else { return nil }
        let count = min(filled, pids.count)

        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var listedAlive = 0
        var seen = Set<Int32>()
        seen.reserveCapacity(count)
        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            listedAlive += 1
            seen.insert(pid)

            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            // A PID that has exited, or that this process may not inspect, returns nonzero
            // and leaves the buffer untouched. Skip it — never default it to zero (§5.5.1).
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { continue }

            // §5.5.4's mitigation, widened by 2.1's identity cache: everything that cannot
            // change while a PID lives is resolved once per process rather than once per
            // second. This is the whole cost saving.
            let identity: Identity
            if let cached = identities[pid] {
                identity = cached
            } else {
                identity = resolveIdentity(pid: pid, userNames: &userNames)
                identities[pid] = identity
            }

            entries.append(Entry(
                pid: pid,
                name: identity.name,
                cpuNanoseconds: machToNanoseconds(info.pti_total_user &+ info.pti_total_system),
                residentBytes: info.pti_resident_size,
                threadCount: Int(info.pti_threadnum),
                path: identity.path,
                uid: identity.uid,
                user: identity.user,
                parentPID: identity.parentPID,
                startedAt: identity.startedAt
            ))
        }
        // Evict dead PIDs, or the cache grows without bound over an 8-hour session and a
        // reused PID answers with the previous process's identity **and uid** — the one
        // place in this app where a stale cache would show the wrong owner for a process
        // about to be signalled. Unconditional: an earlier version guarded this with
        // `names.count > seen.count`, which can never be true — the cache holds only
        // inspectable PIDs and `seen` holds every listed one, so the eviction never ran.
        // Filtering ~500 entries once a second costs nothing.
        identities = identities.filter { seen.contains($0.key) }
        return Enumeration(listedCount: listedAlive, entries: entries)
    }

    /// 2.1's identity resolution. `path` and `name` reuse the fallback chain `name(of:)`
    /// already established; `uid`, `user`, `parentPID` and `startedAt` ride one
    /// `proc_pidinfo(PROC_PIDTBSDINFO)` call, confirmed at plan time to carry all three of
    /// uid, ppid and start together. That call failing (a PID this process cannot inspect)
    /// leaves those four `nil` — the name still resolves, because `proc_pidpath`/`proc_name`
    /// already tolerate exactly this failure independently.
    static func resolveIdentity(pid: Int32, userNames: inout [uid_t: String]) -> Identity {
        let (name, path) = resolveNameAndPath(pid: pid)

        var bsdInfo = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, size) == size else {
            return Identity(name: name, path: path, uid: nil, user: nil, parentPID: nil, startedAt: nil)
        }

        let uid = bsdInfo.pbi_uid
        let user: String?
        if let cached = userNames[uid] {
            user = cached
        } else if let entry = getpwuid(uid) {
            let resolved = String(cString: entry.pointee.pw_name)
            userNames[uid] = resolved
            user = resolved
        } else {
            user = nil
        }

        return Identity(
            name: name, path: path, uid: uid, user: user,
            parentPID: Int32(bitPattern: bsdInfo.pbi_ppid),
            startedAt: Date(timeIntervalSince1970: Double(bsdInfo.pbi_start_tvsec))
        )
    }

    /// 1.4 outcome A. `AGXDeviceUserClient` entries under `IOAccelerator` carry
    /// per-PID GPU accounting in their `AppUsage` property, keyed by `IOUserClientCreator`'s
    /// PID. `IOServiceMatching("AGXDeviceUserClient")` directly returns zero on this Mac --
    /// these clients are reachable only as descendants of the accelerator service, which is
    /// why this walks children rather than matching the class by name. ~1 ms measured for the
    /// full walk (wave-1 notes), well inside this sub-step's own 20 ms trigger.
    ///
    /// Every matched service and iterator released on every path out, `defer`-placed so an
    /// early `return` cannot skip one -- `DiskProvider.readCounters()`'s pattern.
    static func readGPUTimes() -> [Int32: UInt64] {
        guard let matching = IOServiceMatching("IOAccelerator") else { return [:] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var result: [Int32: UInt64] = [:]
        while case let accelerator = IOIteratorNext(iterator), accelerator != 0 {
            defer { IOObjectRelease(accelerator) }
            collectAGXClients(under: accelerator, into: &result)
        }
        return result
    }

    /// Recurses the whole subtree rather than matching one level: the wave-1 investigation
    /// found `AGXDeviceUserClient` children nested under the accelerator service, not
    /// directly, and did not establish a fixed depth.
    private static func collectAGXClients(under parent: io_registry_entry_t, into result: inout [Int32: UInt64]) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(parent, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while case let child = IOIteratorNext(iterator), child != 0 {
            defer { IOObjectRelease(child) }
            if isAGXDeviceUserClient(child), let pid = creatorPID(of: child) {
                // `AppUsage` is an array per client (wave-1 notes: WindowServer carried
                // three entries); summing every entry is the obvious move and is itself an
                // assumption, recorded rather than silently adopted.
                result[pid, default: 0] += gpuTime(of: child)
            }
            collectAGXClients(under: child, into: &result)
        }
    }

    private static func isAGXDeviceUserClient(_ entry: io_registry_entry_t) -> Bool {
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &name) == KERN_SUCCESS else { return false }
        return String(cString: name) == "AGXDeviceUserClient"
    }

    /// `IOUserClientCreator` reads `"pid <N>, <name>"`. The name half truncates to 16
    /// characters (`NotificationCent` for NotificationCenter) -- phase-02's "match by
    /// identifier, never display name" rule -- so only the PID is ever parsed.
    private static func creatorPID(of client: io_registry_entry_t) -> Int32? {
        guard let creator = IORegistryEntryCreateCFProperty(
            client, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        return parsePID(from: creator)
    }

    static func parsePID(from creator: String) -> Int32? {
        guard let range = creator.range(of: "pid ") else { return nil }
        let digits = creator[range.upperBound...].prefix { $0.isNumber }
        return Int32(digits)
    }

    private static func gpuTime(of client: io_registry_entry_t) -> UInt64 {
        guard let usage = IORegistryEntryCreateCFProperty(
            client, "AppUsage" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? [[String: Any]] else { return 0 }
        return usage.reduce(UInt64(0)) { total, entry in
            total + ((entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    /// §5.5.1: prefer the last path component of `proc_pidpath`, falling back to `proc_name`,
    /// which truncates at 16 characters. Both can fail for a process this one cannot inspect,
    /// and then the PID is all there is to show.
    static func name(of pid: Int32) -> String {
        resolveNameAndPath(pid: pid).name
    }

    /// The shared resolution `name(of:)` and `resolveIdentity(pid:userNames:)` both need: the
    /// path is already computed resolving the name, so 2.1 keeps it rather than discarding it
    /// a second time.
    private static func resolveNameAndPath(pid: Int32) -> (name: String, path: String?) {
        // `PROC_PIDPATHINFO_MAXSIZE` is a #define in <libproc.h> (4 * MAXPATHLEN) and is not
        // projected into Swift, so it is spelled out here.
        let pathMax = 4 * Int(MAXPATHLEN)
        var pathBuffer = [CChar](repeating: 0, count: pathMax)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathMax)) > 0 {
            let full = String(cString: pathBuffer)
            if let component = full.split(separator: "/").last, !component.isEmpty {
                return (String(component), full)
            }
        }
        var short = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &short, UInt32(short.count)) > 0 {
            let text = String(cString: short)
            if !text.isEmpty { return (text, nil) }
        }
        return ("pid \(pid)", nil)
    }

    /// `RUSAGE_INFO_V6`'s `ri_energy_nj`, the fourth per-PID call, read only when `detail` is
    /// set. `rusage_info_t` is `<sys/resource.h>`'s placeholder `void *` typedef for this
    /// family of calls; the buffer pointer is reinterpreted to that type rather than
    /// allocated as one, which is the established idiom for this API -- the kernel writes
    /// `rusage_info_v6`'s concrete bytes at the address given.
    static func readEnergyNanojoules(pid: Int32) -> UInt64? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        guard result == 0 else { return nil }
        return info.ri_energy_nj
    }

    /// §8.2's Energy column, defined once as a pure function: a *relative* impact 0–100
    /// within **this** snapshot, never an absolute unit -- so the busiest process in a
    /// snapshot reads exactly `100.0` by construction, a fact about the scale rather than a
    /// measurement. A PID absent from the returned map has no baseline yet, or every delta in
    /// the snapshot was zero; the caller renders that as `nil` / `—`, never `0.0`.
    static func energyImpact(deltas: [Int32: UInt64]) -> [Int32: Double] {
        guard let maxDelta = deltas.values.max(), maxDelta > 0 else { return [:] }
        return deltas.mapValues { 100 * Double($0) / Double(maxDelta) }
    }

    /// `pti_total_user` and `pti_total_system` are in mach absolute time units, which are not
    /// nanoseconds on Apple Silicon. §5.5.2 requires the `mach_timebase_info` conversion.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func machToNanoseconds(_ ticks: UInt64) -> UInt64 {
        guard timebase.denom != 0 else { return ticks }
        return ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = start.duration(to: end).components
        return Double(seconds) * 1000 + Double(attoseconds) * 1e-15
    }
}
