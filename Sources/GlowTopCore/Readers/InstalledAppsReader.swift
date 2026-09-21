import Foundation
import Security

/// SPEC.md §14.3. A pane-owned one-shot scan, `SystemInfoReader`'s shape -- never held as a
/// slot in the metrics store (a scan has no "current value" between refreshes, and §6.3's
/// 2 s stall rule would misfire on every idle minute between scans).
public struct InstalledApp: Sendable, Equatable {
    public let bundlePath: String
    public let name: String
    public let version: String?
    public let bundleIdentifier: String?  // "Unparseable" when Info.plist would not decode
    public let allocatedBytes: UInt64?    // nil when the walk could not finish
    public let signingIdentity: String?   // certificate summary / "Ad-hoc" / "Unsigned"
    public let architectures: [String]    // sorted; empty when unreadable
    public let isUnparseable: Bool

    public init(
        bundlePath: String, name: String, version: String?, bundleIdentifier: String?,
        allocatedBytes: UInt64?, signingIdentity: String?, architectures: [String], isUnparseable: Bool
    ) {
        self.bundlePath = bundlePath
        self.name = name
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.allocatedBytes = allocatedBytes
        self.signingIdentity = signingIdentity
        self.architectures = architectures
        self.isUnparseable = isUnparseable
    }
}

public struct InstalledAppsScan: Sendable, Equatable {
    public let apps: [InstalledApp]
    public let scannedCount: Int
    public let totalCount: Int
    public let cancelled: Bool
    public let unreadableRoots: [String]
    public let millisecondsElapsed: Double

    public init(
        apps: [InstalledApp], scannedCount: Int, totalCount: Int, cancelled: Bool,
        unreadableRoots: [String], millisecondsElapsed: Double
    ) {
        self.apps = apps
        self.scannedCount = scannedCount
        self.totalCount = totalCount
        self.cancelled = cancelled
        self.unreadableRoots = unreadableRoots
        self.millisecondsElapsed = millisecondsElapsed
    }
}

public enum InstalledAppsReader {
    /// D-17: two roots, one level deep. `/System/Applications` is deliberately absent
    /// (§14.3, override O-3).
    public static var defaultRoots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    }

    /// Every `.app` bundle under `roots`, one level deep into a non-bundle subdirectory,
    /// symlinks resolved (D-17 -- `/Applications/Safari.app` is one on this Mac).
    public static func bundleURLs(under roots: [URL]) -> (urls: [URL], unreadableRoots: [String]) {
        var found: [URL] = []
        var unreadable: [String] = []
        for root in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]
            ) else {
                unreadable.append(root.path)
                continue
            }
            for entry in entries.sorted(by: { $0.path < $1.path }) {
                if entry.pathExtension == "app" {
                    found.append(entry.resolvingSymlinksInPath())
                } else if let nested = try? FileManager.default.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                    found.append(contentsOf: nested.filter { $0.pathExtension == "app" }
                        .sorted(by: { $0.path < $1.path }).map { $0.resolvingSymlinksInPath() })
                }
            }
        }
        return (found, unreadable)
    }

    /// One bundle, every field independently -- a failure in one does not blank the rest
    /// (§5.5.1's rule, applied here: signing failing does not hide the size).
    public static func app(at url: URL) -> InstalledApp {
        let bundle = Bundle(url: url)
        let plistOK = Self.infoPlistParses(at: url)
        let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? bundle?.infoDictionary?["CFBundleName"] as? String
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(
            bundlePath: url.path, name: name,
            version: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String,
            bundleIdentifier: plistOK ? bundle?.bundleIdentifier : "Unparseable",
            allocatedBytes: Self.allocatedSize(of: url),
            signingIdentity: Self.signingIdentity(at: url),
            architectures: Self.architectureNames(bundle),
            isUnparseable: !plistOK
        )
    }

    /// `Bundle.infoDictionary` does not return `nil` for a malformed `Info.plist` -- confirmed
    /// empirically, it returns an empty dictionary instead -- so "did the plist parse" is
    /// answered by decoding the file directly, `LaunchdReader`'s precedent (finding F-12),
    /// not by `Bundle`'s own lazily-loaded accessor.
    private static func infoPlistParses(at url: URL) -> Bool {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return false }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil
    }

    /// D-21: allocated bytes (`totalFileAllocatedSizeKey`), not apparent -- the figure that is
    /// true about disk space (Xcode's 8.87 GB apparent / 3.76 GB allocated gap, finding F-14).
    /// Cancellable every 512 files.
    ///
    /// **Manual recursion, not `FileManager`'s deep enumerator.** `NSDirectoryEnumerator`'s
    /// `skipDescendants()` has an undocumented off-by-one confirmed live on this Mac: calling
    /// it while visiting one directory suppressed descent into the *next sibling* directory
    /// instead of the one just visited. A directory symlink (a standard umbrella-framework
    /// alias, `Foo.framework/Resources -> Versions/Current/Resources`) is excluded by simply
    /// never recursing into it here, sidestepping that API rather than fighting it.
    ///
    /// **Hard-link dedup, the other half of matching `du -sk`.** `.fileResourceIdentifierKey`
    /// is a stable per-inode identity, fetched in the same batch as every other property;
    /// without deduping by it, Xcode's 30 000+ hard-linked files (per-platform icons shared
    /// via hard link, `make`/`gnumake` sharing one inode) were each counted once per
    /// directory entry, reading 7% *larger* than `du -sk` -- the exact over-count shape this
    /// sub-step's own "Failure" section named in advance, traced to hard links rather than
    /// symlinks. With both fixes the two now agree exactly on this Mac: 3 756 228 608 B,
    /// byte for byte against `du -sk`'s 3 668 192 K (finding F-14).
    public static func allocatedSize(of url: URL, isCancelled: () -> Bool = { false }) -> UInt64? {
        var seenFiles = Set<AnyHashable>()
        var seenCount = 0
        var cancelled = false
        let total = Self.walkAllocatedSize(
            url, seenFiles: &seenFiles, seenCount: &seenCount, isCancelled: isCancelled, cancelled: &cancelled
        )
        return cancelled ? nil : total
    }

    private static let allocatedSizeKeys: Set<URLResourceKey> = [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileResourceIdentifierKey,
    ]

    private static func walkAllocatedSize(
        _ url: URL, seenFiles: inout Set<AnyHashable>, seenCount: inout Int,
        isCancelled: () -> Bool, cancelled: inout Bool
    ) -> UInt64 {
        guard !cancelled,
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: url, includingPropertiesForKeys: Array(allocatedSizeKeys)
              )
        else { return 0 }
        var total: UInt64 = 0
        for entry in entries {
            if cancelled { break }
            seenCount += 1
            if seenCount % 512 == 0, isCancelled() {
                cancelled = true
                break
            }
            guard let values = try? entry.resourceValues(forKeys: allocatedSizeKeys) else { continue }
            if values.isSymbolicLink == true { continue } // D-21: no symlink following, either direction
            if values.isDirectory == true {
                total += Self.walkAllocatedSize(
                    entry, seenFiles: &seenFiles, seenCount: &seenCount, isCancelled: isCancelled, cancelled: &cancelled
                )
            } else if values.isRegularFile == true, let size = values.totalFileAllocatedSize {
                if let identifier = values.fileResourceIdentifier as? NSObject {
                    let key = AnyHashable(identifier)
                    if seenFiles.contains(key) { continue }
                    seenFiles.insert(key)
                }
                total += UInt64(size)
            }
        }
        return total
    }

    /// D-20: read, never validated. `SecCodeCopySigningInformation`, not the signature
    /// *validity*-check API -- the latter hashes every file in the bundle and turns a
    /// sub-second row into a multi-second one on something the size of Xcode.
    public static func signingIdentity(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        if status == errSecCSUnsigned { return "Unsigned" }
        guard status == errSecSuccess, let dict = info as? [String: Any] else { return nil }
        if let flags = dict[kSecCodeInfoFlags as String] as? UInt32,
           SecCodeSignatureFlags(rawValue: flags).contains(.adhoc) {
            return "Ad-hoc"
        }
        guard let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?
        else { return nil }
        return summary
    }

    /// D-19: `Bundle.executableArchitectures`, no Mach-O parser (finding F-16) -- Foundation
    /// already reads the fat/thin header.
    public static func architectureNames(_ bundle: Bundle?) -> [String] {
        architectureNames(from: bundle?.executableArchitectures ?? [])
    }

    /// The mapping alone (finding F-16's two raw values), separated from the `Bundle`
    /// accessor above so it is testable without a real executable on disk.
    static func architectureNames(from numbers: [NSNumber]) -> [String] {
        numbers.compactMap { number -> String? in
            switch number.intValue {
            case NSBundleExecutableArchitectureARM64: return "arm64"
            case NSBundleExecutableArchitectureX86_64: return "x86_64"
            default: return nil
            }
        }.sorted()
    }

    /// The entry point 4.4 calls from its detached task. D-23: cancellable, partial-result
    /// flagged.
    public static func scan(
        roots: [URL] = defaultRoots,
        progress: (Int, Int) -> Void = { _, _ in },
        isCancelled: () -> Bool = { false }
    ) -> InstalledAppsScan {
        let started = ContinuousClock().now
        let (urls, unreadableRoots) = bundleURLs(under: roots)
        var apps: [InstalledApp] = []
        for (index, url) in urls.enumerated() {
            if isCancelled() {
                return InstalledAppsScan(
                    apps: apps, scannedCount: index, totalCount: urls.count,
                    cancelled: true, unreadableRoots: unreadableRoots,
                    millisecondsElapsed: ProcessProvider.milliseconds(from: started, to: ContinuousClock().now)
                )
            }
            apps.append(app(at: url))
            progress(index + 1, urls.count)
        }
        return InstalledAppsScan(
            apps: apps, scannedCount: urls.count, totalCount: urls.count,
            cancelled: false, unreadableRoots: unreadableRoots,
            millisecondsElapsed: ProcessProvider.milliseconds(from: started, to: ContinuousClock().now)
        )
    }
}
