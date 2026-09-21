import XCTest
@testable import GlowTopCore

/// SPEC.md §6.3's batched reader, §6.2's occlusion scaling, §6.8's pause, §3.5's ⌘R, and
/// §5.10's ten-provider health list. Phase-03 sub-step 1.2.
final class SummaryFramesTests: XCTestCase {
    func testSummaryFramesReturnsEveryMetricInOneActorHop() async {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(350))
        let frames = await store.summaryFrames()
        await store.stop()

        XCTAssertEqual(frames.cpu.state, .live)
        XCTAssertEqual(frames.memory.state, .live)
        XCTAssertGreaterThan(frames.cpuTotal.count, 0)
        XCTAssertEqual(frames.cpuTotal.count, frames.cpuSystem.count,
                       "§4.4 plots both against one time base")
        XCTAssertGreaterThan(frames.generation, 0)
        XCTAssertEqual(frames.health.count, 10)
    }

    /// §5.10, after 3.1: all ten providers report their slot's real state. On a fresh,
    /// unstarted store every slot defaults to `.warming` (`Slot`'s own default) -- never the
    /// retired `notBuiltReason`, which `health()` no longer hardcodes for any of the five.
    func testHealthReportsTenProvidersFromRealState() async {
        let store = MetricStore()
        let health = await store.health()

        XCTAssertEqual(health.count, ProviderID.allCases.count)
        XCTAssertEqual(health.map(\.id), ProviderID.allCases)
        XCTAssertTrue(
            health.allSatisfy { $0.state != .unavailable(reason: MetricStore.notBuiltReason) },
            "no provider may still report the retired notBuilt reason"
        )
    }

    /// §5.6.4's discretion: the ANE rides `EnergySample`, so `.npu` must mirror `.energy`'s
    /// slot exactly rather than carry a second copy of one number that could disagree with
    /// its own source.
    func testNpuStateMirrorsEnergySlot() async throws {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(300))
        let health = await store.health()
        await store.stop()

        let npu = health.first { $0.id == .npu }?.state
        let energy = health.first { $0.id == .energy }?.state
        XCTAssertEqual(npu, energy)
    }

    func testGpuHistoryCapacityIsOneHundredTwenty() async {
        let store = MetricStore()
        let capacity = await store.gpuHistory.capacity
        XCTAssertEqual(capacity, 120, "60 s at 500 ms")
    }

    func testEnergyHistoryCapacityIsSixty() async {
        let store = MetricStore()
        let capacity = await store.energyHistory.capacity
        XCTAssertEqual(capacity, 60, "60 s at 1 s")
    }

    /// This Mac carries well over four thermal sensors (§13.6's sensor-list row), so the top
    /// four hottest fix the temperature series' identity.
    func testTemperatureHistoryIsFourBuffersOfSixty() async throws {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(2200))
        let history = await store.temperatureHistory
        let names = await store.temperatureNames
        await store.stop()

        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(history.count, 4)
        XCTAssertTrue(history.allSatisfy { $0.capacity == 60 })
    }

    /// The failure this sub-step is written to prevent: re-ranking the top four every sample
    /// would let two sensors trading places swap which history line is which.
    func testTemperatureNamesFixOnFirstLiveSampleAndSurviveReordering() {
        func sensor(_ name: String, _ celsius: Double) -> ThermalSample.Sensor {
            ThermalSample.Sensor(name: name, celsius: celsius)
        }

        let first = ThermalSample(
            sensors: [sensor("tdie1", 50), sensor("tdie2", 48), sensor("tdie3", 40),
                     sensor("tdie4", 35), sensor("tdie5", 20)],
            maxCelsius: 50, rejected: []
        )
        let names = MetricStore.temperatureIdentity(current: [], sample: first)
        XCTAssertEqual(names, ["tdie1", "tdie2", "tdie3", "tdie4"])

        // Same four sensors, reordered by rank under load -- identity must not rebuild.
        let reordered = ThermalSample(
            sensors: [sensor("tdie4", 55), sensor("tdie1", 50), sensor("tdie2", 45),
                     sensor("tdie3", 30), sensor("tdie5", 20)],
            maxCelsius: 55, rejected: []
        )
        XCTAssertEqual(MetricStore.temperatureIdentity(current: names, sample: reordered), names,
                       "re-ranking must not swap which line is which")

        // A tracked sensor drops out of the matched set -- identity rebuilds.
        let dropped = ThermalSample(
            sensors: [sensor("tdie2", 45), sensor("tdie3", 30), sensor("tdie5", 20)],
            maxCelsius: 45, rejected: []
        )
        XCTAssertNotEqual(MetricStore.temperatureIdentity(current: names, sample: dropped), names)
    }

    /// §6.8: resuming discards every provider's delta baseline, so the first post-resume CPU
    /// frame is warming. A pause that kept the baselines would produce a "utilization"
    /// averaged across a period during which nothing was measured.
    func testPauseThenResumeReWarmsDeltaProviders() async {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(300))
        let live = await store.cpuFrame().state
        XCTAssertEqual(live, .live)

        await store.pause()
        await store.resume()
        try? await Task.sleep(for: .milliseconds(150))
        let rewarmed = await store.cpuFrame().state
        XCTAssertEqual(rewarmed, .warming,
                       "§5.0.3: a fresh provider's first sample has no baseline")
        await store.stop()
    }

    /// §3.5's ⌘R must feel immediate. `stop()` awaits each loop out of its body, and
    /// `Task.sleep(until:)` returns at once on cancellation, so the only wait is an
    /// in-flight `sample()`.
    func testForceSampleReturnsUnderOneHundredMilliseconds() async {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(200))

        let started = ContinuousClock().now
        await store.forceSample()
        let elapsed = started.duration(to: ContinuousClock().now)
        await store.stop()

        XCTAssertLessThan(elapsed, .milliseconds(100), "⌘R blocked for \(elapsed)")
    }

    /// §6.2. The assertion that matters is the second one: an occlusion implemented as
    /// stop/start would also slow the generation counter, and would additionally re-warm
    /// every provider — so switching apps and back would show `···`, which looks defensible
    /// and is wrong.
    func testOccludedScalesTheFastLoopToOneHertz() async {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(300))
        await store.setOccluded(true)
        try? await Task.sleep(for: .milliseconds(100))

        let before = await store.snapshotGeneration()
        try? await Task.sleep(for: .milliseconds(600))
        let after = await store.snapshotGeneration()
        let state = await store.cpuFrame().state
        await store.stop()

        XCTAssertLessThanOrEqual(after - before, 2,
                                 "600 ms at 1 Hz is at most 1 pass, not 6")
        XCTAssertEqual(state, .live, "occlusion slows sampling; it does not re-warm it")
    }

    /// §6.2's divisor applies to `samples(tick:)`, which every loop calls -- including the
    /// 500 ms GPU/frequency loop this sub-step adds. An implementation that only throttled
    /// the original three loops would leave the GPU tile sampling at full rate while occluded.
    func testOccludedScalesEveryLoopIncludingGpu() async throws {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(1100)) // GPU's 500 ms loop has reached .value
        await store.setOccluded(true)
        try? await Task.sleep(for: .milliseconds(100))

        let before = await store.gpuHistory.count
        try? await Task.sleep(for: .milliseconds(2500)) // ~5 more samples at 500 ms, unoccluded
        let after = await store.gpuHistory.count
        await store.stop()

        XCTAssertLessThanOrEqual(after - before, 1,
                                 "occlusion must divide the GPU loop's rate too, not just the fast one")
    }

    func testUnoccludingRestoresTheTenHertzRate() async {
        let store = MetricStore()
        await store.setOccluded(true)
        await store.start()
        try? await Task.sleep(for: .milliseconds(200))
        await store.setOccluded(false)
        try? await Task.sleep(for: .milliseconds(100))

        let before = await store.snapshotGeneration()
        try? await Task.sleep(for: .milliseconds(500))
        let after = await store.snapshotGeneration()
        await store.stop()

        XCTAssertGreaterThanOrEqual(after - before, 3, "back to 100 ms ticks")
    }

    func testCpuSystemHistoryFillsAtTenHertz() async {
        let store = MetricStore()
        await store.start()
        try? await Task.sleep(for: .milliseconds(400))
        let frames = await store.summaryFrames()
        await store.stop()

        XCTAssertGreaterThanOrEqual(frames.cpuSystem.count, 2)
        XCTAssertTrue(frames.cpuSystem.allSatisfy { $0 >= 0 && $0 <= 1 },
                      "§5.1.3 carries system as a 0-1 fraction, not points")
    }

    /// §3.3. Nothing suspends in phase-03 — Summary is exempt and is the only live pane —
    /// but the setter exists so phase-04 has somewhere to hang suspension.
    func testActivePaneIsStoredAndDefaultsToSummary() async {
        let store = MetricStore()
        let initial = await store.activePane
        XCTAssertEqual(initial, .summary)
        await store.setActivePane(.processes)
        let changed = await store.activePane
        XCTAssertEqual(changed, .processes)
    }
}
