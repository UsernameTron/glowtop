import Darwin
import Foundation
import IOKit

/// SPEC.md §9.2's four groups: Hardware, Software, Memory and storage, GlowTop itself.
///
/// Every field is a pre-formatted string -- the view draws exactly what it is handed and
/// decides nothing about what a number is (§7.1). `colorToken` is `nil` on every row except
/// memory pressure, §9.2's only coloured row.
public struct SystemInfo: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        public let label: String
        public let value: String
        public let isMonospaced: Bool
        public let colorToken: String?

        public init(label: String, value: String, isMonospaced: Bool, colorToken: String? = nil) {
            self.label = label
            self.value = value
            self.isMonospaced = isMonospaced
            self.colorToken = colorToken
        }
    }

    /// §9.3: "read once at launch and refreshed on wake from sleep." `software` holds the
    /// five rows that never change on their own; the sixth row of that card, Uptime, is a
    /// live row (below) the pane controller splices in at display time -- §9.2 lists Uptime
    /// inside the Software card even though it updates on its own cadence.
    public struct StaticRows: Sendable, Equatable {
        public let hardware: [Row]
        public let software: [Row]
    }

    /// §9.3's 1 Hz rows, plus the tooltip for the Providers row (§5.0.5's reasons, named on
    /// hover rather than only counted).
    public struct Live: Sendable, Equatable {
        public let uptime: Row
        public let memoryAndStorage: [Row]
        public let glowTop: [Row]
        public let providersTooltip: String
    }
}

/// §9.2's readers. `staticRows()` is a pure `static func`: nothing it reads changes between
/// calls except on wake from sleep, which the pane controller re-triggers explicitly rather
/// than this type polling for it.
///
/// `liveRows(memory:health:frameRate:)` is **not** static: the GlowTop's-own CPU row is a delta
/// (§5.0.3's convention, the same one every other per-second reading in this codebase uses),
/// and a delta needs a baseline carried between calls. A `static func` cannot hold that
/// baseline without an unguarded global, so this type is a small stateful reader, shaped like
/// `CPUProvider`/`GPUProvider` rather than like `Format`'s stateless functions.
public struct SystemInfoReader: Sendable {
    private var previousOwnCPUTime: (nanoseconds: UInt64, at: ContinuousClock.Instant)?

    public init() {}

    // MARK: - Static rows

    public static func staticRows() -> SystemInfo.StaticRows {
        let chipName = Sysctl.string("machdep.cpu.brand_string")
        let logical = Sysctl.integer("hw.logicalcpu") ?? 0
        let performance = Sysctl.integer("hw.perflevel0.logicalcpu") ?? logical
        let efficiency = Sysctl.integer("hw.perflevel1.logicalcpu") ?? 0

        let hardware: [SystemInfo.Row] = [
            .init(label: "Model name", value: modelNameText(), isMonospaced: false),
            .init(label: "Model identifier", value: Sysctl.string("hw.model") ?? Format.unknown, isMonospaced: true),
            .init(label: "Chip", value: chipName ?? Format.unknown, isMonospaced: false),
            .init(label: "Total cores", value: coreSplitText(logical: logical, performance: performance, efficiency: efficiency), isMonospaced: true),
            .init(label: "GPU cores", value: gpuCoreCountText(), isMonospaced: true),
            .init(label: "Neural Engine cores", value: neuralEngineCoreCountText(chipName: chipName), isMonospaced: true),
            .init(label: "Memory", value: Sysctl.uint64("hw.memsize").map(Format.bytes) ?? Format.unknown, isMonospaced: true),
            .init(label: "Serial number", value: platformString("IOPlatformSerialNumber") ?? Format.unknown, isMonospaced: true),
            .init(label: "Hardware UUID", value: platformString("IOPlatformUUID") ?? Format.unknown, isMonospaced: true),
        ]

        let software: [SystemInfo.Row] = [
            .init(label: "macOS version", value: ProcessInfo.processInfo.operatingSystemVersionString, isMonospaced: true),
            .init(label: "Build", value: Sysctl.string("kern.osversion") ?? Format.unknown, isMonospaced: true),
            .init(label: "Kernel", value: Sysctl.string("kern.version").map(firstLine) ?? Format.unknown, isMonospaced: true),
            .init(label: "Boot volume", value: bootVolumeText(), isMonospaced: false),
            .init(label: "Computer name", value: Host.current().localizedName ?? Format.unknown, isMonospaced: false),
        ]

        return SystemInfo.StaticRows(hardware: hardware, software: software)
    }

    // MARK: - Live rows

    /// `memory` is §5.2.3's existing composition, passed in rather than re-read -- two readers
    /// of one quantity would be two answers to one question. It is optional because the pane
    /// can be shown before the first sample lands: the three memory rows then read `—` and
    /// every other row still renders, rather than the whole pane returning nothing.
    ///
    /// `frameRate` is Summary's §6.7 counter with the instant it was computed. It is `nil`
    /// wherever no display link has ever run (the probe, a cold launch), and renders as `—`
    /// rather than a fabricated number.
    public mutating func liveRows(
        memory: MemorySample?, health: [ProviderHealth], frameRate: (fps: Double, at: Date)?
    ) -> SystemInfo.Live {
        let now = ContinuousClock().now

        let uptimeValue = Self.bootDate().map { Self.uptimeText(bootDate: $0, now: Date()) } ?? Format.unknown
        let uptimeRow = SystemInfo.Row(label: "Uptime", value: uptimeValue, isMonospaced: true)

        let bucket = memory.map { Self.pressureBucket($0.pressure) }
        let memoryAndStorage: [SystemInfo.Row] = [
            .init(label: "Memory in use",
                  value: memory.map { "\(Format.bytes($0.resident)) / \(Format.bytes($0.total))" } ?? Format.unknown,
                  isMonospaced: true),
            .init(label: "Memory pressure",
                  value: memory.flatMap { sample in
                      bucket.map { "\(Format.percent(fraction: sample.pressure)) · \($0.label)" }
                  } ?? Format.unknown,
                  isMonospaced: true, colorToken: bucket?.token),
            .init(label: "Swap used",
                  value: memory.map { Format.bytes($0.swapUsed) } ?? Format.unknown, isMonospaced: true),
            .init(label: "Boot volume capacity / free", value: Self.bootVolumeCapacityText(), isMonospaced: true),
        ]

        let (ownCPUText, ownRSSText) = ownUsage(now: now)
        let glowTop: [SystemInfo.Row] = [
            .init(label: "Version", value: Self.appVersionText(), isMonospaced: true),
            .init(label: "Own CPU / RSS", value: "\(ownCPUText) · \(ownRSSText)", isMonospaced: true),
            .init(label: "Frame rate",
                  value: frameRate.map { Self.frameRateText(fps: $0.fps, sampledAt: $0.at, now: Date()) }
                         ?? Format.unknown,
                  isMonospaced: true),
            .init(label: "Providers", value: Self.providersText(health), isMonospaced: true),
        ]

        return SystemInfo.Live(
            uptime: uptimeRow, memoryAndStorage: memoryAndStorage, glowTop: glowTop,
            providersTooltip: Self.providersTooltip(health)
        )
    }

    // MARK: - GlowTop's own CPU / RSS

    /// `ri_resident_size` is instantaneous -- no baseline needed. `ri_user_time` and
    /// `ri_system_time` are cumulative nanoseconds since launch (unlike `proc_pidinfo`'s tick
    /// counters, `rusage_info_v6`'s time fields need no `mach_timebase_info` conversion), so
    /// the CPU figure is a delta across two calls, the same §5.0.3 convention every other
    /// per-second reading in this codebase uses: `nil` on the first call, and again if the
    /// gap between calls falls outside `SampleInterval`'s usable window.
    private mutating func ownUsage(now: ContinuousClock.Instant) -> (cpu: String, rss: String) {
        guard let info = Self.readOwnRusage() else { return (Format.unknown, Format.unknown) }
        let rssText = Format.bytes(info.ri_resident_size)
        let totalNanoseconds = info.ri_user_time + info.ri_system_time

        defer { previousOwnCPUTime = (totalNanoseconds, now) }

        guard let (beforeNanoseconds, beforeAt) = previousOwnCPUTime, totalNanoseconds >= beforeNanoseconds,
              case .usable(let seconds) = SampleInterval.classify(from: beforeAt, to: now)
        else { return (Format.unknown, rssText) }

        let deltaNanoseconds = totalNanoseconds - beforeNanoseconds
        let percent = Double(deltaNanoseconds) / (seconds * 1_000_000_000) * 100
        return (Format.percent(points: percent), rssText)
    }

    static func readOwnRusage() -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, rebound)
            }
        }
        return result == 0 ? info : nil
    }

    static func appVersionText() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return Format.unknown
        }
    }

    // MARK: - Providers

    static func providersText(_ health: [ProviderHealth]) -> String {
        guard !health.isEmpty else { return Format.unknown }
        let unavailable = health.filter { $0.state.isUnavailableState }.count
        return "\(health.count - unavailable) healthy · \(unavailable) unavailable"
    }

    /// §5.0.5's reasons, one per unavailable provider -- the same shape `SummaryModel`'s own
    /// status tooltip uses for the same data.
    static func providersTooltip(_ health: [ProviderHealth]) -> String {
        health.filter { $0.state.isUnavailableState }.map { entry -> String in
            if case .unavailable(let reason) = entry.state { return "\(entry.id.rawValue): \(reason)" }
            return entry.id.rawValue
        }.joined(separator: "\n")
    }

    // MARK: - Memory pressure bucket (§5.2.3, provisional)

    static func pressureBucket(_ pressure: Double) -> (label: String, token: String) {
        if pressure > 0.80 { return ("Critical", "critical") }
        if pressure >= 0.60 { return ("Warning", "warning") }
        return ("Normal", "textPrimary")
    }

    // MARK: - Pure formatting helpers (tested from fixtures, no syscalls)

    static func firstLine(_ raw: String) -> String {
        raw.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
    }

    static func coreSplitText(logical: Int, performance: Int, efficiency: Int) -> String {
        "\(logical) (\(performance) performance, \(efficiency) efficiency)"
    }

    static func uptimeText(bootDate: Date, now: Date) -> String {
        Format.duration(seconds: now.timeIntervalSince(bootDate))
    }

    /// §9.2's Frame rate row. §6.7's counter lives in Summary's display link and stops with it,
    /// so from any other pane the reading is necessarily the last one Summary took — labelled
    /// with its age rather than passed off as current (§4.8). Whole seconds under a minute,
    /// §4.9's duration format above it.
    static func frameRateText(fps: Double, sampledAt: Date, now: Date) -> String {
        let age = max(0, now.timeIntervalSince(sampledAt))
        let ageText = age < 60 ? "\(Int(age)) s" : Format.duration(seconds: age)
        return "\(String(format: "%.1f", fps)) fps · Summary, \(ageText) ago"
    }

    // MARK: - sysctl / IOKit / statfs reads

    static func bootDate() -> Date? {
        var boottime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boottime, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(boottime.tv_sec) + Double(boottime.tv_usec) / 1_000_000)
    }

    /// `IOPlatformExpertDevice`'s properties. Released on every path out -- `DiskProvider`'s
    /// established discipline for a registry lookup.
    static func platformProperty(_ key: String) -> AnyObject? {
        guard let matching = IOServiceMatching("IOPlatformExpertDevice") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func platformString(_ key: String) -> String? {
        platformProperty(key) as? String
    }

    /// §9.2: `hw.model` mapped through the IOKit `product-name` when present. `product-name`
    /// is a NUL-terminated data blob, not a `CFString`.
    static func modelNameText() -> String {
        if let data = platformProperty("product-name") as? Data {
            let trimmed = data.prefix { $0 != 0 }
            if let name = String(data: trimmed, encoding: .utf8), !name.isEmpty { return name }
        }
        return Sysctl.string("hw.model") ?? Format.unknown
    }

    /// §5.6.6's GPU core count, already implemented in `GPUProvider` -- read directly rather
    /// than duplicated. `GPUProvider.readIOAccelerator()` does not itself check
    /// §13.7.3's flag (only `sample()` does), so the gate is applied here.
    static func gpuCoreCountText() -> String {
        guard !PrivateAPI.disabled, let count = GPUProvider.readIOAccelerator()?.coreCount else { return Format.unknown }
        return "\(count)"
    }

    /// §5.6.4: "the core count in the footer comes from the SoC identification, not from
    /// IOReport." The same small table `SummaryModel.npuFooter` keeps for the Summary tile's
    /// footer -- duplicated rather than shared because `SummaryModel.swift` is out of this
    /// sub-step's scope, and it is a static data fact, not logic that could drift in behaviour.
    private static let aneCoreCounts: [(String, Int)] = [
        ("M1 Ultra", 32), ("M1 Max", 16), ("M1 Pro", 16), ("M1", 16),
        ("M2 Ultra", 32), ("M2 Max", 16), ("M2 Pro", 16), ("M2", 16),
        ("M3 Ultra", 32), ("M3 Max", 16), ("M3 Pro", 16), ("M3", 16),
        ("M4 Max", 16), ("M4 Pro", 16), ("M4", 16),
    ]

    static func neuralEngineCoreCountText(chipName: String?) -> String {
        guard !PrivateAPI.disabled, let chipName else { return Format.unknown }
        guard let cores = aneCoreCounts.first(where: { chipName.contains($0.0) })?.1 else { return Format.unknown }
        return "\(cores)"
    }

    /// §9.2's "Boot volume": name and filesystem type, `NSFileManager`/`statfs` on `/`.
    static func bootVolumeText() -> String {
        let name = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return name ?? Format.unknown }
        let fsType = withUnsafeBytes(of: &stats.f_fstypename) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return "\(name ?? Format.unknown) (\(fsType.uppercased()))"
    }

    /// §9.2's "Boot volume capacity / free", live.
    static func bootVolumeCapacityText() -> String {
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(
            forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        ), let total = values.volumeTotalCapacity else { return Format.unknown }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return "\(Format.bytes(UInt64(total))) total / \(Format.bytes(UInt64(free))) free"
    }
}
