import Foundation
import IOKit

/// SPEC.md §5.8.1 path 1 (IOHIDEventSystem), §5.8.2 sensor selection. Path 2 (SMC) is **not
/// implemented** -- path 1 yields sensors on this Mac (recorded in 4.2's SPEC amendment),
/// so path 2 would be code no hardware in this project can execute; the stated fallback is
/// this provider's own `.unavailable("unsupported on this Mac")`.
public struct ThermalProvider: MetricProvider {
    public let id = ProviderID.thermal
    public let nominalInterval = SampleRate.hz1

    private typealias ClientCreateFn = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
    private typealias ClientSetMatchingFn = @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> Void
    private typealias ClientCopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias ServiceCopyPropertyFn =
        @convention(c) (UnsafeMutableRawPointer, UnsafeRawPointer) -> UnsafeMutableRawPointer?
    private typealias ServiceCopyEventFn =
        @convention(c) (UnsafeMutableRawPointer, Int32, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias EventGetFloatValueFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

    /// `IOHIDEvent` field selectors are `(type << 16) | index` -- neither constant is
    /// projected into Swift, so a bare `983040` in a call site would be unreadable and
    /// unverifiable; the derivation is written out instead.
    static let kIOHIDEventTypeTemperature: Int32 = 15
    static let temperatureField: Int32 = 15 << 16 // 983040

    private static let clientCreateFn =
        PrivateLib.symbol("IOHIDEventSystemClientCreate", in: .ioKit, as: ClientCreateFn.self)
    private static let clientSetMatchingFn =
        PrivateLib.symbol("IOHIDEventSystemClientSetMatching", in: .ioKit, as: ClientSetMatchingFn.self)
    private static let clientCopyServicesFn =
        PrivateLib.symbol("IOHIDEventSystemClientCopyServices", in: .ioKit, as: ClientCopyServicesFn.self)
    private static let serviceCopyPropertyFn =
        PrivateLib.symbol("IOHIDServiceClientCopyProperty", in: .ioKit, as: ServiceCopyPropertyFn.self)
    private static let serviceCopyEventFn =
        PrivateLib.symbol("IOHIDServiceClientCopyEvent", in: .ioKit, as: ServiceCopyEventFn.self)
    private static let eventGetFloatValueFn =
        PrivateLib.symbol("IOHIDEventGetFloatValue", in: .ioKit, as: EventGetFloatValueFn.self)

    public init() {}

    public mutating func sample() -> Snapshot<ThermalSample> {
        guard !PrivateAPI.disabled else { return .unavailable(reason: PrivateAPI.disabledReason) }
        guard let (kept, rejected) = Self.readSensors(), !kept.isEmpty else {
            return .unavailable(reason: "unsupported on this Mac")
        }
        let sample = Self.compose(kept: kept, rejected: rejected)
        return .value(sample, timestamp: ContinuousClock().now)
    }

    /// §5.8.2: sort hottest first, headline is the maximum. Pure and static so the ranking
    /// is testable from fixture sensors with no hardware.
    static func compose(kept: [ThermalSample.Sensor], rejected: [ThermalSample.Sensor]) -> ThermalSample {
        let sorted = kept.sorted { $0.celsius > $1.celsius }
        return ThermalSample(sensors: sorted, maxCelsius: sorted[0].celsius, rejected: rejected)
    }

    /// §5.8.2's filter: sensors reading 0...120 °C are kept, everything else is `rejected`
    /// with its raw value -- no further filtering (the discretion table). Every copied CF
    /// object released, the client released, a service with no readable name or no event
    /// **skipped**, never force-unwrapped.
    static func readSensors() -> (kept: [ThermalSample.Sensor], rejected: [ThermalSample.Sensor])? {
        guard let create = clientCreateFn, let setMatching = clientSetMatchingFn,
              let copyServices = clientCopyServicesFn, let copyProperty = serviceCopyPropertyFn,
              let copyEvent = serviceCopyEventFn, let getFloat = eventGetFloatValueFn
        else { return nil }

        guard let clientPtr = create(kCFAllocatorDefault) else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(clientPtr).release() }

        // §5.8.1's matching dictionary, verbatim.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        withExtendedLifetime(matching) {
            setMatching(clientPtr, Unmanaged.passUnretained(matching).toOpaque())
        }

        guard let servicesPtr = copyServices(clientPtr) else { return nil }
        let services = Unmanaged<CFArray>.fromOpaque(servicesPtr).takeRetainedValue()
        let count = CFArrayGetCount(services)

        var kept: [ThermalSample.Sensor] = []
        var rejected: [ThermalSample.Sensor] = []

        for index in 0..<count {
            guard let serviceRaw = CFArrayGetValueAtIndex(services, index) else { continue }
            let servicePtr = UnsafeMutableRawPointer(mutating: serviceRaw)

            guard let namePtr = copyProperty(servicePtr, Unmanaged.passUnretained("Product" as CFString).toOpaque())
            else { continue }
            let name = Unmanaged<CFString>.fromOpaque(namePtr).takeRetainedValue() as String
            guard !name.isEmpty else { continue }

            guard let eventPtr = copyEvent(servicePtr, kIOHIDEventTypeTemperature, 0, 0) else { continue }
            defer { Unmanaged<CFTypeRef>.fromOpaque(eventPtr).release() }

            let celsius = getFloat(eventPtr, temperatureField)
            let sensor = ThermalSample.Sensor(name: name, celsius: celsius)
            if (0...120).contains(celsius) {
                kept.append(sensor)
            } else {
                rejected.append(sensor)
            }
        }
        return (kept, rejected)
    }
}
