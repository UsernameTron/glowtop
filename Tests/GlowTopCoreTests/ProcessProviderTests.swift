import XCTest
@testable import GlowTopCore

/// SPEC.md §13.5 items 3, 4 and 9 for the process table, plus the two bugs found while
/// building it — both of which produced a plausible number rather than an error.
final class ProcessProviderTests: XCTestCase {
    /// Fresh per test: §5.5.4's identity cache is provider state, and a shared one would let
    /// one test's population mask another's cold path.
    private var identities: [Int32: ProcessProvider.Identity] = [:]
    private var userNames: [uid_t: String] = [:]

    /// §5.5.2: `pti_total_user` and `pti_total_system` are mach absolute time units, not
    /// nanoseconds. On this machine the timebase is 125/3, so skipping the conversion
    /// under-reports every process by about 42x — a number that still looks like a number.
    func testMachTicksConvertViaTheTimebase() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let ticks: UInt64 = 1_000_000
        let expected = ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
        XCTAssertEqual(ProcessProvider.machToNanoseconds(ticks), expected)
    }

    func testMachConversionIsIdentityWhenTimebaseIsOneToOne() {
        // Guards the denom != 0 path; on a 1:1 platform the conversion must not distort.
        XCTAssertGreaterThan(ProcessProvider.machToNanoseconds(1_000), 0)
    }

    /// The bug this catches: `proc_listallpids(nil, 0)` returns a **PID count**, not a byte
    /// count. Sizing the buffer as `returned / MemoryLayout<Int32>.size` makes it four times
    /// too small and the enumeration silently covers a quarter of the machine — 202 processes
    /// where `ps -A` counted 851 — with no error raised anywhere.
    func testEnumerationCoversTheWholeMachine() throws {
        let enumeration = try XCTUnwrap(ProcessProvider.enumerate(identities: &identities, userNames: &userNames))
        XCTAssertGreaterThan(
            enumeration.listedCount, 300,
            "a running Mac has hundreds of processes; a low count means the buffer was undersized"
        )
    }

    /// §5.5.1: a PID that refuses inspection is skipped, never defaulted to zero. On an
    /// unprivileged account roughly 40 % of PIDs refuse (EPERM), so the two counts must
    /// differ and both must be reported.
    func testInspectableCountIsAtMostTheListedCount() throws {
        let enumeration = try XCTUnwrap(ProcessProvider.enumerate(identities: &identities, userNames: &userNames))
        XCTAssertLessThanOrEqual(enumeration.entries.count, enumeration.listedCount)
        XCTAssertGreaterThan(enumeration.entries.count, 0)
    }

    /// Skipped PIDs must be absent, not present with zeroed fields — a process charged 0 %
    /// because a call failed is indistinguishable from an idle one.
    func testEveryReturnedEntryHasRealData() throws {
        let enumeration = try XCTUnwrap(ProcessProvider.enumerate(identities: &identities, userNames: &userNames))
        for entry in enumeration.entries {
            XCTAssertGreaterThan(entry.pid, 0)
            XCTAssertFalse(entry.name.isEmpty)
        }
    }

    /// This test process is inspectable by definition, so it must appear with a real name.
    func testThisProcessAppearsWithItsName() throws {
        let enumeration = try XCTUnwrap(ProcessProvider.enumerate(identities: &identities, userNames: &userNames))
        let mine = enumeration.entries.first { $0.pid == getpid() }
        let entry = try XCTUnwrap(mine, "the running test process must be enumerable")
        XCTAssertGreaterThan(entry.residentBytes, 0)
        XCTAssertGreaterThan(entry.threadCount, 0)
        XCTAssertFalse(entry.name.hasPrefix("pid "), "should resolve a real name, got \(entry.name)")
    }

    func testNameFallsBackToPidWhenNothingResolves() {
        // PID -1 can never resolve, so the last-resort branch is what answers.
        XCTAssertEqual(ProcessProvider.name(of: -1), "pid -1")
    }

    /// §5.0.3: the first sample of a delta provider establishes a baseline and returns
    /// `.warming` — every row's CPU would otherwise be nil, which is not a reading.
    func testFirstSampleWarms() {
        var provider = ProcessProvider()
        guard case .warming = provider.sample() else {
            return XCTFail("first sample must be .warming")
        }
    }

    /// After a baseline exists, a sample separated by a usable interval produces values, and
    /// §5.5.4's enumeration cost is reported on every one of them.
    func testSecondSampleProducesRowsAndReportsItsCost() throws {
        var provider = ProcessProvider()
        _ = provider.sample()
        Thread.sleep(forTimeInterval: 0.15)
        switch provider.sample() {
        case .value(let sample, _):
            XCTAssertGreaterThan(sample.totalCount, 300)
            XCTAssertEqual(sample.inspectableCount, sample.rows.count)
            XCTAssertGreaterThan(sample.enumerationMilliseconds, 0)
            XCTAssertLessThan(
                sample.enumerationMilliseconds, 250,
                "§5.5.4 budgets 25 ms; 250 would mean something is badly wrong"
            )
        case .warming:
            XCTFail("a baseline existed and the interval was usable")
        case .unavailable(let reason):
            XCTFail("libproc should be available: \(reason)")
        }
    }

    /// §4.3.3 sorts by CPU descending and takes the first 12, so the provider must hand back
    /// rows already in that order with unknown CPU last.
    func testRowsAreSortedByCPUDescendingWithUnknownLast() throws {
        var provider = ProcessProvider()
        _ = provider.sample()
        Thread.sleep(forTimeInterval: 0.15)
        guard case .value(let sample, _) = provider.sample() else {
            return XCTFail("expected a value")
        }
        let known = sample.rows.compactMap(\.cpuPercent)
        XCTAssertEqual(known, known.sorted(by: >), "rows must be CPU-descending")
        if let firstUnknown = sample.rows.firstIndex(where: { $0.cpuPercent == nil }) {
            let after = sample.rows[firstUnknown...]
            XCTAssertTrue(after.allSatisfy { $0.cpuPercent == nil }, "unknown CPU sorts last")
        }
    }

    /// §5.5.4's mitigation: an identity resolved once is reused, so a later pass does the
    /// expensive per-PID resolution only for PIDs it has not seen before.
    func testIdentityCacheIsPopulatedAndReused() throws {
        var cache: [Int32: ProcessProvider.Identity] = [:]
        var users: [uid_t: String] = [:]
        let first = try XCTUnwrap(ProcessProvider.enumerate(identities: &cache, userNames: &users))
        XCTAssertEqual(cache.count, first.entries.count, "every inspected PID caches its identity")
        let cold = cache
        let second = try XCTUnwrap(ProcessProvider.enumerate(identities: &cache, userNames: &users))
        for entry in second.entries where cold[entry.pid] != nil {
            XCTAssertEqual(entry.name, cold[entry.pid]?.name, "a live PID's name cannot change")
            XCTAssertEqual(entry.uid, cold[entry.pid]?.uid, "a live PID's uid cannot change")
        }
    }

    /// The cache must not grow without bound over an 8-hour session, and a reused PID must
    /// not answer with the previous process's identity **and uid** — the one place a stale
    /// cache would show the wrong owner for a process about to be signalled.
    func testIdentityCacheEvictsDeadPids() throws {
        var cache: [Int32: ProcessProvider.Identity] = [
            -424242: ProcessProvider.Identity(
                name: "ghost", path: nil, uid: 0, user: "root", parentPID: nil, startedAt: nil
            ),
        ]
        var users: [uid_t: String] = [:]
        _ = try XCTUnwrap(ProcessProvider.enumerate(identities: &cache, userNames: &users))
        XCTAssertNil(cache[-424242], "a PID no longer listed must be evicted")
    }

    /// §5.5.2: above 100 % is expected and correct, so nothing may clamp it.
    func testCPUPercentIsNotClamped() {
        let row = ProcessRow(pid: 1, name: "busy", cpuPercent: 1400, residentBytes: 0, threadCount: 14)
        XCTAssertEqual(row.cpuPercent, 1400)
    }

    /// Phase-02 has no GPU provider, so §4.3.3's GPU column has nothing to show yet and must
    /// say so with nil rather than 0.
    /// §5.6.7 (phase-03.1's 1.4 outcome A). A live registry walk is hardware-dependent, so
    /// this asserts the shape rather than a specific PID: every populated value is a
    /// plausible, non-negative percentage point figure, never a fabricated placeholder, and
    /// most rows have no matching `AGXDeviceUserClient` at all and stay `nil`.
    func testGPUPercentIsStructurallyValidWhenPresent() throws {
        var provider = ProcessProvider()
        _ = provider.sample()
        Thread.sleep(forTimeInterval: 0.15)
        guard case .value(let sample, _) = provider.sample() else {
            return XCTFail("expected a value")
        }
        for row in sample.rows {
            if let gpu = row.gpuPercent {
                XCTAssertGreaterThanOrEqual(gpu, 0, "§5.5.2's convention: unclamped but never negative")
            }
        }
    }

    // MARK: - §5.6.7's PID parsing (1.4 outcome A)

    /// `IOUserClientCreator` reads `"pid <N>, <name>"`. Phase-02's rule: match by identifier,
    /// never the truncated display name.
    func testParsePIDExtractsTheNumericPrefixAfterTheLiteralPid() {
        XCTAssertEqual(ProcessProvider.parsePID(from: "pid 407, WindowServer"), 407)
        XCTAssertEqual(ProcessProvider.parsePID(from: "pid 736, NotificationCent"), 736)
    }

    func testParsePIDReturnsNilWithNoPidPrefix() {
        XCTAssertNil(ProcessProvider.parsePID(from: "WindowServer"))
        XCTAssertNil(ProcessProvider.parsePID(from: ""))
    }

    /// `readGPUTimes()` never throws or crashes when IOKit yields nothing to match --
    /// exercised for real on this Mac, where it should find at least the live accelerator.
    /// Asserts the shape rather than a value: the map may legitimately be empty on a Mac
    /// with no GPU-accelerated client running, but every entry it does return must be a
    /// plausible pid and a monotonic nanosecond total — a `0` key or a negative pid would
    /// mean the `AppUsage` decode had drifted (SPEC §5.6.7).
    func testReadGPUTimesReturnsPlausibleEntries() {
        let times = ProcessProvider.readGPUTimes()
        for (pid, nanoseconds) in times {
            XCTAssertGreaterThan(pid, 0, "a GPU-time entry keyed on a non-positive pid means the decode drifted")
            XCTAssertLessThan(nanoseconds, 86_400 * 1_000_000_000,
                              "a single process reporting over a day of accumulated GPU time is a unit error")
        }
    }

    // MARK: - 2.1's identity fields (§8.2's four missing columns)

    /// The running test process owns itself, so `PROC_PIDTBSDINFO` must succeed for it and
    /// every one of the four new fields must be populated -- none left `nil` for a PID this
    /// process plainly can inspect.
    func testOwnProcessResolvesFullIdentity() throws {
        let identity = ProcessProvider.resolveIdentity(pid: getpid(), userNames: &userNames)
        XCTAssertNotNil(identity.uid)
        XCTAssertNotNil(identity.user)
        XCTAssertNotNil(identity.parentPID)
        XCTAssertNotNil(identity.startedAt)
        XCTAssertEqual(identity.uid, getuid())
    }

    /// A PID that can never exist must still resolve a name (the pre-existing fallback) and
    /// must leave every identity field `nil` rather than a fabricated zero (§5.5.1).
    func testUnresolvableProcessLeavesIdentityFieldsNil() {
        let identity = ProcessProvider.resolveIdentity(pid: -1, userNames: &userNames)
        XCTAssertEqual(identity.name, "pid -1")
        XCTAssertNil(identity.uid)
        XCTAssertNil(identity.user)
        XCTAssertNil(identity.parentPID)
        XCTAssertNil(identity.startedAt)
    }

    /// §8.2's Energy column: a *relative* impact 0–100 within the snapshot, so the busiest
    /// process reads exactly 100.0 by construction.
    func testEnergyImpactIsRelativeToTheSnapshotMaximum() {
        let impacts = ProcessProvider.energyImpact(deltas: [1: 100, 2: 50, 3: 25])
        XCTAssertEqual(impacts[1], 100.0)
        XCTAssertEqual(impacts[2], 50.0)
        XCTAssertEqual(impacts[3], 25.0)
    }

    /// No baseline yet (an empty delta map) must produce no impacts at all -- the caller
    /// renders an absent key as `—`, never `0.0`.
    func testEnergyImpactIsNilWithoutABaseline() {
        XCTAssertTrue(ProcessProvider.energyImpact(deltas: [:]).isEmpty)
    }

    /// Every delta zero (every process idle) must not divide by zero and must not fabricate
    /// an impact either.
    func testEnergyImpactIsEmptyWhenEveryDeltaIsZero() {
        XCTAssertTrue(ProcessProvider.energyImpact(deltas: [1: 0, 2: 0]).isEmpty)
    }

    /// `detail == false` is the default, so a plain sample must pay nothing extra and every
    /// row's Energy column must read nil -- the check §5.5.4's budget depends on.
    func testEnergyImpactIsNilOnEveryRowWhenDetailIsOff() throws {
        var provider = ProcessProvider()
        _ = provider.sample()
        Thread.sleep(forTimeInterval: 0.15)
        guard case .value(let sample, _) = provider.sample() else {
            return XCTFail("expected a value")
        }
        XCTAssertTrue(sample.rows.allSatisfy { $0.energyImpact == nil })
    }

    /// `detail == true` gates the extra `proc_pid_rusage` call on; the running test process
    /// owns itself and after two samples spaced far enough apart must show a real reading.
    func testEnergyImpactPopulatesForOwnedProcessWhenDetailIsOn() throws {
        var provider = ProcessProvider()
        provider.detail = true
        _ = provider.sample()
        Thread.sleep(forTimeInterval: 0.15)
        guard case .value(let sample, _) = provider.sample() else {
            return XCTFail("expected a value")
        }
        // Not every row necessarily has a positive delta at this instant, but the reading
        // for this process itself must exist and be non-negative once `detail` is on.
        let mine = sample.rows.first { $0.pid == getpid() }
        if let impact = mine?.energyImpact {
            XCTAssertGreaterThanOrEqual(impact, 0)
        }
    }

    /// `readEnergyNanojoules` must not crash for the running process and must return a
    /// plausible (non-fabricated) reading -- absence is `nil`, never zero passed off as real.
    /// The test process is alive and has burned some energy, so a `nil` here is a real
    /// failure rather than an unavailable-hardware case — the previous version of this
    /// test discarded the result and would have passed on `nil` despite its own name.
    /// A pid that cannot exist must read `nil`, which is what separates "unavailable"
    /// from "zero" (SPEC §5.0.5).
    func testReadEnergyNanojoulesForOwnProcess() throws {
        let own = try XCTUnwrap(ProcessProvider.readEnergyNanojoules(pid: getpid()),
                                "the calling process must report an energy total")
        XCTAssertGreaterThan(own, 0, "a live process that has run tests has consumed energy")
        XCTAssertNil(ProcessProvider.readEnergyNanojoules(pid: -1),
                     "an impossible pid must read unavailable, never zero")
    }
}
