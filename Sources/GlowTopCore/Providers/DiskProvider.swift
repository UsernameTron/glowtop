import Foundation
import IOKit

/// SPEC.md §5.3. Tagged **public** (interface) / **uncertain** (semantics): the IOKit calls
/// are public and documented, but the `Statistics` dictionary keys are conventional rather
/// than formally specified. Fallback when no service matches: `.unavailable("no matching
/// IOService")`, and §4.6.1's tile shows `—` (§5.10).
public struct DiskProvider: MetricProvider {
    public let id = ProviderID.disk
    public let nominalInterval = SampleRate.hz4

    /// `kIOBlockStorageDriverStatistics*` spell these strings. They are `#define`s in
    /// `IOBlockStorageDriver.h` and are not projected into Swift, so they are written out
    /// here — which is also why §5.3.1 tags the semantics uncertain.
    private enum Key {
        static let bytesRead = "Bytes (Read)"
        static let bytesWritten = "Bytes (Write)"
        static let opsRead = "Operations (Read)"
        static let opsWritten = "Operations (Write)"
        static let timeRead = "Total Time (Read)"
        static let timeWritten = "Total Time (Write)"
    }

    struct Counters: Sendable, Equatable {
        var bytesRead: UInt64 = 0
        var bytesWritten: UInt64 = 0
        var opsRead: UInt64 = 0
        var opsWritten: UInt64 = 0
        /// Cumulative nanoseconds spent servicing requests.
        var timeRead: UInt64 = 0
        var timeWritten: UInt64 = 0
        var deviceCount = 0
    }

    private var previous: Counters?
    private var previousAt: ContinuousClock.Instant?
    private var lastValue: DiskSample?

    public init() {}

    public mutating func sample() -> Snapshot<DiskSample> {
        guard let counters = Self.readCounters() else {
            return .unavailable(reason: "no matching IOService")
        }
        let now = ContinuousClock().now
        defer { previous = counters; previousAt = now }

        guard let previousAt, let previous else { return .warming }

        switch SampleInterval.classify(from: previousAt, to: now) {
        case .toosoon:
            if let lastValue { return .value(lastValue, timestamp: now) }
            return .warming
        case .stale:
            return .warming
        case .usable(let seconds):
            guard let sample = Self.rates(previous: previous, current: counters, seconds: seconds) else {
                return .warming
            }
            lastValue = sample
            return .value(sample, timestamp: now)
        }
    }

    /// Pure, so the busy-percentage clamp and the wrap rejection are testable without a disk.
    /// Returns `nil` if any counter went backwards — a device can be unplugged or the driver
    /// set can change between samples, and §5.0.4 says that produces one `.warming`.
    static func rates(previous: Counters, current: Counters, seconds: Double) -> DiskSample? {
        guard seconds > 0 else { return nil }
        guard current.bytesRead >= previous.bytesRead,
              current.bytesWritten >= previous.bytesWritten,
              current.opsRead >= previous.opsRead,
              current.opsWritten >= previous.opsWritten,
              current.timeRead >= previous.timeRead,
              current.timeWritten >= previous.timeWritten
        else { return nil }

        // §5.3.2: busy is service time over wall time. Overlapping requests can push this
        // past 100 %, and clamping is the honest presentation at this resolution.
        let busyNanoseconds = Double((current.timeRead - previous.timeRead) + (current.timeWritten - previous.timeWritten))
        let busy = min(100, max(0, busyNanoseconds / (seconds * 1_000_000_000) * 100))

        return DiskSample(
            readBytesPerSecond: Double(current.bytesRead - previous.bytesRead) / seconds,
            writeBytesPerSecond: Double(current.bytesWritten - previous.bytesWritten) / seconds,
            readOpsPerSecond: Double(current.opsRead - previous.opsRead) / seconds,
            writeOpsPerSecond: Double(current.opsWritten - previous.opsWritten) / seconds,
            busyPercent: busy,
            totalBytesRead: current.bytesRead,
            totalBytesWritten: current.bytesWritten,
            deviceCount: current.deviceCount
        )
    }

    /// Iterates every `IOBlockStorageDriver` and sums its `Statistics`.
    ///
    /// **Every matched service is released, and the iterator too, on every path out**
    /// (§5.3.2). IOKit object leaks in a process that samples four times a second are not
    /// survivable over an 8-hour session — §13.4 lists it as a known trap and gate 10 is
    /// what would catch it. The `defer`s are placed so an early `continue` cannot skip one.
    static func readCounters() -> Counters? {
        guard let matching = IOServiceMatching("IOBlockStorageDriver") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var counters = Counters()
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let raw = IORegistryEntryCreateCFProperty(
                service, "Statistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            counters.deviceCount += 1
            // §5.3.3: a missing key zeroes that field and the rest of the payload still
            // ships. A missing `Total Time` costs the busy percentage, not the throughput.
            counters.bytesRead += number(raw, Key.bytesRead)
            counters.bytesWritten += number(raw, Key.bytesWritten)
            counters.opsRead += number(raw, Key.opsRead)
            counters.opsWritten += number(raw, Key.opsWritten)
            counters.timeRead += number(raw, Key.timeRead)
            counters.timeWritten += number(raw, Key.timeWritten)
        }

        // No block storage driver at all is a real unavailability, not a zero reading.
        guard counters.deviceCount > 0 else { return nil }
        return counters
    }

    private static func number(_ dictionary: [String: Any], _ key: String) -> UInt64 {
        (dictionary[key] as? NSNumber)?.uint64Value ?? 0
    }
}
