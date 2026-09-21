import Foundation

/// SPEC.md §8.2–§8.4's shape, copied argument for argument from `ProcessesModel` (D-13):
/// filter → stable sort → format, over `ConnectionsSample` rather than `ProcessSample`. No
/// column here carries `ProcessesModel`'s CPU nil-last special case -- every field is
/// non-optional text, so `stableSort`'s tie-break is the only rule this file needs.
public enum ConnectionSortKey: String, Sendable, CaseIterable {
    case process, pid, proto, local, remote, state
}

/// One row of §8.7's table, already formatted -- the §7.1 boundary. `pid` is carried raw
/// alongside its text because 4.3's `Show Process` context action needs to branch on it.
public struct SocketRowDetail: Sendable, Equatable {
    public let key: String  // "\(pid):\(fd)" -- §8.7's selection identity
    public let pid: Int32
    public let processText: String
    public let pidText: String
    public let protoText: String
    public let localText: String
    public let remoteText: String
    public let stateText: String

    public init(
        key: String, pid: Int32, processText: String, pidText: String, protoText: String,
        localText: String, remoteText: String, stateText: String
    ) {
        self.key = key
        self.pid = pid
        self.processText = processText
        self.pidText = pidText
        self.protoText = protoText
        self.localText = localText
        self.remoteText = remoteText
        self.stateText = stateText
    }
}

/// SPEC.md §14.5's pane, as pure functions over `ConnectionsSample` -- §7.1's boundary.
public struct ConnectionsModel: Sendable, Equatable {
    public let rows: [SocketRowDetail]
    public let totalCount: Int  // sockets shown before search, after kind filtering
    public let shownCount: Int
    public let countText: String
    public let footerText: String
    public let emptyBodyText: String  // "" unless genuinely empty (CONN-04)

    public init(
        rows: [SocketRowDetail], totalCount: Int, shownCount: Int, countText: String,
        footerText: String, emptyBodyText: String
    ) {
        self.rows = rows
        self.totalCount = totalCount
        self.shownCount = shownCount
        self.countText = countText
        self.footerText = footerText
        self.emptyBodyText = emptyBodyText
    }

    /// Filter (D-13's four fields), then sort, then format. CONN-04's footer counts the PIDs
    /// that refused inspection rather than dropping them; the empty-body text is populated
    /// only when the *unfiltered* sample genuinely has zero sockets, never when a search
    /// query narrows a non-empty table down to nothing.
    public static func project(
        _ sample: ConnectionsSample, sort: ConnectionSortKey, ascending: Bool, search: String
    ) -> ConnectionsModel {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? sample.rows : sample.rows.filter { matches($0, query: query) }
        let sorted = stableSort(filtered, key: sort, ascending: ascending)
        let rows = sorted.map(project(row:))
        let processCount = Set(sample.rows.map(\.pid)).count

        return ConnectionsModel(
            rows: rows, totalCount: sample.rows.count, shownCount: rows.count,
            countText: "\(Format.count(sample.rows.count)) sockets · \(Format.count(processCount)) processes · \(Format.count(rows.count)) shown",
            footerText: "\(Format.count(sample.inspectedPIDCount)) of \(Format.count(sample.pidCount)) processes inspected · sockets of the other \(Format.count(sample.pidCount - sample.inspectedPIDCount)) are not listed",
            emptyBodyText: sample.rows.isEmpty
                ? "No open TCP or UDP sockets among the \(Format.count(sample.inspectedPIDCount)) processes this user can inspect"
                : ""
        )
    }

    /// §8.7's rule expressed as a function: keyed on `(pid, fd)`, never on row index.
    public static func selectionIndex(of key: String?, in rows: [SocketRowDetail]) -> Int? {
        guard let key else { return nil }
        return rows.firstIndex { $0.key == key }
    }

    // MARK: - Search (D-13)

    /// Case-insensitive substring against Process, PID, Local and Remote -- D-13's four fields.
    private static func matches(_ row: SocketRow, query: String) -> Bool {
        let needle = query.lowercased()
        if row.processName.lowercased().contains(needle) { return true }
        if String(row.pid).contains(needle) { return true }
        if row.localAddress.lowercased().contains(needle) { return true }
        if row.remoteAddress.lowercased().contains(needle) { return true }
        return false
    }

    // MARK: - Sort

    /// Decorated by original index and compared on that index for a tie, `ProcessesModel`'s
    /// own idiom -- Swift's `sorted(by:)` is not guaranteed stable.
    static func stableSort(_ rows: [SocketRow], key: ConnectionSortKey, ascending: Bool) -> [SocketRow] {
        let indexed = Array(rows.enumerated())
        let sorted = indexed.sorted { lhs, rhs in
            let comparison = compare(lhs.element, rhs.element, key: key)
            if comparison == 0 { return lhs.offset < rhs.offset }
            return ascending ? comparison < 0 : comparison > 0
        }
        return sorted.map(\.element)
    }

    private static func compare(_ lhs: SocketRow, _ rhs: SocketRow, key: ConnectionSortKey) -> Int {
        func cmp<T: Comparable>(_ a: T, _ b: T) -> Int { a == b ? 0 : (a < b ? -1 : 1) }
        switch key {
        case .process: return cmp(lhs.processName.lowercased(), rhs.processName.lowercased())
        case .pid: return cmp(lhs.pid, rhs.pid)
        case .proto: return cmp(protoText(lhs), protoText(rhs))
        case .local: return cmp(lhs.localAddress, rhs.localAddress)
        case .remote: return cmp(lhs.remoteAddress, rhs.remoteAddress)
        case .state: return cmp(lhs.tcpState ?? -1, rhs.tcpState ?? -1)
        }
    }

    // MARK: - Projection (D-06, the five address forms)

    private static func protoText(_ row: SocketRow) -> String {
        switch (row.transport, row.isIPv6) {
        case (.tcp, false): return "TCP"
        case (.tcp, true): return "TCP6"
        case (.udp, false): return "UDP"
        case (.udp, true): return "UDP6"
        }
    }

    /// The five locked address forms. A wildcard address (`0.0.0.0`/`::`, a listener bound to
    /// all interfaces) reads `*:{port}`; an all-zero address **and** port 0 -- the "no remote
    /// peer" case -- reads `—`. The two share an address value but never a port, so the
    /// branch order below keeps them from collapsing into the same string (D-05).
    private static func addressText(_ address: String, port: Int, isIPv6: Bool, scope: String) -> String {
        let isWildcard = address == "0.0.0.0" || address == "::"
        let isUnset = address.isEmpty || (address == "0.0.0.0" && port == 0) || (address == "::" && port == 0)
        if isUnset && port == 0 && isWildcard { return Format.unknown }  // unconnected remote
        if isWildcard { return "*:\(port)" }
        if isIPv6 {
            let scoped = scope.isEmpty ? address : "\(address)%\(scope)"
            return "[\(scoped)]:\(port)"
        }
        return "\(address):\(port)"
    }

    private static func project(row: SocketRow) -> SocketRowDetail {
        SocketRowDetail(
            key: "\(row.pid):\(row.fd)", pid: row.pid, processText: row.processName,
            pidText: String(row.pid), protoText: protoText(row),
            localText: addressText(row.localAddress, port: row.localPort, isIPv6: row.isIPv6, scope: row.scopeInterface),
            remoteText: addressText(row.remoteAddress, port: row.remotePort, isIPv6: row.isIPv6, scope: ""),
            stateText: row.tcpState.map(ConnectionsProvider.tcpStateName) ?? Format.unknown
        )
    }
}
