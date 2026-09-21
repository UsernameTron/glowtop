import Foundation

/// SPEC.md §5.4. Data source is `getifaddrs(3)` — **public**, documented, POSIX-adjacent.
/// The primary-interface choice (§5.4.2, highest cumulative byte total) is a heuristic and is
/// tagged **uncertain**; it is right on any machine with one active network path.
/// Fallback if the walk fails: `.unavailable`, and §4.6.2's tile shows `—` (§5.10).
public struct NetworkProvider: MetricProvider {
    public let id = ProviderID.network
    public let nominalInterval = SampleRate.hz4

    /// The raw cumulative state one walk produces. Counters are summed as `UInt64` but their
    /// source fields are 32-bit and do wrap (§5.4.3) — at 1 Gb/s a 32-bit byte counter wraps
    /// in about 34 seconds — so the delta step clamps rather than trusting monotonicity.
    struct Counters: Sendable, Equatable {
        var bytesIn: UInt64 = 0
        var bytesOut: UInt64 = 0
        var packetsIn: UInt64 = 0
        var packetsOut: UInt64 = 0
        var errorsIn: UInt64 = 0
        var errorsOut: UInt64 = 0
        var primaryInterface = ""
        var primaryAddress: String?
        var primaryBytesIn: UInt64 = 0
        var primaryBytesOut: UInt64 = 0
    }

    private var previous: Counters?
    private var previousAt: ContinuousClock.Instant?
    private var lastValue: NetworkSample?

    public init() {}

    public mutating func sample() -> Snapshot<NetworkSample> {
        guard let counters = Self.readCounters() else {
            return .unavailable(reason: "kernel call failed: getifaddrs")
        }
        let now = ContinuousClock().now
        // The baseline advances on every path out, including the ones returning .warming,
        // or a provider that re-warms once never recovers.
        defer { previous = counters; previousAt = now }

        guard let previousAt, let previous else { return .warming }

        switch SampleInterval.classify(from: previousAt, to: now) {
        case .toosoon:
            // Below 50 ms the denominator is near zero. Hold the last value rather than
            // dividing by it (§5.0.3).
            if let lastValue { return .value(lastValue, timestamp: now) }
            return .warming
        case .stale:
            // A delta across a sleep is not a measurement of anything (§5.0.3).
            return .warming
        case .usable(let seconds):
            guard let sample = Self.rates(previous: previous, current: counters, seconds: seconds) else {
                return .warming
            }
            lastValue = sample
            return .value(sample, timestamp: now)
        }
    }

    /// Pure, so the wrap and rate arithmetic is testable without a network interface.
    /// Returns `nil` when any counter went backwards — §5.0.4 says a decrease produces one
    /// `.warming` sample, never a huge or negative rate.
    static func rates(previous: Counters, current: Counters, seconds: Double) -> NetworkSample? {
        guard seconds > 0 else { return nil }
        guard current.bytesIn >= previous.bytesIn,
              current.bytesOut >= previous.bytesOut,
              current.packetsIn >= previous.packetsIn,
              current.packetsOut >= previous.packetsOut
        else { return nil }

        return NetworkSample(
            bytesInPerSecond: Double(current.bytesIn - previous.bytesIn) / seconds,
            bytesOutPerSecond: Double(current.bytesOut - previous.bytesOut) / seconds,
            packetsInPerSecond: Double(current.packetsIn - previous.packetsIn) / seconds,
            packetsOutPerSecond: Double(current.packetsOut - previous.packetsOut) / seconds,
            totalBytesIn: current.bytesIn,
            totalBytesOut: current.bytesOut,
            errorsIn: current.errorsIn,
            errorsOut: current.errorsOut,
            primaryInterface: current.primaryInterface,
            primaryAddress: current.primaryAddress,
            primaryBytesIn: current.primaryBytesIn,
            primaryBytesOut: current.primaryBytesOut
        )
    }

    /// One `getifaddrs` walk. `freeifaddrs` runs on every path out, including error paths
    /// (§5.4.1) — that is what the `defer` immediately after the guard is for.
    static func readCounters() -> Counters? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, head != nil else { return nil }
        defer { freeifaddrs(head) }

        var counters = Counters()
        var addresses: [String: String] = [:]
        var best: UInt64 = 0

        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let name = String(cString: entry.pointee.ifa_name)

            if address.pointee.sa_family == UInt8(AF_INET) {
                // The interface's IPv4 address for §4.6.2's footer, from the same walk.
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                    var raw = inet.pointee.sin_addr
                    var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &raw, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                        addresses[name] = String(cString: text)
                    }
                }
                continue
            }

            guard address.pointee.sa_family == UInt8(AF_LINK), let raw = entry.pointee.ifa_data else { continue }
            // §5.4.2: skip loopback, and skip interfaces silent since boot.
            guard name != "lo0" else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            guard data.ifi_ibytes != 0 || data.ifi_obytes != 0 else { continue }

            counters.bytesIn += UInt64(data.ifi_ibytes)
            counters.bytesOut += UInt64(data.ifi_obytes)
            counters.packetsIn += UInt64(data.ifi_ipackets)
            counters.packetsOut += UInt64(data.ifi_opackets)
            counters.errorsIn += UInt64(data.ifi_ierrors)
            counters.errorsOut += UInt64(data.ifi_oerrors)

            let total = UInt64(data.ifi_ibytes) + UInt64(data.ifi_obytes)
            if total > best {
                best = total
                counters.primaryInterface = name
                counters.primaryBytesIn = UInt64(data.ifi_ibytes)
                counters.primaryBytesOut = UInt64(data.ifi_obytes)
            }
        }

        counters.primaryAddress = addresses[counters.primaryInterface]
        return counters
    }
}
