import Foundation

/// SPEC.md §14.6's projection -- pure functions over `DiskSpaceReader`'s two halves
/// (`VolumeInfo`, `LevelResult`), `InstalledAppsModel`/`ConnectionsModel`'s sibling: no view
/// formats a number (`Formatting.swift`'s one-owner rule), every string here is verbatim from
/// `phase-13-UI-SPEC.md`'s Copywriting Contract.
///
/// The aggregate rectangle's `{k} smaller items` text is `TreemapLayout`'s own output (2.1) --
/// this model never re-derives it, it only supplies the sorted `TreemapChild` list that layout
/// aggregates from.
public enum DiskSpaceModel {
    // MARK: - The treemap input (D-14: allocated is the layout key)

    /// Sorts `level.children` **descending by `allocatedBytes`, `nil` last regardless of
    /// direction, name ascending as the tie-break** -- `InstalledAppsModel.stableSort`'s size
    /// rule, generalised to the one column this pane has. `readable == false` always maps to
    /// `bytes: nil` here even though the reader already guarantees it (D-20: never a low
    /// number) -- this is the boundary the treemap's `Locked` carve-out reads.
    public static func project(_ level: LevelResult) -> [TreemapChild] {
        level.children
            .sorted { lhs, rhs in
                switch (lhs.allocatedBytes, rhs.allocatedBytes) {
                case (nil, nil): return lhs.name < rhs.name
                case (nil, _): return false
                case (_, nil): return true
                case let (l?, r?):
                    if l == r { return lhs.name < rhs.name }
                    return l > r
                }
            }
            .map { TreemapChild(name: $0.name, bytes: $0.readable ? $0.allocatedBytes : nil) }
    }

    // MARK: - Node readout and the DISK-03 disclosure line (D-14, D-15, D-16)

    /// `{name} — {allocated} on disk · {apparent} apparent · {entries} items`. A `Locked`
    /// child's sizes are `Format.unknown` -- there was nothing to read.
    public static func readoutText(for child: DirectoryChild) -> String {
        let allocatedText = child.allocatedBytes.map(Format.bytes) ?? Format.unknown
        let apparentText = child.apparentBytes.map(Format.bytes) ?? Format.unknown
        return "\(child.name) — \(allocatedText) on disk · \(apparentText) apparent · \(Format.count(child.entries)) items"
    }

    /// D-15's three computed forms. A `Locked` node (no sizes were read) gets **no** line --
    /// there is nothing to disclose about a size that was never read. Both directions are real
    /// on the reference Mac and both are exercised in `DiskSpaceModelTests` -- a disclosure
    /// line that only ever named the sparse-file direction would miss the commoner one (D-15).
    public static func disclosureText(for child: DirectoryChild) -> String? {
        guard child.readable, let allocated = child.allocatedBytes, let apparent = child.apparentBytes else {
            return nil
        }
        let allocatedD = Double(allocated)
        let apparentD = Double(apparent)
        if apparentD > allocatedD * 1.10 {
            return "On-disk sizes. \(Format.bytes(allocated)) here, from files whose logical size is "
                + "\(Format.bytes(apparent)) — sparse, cloned or cloud-evicted."
        }
        if allocatedD > apparentD * 1.10 {
            return "On-disk sizes; \(Format.count(child.entries)) small files round up to 4 KB blocks."
        }
        return "On-disk sizes; clones, sparse files and snapshots can differ from logical size."
    }

    // MARK: - The three failure footers (§14.6's closing sentence: never confusable, never collapsed)

    /// Cancelled and partial-read can **co-occur** -- a walk stopped mid-way through a node that
    /// already turned up an unreadable grandchild -- so both notes are built independently and
    /// joined with `StartupAppsPaneController.footerText()`'s two-space separator. A root that
    /// refused to enumerate at all returns its own reason, verbatim, and nothing else -- the
    /// reader never produces a root failure alongside a cancelled or partial one.
    public static func footerText(for level: LevelResult) -> String {
        if let reason = level.rootUnavailableReason { return reason }
        var lines: [String] = []
        if level.cancelled {
            lines.append("Sizing stopped at \(Format.count(level.sizedCount)) of \(Format.count(level.totalCount)) items.")
        }
        if level.unreadableCount > 0 {
            lines.append("\(Format.count(level.unreadableCount)) items could not be read; their sizes are not included.")
        }
        return lines.joined(separator: "  ")
    }

    // MARK: - The volumes card (D-07)

    /// `{capacity} · {used} · {free}`.
    public static func volumeRowText(_ volume: VolumeInfo) -> String {
        "\(Format.bytes(volume.capacityBytes)) · \(Format.bytes(volume.usedBytes)) · \(Format.bytes(volume.freeBytes))"
    }

    /// D-07: Finder's larger "important usage" free figure names the purgeable gap rather than
    /// replacing `df`'s `Free` -- `nil` unless the gap exceeds 1 GB, so an ordinary handful of
    /// snapshot megabytes never earns a clause.
    private static let oneGigabyte: UInt64 = 1_073_741_824

    public static func purgeableClause(_ volume: VolumeInfo) -> String? {
        guard let importantFree = volume.importantUsageFreeBytes, importantFree > volume.freeBytes else {
            return nil
        }
        let gap = importantFree - volume.freeBytes
        guard gap > oneGigabyte else { return nil }
        return "\(Format.bytes(gap)) more is purgeable (snapshots, caches)"
    }

    // MARK: - The progress label's two forms (D-10, D-23)

    /// The label before the first child completes -- "says what it is about to do before it
    /// does it".
    public static func preScanAnnouncement(count: Int, rootLabel: String) -> String {
        "Sizing \(Format.count(count)) items in \(rootLabel) — this walks every file beneath them."
    }

    /// The same label, from the first progress callback onward.
    public static func progressText(done: Int, total: Int, name: String) -> String {
        "Sizing \(Format.count(done)) of \(Format.count(total)) — \(name)"
    }

    // MARK: - The three §4.8 bodies (D-23) -- verbatim, and distinct from one another and from every footer above

    public static let emptyBodyText = "No browsable volumes"
    public static let noRootBodyText = "Select a volume or press ⌘D again for your home folder"
    public static let unavailableBodyText = "Unavailable on this Mac"
}
