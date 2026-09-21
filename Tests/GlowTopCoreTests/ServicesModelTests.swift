import XCTest
@testable import GlowTopCore

/// §12.1's correlation and §12.2's three status states, from fixture jobs and a fixture
/// `ProcessRow` -- no real `launchctl`, no real process table.
final class ServicesModelTests: XCTestCase {
    private func job(
        label: String = "com.example.job", type: String = "Launch Agent",
        program: String = "/usr/bin/example", runAtLoad: Bool? = false
    ) -> LaunchdJob {
        LaunchdJob(
            label: label, type: type, program: program, runAtLoad: runAtLoad,
            keepAlive: nil, path: "/Users/test/Library/LaunchAgents/\(label).plist",
            enabled: true, programArguments: [program]
        )
    }

    private func process(pid: Int32 = 100, path: String) -> ProcessRow {
        ProcessRow(pid: pid, name: "example", cpuPercent: 1.5, residentBytes: 1024, threadCount: 1, path: path)
    }

    func testRunningRequiresAPathMatchNotABasenameMatch() {
        let jobs = [job(program: "/usr/bin/python3")]
        // Same basename, different full path -- must not be treated as a match.
        let processes = [process(path: "/opt/homebrew/bin/python3")]
        let rows = ServicesModel.correlate(jobs: jobs, processes: processes)
        XCTAssertEqual(rows[0].status, .configured)

        let exactMatch = [process(path: "/usr/bin/python3")]
        let matchedRows = ServicesModel.correlate(jobs: jobs, processes: exactMatch)
        XCTAssertEqual(matchedRows[0].status, .running)
        XCTAssertEqual(matchedRows[0].pid, 100)
    }

    func testJobWithNoMatchIsConfiguredNotStopped() {
        let row = ServicesModel.statusFor(
            job: job(type: "Launch Agent", runAtLoad: false), matched: nil
        )
        XCTAssertEqual(row, .configured)
    }

    func testUninspectablePidYieldsUnknown() {
        // A Launch Daemon (root-owned, ~40% of PIDs -- disproportionately root's -- refuse
        // inspection per §5.5.1) with no matched process is genuinely undetermined, not
        // confidently stopped.
        let daemonStatus = ServicesModel.statusFor(job: job(type: "Launch Daemon"), matched: nil)
        XCTAssertEqual(daemonStatus, .unknown)

        // A RunAtLoad job with no match may simply have already run and exited.
        let runAtLoadStatus = ServicesModel.statusFor(
            job: job(type: "Launch Agent", runAtLoad: true), matched: nil
        )
        XCTAssertEqual(runAtLoadStatus, .unknown)
    }

    /// Found live on this machine: three cron-style agents all invoked as `/bin/bash
    /// <script>`, so `program` (the first `ProgramArguments` element) is the identical bare
    /// string `/bin/bash` for all three. One running `/bin/bash` process must not be claimed
    /// as "Running" by every job that happens to share that interpreter path.
    func testAmbiguousSharedProgramDoesNotClaimRunning() {
        let jobs = [
            job(label: "a", program: "/bin/bash"),
            job(label: "b", program: "/bin/bash"),
        ]
        let processes = [process(pid: 999, path: "/bin/bash")]
        let rows = ServicesModel.correlate(jobs: jobs, processes: processes)
        XCTAssertTrue(rows.allSatisfy { $0.status != .running })
        XCTAssertTrue(rows.allSatisfy { $0.pid == nil })
    }

    /// §12.1's fix (4.1): a job's `Program` is a Homebrew `opt/` symlink; the live process's
    /// path (from `proc_pidpath`, already resolved) is the real `Cellar/` file. The job side
    /// must resolve through the symlink to match.
    func testResolvesSymlinkedProgramToTheRealPath() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realBinary = tmp.appendingPathComponent("real/bin/tool")
        try FileManager.default.createDirectory(
            at: realBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: realBinary.path, contents: Data())
        let symlink = tmp.appendingPathComponent("opt/tool")
        try FileManager.default.createDirectory(
            at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: realBinary)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let jobs = [job(program: symlink.path)]
        let processes = [process(pid: 555, path: realBinary.path)]
        let rows = ServicesModel.correlate(jobs: jobs, processes: processes)
        XCTAssertEqual(rows[0].status, .running)
        XCTAssertEqual(rows[0].pid, 555)
    }

    /// The uniqueness guard moved onto resolved paths with the fix: two jobs whose different
    /// symlinks resolve to the same binary stay exactly as ambiguous as two jobs sharing one
    /// raw interpreter path (`testAmbiguousSharedProgramDoesNotClaimRunning`, above).
    func testTwoJobsResolvingToOneBinaryStayAmbiguous() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realBinary = tmp.appendingPathComponent("real/bin/tool")
        try FileManager.default.createDirectory(
            at: realBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: realBinary.path, contents: Data())
        let optDir = tmp.appendingPathComponent("opt")
        try FileManager.default.createDirectory(at: optDir, withIntermediateDirectories: true)
        let symlinkA = optDir.appendingPathComponent("tool-a")
        let symlinkB = optDir.appendingPathComponent("tool-b")
        try FileManager.default.createSymbolicLink(at: symlinkA, withDestinationURL: realBinary)
        try FileManager.default.createSymbolicLink(at: symlinkB, withDestinationURL: realBinary)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let jobs = [
            job(label: "a", program: symlinkA.path),
            job(label: "b", program: symlinkB.path),
        ]
        let processes = [process(pid: 777, path: realBinary.path)]
        let rows = ServicesModel.correlate(jobs: jobs, processes: processes)
        XCTAssertTrue(rows.allSatisfy { $0.status != .running })
        XCTAssertTrue(rows.allSatisfy { $0.pid == nil })
    }

    /// A `Program` pointing at a path that no longer exists resolves to itself --
    /// `resolvingSymlinksInPath()` leaves an unresolvable path unchanged -- so it is a
    /// `Configured`/`Unknown` job, not a correlation error.
    func testUnresolvableProgramStillCorrelatesOnItsLiteralPath() {
        let jobs = [job(program: "/no/such/tool")]
        let processes = [process(pid: 42, path: "/no/such/tool")]
        let rows = ServicesModel.correlate(jobs: jobs, processes: processes)
        XCTAssertEqual(rows[0].status, .running)
        XCTAssertEqual(rows[0].pid, 42)
    }

    func testSortIsStatusThenLabel() {
        let jobs = [
            job(label: "z-configured", program: "/no/match/z"),
            job(label: "a-running", program: "/usr/bin/a"),
            job(label: "b-running", program: "/usr/bin/b"),
            job(label: "a-configured", program: "/no/match/a"),
        ]
        let processes = [process(pid: 1, path: "/usr/bin/a"), process(pid: 2, path: "/usr/bin/b")]
        let rows = ServicesModel.correlate(jobs: jobs, processes: processes)
        XCTAssertEqual(rows.map(\.label), ["a-running", "b-running", "a-configured", "z-configured"])
    }
}
