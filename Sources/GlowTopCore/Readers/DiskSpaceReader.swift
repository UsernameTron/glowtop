import Foundation

/// SPEC.md §14.6's volume half. A pane-owned one-shot read (D-08) -- never held as a slot in
/// the 10 Hz metrics-sampling actor and never given a provider identity there: a capacity
/// figure has no current value between reads, §4.8's 2 s stall rule would misfire on every
/// idle minute, and a slot read once and never refreshed would read as stalled on Summary
/// forever after one visit (§14.5's own argument, applying unchanged to a second pane).
public struct VolumeInfo: Sendable, Equatable {
    public let name: String
    public let path: String
    public let capacityBytes: UInt64
    public let freeBytes: UInt64                    // volumeAvailableCapacity -- the reconcilable figure
    public let importantUsageFreeBytes: UInt64?      // Finder's larger number; the purgeable gap (D-07)
    public let isRemovable: Bool
    public let isInternal: Bool
    public let isRootFileSystem: Bool

    public init(
        name: String, path: String, capacityBytes: UInt64, freeBytes: UInt64,
        importantUsageFreeBytes: UInt64?, isRemovable: Bool, isInternal: Bool, isRootFileSystem: Bool
    ) {
        self.name = name
        self.path = path
        self.capacityBytes = capacityBytes
        self.freeBytes = freeBytes
        self.importantUsageFreeBytes = importantUsageFreeBytes
        self.isRemovable = isRemovable
        self.isInternal = isInternal
        self.isRootFileSystem = isRootFileSystem
    }

    public var usedBytes: UInt64 { capacityBytes >= freeBytes ? capacityBytes - freeBytes : 0 }
}

/// One child of the node being sized. **`readable == false` is D-20's Locked state**: both byte
/// totals are `nil`, never `0` -- a low number in a treemap silently shrinks the rectangle and
/// rearranges every sibling around it (§14.6, §10.4).
public struct DirectoryChild: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let readable: Bool
    public let allocatedBytes: UInt64?   // D-14: the layout key
    public let apparentBytes: UInt64?    // D-14: read in the same call, shown in the readout
    public let entries: Int

    public init(
        name: String, path: String, isDirectory: Bool, readable: Bool,
        allocatedBytes: UInt64?, apparentBytes: UInt64?, entries: Int
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.readable = readable
        self.allocatedBytes = allocatedBytes
        self.apparentBytes = apparentBytes
        self.entries = entries
    }
}

public struct LevelResult: Sendable, Equatable {
    public let rootPath: String
    public let children: [DirectoryChild]
    public let sizedCount: Int
    public let totalCount: Int
    public let cancelled: Bool
    /// Non-nil when the **root itself** could not be enumerated -- DISK-05's unavailable state,
    /// distinct from a child that refused (`readable == false`) and from a cancelled walk. All
    /// three must stay distinguishable (§14.6's closing sentence).
    public let rootUnavailableReason: String?
    public let millisecondsElapsed: Double
    /// Directories refused **deeper** inside an otherwise-readable child -- the child itself is
    /// not flipped to Locked for a grandchild's refusal. Surfaces in the pane's partial-read
    /// footer, `{k} items could not be read; their sizes are not included.`
    public let unreadableCount: Int

    public init(
        rootPath: String, children: [DirectoryChild], sizedCount: Int, totalCount: Int,
        cancelled: Bool, rootUnavailableReason: String?, millisecondsElapsed: Double, unreadableCount: Int
    ) {
        self.rootPath = rootPath
        self.children = children
        self.sizedCount = sizedCount
        self.totalCount = totalCount
        self.cancelled = cancelled
        self.rootUnavailableReason = rootUnavailableReason
        self.millisecondsElapsed = millisecondsElapsed
        self.unreadableCount = unreadableCount
    }
}

/// SPEC.md §14.6. The volumes half (`volumes()`) and the treemap half (`children(of:)`) share a
/// pane and not a mechanism (§14.6's opening sentence) -- neither one samples on a loop, and
/// this file never opens the metrics-sampling actor at all.
public enum DiskSpaceReader {
    private static let volumeKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey,
        .volumeIsInternalKey, .volumeIsRootFileSystemKey,
    ]

    /// D-05/D-06: `.skipHiddenVolumes` is the whole filter and it is doing real work --
    /// unfiltered this Mac reports fourteen volumes of which four share one 494 GB container
    /// total, so summing the unfiltered list triple-counts the disk. A volume whose capacity
    /// keys will not read is **skipped, not defaulted** -- never a zero-capacity row.
    public static func volumes() -> [VolumeInfo] {
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: volumeKeys, options: [.skipHiddenVolumes]
        ) else { return [] }

        var result: [VolumeInfo] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(volumeKeys)),
                  let capacity = values.volumeTotalCapacity, capacity >= 0,
                  let free = values.volumeAvailableCapacity, free >= 0
            else { continue }
            let importantUsage = values.volumeAvailableCapacityForImportantUsage.flatMap {
                $0 >= 0 ? UInt64($0) : nil
            }
            result.append(VolumeInfo(
                name: values.volumeName ?? url.lastPathComponent,
                path: url.path,
                capacityBytes: UInt64(capacity),
                freeBytes: UInt64(free),
                importantUsageFreeBytes: importantUsage,
                isRemovable: values.volumeIsRemovable ?? false,
                isInternal: values.volumeIsInternal ?? false,
                isRootFileSystem: values.volumeIsRootFileSystem ?? false
            ))
        }
        return result
    }

    private static let walkKeys: Set<URLResourceKey> = [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .isVolumeKey, .linkCountKey,
        .totalFileAllocatedSizeKey, .totalFileSizeKey, .fileResourceIdentifierKey,
    ]

    /// Sizes **exactly** the children of `url` and retains only their totals. Every subtotal
    /// beneath them is discarded (D-09) -- the price is a re-walk on descent and the reason is
    /// memory, not time: `/System/Volumes/Data` carries 4.9 M inodes against §13.7's 210 MB cap.
    ///
    /// `progress` is called once per child **after** its walk, carrying the finished child, so
    /// the pane can draw a rectangle the moment its size lands (§14.6's "appearing as their
    /// children finish"). `isCancelled` is checked before each child and every 512 entries.
    public static func children(
        of url: URL,
        progress: (Int, Int, DirectoryChild) -> Void = { _, _, _ in },
        isCancelled: () -> Bool = { false }
    ) -> LevelResult {
        let started = ContinuousClock().now

        let sortedEntries: [URL]
        do {
            let raw = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            sortedEntries = raw.sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            // A failure here is the root itself refusing (DISK-05) -- never an empty child list.
            return LevelResult(
                rootPath: url.path, children: [], sizedCount: 0, totalCount: 0, cancelled: false,
                rootUnavailableReason: error.localizedDescription,
                millisecondsElapsed: ProcessProvider.milliseconds(from: started, to: ContinuousClock().now),
                unreadableCount: 0
            )
        }

        var children: [DirectoryChild] = []
        var unreadableCount = 0
        var levelCancelled = false

        for entryURL in sortedEntries {
            if isCancelled() {
                levelCancelled = true
                break
            }
            let name = entryURL.lastPathComponent
            // The full key set on purpose: through a three-key read `/.nofollow`'s `isVolume`
            // answers false, through this set true (5.3b) -- the recursion reads the same set.
            let topValues = try? entryURL.resourceValues(forKeys: walkKeys)
            let isSymlink = topValues?.isSymbolicLink == true
            let isDir = !isSymlink && topValues?.isDirectory == true

            if isDir, topValues?.isVolume == true {
                // A volume root beneath the node -- `/System/Volumes/Data`, `/.nofollow`, a mounted
                // disk image -- is never crossed, `du -x`'s rule (§14.6): it reads 0 B here and is
                // sized on its own when entered. Walking it re-walks the whole disk (5.3b's finding).
                let child = DirectoryChild(
                    name: name, path: entryURL.path, isDirectory: true, readable: true,
                    allocatedBytes: 0, apparentBytes: 0, entries: 0
                )
                children.append(child)
                progress(children.count, sortedEntries.count, child)
                continue
            }

            guard isDir else {
                // A plain file (or a symlink, never followed either direction): its own sizes,
                // no recursion, no descendants.
                let values = topValues
                let child = DirectoryChild(
                    name: name, path: entryURL.path, isDirectory: false, readable: true,
                    allocatedBytes: values?.totalFileAllocatedSize.map { UInt64($0) },
                    apparentBytes: values?.totalFileSize.map { UInt64($0) },
                    entries: 0
                )
                children.append(child)
                progress(children.count, sortedEntries.count, child)
                continue
            }

            var childCancelled = false
            // One pool per child: every `resourceValues` call leaves autoreleased objects behind,
            // and without a drain a 2.8 M-entry `~` walk held ~1.8 GB until the task ended (5.3b).
            let sized: (allocated: UInt64, apparent: UInt64, entries: Int)? = autoreleasepool {
                guard let topEntries = try? FileManager.default.contentsOfDirectory(
                    at: entryURL, includingPropertiesForKeys: Array(walkKeys)
                ) else { return nil }
                var seenFiles = Set<AnyHashable>()
                var seenCount = 0
                let totals = processEntries(
                    topEntries, seenFiles: &seenFiles, seenCount: &seenCount,
                    isCancelled: isCancelled, cancelled: &childCancelled, unreadableCount: &unreadableCount
                )
                return (totals.allocated, totals.apparent, seenCount)
            }
            guard let sized else {
                // D-20: the child directory itself refuses -- Locked, nil sizes, never zero.
                let child = DirectoryChild(
                    name: name, path: entryURL.path, isDirectory: true, readable: false,
                    allocatedBytes: nil, apparentBytes: nil, entries: 0
                )
                children.append(child)
                progress(children.count, sortedEntries.count, child)
                continue
            }
            let child = DirectoryChild(
                name: name, path: entryURL.path, isDirectory: true, readable: true,
                allocatedBytes: sized.allocated, apparentBytes: sized.apparent, entries: sized.entries
            )
            children.append(child)
            progress(children.count, sortedEntries.count, child)

            if childCancelled {
                levelCancelled = true
                break
            }
        }

        return LevelResult(
            rootPath: url.path, children: children, sizedCount: children.count,
            totalCount: sortedEntries.count, cancelled: levelCancelled, rootUnavailableReason: nil,
            millisecondsElapsed: ProcessProvider.milliseconds(from: started, to: ContinuousClock().now),
            unreadableCount: unreadableCount
        )
    }

    /// `InstalledAppsReader.walkAllocatedSize`'s exact shape (F-8), with two size keys read in
    /// one batch instead of one, and a per-child hard-link `Set` instead of a per-scan one.
    ///
    /// **Manual recursion, not `FileManager`'s deep enumerator.** Its `skipDescendants()` has an
    /// undocumented off-by-one confirmed live on this Mac; a directory symlink is excluded by
    /// simply never recursing into it, sidestepping the API rather than fighting it.
    ///
    /// **Hard-link dedup**, the other half of §13.6's cross-check agreeing byte for byte:
    /// `.fileResourceIdentifierKey` is a stable per-inode identity, deduped **per child** -- a
    /// file hard-linked into two sibling directories is genuinely on disk once under each, and
    /// the cross-check instrument run per child counts it the same way. Only a file with
    /// `linkCount > 1` enters the set: a single-link inode cannot recur, and boxing every
    /// file's identifier held ~2 GB across a `~` walk (5.3b's finding, 2.8 M entries).
    ///
    /// **Volume boundaries are never crossed** (`du -x`): a directory that is itself a volume
    /// root contributes nothing and is not descended.
    private static func processEntries(
        _ entries: [URL], seenFiles: inout Set<AnyHashable>, seenCount: inout Int,
        isCancelled: () -> Bool, cancelled: inout Bool, unreadableCount: inout Int
    ) -> (allocated: UInt64, apparent: UInt64) {
        var allocatedTotal: UInt64 = 0
        var apparentTotal: UInt64 = 0
        for entry in entries {
            if cancelled { break }
            seenCount += 1
            if seenCount % 512 == 0, isCancelled() {
                cancelled = true
                break
            }
            guard let values = try? entry.resourceValues(forKeys: walkKeys) else { continue }
            if values.isSymbolicLink == true { continue } // never followed, either direction
            if values.isDirectory == true {
                if values.isVolume == true { continue } // a mount point beneath the node: du -x
                let sub = walk(
                    entry, seenFiles: &seenFiles, seenCount: &seenCount,
                    isCancelled: isCancelled, cancelled: &cancelled, unreadableCount: &unreadableCount
                )
                allocatedTotal += sub.allocated
                apparentTotal += sub.apparent
            } else if values.isRegularFile == true {
                if values.linkCount ?? 1 > 1, let identifier = values.fileResourceIdentifier as? NSObject {
                    let key = AnyHashable(identifier)
                    if seenFiles.contains(key) { continue }
                    seenFiles.insert(key)
                }
                if let allocated = values.totalFileAllocatedSize { allocatedTotal += UInt64(allocated) }
                if let apparent = values.totalFileSize { apparentTotal += UInt64(apparent) }
            }
        }
        return (allocatedTotal, apparentTotal)
    }

    /// A refusal here is **deeper** than the child entered from `children(of:)` -- it is counted
    /// into the level's `unreadableCount` and does not flip the child itself to Locked; the
    /// footer states the shortfall.
    private static func walk(
        _ url: URL, seenFiles: inout Set<AnyHashable>, seenCount: inout Int,
        isCancelled: () -> Bool, cancelled: inout Bool, unreadableCount: inout Int
    ) -> (allocated: UInt64, apparent: UInt64) {
        autoreleasepool {
            guard !cancelled,
                  let entries = try? FileManager.default.contentsOfDirectory(
                      at: url, includingPropertiesForKeys: Array(walkKeys)
                  )
            else {
                unreadableCount += 1
                return (0, 0)
            }
            return processEntries(
                entries, seenFiles: &seenFiles, seenCount: &seenCount,
                isCancelled: isCancelled, cancelled: &cancelled, unreadableCount: &unreadableCount
            )
        }
    }
}
