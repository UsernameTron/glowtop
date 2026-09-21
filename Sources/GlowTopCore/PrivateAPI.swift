import Foundation

/// SPEC.md §13.7.3: the debug flag that forces every private provider to `.unavailable`.
/// This is what gate 3 exercises -- a 30-minute run at full frame rate with four tiles
/// reading `—` -- and it must be the *same* code path a real dyld failure takes, or it
/// proves nothing about the real failure.
public enum PrivateAPI {
    /// A `static let`, evaluated once per process. Every provider necessarily agrees on
    /// this value for the process's lifetime; a computed property would let the flag
    /// change mid-run and produce a build that half-honours gate 3.
    public static let disabled: Bool = ProcessInfo.processInfo.environment["GLOWTOP_DISABLE_PRIVATE"] != nil

    /// SPEC.md §5.0.5's newest reason. Not `"unsupported on this Mac"`: the Mac supports
    /// these APIs, the operator turned them off, and a blackout run whose tooltip blames
    /// the hardware is a tooltip that lies about the one thing gate 3 exists to test.
    public static let disabledReason = "private APIs disabled"
}

/// The **one** `dlopen`/`dlsym` site in the codebase. GPU, energy and frequency share
/// `.ioReport`; thermals uses `.ioKit`. Three `dlopen`s of one library would be three
/// places for the same failure and three places for §13.7.3's flag to be forgotten --
/// checking it here, once, means a provider physically cannot bypass the blackout.
public enum PrivateLib {
    public enum Library: String, Sendable {
        case ioReport = "/usr/lib/libIOReport.dylib"
        case ioKit = "/System/Library/Frameworks/IOKit.framework/IOKit"
    }

    /// `nil` immediately when `PrivateAPI.disabled`. Otherwise the cached `dlopen` result
    /// for `library` -- including a cached failure, since each cache is a `static let` and
    /// therefore initialised exactly once with no lock.
    ///
    /// Deliberately no on-disk existence check before the `dlopen` call:
    /// `/usr/lib/libIOReport.dylib` does not exist as a file on this macOS -- it resolves
    /// only from the dyld shared cache -- and `dlopen` succeeds regardless. Such a check
    /// would black out every private provider permanently on a machine where all of them
    /// work.
    public static func handle(_ library: Library) -> UnsafeMutableRawPointer? {
        guard !PrivateAPI.disabled else { return nil }
        switch library {
        case .ioReport: return ioReportHandle
        case .ioKit: return ioKitHandle
        }
    }

    public static func symbol<T>(_ name: String, in library: Library, as type: T.Type) -> T? {
        guard let handle = handle(library), let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: type)
    }

    // `nonisolated(unsafe)`: a `static let` initializes exactly once, guarded by Swift's own
    // one-time-init lock, so the handle is safely shared despite `UnsafeMutableRawPointer`
    // not being `Sendable`.
    nonisolated(unsafe) private static let ioReportHandle: UnsafeMutableRawPointer? =
        dlopen(Library.ioReport.rawValue, RTLD_LAZY)
    nonisolated(unsafe) private static let ioKitHandle: UnsafeMutableRawPointer? =
        dlopen(Library.ioKit.rawValue, RTLD_LAZY)
}
