import XCTest
@testable import GlowTopCore

/// SPEC.md §13.5 items 3 and 4 at the store level, plus the one regression that the
/// multi-rate refactor exists to prevent.
final class SlotTests: XCTestCase {
    /// Taken per test, never stored: XCTest builds every test instance before running any of
    /// them, so a stored `now` is already seconds old by the time a later suite's tests run —
    /// which reads as `.stalled` and fails for reasons that have nothing to do with the code.
    private var t0: ContinuousClock.Instant { ContinuousClock().now }

    func testFirstValueGoesLiveAndLeavesPreviousEmpty() {
        var slot = MetricStore.Slot<Double>(SampleRate.hz10)
        slot.store(.value(1.5, timestamp: t0))
        XCTAssertEqual(slot.frame().current, 1.5)
        XCTAssertNil(slot.frame().previous)
        XCTAssertEqual(slot.frame().state, .live)
    }

    func testSecondValueShiftsCurrentIntoPrevious() {
        var slot = MetricStore.Slot<Double>(SampleRate.hz10)
        slot.store(.value(1.0, timestamp: t0))
        slot.store(.value(2.0, timestamp: t0))
        XCTAssertEqual(slot.frame().previous, 1.0)
        XCTAssertEqual(slot.frame().current, 2.0)
    }

    /// §4.8 separates warming from stalled by appearance, so warming must not discard the
    /// last good value — a provider that re-warms after a sleep still has something to draw.
    func testWarmingKeepsTheLastValue() {
        var slot = MetricStore.Slot<Double>(SampleRate.hz10)
        slot.store(.value(7.0, timestamp: t0))
        slot.store(.warming)
        XCTAssertEqual(slot.frame().state, .warming)
        XCTAssertEqual(slot.frame().current, 7.0)
    }

    func testUnavailableCarriesItsReason() {
        var slot = MetricStore.Slot<Double>(SampleRate.hz10)
        slot.store(.unavailable(reason: "no matching IOService"))
        XCTAssertEqual(slot.frame().state, .unavailable(reason: "no matching IOService"))
    }

    /// A sample stamped more than 2 s ago reads `.stalled` without the test sleeping for it,
    /// because the timestamp is supplied rather than taken.
    func testStaleTimestampReadsStalled() {
        var slot = MetricStore.Slot<Double>(SampleRate.hz10)
        slot.store(.value(1.0, timestamp: ContinuousClock().now.advanced(by: .seconds(-3))))
        XCTAssertEqual(slot.frame().state, .stalled)
        XCTAssertEqual(slot.frame().current, 1.0, "stalled holds the last value (§4.8)")
    }

    func testFreshTimestampDoesNotReadStalled() {
        var slot = MetricStore.Slot<Double>(SampleRate.hz10)
        slot.store(.value(1.0, timestamp: ContinuousClock().now))
        XCTAssertEqual(slot.frame().state, .live)
    }

    /// An unavailable provider never reads `.stalled`: the reason string is what the tooltip
    /// needs, and "stalled" would hide it.
    func testUnavailableIsNotOverwrittenByStalled() {
        var slot = MetricStore.Slot<Double>(SampleRate.hz10)
        slot.store(.value(1.0, timestamp: ContinuousClock().now.advanced(by: .seconds(-3))))
        slot.store(.unavailable(reason: "unsupported on this Mac"))
        XCTAssertEqual(slot.frame().state, .unavailable(reason: "unsupported on this Mac"))
    }
}

final class NextTickTests: XCTestCase {
    /// SPEC.md §6.3: the next deadline comes from the previous deadline, not from "now".
    func testOnTimeTickAdvancesByExactlyOneInterval() async {
        let start = ContinuousClock().now
        let next = await MetricStore.nextTick(after: start, by: .milliseconds(50))
        XCTAssertEqual(next, start.advanced(by: .milliseconds(50)))
    }

    /// A deadline already in the past must not schedule a burst of catch-up ticks; §6.3 says
    /// missed ticks are dropped, so the new deadline is measured from now.
    func testLateTickIsDroppedRatherThanRunBackToBack() async {
        let longPast = ContinuousClock().now.advanced(by: .seconds(-10))
        let before = ContinuousClock().now
        let next = await MetricStore.nextTick(after: longPast, by: .milliseconds(50))
        XCTAssertGreaterThan(next, before, "a missed tick reschedules from now, not from the stale deadline")
        XCTAssertLessThan(next, before.advanced(by: .seconds(1)))
    }
}

/// Phase-11: §6.4's cluster identity rule and override O-2's defaulted `SummaryFrames` fields.
final class ClusterHistoryTests: XCTestCase {
    private func sample(clusters names: [String]) -> FrequencySample {
        FrequencySample(
            performanceMegahertz: 1_260, maxMegahertz: 4_512, fraction: 0.28, stateCount: 19,
            tableSource: "device-tree:voltage-states5-sram",
            clusters: names.map {
                ClusterFrequency(name: $0, label: FrequencyProvider.clusterLabel(for: $0), coreCount: 0, states: [],
                                 averageMegahertz: nil, maxMegahertz: nil, tableSource: nil, missingTableKey: nil)
            }
        )
    }

    /// The swap this rule exists to prevent: a re-ordered enumeration keeps the current identity.
    func testClusterIdentityHoldsWhileEveryNameIsStillPresent() {
        let current = ["PCPU", "PCPU1", "ECPU"]
        let names = MetricStore.clusterIdentity(current: current, sample: sample(clusters: ["ECPU", "PCPU", "PCPU1"]))
        XCTAssertEqual(names, current)
    }

    func testClusterIdentityRebuildsWhenANameDropsOut() {
        let names = MetricStore.clusterIdentity(current: ["PCPU", "PCPU1", "ECPU"], sample: sample(clusters: ["PCPU", "ECPU"]))
        XCTAssertEqual(names, ["PCPU", "ECPU"])
    }

    /// Override O-2, held by the compiler: this constructs `SummaryFrames` with the
    /// pre-phase-11 argument list only. Remove the defaults and this stops compiling.
    func testSummaryFramesDefaultsLeaveTheNewFieldsEmpty() {
        func empty<T: Sendable>() -> MetricStore.Frame<T> {
            MetricStore.Frame(previous: nil, current: nil, sampledAt: nil, interval: .seconds(1), state: .warming)
        }
        let frames = SummaryFrames(
            cpu: empty(), memory: empty(), disk: empty(), network: empty(), processes: empty(),
            gpu: empty(), energy: empty(), thermal: empty(), frequency: empty(),
            cpuTotal: [], cpuSystem: [], memoryHistory: [], diskHistory: [], networkHistory: [],
            gpuHistory: [], energyHistory: [], temperatureHistory: [], temperatureNames: [],
            powerSource: nil, thermalPressure: ThermalPressure.current(), generation: 0, health: []
        )
        XCTAssertTrue(frames.clusterHistory.isEmpty)
        XCTAssertTrue(frames.cpuWattsHistory.isEmpty)
        XCTAssertTrue(frames.gpuWattsHistory.isEmpty)
        XCTAssertTrue(frames.aneWattsHistory.isEmpty)
        XCTAssertTrue(frames.dramWattsHistory.isEmpty)
    }
}

final class MetricStoreLoopTests: XCTestCase {
    /// The regression this refactor exists to prevent. `Task { }` inside an actor method
    /// inherits that actor's isolation, so every `sample()` would run on the actor and the
    /// loop would serialize against readers — with no compiler error and no visible symptom
    /// until a slow provider (§5.5.4's 25 ms enumeration) lands. `Task.detached` is what
    /// keeps sampling off the actor; this asserts the 10 Hz loop actually reaches 10 Hz.
    func testFastLoopAdvancesGenerationAtRoughlyTenHertz() async throws {
        let store = MetricStore()
        await store.start()
        try await Task.sleep(for: .milliseconds(1200))
        let generation = await store.snapshotGeneration()
        await store.stop()
        XCTAssertGreaterThanOrEqual(generation, 8, "10 Hz for 1.2 s should be ~12 passes, got \(generation)")
    }

    /// Memory is on the 10 Hz loop now, not sampled on demand, so it must reach `.live`
    /// without anyone calling it. It is an absolute gauge, so it never warms.
    func testMemoryReachesLiveFromTheLoopAlone() async throws {
        let store = MetricStore()
        await store.start()
        try await Task.sleep(for: .milliseconds(400))
        let frame = await store.memoryFrame()
        await store.stop()
        XCTAssertEqual(frame.state, .live)
        XCTAssertNotNil(frame.current)
    }

    /// §6.3's fourth and last loop. One `start()` and every rate the store owns -- 100 ms,
    /// 250 ms, 500 ms, 1 s -- reaches a real value, proving the GPU/frequency loop runs on
    /// its own schedule rather than piggy-backing on one of the other three.
    func testFourLoopsRunAtFourDistinctRates() async throws {
        let store = MetricStore()
        await store.start()
        try await Task.sleep(for: .milliseconds(2300))
        let frames = await store.summaryFrames()
        await store.stop()

        XCTAssertEqual(frames.cpu.state, .live, "100 ms loop")
        XCTAssertNotNil(frames.gpu.sampledAt, "500 ms loop")
        XCTAssertNotNil(frames.frequency.sampledAt, "500 ms loop")
        XCTAssertNotNil(frames.energy.sampledAt, "1 s loop, needs two ticks for its delta")
        XCTAssertNotNil(frames.thermal.sampledAt, "1 s loop")
    }

    func testStopHaltsTheLoop() async throws {
        let store = MetricStore()
        await store.start()
        try await Task.sleep(for: .milliseconds(300))
        await store.stop()
        let settled = await store.snapshotGeneration()
        try await Task.sleep(for: .milliseconds(300))
        let after = await store.snapshotGeneration()
        XCTAssertEqual(settled, after, "generation must not advance after stop()")
    }
}
