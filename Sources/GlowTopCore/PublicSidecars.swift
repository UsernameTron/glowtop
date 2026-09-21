import Foundation
import IOKit
import IOKit.ps

/// SPEC.md §5.7.2, feeding §4.6.3's Energy footer and the unprivileged upper bound §5.6.3's
/// locked decision uses to catch a package-power unit wrong by orders of magnitude.
///
/// **Public** and unaffected by §13.7.3's flag -- deliberately kept off every private
/// provider's payload (see the discretion table): a `Snapshot.unavailable` carries no
/// payload, and trapping this read inside `EnergySample` would mean the footer goes dark
/// under the blackout too, breaking §5.7.2's promise that the power source "is reliable even
/// when the wattage is not".
public struct PowerSourceInfo: Sendable, Codable, Equatable {
    /// IOKit's own value, unmodified: `"AC Power"`, `"Battery Power"`, or `"Off Line"`.
    public let type: String
    public let chargePercent: Double?
    public let timeToEmptyMinutes: Int?
    /// `AppleSmartBattery`'s `CycleCount` registry property -- a separate public IOKit read,
    /// conventional rather than documented (**uncertain**, same tag `DiskProvider`'s
    /// `Statistics` keys carry). `nil` when absent.
    public let cycleCount: Int?
    /// Amperage x voltage, watts, **on battery only** -- §5.6.3's locked decision: package
    /// power must sit under this. `nil` on AC, where IOKit reports no whole-system draw.
    public let wholeSystemWatts: Double?

    public init(
        type: String, chargePercent: Double?, timeToEmptyMinutes: Int?,
        cycleCount: Int?, wholeSystemWatts: Double?
    ) {
        self.type = type
        self.chargePercent = chargePercent
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.cycleCount = cycleCount
        self.wholeSystemWatts = wholeSystemWatts
    }
}

/// SPEC.md §5.7.2. `IOPSCopyPowerSourcesInfo` and friends are public, linked directly --
/// no `dlopen`, no `PrivateLib`, no §13.7.3 check.
public enum PowerSource {
    public static func current() -> PowerSourceInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let ps = list.first
        else { return nil }
        guard let description = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let type = description[kIOPSPowerSourceStateKey] as? String ?? kIOPSACPowerValue
        let current = (description[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue
        let max = (description[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue
        let chargePercent = (current.map { c in max.map { m in m > 0 ? c / m * 100 : nil } ?? nil }) ?? nil
        let timeToEmpty = (description[kIOPSTimeToEmptyKey] as? NSNumber)?.intValue

        // §5.6.3's locked decision: amperage x voltage, on battery only -- IOKit reports no
        // whole-system draw on AC.
        var wholeSystemWatts: Double?
        if type == kIOPSBatteryPowerValue,
           let milliamps = (description[kIOPSCurrentKey] as? NSNumber)?.doubleValue,
           let millivolts = (description[kIOPSVoltageKey] as? NSNumber)?.doubleValue {
            wholeSystemWatts = abs(milliamps * millivolts) / 1_000_000
        }

        return PowerSourceInfo(
            type: type, chargePercent: chargePercent, timeToEmptyMinutes: timeToEmpty,
            cycleCount: readCycleCount(), wholeSystemWatts: wholeSystemWatts
        )
    }

    /// `AppleSmartBattery`'s `CycleCount` -- a second, unrelated public IOKit registry read.
    /// Matched service released on every path out (`DiskProvider.readCounters()`'s pattern).
    private static func readCycleCount() -> Int? {
        guard let matching = IOServiceMatching("AppleSmartBattery") else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(
            service, "CycleCount" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? NSNumber)?.intValue
    }
}

/// SPEC.md §5.8.4. **Public**, documented, unaffected by §13.7.3's flag -- deliberately not
/// part of `ThermalSample`'s payload (see the discretion table), so the Thermals tile still
/// shows a real pressure state when every raw sensor is unreadable, including under the
/// blackout.
public enum ThermalPressure: Sendable, Codable, Equatable {
    case nominal, fair, serious, critical

    public static func current() -> ThermalPressure {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    /// §5.8.4's table, verbatim.
    public var footerText: String {
        switch self {
        case .nominal: return "Nominal thermal pressure"
        case .fair: return "Fair thermal pressure"
        case .serious: return "Serious thermal pressure"
        case .critical: return "Critical thermal pressure"
        }
    }

    /// §5.8.4's color column, as a `Theme` token -- never a hex literal (§7.1's boundary).
    public var colorToken: String {
        switch self {
        case .nominal: return "textTertiary"
        case .fair: return "warning"
        case .serious: return "accentThermal"
        case .critical: return "critical"
        }
    }
}
