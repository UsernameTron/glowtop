import Foundation

/// One IOReport channel's identity plus its most recently decoded value. `states` is
/// non-empty for state-residency channels (e.g. `GPU Performance States`); `value` is
/// populated for simple/scalar channels (e.g. `Energy Model`'s cumulative counters). A
/// channel is one shape or the other, never both, on every Mac this project has seen.
public struct IOReportChannel: Sendable {
    public let group: String
    public let subGroup: String
    public let name: String
    public let unit: String
    public let states: [(name: String, residency: UInt64)]
    public let value: Int64
}

/// Typed Swift wrappers over the `dlsym`'d IOReport symbols SPEC.md §5.6.1 names, plus the
/// extras 1.2, 2.1, 2.2 and 2.4 need for state names and units. Every function pointer is
/// resolved through `PrivateLib.symbol(_:in:as:)` -- the codebase's one library-loading site
/// -- so this enum never calls `dlsym` or its counterpart directly.
public enum IOReport {
    private typealias CopyAllChannelsFn = @convention(c) (UInt64, UInt64) -> UnsafeMutableRawPointer?
    private typealias CopyChannelsInGroupFn =
        @convention(c) (UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) -> UnsafeMutableRawPointer?
    private typealias CreateSubscriptionFn = @convention(c) (
        UnsafeRawPointer?, UnsafeMutableRawPointer, UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UInt64, UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn =
        @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesDeltaFn =
        @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias ChannelGetStringFn = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias ChannelGetFormatFn = @convention(c) (UnsafeRawPointer?) -> Int64
    private typealias SimpleGetIntegerValueFn = @convention(c) (UnsafeRawPointer?, Int32) -> Int64
    private typealias StateGetCountFn = @convention(c) (UnsafeRawPointer?) -> Int32
    private typealias StateGetResidencyFn = @convention(c) (UnsafeRawPointer?, Int32) -> UInt64
    private typealias StateGetNameForIndexFn = @convention(c) (UnsafeRawPointer?, Int32) -> UnsafeRawPointer?

    // Every symbol below is resolved once, lazily, on first access -- and every access runs
    // through `PrivateLib.symbol`, which returns `nil` under §13.7.3's flag before `dlsym`
    // is ever called.
    private static let copyAllChannelsFn =
        PrivateLib.symbol("IOReportCopyAllChannels", in: .ioReport, as: CopyAllChannelsFn.self)
    private static let copyChannelsInGroupFn =
        PrivateLib.symbol("IOReportCopyChannelsInGroup", in: .ioReport, as: CopyChannelsInGroupFn.self)
    private static let createSubscriptionFn =
        PrivateLib.symbol("IOReportCreateSubscription", in: .ioReport, as: CreateSubscriptionFn.self)
    private static let createSamplesFn =
        PrivateLib.symbol("IOReportCreateSamples", in: .ioReport, as: CreateSamplesFn.self)
    private static let createSamplesDeltaFn =
        PrivateLib.symbol("IOReportCreateSamplesDelta", in: .ioReport, as: CreateSamplesDeltaFn.self)
    private static let channelGetGroupFn =
        PrivateLib.symbol("IOReportChannelGetGroup", in: .ioReport, as: ChannelGetStringFn.self)
    private static let channelGetSubGroupFn =
        PrivateLib.symbol("IOReportChannelGetSubGroup", in: .ioReport, as: ChannelGetStringFn.self)
    private static let channelGetNameFn =
        PrivateLib.symbol("IOReportChannelGetChannelName", in: .ioReport, as: ChannelGetStringFn.self)
    private static let channelGetUnitLabelFn =
        PrivateLib.symbol("IOReportChannelGetUnitLabel", in: .ioReport, as: ChannelGetStringFn.self)
    private static let channelGetFormatFn =
        PrivateLib.symbol("IOReportChannelGetFormat", in: .ioReport, as: ChannelGetFormatFn.self)
    private static let simpleGetIntegerValueFn =
        PrivateLib.symbol("IOReportSimpleGetIntegerValue", in: .ioReport, as: SimpleGetIntegerValueFn.self)
    private static let stateGetCountFn =
        PrivateLib.symbol("IOReportStateGetCount", in: .ioReport, as: StateGetCountFn.self)
    private static let stateGetResidencyFn =
        PrivateLib.symbol("IOReportStateGetResidency", in: .ioReport, as: StateGetResidencyFn.self)
    private static let stateGetNameForIndexFn =
        PrivateLib.symbol("IOReportStateGetNameForIndex", in: .ioReport, as: StateGetNameForIndexFn.self)

    /// `true` only when every symbol above resolved. A single missing symbol makes the
    /// whole enum report unavailable -- partial IOReport is not a state any provider should
    /// reason about.
    public static var available: Bool {
        copyAllChannelsFn != nil && copyChannelsInGroupFn != nil && createSubscriptionFn != nil
            && createSamplesFn != nil && createSamplesDeltaFn != nil && channelGetGroupFn != nil
            && channelGetSubGroupFn != nil && channelGetNameFn != nil && channelGetUnitLabelFn != nil
            && channelGetFormatFn != nil && simpleGetIntegerValueFn != nil && stateGetCountFn != nil
            && stateGetResidencyFn != nil && stateGetNameForIndexFn != nil
    }

    /// `IOReportCopyAllChannels(0, 0)` -- the discovery instrument every wave-2 sub-step
    /// reads before it selects a channel. Caller owns the result and releases it with
    /// `releaseRaw(_:)`.
    public static func copyAll() -> UnsafeMutableRawPointer? {
        copyAllChannelsFn?(0, 0)
    }

    static func copyChannelsInGroup(_ group: String, _ subGroup: String?) -> UnsafeMutableRawPointer? {
        let groupCF = group as CFString
        let subGroupCF = subGroup.map { $0 as CFString }
        return withExtendedLifetime((groupCF, subGroupCF)) {
            let groupPtr = Unmanaged.passUnretained(groupCF).toOpaque()
            let subGroupPtr = subGroupCF.map { Unmanaged.passUnretained($0).toOpaque() }
            return copyChannelsInGroupFn?(groupPtr, subGroupPtr, 0, 0, 0)
        }
    }

    static func createSubscription(
        _ desired: UnsafeMutableRawPointer, _ subbed: inout UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer? {
        createSubscriptionFn?(nil, desired, &subbed, 0, nil)
    }

    static func createSamples(
        _ subscription: UnsafeMutableRawPointer, _ subbedChannels: UnsafeMutableRawPointer
    ) -> UnsafeMutableRawPointer? {
        createSamplesFn?(subscription, subbedChannels, nil)
    }

    static func createSamplesDelta(
        _ previous: UnsafeMutableRawPointer, _ current: UnsafeMutableRawPointer
    ) -> UnsafeMutableRawPointer? {
        createSamplesDeltaFn?(previous, current, nil)
    }

    /// Every CF object this enum hands back follows the `Copy`/`Create` ownership rule; the
    /// caller releases it exactly once, through here.
    public static func releaseRaw(_ ptr: UnsafeMutableRawPointer) {
        Unmanaged<CFTypeRef>.fromOpaque(ptr).release()
    }

    /// Decodes a sample or delta dictionary's `"IOReportChannels"` array. Borrows `ptr` --
    /// the caller still owns it and is responsible for `releaseRaw(_:)`.
    public static func decodeChannels(_ ptr: UnsafeMutableRawPointer) -> [IOReportChannel] {
        let dict = Unmanaged<CFDictionary>.fromOpaque(ptr).takeUnretainedValue()
        guard let channels = (dict as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return [] }
        return channels.compactMap(decode)
    }

    private static func decode(_ chan: CFDictionary) -> IOReportChannel? {
        let chanPtr = Unmanaged.passUnretained(chan).toOpaque()
        guard let group = decodeString(channelGetGroupFn?(chanPtr)),
              let name = decodeString(channelGetNameFn?(chanPtr))
        else { return nil }
        let subGroup = decodeString(channelGetSubGroupFn?(chanPtr)) ?? ""
        let unit = decodeString(channelGetUnitLabelFn?(chanPtr)) ?? ""

        let stateCount = Int(stateGetCountFn?(chanPtr) ?? 0)
        guard stateCount > 0 else {
            let value = simpleGetIntegerValueFn?(chanPtr, 0) ?? 0
            return IOReportChannel(group: group, subGroup: subGroup, name: name, unit: unit, states: [], value: value)
        }

        var states: [(name: String, residency: UInt64)] = []
        states.reserveCapacity(stateCount)
        for index in 0..<stateCount {
            let stateName = decodeString(stateGetNameForIndexFn?(chanPtr, Int32(index))) ?? "state\(index)"
            states.append((stateName, stateGetResidencyFn?(chanPtr, Int32(index)) ?? 0))
        }
        return IOReportChannel(group: group, subGroup: subGroup, name: name, unit: unit, states: states, value: 0)
    }

    private static func decodeString(_ ptr: UnsafeRawPointer?) -> String? {
        guard let ptr else { return nil }
        return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
    }
}

/// Owns one IOReport subscription and its subscribed-channels dictionary, releasing both in
/// `deinit`. **Not** a struct: a struct's caller could copy it and release the same CF
/// object twice, or drop it without releasing at all. `init?` returns `nil` on any failure
/// -- missing symbols, an empty group, or a subscription the API refuses -- so a provider
/// never has to distinguish "no such channel" from "IOReport itself is unavailable".
public final class IOReportSubscription: @unchecked Sendable {
    private let subscription: UnsafeMutableRawPointer
    private let subbedChannels: UnsafeMutableRawPointer
    private var previousSample: UnsafeMutableRawPointer?

    public init?(group: String, subGroup: String? = nil) {
        guard IOReport.available else { return nil }
        guard let desired = IOReport.copyChannelsInGroup(group, subGroup) else { return nil }
        defer { IOReport.releaseRaw(desired) }

        var subbed: UnsafeMutableRawPointer?
        guard let sub = IOReport.createSubscription(desired, &subbed), let subbedChannels = subbed else {
            return nil
        }
        subscription = sub
        self.subbedChannels = subbedChannels
    }

    deinit {
        if let previousSample { IOReport.releaseRaw(previousSample) }
        IOReport.releaseRaw(subbedChannels)
        // `subscription` itself is not released: every reference implementation of this
        // private API treats it as a handle rather than a CF object, and it lives for this
        // instance's lifetime -- the app's lifetime, for every wave-2 provider.
    }

    /// `nil` on the first call (no baseline yet -- the caller returns `.warming`, per
    /// §5.0.3) and whenever a sample fails; a channel list on every call after that.
    public func sampleDelta() -> [IOReportChannel]? {
        guard let sample = IOReport.createSamples(subscription, subbedChannels) else { return nil }

        guard let previous = previousSample else {
            previousSample = sample
            return nil
        }

        defer {
            IOReport.releaseRaw(previous)
            previousSample = sample
        }

        guard let delta = IOReport.createSamplesDelta(previous, sample) else { return nil }
        defer { IOReport.releaseRaw(delta) }
        return IOReport.decodeChannels(delta)
    }
}
