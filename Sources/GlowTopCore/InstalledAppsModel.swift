import Foundation

/// SPEC.md §14.3's pane, as pure functions over `InstalledAppsScan` -- §7.1's boundary,
/// `ProcessesModel`'s filter → stable sort → format shape. `size` is the one column that can
/// be `nil` (D-21: the walk did not finish for that bundle) and reuses `ProcessesModel`'s
/// nil-last convention, made direction-independent the way CPU's rule already is.
public enum InstalledAppSortKey: String, Sendable, CaseIterable {
    case name, version, bundleID, size, signing, arch
}

/// One row of §14.3's table, already formatted -- the §7.1 boundary.
public struct InstalledAppDetail: Sendable, Equatable {
    public let path: String
    public let nameText: String
    public let versionText: String
    public let bundleIDText: String
    public let sizeText: String
    public let signingText: String
    public let archText: String

    public init(
        path: String, nameText: String, versionText: String, bundleIDText: String,
        sizeText: String, signingText: String, archText: String
    ) {
        self.path = path
        self.nameText = nameText
        self.versionText = versionText
        self.bundleIDText = bundleIDText
        self.sizeText = sizeText
        self.signingText = signingText
        self.archText = archText
    }
}

public struct InstalledAppsModel: Sendable, Equatable {
    public let rows: [InstalledAppDetail]
    public let shownCount: Int
    public let countText: String
    public let footerNotes: [String]

    public init(rows: [InstalledAppDetail], shownCount: Int, countText: String, footerNotes: [String]) {
        self.rows = rows
        self.shownCount = shownCount
        self.countText = countText
        self.footerNotes = footerNotes
    }

    /// Filter (D-25: Name, Bundle ID), then sort, then format. D-22: an unreadable root and a
    /// cancelled scan each add their own footer note; a bundle whose size could not be walked
    /// adds to the "size unavailable" count rather than being silently absent from it.
    public static func project(
        _ scan: InstalledAppsScan, sort: InstalledAppSortKey, ascending: Bool, search: String
    ) -> InstalledAppsModel {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = query.isEmpty ? scan.apps : scan.apps.filter {
            $0.name.lowercased().contains(query) || ($0.bundleIdentifier ?? "").lowercased().contains(query)
        }
        let sorted = stableSort(filtered, key: sort, ascending: ascending)
        let rows = sorted.map(project(app:))
        let knownTotal = scan.apps.compactMap(\.allocatedBytes).reduce(0, +)
        let unknownCount = scan.apps.filter { $0.allocatedBytes == nil }.count

        var notes = scan.unreadableRoots.map { "\($0) is unreadable" }
        if scan.cancelled { notes.append("Scan stopped at \(scan.scannedCount) of \(scan.totalCount) bundles.") }
        if unknownCount > 0 { notes.append("Size unavailable for \(Format.count(unknownCount)) bundles this user cannot fully read.") }

        return InstalledAppsModel(
            rows: rows, shownCount: rows.count,
            countText: "\(Format.count(scan.apps.count)) apps · \(Format.bytes(knownTotal)) on disk · \(Format.count(rows.count)) shown",
            footerNotes: notes
        )
    }

    // MARK: - Sort (D-25: Size descending default, `—` last both directions)

    /// Decorated by original index and compared on that index for a tie, `ProcessesModel`'s
    /// own idiom. `size`'s nil-last rule is `ProcessesModel.stableSort`'s `.cpu` special case
    /// generalised to one column: unknown size sorts last regardless of direction.
    static func stableSort(_ apps: [InstalledApp], key: InstalledAppSortKey, ascending: Bool) -> [InstalledApp] {
        let indexed = Array(apps.enumerated())
        let sorted = indexed.sorted { lhs, rhs in
            if key == .size {
                switch (lhs.element.allocatedBytes, rhs.element.allocatedBytes) {
                case (nil, nil): return lhs.offset < rhs.offset
                case (nil, _): return false
                case (_, nil): return true
                case let (l?, r?):
                    if l == r { return lhs.offset < rhs.offset }
                    return ascending ? l < r : l > r
                }
            }
            let comparison = compare(lhs.element, rhs.element, key: key)
            if comparison == 0 { return lhs.offset < rhs.offset }
            return ascending ? comparison < 0 : comparison > 0
        }
        return sorted.map(\.element)
    }

    /// -1 / 0 / 1, never consulted for `.size` -- `stableSort` special-cases that key's
    /// nil-last rule before reaching here.
    private static func compare(_ lhs: InstalledApp, _ rhs: InstalledApp, key: InstalledAppSortKey) -> Int {
        func cmp(_ a: String, _ b: String) -> Int { a == b ? 0 : (a < b ? -1 : 1) }
        switch key {
        case .name: return cmp(lhs.name.lowercased(), rhs.name.lowercased())
        case .version: return cmp(lhs.version ?? "", rhs.version ?? "")
        case .bundleID: return cmp(lhs.bundleIdentifier ?? "", rhs.bundleIdentifier ?? "")
        case .signing: return cmp(lhs.signingIdentity ?? "", rhs.signingIdentity ?? "")
        case .arch: return cmp(lhs.architectures.joined(), rhs.architectures.joined())
        case .size: return 0
        }
    }

    // MARK: - Projection (D-22: `Unparseable` in the Bundle ID column)

    /// Every column through `Format`. `app.bundleIdentifier` is never `nil` *and*
    /// `"Unparseable"` at once -- 2.3 sets it to the literal string `"Unparseable"` on a
    /// plist that failed to decode, so the `?? Format.unknown` fallback here only ever fires
    /// on a genuine `nil` and never collapses the word into an em dash.
    private static func project(app: InstalledApp) -> InstalledAppDetail {
        InstalledAppDetail(
            path: app.bundlePath, nameText: app.name,
            versionText: app.version ?? Format.unknown,
            bundleIDText: app.bundleIdentifier ?? Format.unknown,
            sizeText: app.allocatedBytes.map(Format.bytes) ?? Format.unknown,
            signingText: app.signingIdentity ?? Format.unknown,
            archText: app.architectures.isEmpty ? Format.unknown : app.architectures.joined(separator: ", ")
        )
    }
}
