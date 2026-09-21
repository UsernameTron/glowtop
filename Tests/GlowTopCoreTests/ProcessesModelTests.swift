import XCTest
@testable import GlowTopCore

/// SPEC.md §8.3's stable sort, §8.4's search and §8.7's PID-keyed selection -- all pure, so
/// every test here runs against a fixture `ProcessSample`, never a live process table.
final class ProcessesModelTests: XCTestCase {
    private func row(
        pid: Int32, name: String = "proc", cpu: Double? = 0, memory: UInt64 = 0,
        threads: Int = 1, path: String? = nil
    ) -> ProcessRow {
        ProcessRow(pid: pid, name: name, cpuPercent: cpu, residentBytes: memory, threadCount: threads, path: path)
    }

    // MARK: - §8.3 stability

    /// This is the test that fails on a bare `sort(by:)`: 100 rows all at CPU 0.0 in a known
    /// order must come back in that same order, and must still be in that order the second
    /// time -- §8.3's own reason, "stops the large block of 0.0 % processes from reshuffling
    /// every second."
    func testSortIsStableAcrossEqualValues() {
        let rows = (0..<100).map { row(pid: Int32($0), cpu: 0) }
        let sample = ProcessSample(rows: rows, totalCount: rows.count, inspectableCount: rows.count, enumerationMilliseconds: 1)

        let first = ProcessesModel.stableSort(sample.rows, key: .cpu, ascending: false)
        XCTAssertEqual(first.map(\.pid), rows.map(\.pid))

        let second = ProcessesModel.stableSort(first, key: .cpu, ascending: false)
        XCTAssertEqual(second.map(\.pid), first.map(\.pid))
    }

    // MARK: - §8.4 search

    func testSearchMatchesNamePathAndPidSubstring() {
        let rows = [
            row(pid: 1138, name: "helper", path: "/usr/bin/helper"),
            row(pid: 42, name: "chrome", path: "/Applications/Chrome 1138.app/chrome"),
            row(pid: 7, name: "unrelated", path: "/bin/sh"),
        ]
        let sample = ProcessSample(rows: rows, totalCount: rows.count, inspectableCount: rows.count, enumerationMilliseconds: 1)

        let byPid = ProcessesModel.project(sample, sort: .pid, ascending: true, search: "1138")
        XCTAssertEqual(Set(byPid.rows.map(\.pid)), [1138, 42], "matches the PID exactly and any path containing it")

        let byName = ProcessesModel.project(sample, sort: .pid, ascending: true, search: "chrome")
        XCTAssertEqual(byName.rows.map(\.pid), [42])

        let byPath = ProcessesModel.project(sample, sort: .pid, ascending: true, search: "/bin/sh")
        XCTAssertEqual(byPath.rows.map(\.pid), [7])
    }

    // MARK: - CPU's nil-last rule

    func testNilCpuSortsLastInBothDirections() {
        let rows = [row(pid: 1, cpu: 5), row(pid: 2, cpu: nil), row(pid: 3, cpu: 10)]

        let ascending = ProcessesModel.stableSort(rows, key: .cpu, ascending: true)
        XCTAssertEqual(ascending.last?.pid, 2, "unknown CPU is last ascending too")

        let descending = ProcessesModel.stableSort(rows, key: .cpu, ascending: false)
        XCTAssertEqual(descending.last?.pid, 2, "unknown CPU is last descending")
        XCTAssertEqual(descending.first?.pid, 3, "the known values still sort by value")
    }

    // MARK: - §8.7 selection identity

    func testSelectionSurvivesAResort() {
        let rows = [row(pid: 1, name: "b", cpu: 2), row(pid: 2, name: "a", cpu: 1)]
        let sample = ProcessSample(rows: rows, totalCount: rows.count, inspectableCount: rows.count, enumerationMilliseconds: 1)

        let byCPU = ProcessesModel.project(sample, sort: .cpu, ascending: false, search: "")
        let indexByCPU = ProcessesModel.selectionIndex(of: 1, in: byCPU.rows)

        let byName = ProcessesModel.project(sample, sort: .name, ascending: true, search: "")
        let indexByName = ProcessesModel.selectionIndex(of: 1, in: byName.rows)

        XCTAssertNotEqual(indexByCPU, indexByName, "the sort actually reordered the rows")
        XCTAssertEqual(byCPU.rows[indexByCPU!].pid, 1)
        XCTAssertEqual(byName.rows[indexByName!].pid, 1)
    }

    func testSelectionIndexIsNilWhenThePidIsGone() {
        let rows = [row(pid: 1), row(pid: 2)]
        XCTAssertNil(ProcessesModel.selectionIndex(of: 999, in: rows.map(Self.detail)))
        XCTAssertNil(ProcessesModel.selectionIndex(of: nil, in: rows.map(Self.detail)))
    }

    private static func detail(_ row: ProcessRow) -> ProcessRowDetail {
        ProcessesModel.project(
            ProcessSample(rows: [row], totalCount: 1, inspectableCount: 1, enumerationMilliseconds: 1),
            sort: .pid, ascending: true, search: ""
        ).rows[0]
    }

    // MARK: - §8.1's count text

    func testCountTextMatchesSpecFormat() {
        let rows = (0..<24).map { row(pid: Int32($0)) }
        let sample = ProcessSample(rows: rows, totalCount: 1138, inspectableCount: rows.count, enumerationMilliseconds: 1)
        let model = ProcessesModel.project(sample, sort: .pid, ascending: true, search: "")
        XCTAssertEqual(model.countText, "1138 processes · 24 shown")
    }

    // MARK: - Projection formats every column, never a raw number

    func testProjectionFormatsEveryColumn() {
        // Built directly rather than through this file's `row(...)` helper, which has no way
        // to set uid/user/energyImpact/startedAt.
        let populatedRow = ProcessRow(
            pid: 99, name: "jappleseed-proc", cpuPercent: 42.567, residentBytes: 1024 * 1024 * 1024,
            threadCount: 4, gpuPercent: nil, uid: 501, user: "jappleseed", path: "/bin/x",
            energyImpact: 12.3, parentPID: 1, startedAt: Date()
        )
        let sample = ProcessSample(rows: [populatedRow], totalCount: 1, inspectableCount: 1, enumerationMilliseconds: 1)
        let detail = ProcessesModel.project(sample, sort: .pid, ascending: true, search: "").rows[0]

        XCTAssertEqual(detail.pidText, "99")
        XCTAssertEqual(detail.cpuText, "42.6%")
        XCTAssertEqual(detail.memoryText, "1 GB")
        XCTAssertEqual(detail.threadsText, "4")
        XCTAssertEqual(detail.userText, "jappleseed")
        XCTAssertEqual(detail.energyText, "12.3%")
        XCTAssertEqual(detail.pathText, "/bin/x")

        let missing = ProcessRow(pid: 100, name: "ghost", cpuPercent: nil, residentBytes: 0, threadCount: 0)
        let missingSample = ProcessSample(rows: [missing], totalCount: 1, inspectableCount: 1, enumerationMilliseconds: 1)
        let missingDetail = ProcessesModel.project(missingSample, sort: .pid, ascending: true, search: "").rows[0]
        XCTAssertEqual(missingDetail.cpuText, Format.unknown)
        XCTAssertEqual(missingDetail.userText, Format.unknown)
        XCTAssertEqual(missingDetail.energyText, Format.unknown)
        XCTAssertEqual(missingDetail.pathText, Format.unknown)
    }

    // MARK: - §8.6's inspector

    /// A row with every optional field `nil`, and a PID (`-1`) no syscall in `inspector(for:in:)`
    /// can succeed against, must produce an em dash for every field it cannot resolve and must
    /// not crash.
    func testInspectorFormatsEveryFieldOrEmDash() {
        let ghost = ProcessRow(pid: -1, name: "ghost", cpuPercent: nil, residentBytes: 0, threadCount: 0)
        let sample = ProcessSample(rows: [ghost], totalCount: 1, inspectableCount: 1, enumerationMilliseconds: 1)
        let inspector = ProcessesModel.inspector(for: ghost, in: sample)

        for text in [
            inspector.pathText, inspector.argumentsText, inspector.parentText, inspector.startText,
            inspector.elapsedText, inspector.uidText, inspector.userText, inspector.memoryText,
            inspector.cpuTimeText, inspector.diskText, inspector.architectureText,
        ] {
            XCTAssertEqual(text, Format.unknown, text)
        }
        // `threadCount` is not optional on `ProcessRow` -- it defaults to a real `0`, not a
        // missing value -- so this is the one field that is never an em dash.
        XCTAssertEqual(inspector.threadsText, "0")
    }

    /// A fully-populated row, resolved against this test process's own PID so every syscall
    /// `inspector(for:in:)` makes actually succeeds, must produce a non-empty, non-`—` string
    /// for every field 2.1's identity cache or a live syscall can answer.
    func testInspectorFormatsEveryColumnWhenFullyPopulated() {
        let me = ProcessRow(
            pid: getpid(), name: "self", cpuPercent: 1, residentBytes: 1024, threadCount: 4,
            gpuPercent: nil, uid: getuid(), user: "jappleseed", path: "/bin/self",
            energyImpact: nil, parentPID: 1, startedAt: Date(timeIntervalSinceNow: -60)
        )
        let parent = ProcessRow(pid: 1, name: "launchd", cpuPercent: nil, residentBytes: 0, threadCount: 1)
        let sample = ProcessSample(rows: [me, parent], totalCount: 2, inspectableCount: 2, enumerationMilliseconds: 1)
        let inspector = ProcessesModel.inspector(for: me, in: sample)

        XCTAssertEqual(inspector.pathText, "/bin/self")
        XCTAssertEqual(inspector.parentText, "1 (launchd)", "the parent's name comes from a second lookup in the same snapshot")
        XCTAssertEqual(inspector.uidText, String(getuid()))
        XCTAssertEqual(inspector.userText, "jappleseed")
        XCTAssertEqual(inspector.threadsText, "4")
        XCTAssertNotEqual(inspector.memoryText, Format.unknown, "proc_taskinfo must succeed against this test's own PID")
        XCTAssertNotEqual(inspector.cpuTimeText, Format.unknown)
        XCTAssertNotEqual(inspector.architectureText, Format.unknown)
    }

    /// A parent PID absent from the snapshot (§5.5.1: roughly 40 % of PIDs refuse inspection,
    /// and a parent can be one of them) must render as just the PID, not a crash or a blank.
    func testInspectorParentTextFallsBackWhenParentIsNotInTheSnapshot() {
        let orphan = ProcessRow(
            pid: getpid(), name: "self", cpuPercent: nil, residentBytes: 0, threadCount: 1,
            parentPID: 424242
        )
        let sample = ProcessSample(rows: [orphan], totalCount: 1, inspectableCount: 1, enumerationMilliseconds: 1)
        let inspector = ProcessesModel.inspector(for: orphan, in: sample)
        XCTAssertEqual(inspector.parentText, "424242")
    }
}
