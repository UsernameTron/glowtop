import Darwin
import Foundation

/// SPEC.md §8.2's eight sortable columns. §8.3 says "click a header" and §8.2 has eight
/// columns, so every one of them sorts, not just PROC-02's four named columns.
public enum ProcessSortKey: String, Sendable, CaseIterable {
    case pid, name, cpu, memory, threads, user, energy, path
}

/// One row of §8's table, already formatted -- the §7.1 boundary. `pid`, `uid` and `path` are
/// carried raw alongside their formatted text because 2.3's icon cache and 2.4's kill sheet
/// need to *branch* on them (a file path to resolve an icon for, a uid to test against zero),
/// which is not formatting and stays their job; the table itself draws only the `*Text` strings.
public struct ProcessRowDetail: Sendable, Equatable {
    public let pid: Int32
    public let uid: uid_t?
    public let path: String?

    public let pidText: String
    public let name: String
    public let cpuText: String
    public let memoryText: String
    public let threadsText: String
    public let userText: String
    public let energyText: String
    public let pathText: String

    public init(
        pid: Int32, uid: uid_t?, path: String?, pidText: String, name: String, cpuText: String,
        memoryText: String, threadsText: String, userText: String, energyText: String, pathText: String
    ) {
        self.pid = pid
        self.uid = uid
        self.path = path
        self.pidText = pidText
        self.name = name
        self.cpuText = cpuText
        self.memoryText = memoryText
        self.threadsText = threadsText
        self.userText = userText
        self.energyText = energyText
        self.pathText = pathText
    }
}

/// SPEC.md §8's Processes pane, as pure functions over `ProcessSample` -- §7.1's boundary:
/// Core decides what a number is, the view decides where it is drawn. `ProcessesPaneController`
/// (2.3) calls `project(_:sort:ascending:search:)` once per 1 Hz refresh and renders the result;
/// nothing in the view formats a string or re-derives an ordering.
public struct ProcessesModel: Sendable, Equatable {
    public let rows: [ProcessRowDetail]
    public let totalCount: Int
    public let shownCount: Int
    /// §8.1's toolbar count, e.g. `1138 processes · 24 shown`.
    public let countText: String

    public init(rows: [ProcessRowDetail], totalCount: Int, shownCount: Int, countText: String) {
        self.rows = rows
        self.totalCount = totalCount
        self.shownCount = shownCount
        self.countText = countText
    }

    /// Filter (§8.4), then sort (§8.3), then format -- in that order. §8.4 filters against the
    /// **full** snapshot on every refresh; filtering the already-projected (and Path-truncated)
    /// rows instead would search a display string rather than the data, and a query matching
    /// the elided middle of a long path would silently match nothing.
    public static func project(
        _ sample: ProcessSample, sort: ProcessSortKey, ascending: Bool, search: String
    ) -> ProcessesModel {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? sample.rows : sample.rows.filter { matches($0, query: query) }
        let sorted = stableSort(filtered, key: sort, ascending: ascending)
        let rows = sorted.map(project(row:))

        return ProcessesModel(
            rows: rows,
            totalCount: sample.totalCount,
            shownCount: rows.count,
            countText: "\(Format.count(sample.totalCount)) processes · \(Format.count(rows.count)) shown"
        )
    }

    /// §8.7's rule expressed as a function so the table cannot express selection any other
    /// way: keyed on PID, never on row index, which is wrong the instant a re-sort moves the
    /// selected row.
    public static func selectionIndex(of pid: Int32?, in rows: [ProcessRowDetail]) -> Int? {
        guard let pid else { return nil }
        return rows.firstIndex { $0.pid == pid }
    }

    // MARK: - Search (§8.4)

    /// Case-insensitive substring against Name, Path and PID -- §8.4's own three fields.
    /// Matching the PID as the substring of its decimal text is what makes `"1138"` match the
    /// PID exactly *and* any path containing `1138`, in the same pass.
    private static func matches(_ row: ProcessRow, query: String) -> Bool {
        let needle = query.lowercased()
        if row.name.lowercased().contains(needle) { return true }
        if let path = row.path, path.lowercased().contains(needle) { return true }
        if String(row.pid).contains(needle) { return true }
        return false
    }

    // MARK: - Sort (§8.3)

    /// Decorated by original index and compared on that index for a tie -- Swift's
    /// `sorted(by:)` is not guaranteed stable, and §8.3 asks for stability by name: "stops the
    /// large block of 0.0 % processes from reshuffling every second."
    static func stableSort(_ rows: [ProcessRow], key: ProcessSortKey, ascending: Bool) -> [ProcessRow] {
        let indexed = Array(rows.enumerated())
        let sorted = indexed.sorted { lhs, rhs in
            if key == .cpu {
                // Unknown CPU sorts last **regardless of direction**: a process with no
                // baseline yet is not the busiest, and it is not the least busy either --
                // it is unknown, and unknown belongs at the end either way.
                switch (lhs.element.cpuPercent, rhs.element.cpuPercent) {
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

    /// -1 / 0 / 1, never consulted for `.cpu` -- `stableSort` special-cases that key's
    /// nil-last rule before reaching here.
    private static func compare(_ lhs: ProcessRow, _ rhs: ProcessRow, key: ProcessSortKey) -> Int {
        switch key {
        case .pid: return compareValues(lhs.pid, rhs.pid)
        case .name: return compareValues(lhs.name.lowercased(), rhs.name.lowercased())
        case .memory: return compareValues(lhs.residentBytes, rhs.residentBytes)
        case .threads: return compareValues(lhs.threadCount, rhs.threadCount)
        case .user: return compareOptionals(lhs.user, rhs.user)
        case .energy: return compareOptionals(lhs.energyImpact, rhs.energyImpact)
        case .path: return compareOptionals(lhs.path, rhs.path)
        case .cpu: return 0
        }
    }

    private static func compareValues<T: Comparable>(_ lhs: T, _ rhs: T) -> Int {
        if lhs == rhs { return 0 }
        return lhs < rhs ? -1 : 1
    }

    /// `nil` sorts before any real value -- there is no §8.3 ruling for these columns the way
    /// there is for CPU, so this is the ordinary "unknown is the smallest thing" convention
    /// rather than a direction-independent rule.
    private static func compareOptionals<T: Comparable>(_ lhs: T?, _ rhs: T?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        case let (l?, r?): return compareValues(l, r)
        }
    }

    // MARK: - Projection (§8.2)

    /// Every column pre-formatted to its final string, so `ProcessesPaneController` draws
    /// strings and computes nothing.
    private static func project(row: ProcessRow) -> ProcessRowDetail {
        ProcessRowDetail(
            pid: row.pid,
            uid: row.uid,
            path: row.path,
            pidText: String(row.pid),
            name: row.name,
            cpuText: row.cpuPercent.map { Format.percent(points: $0) } ?? Format.unknown,
            memoryText: Format.bytes(row.residentBytes),
            threadsText: String(row.threadCount),
            userText: row.user ?? Format.unknown,
            energyText: row.energyImpact.map { Format.percent(points: $0) } ?? Format.unknown,
            pathText: row.path ?? Format.unknown
        )
    }
}

/// SPEC.md §8.6's read-only inspector, already formatted -- twelve values, all pre-formatted
/// so `ProcessInspectorSheet` (2.5) draws strings and computes nothing, the same §7.1 rule
/// `ProcessRowDetail` follows.
public struct ProcessInspectorModel: Sendable, Equatable {
    public let pathText: String
    public let argumentsText: String
    public let parentText: String
    public let startText: String
    public let elapsedText: String
    public let uidText: String
    public let userText: String
    public let threadsText: String
    public let memoryText: String
    public let cpuTimeText: String
    public let diskText: String
    public let architectureText: String

    public init(
        pathText: String, argumentsText: String, parentText: String, startText: String,
        elapsedText: String, uidText: String, userText: String, threadsText: String,
        memoryText: String, cpuTimeText: String, diskText: String, architectureText: String
    ) {
        self.pathText = pathText
        self.argumentsText = argumentsText
        self.parentText = parentText
        self.startText = startText
        self.elapsedText = elapsedText
        self.uidText = uidText
        self.userText = userText
        self.threadsText = threadsText
        self.memoryText = memoryText
        self.cpuTimeText = cpuTimeText
        self.diskText = diskText
        self.architectureText = architectureText
    }
}

extension ProcessesModel {
    /// §8.6: one-shot reads at sheet-open time, never a live poll -- a 1 Hz refresh under a
    /// modal nobody can interact with is cost with no reader (item 4). Five of the twelve
    /// values are already resolved in 2.1's identity cache and carried on `row`; the rest
    /// cost one `proc_pidinfo(PROC_PIDTASKINFO)`, one `proc_pid_rusage`, one
    /// `sysctl(KERN_PROCARGS2)` and one architecture check, paid exactly once, here.
    public static func inspector(for row: ProcessRow, in sample: ProcessSample) -> ProcessInspectorModel {
        let parentText: String
        if let parentPID = row.parentPID {
            // The parent's *name* is a second lookup into this same snapshot's rows -- `—`
            // when the parent is not in it, which happens whenever the parent is one of the
            // ~40 % that refuse inspection (§5.5.1).
            let parentName = sample.rows.first { $0.pid == parentPID }?.name
            parentText = parentName.map { "\(parentPID) (\($0))" } ?? String(parentPID)
        } else {
            parentText = Format.unknown
        }

        let startText = row.startedAt.map(Self.absoluteDate) ?? Format.unknown
        let elapsedText = row.startedAt
            .map { Format.duration(seconds: Date().timeIntervalSince($0)) } ?? Format.unknown

        let taskInfo = Self.readTaskInfo(pid: row.pid)
        let memoryText = taskInfo.map {
            "\(Format.bytes(row.residentBytes)) resident · \(Format.bytes($0.pti_virtual_size)) virtual"
        } ?? Format.unknown
        let cpuTimeText = taskInfo.map {
            "\(Format.duration(seconds: Self.seconds($0.pti_total_user))) user · "
                + "\(Format.duration(seconds: Self.seconds($0.pti_total_system))) system"
        } ?? Format.unknown

        let disk = Self.readDiskIO(pid: row.pid)
        let diskText = disk.map { "\(Format.bytes($0.read)) read · \(Format.bytes($0.written)) written" }
            ?? Format.unknown

        return ProcessInspectorModel(
            pathText: row.path ?? Format.unknown,
            // §8.6: "fails for processes owned by other users; those show `—` rather than an
            // error" -- the failure path is written first, in `readArguments` itself.
            argumentsText: Self.readArguments(pid: row.pid) ?? Format.unknown,
            parentText: parentText,
            startText: startText,
            elapsedText: elapsedText,
            uidText: row.uid.map(String.init) ?? Format.unknown,
            userText: row.user ?? Format.unknown,
            threadsText: String(row.threadCount),
            memoryText: memoryText,
            cpuTimeText: cpuTimeText,
            diskText: diskText,
            architectureText: Self.architecture(pid: row.pid)
        )
    }

    private static func absoluteDate(_ date: Date) -> String {
        // A fresh formatter per call, not a cached static one: `DateFormatter` is not
        // `Sendable`, and this runs once per inspector open -- nowhere near often enough for
        // the allocation to matter (`ProcessActions.logLine`'s same reasoning for its own
        // per-call `ISO8601DateFormatter`).
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func seconds(_ machTicks: UInt64) -> Double {
        Double(ProcessProvider.machToNanoseconds(machTicks)) / 1_000_000_000
    }

    private static func readTaskInfo(pid: Int32) -> proc_taskinfo? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func readDiskIO(pid: Int32) -> (read: UInt64, written: UInt64)? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V6, rebound)
            }
        }
        guard result == 0 else { return nil }
        return (info.ri_diskio_bytesread, info.ri_diskio_byteswritten)
    }

    /// `PROC_FLAG_LP64` only -- `NSRunningApplication.executableArchitecture` would need
    /// AppKit, and `GlowTopCore` stays free of it (§7.1, gate 13). Every process on Apple
    /// Silicon macOS is effectively this bit's true branch; the false branch is kept because
    /// the bit is real and untested is not the same as impossible.
    private static func architecture(pid: Int32) -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return Format.unknown }
        return (info.pbi_flags & UInt32(PROC_FLAG_LP64)) != 0 ? "arm64" : "arm64 (32-bit)"
    }

    /// `KERN_PROCARGS2`'s buffer: `argc`, then the executable path (NUL-terminated), then a
    /// NUL-padded alignment gap, then exactly `argc` NUL-terminated argument strings, then
    /// the process's **environment**. Reading `argc` first and stopping after exactly that
    /// many strings is what keeps this from ever handing back a process's environment
    /// variables -- a naive split-on-NUL of the whole blob would, and a developer machine's
    /// environment routinely holds API tokens (§9.2 already refuses to one-click-copy the
    /// serial number for the same reason).
    private static func readArguments(pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size >= MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0 else { return nil }

        var offset = MemoryLayout<Int32>.size
        while offset < size, buffer[offset] != 0 { offset += 1 }
        while offset < size, buffer[offset] == 0 { offset += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argc))
        while arguments.count < argc, offset < size {
            let start = offset
            while offset < size, buffer[offset] != 0 { offset += 1 }
            arguments.append(String(decoding: buffer[start..<offset], as: UTF8.self))
            offset += 1
        }
        guard arguments.count == Int(argc) else { return nil }
        return arguments.joined(separator: " ")
    }
}
