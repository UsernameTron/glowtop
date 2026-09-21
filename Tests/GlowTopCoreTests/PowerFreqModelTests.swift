import XCTest
@testable import GlowTopCore

/// SPEC.md §14.1. Phase-11 sub-steps 3.1 and 3.2.
///
/// The projection's arithmetic (the histogram mean, the opacity ramp, the cumulative bands),
/// its locked strings (byte-exact, two spaces included), and this file's own copy of the
/// `Format` grep test -- `SummaryModelTests`' copy reads `SummaryModel.swift` only.
final class PowerFreqModelTests: XCTestCase {
    // MARK: - Fixtures

    private func state(_ name: String, _ megahertz: Double?, _ fraction: Double) -> ClusterFrequency.State {
        ClusterFrequency.State(name: name, megahertz: megahertz, residencyFraction: fraction,
                               isIdle: megahertz == nil)
    }

    /// `DOWN` (idle), `V0` at 1000 MHz, `V1` at 4000 MHz unless given. Paired against
    /// `voltage-states5-sram` unless `table` is `nil`, in which case the cluster wants
    /// `missingKey` (D-11).
    private func cluster(
        _ label: String, coreCount: Int = 5, states: [ClusterFrequency.State]? = nil,
        average: Double? = 3920, table: String? = "voltage-states5-sram",
        missingKey: String = "voltage-states5-sram"
    ) -> ClusterFrequency {
        let states = states ?? [state("DOWN", nil, 0.5), state("V0", 1000, 0.3), state("V1", 4000, 0.2)]
        return ClusterFrequency(
            name: label, label: label, coreCount: coreCount, states: states,
            averageMegahertz: table == nil ? nil : average,
            maxMegahertz: table == nil ? nil : states.compactMap(\.megahertz).max(),
            tableSource: table.map { "device-tree:\($0)" },
            missingTableKey: table == nil ? missingKey : nil
        )
    }

    private func frame<T: Sendable>(_ value: T?, _ state: MetricState) -> MetricStore.Frame<T> {
        MetricStore.Frame(previous: nil, current: value, sampledAt: nil,
                          interval: SampleRate.hz2, state: state)
    }

    /// D-04's example reading. `watts` stays the three-channel sum (D-07); DRAM rides beside.
    private func energySample(cpu: Double? = 3.1, gpu: Double? = 0.9, ane: Double? = 0.0,
                              dram: Double? = 1.2) -> EnergySample {
        EnergySample(watts: (cpu ?? 0) + (gpu ?? 0) + (ane ?? 0), cpuWatts: cpu, gpuWatts: gpu,
                     aneWatts: ane, contributingChannels: ["CPU Energy", "GPU", "ANE"],
                     aneUtilization: nil, aneSource: "power/8W", dramWatts: dram)
    }

    /// Only the fields this model reads; every cluster shares one `residency`/`average`
    /// history so a fixture is one line. `watts` is the four channel histories, CPU, GPU,
    /// ANE, DRAM -- one sample each unless given.
    private func frames(
        clusters: [ClusterFrequency] = [], residency: [[Double]] = [], average: [Double] = [],
        frequencyState: MetricState = .live,
        energyState: MetricState = .unavailable(reason: MetricStore.notBuiltReason),
        energy: EnergySample? = nil, watts: [[Double]] = [[3.1], [0.9], [0.0], [1.2]]
    ) -> SummaryFrames {
        let absent = MetricState.unavailable(reason: MetricStore.notBuiltReason)
        let sample = FrequencySample(
            performanceMegahertz: 3920, maxMegahertz: 4000, fraction: 0.98, stateCount: 2,
            tableSource: "device-tree:voltage-states5-sram", clusters: clusters
        )
        let energySample = energyState == .live || energyState == .stalled
            ? (energy ?? self.energySample()) : nil
        return SummaryFrames(
            cpu: frame(nil, absent), memory: frame(nil, absent), disk: frame(nil, absent),
            network: frame(nil, absent), processes: frame(nil, absent), gpu: frame(nil, absent),
            energy: frame(energySample, energyState), thermal: frame(nil, absent),
            frequency: frame(frequencyState == .live ? sample : nil, frequencyState),
            cpuTotal: [], cpuSystem: [], memoryHistory: [], diskHistory: [], networkHistory: [],
            gpuHistory: [], energyHistory: [], temperatureHistory: [], temperatureNames: [],
            powerSource: nil, thermalPressure: .nominal, generation: 1, health: [],
            clusterHistory: clusters.map {
                ClusterHistory(name: $0.name, residency: residency, averageMegahertz: average)
            },
            cpuWattsHistory: watts[0], gpuWattsHistory: watts[1],
            aneWattsHistory: watts[2], dramWattsHistory: watts[3]
        )
    }

    private func assertEqual(_ actual: [Double], _ expected: [Double], accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: accuracy, file: file, line: line) }
    }

    // MARK: - The ramp

    func testRampOpacityHitsTheFourLockedPoints() {
        XCTAssertEqual(PowerFreqModel.rampOpacity(rank: 0, activeCount: 1), 1.0, accuracy: 1e-12)
        XCTAssertEqual(PowerFreqModel.rampOpacity(rank: 0, activeCount: 20), 0.25, accuracy: 1e-12)
        XCTAssertEqual(PowerFreqModel.rampOpacity(rank: 19, activeCount: 20), 1.0, accuracy: 1e-12)
        XCTAssertEqual(PowerFreqModel.rampOpacity(rank: 9, activeCount: 19), 0.625, accuracy: 1e-12)
    }

    // MARK: - The histogram

    /// A newest-only implementation returns `[0.20, 0.30, 0.20, 0.30]`; a mean returns
    /// `[0.30, 0.20, 0.30, 0.20]`. The sum assertion catches a normalisation bug; the
    /// element assertions catch a transposition.
    func testHistogramSharesOverAKnownBuffer() {
        let shares = PowerFreqModel.histogramShares([
            [0.50, 0.10, 0.30, 0.10],
            [0.20, 0.20, 0.40, 0.20],
            [0.20, 0.30, 0.20, 0.30],
        ], stateCount: 4)
        assertEqual(shares, [0.30, 0.20, 0.30, 0.20])
        XCTAssertEqual(shares.reduce(0, +), 1.0, accuracy: 1e-9)
    }

    func testHistogramSkipsSamplesWhoseStateCountChanged() {
        let shares = PowerFreqModel.histogramShares([
            [0.50, 0.10, 0.30, 0.10],
            [0.20, 0.20, 0.40, 0.20],
            [0.20, 0.30, 0.20, 0.30],
            [0.10, 0.20, 0.70],
        ], stateCount: 4)
        assertEqual(shares, [0.30, 0.20, 0.30, 0.20])
    }

    func testHistogramOverAnEmptyBufferIsEmpty() {
        XCTAssertEqual(PowerFreqModel.histogramShares([], stateCount: 4), [])
        XCTAssertEqual(PowerFreqModel.histogramShares([[0, 0, 0]], stateCount: 4), [])
    }

    func testSparseLabelRuleAtEightBarsAndAtTwenty() {
        XCTAssertEqual(PowerFreqModel.labelledIndices(barCount: 8), [0, 4, 7])
        XCTAssertEqual(PowerFreqModel.labelledIndices(barCount: 20), [0, 4, 8, 12, 16, 19])
        XCTAssertEqual(PowerFreqModel.labelledIndices(barCount: 1), [0])
    }

    func testSpanFooterGrowsFromTwelveToSixty() {
        XCTAssertEqual(PowerFreqModel.spanFooter(sampleCount: 24), "12 s")
        XCTAssertEqual(PowerFreqModel.spanFooter(sampleCount: 120), "60 s")
        XCTAssertEqual(PowerFreqModel.spanFooter(sampleCount: 0), "0 s")
        XCTAssertEqual(PowerFreqModel.spanFooter(sampleCount: 240), "60 s")
    }

    // MARK: - Cards 1 and 2

    func testResidencyBandsAreCumulativeAndIdleIsTheBottomBandAtEightPercent() {
        let f = frames(clusters: [cluster("P0")], residency: [[0.5, 0.3, 0.2], [0.5, 0.3, 0.2]],
                       average: [3920, 3920])
        let series = PowerFreqModel.project(f).columns[0].residencySeries
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series[0].fill, .solid(opacity: 0.08))
        assertEqual(series[0].values, [50, 50])
        assertEqual(series[1].values, [80, 80])
        assertEqual(series[2].values, [100, 100])
        XCTAssertEqual(series[1].opacity, 0.25, accuracy: 1e-12)
        XCTAssertEqual(series[2].opacity, 1.0, accuracy: 1e-12)
    }

    func testColumnOrderAndAccentsMatchTheLockedTable() {
        let columns = PowerFreqModel.project(frames(clusters: [cluster("P0"), cluster("P1"), cluster("E", coreCount: 4)])).columns
        XCTAssertEqual(columns.map(\.label), ["P0", "P1", "E"])
        XCTAssertEqual(columns.map(\.accentToken), ["accentClock", "accentClock", "accentGPU"])
    }

    /// D-11, held by a test: one column's failure is that column's alone.
    func testAColumnWhoseTableDidNotPairIsUnavailableAloneAndNamesTheKey() {
        let f = frames(clusters: [cluster("P0"), cluster("E", coreCount: 4, table: nil, missingKey: "voltage-states1-sram")],
                       residency: [[0.5, 0.3, 0.2]], average: [3920])
        let columns = PowerFreqModel.project(f).columns
        XCTAssertTrue(columns[1].state.isUnavailable)
        XCTAssertEqual(columns[1].unavailableText, "No voltage-states1-sram table")
        XCTAssertTrue(columns[1].residencySeries.isEmpty)
        XCTAssertNil(columns[1].averageSeries)
        XCTAssertEqual(columns[0].state, .live)
        XCTAssertEqual(columns[0].residencySeries.count, 3)
    }

    /// Byte-exact, two spaces included. The warming form is reached through the caption
    /// helper: a warming frequency frame carries no sample, so `project` has no cluster to
    /// caption and omits the columns (§4.8's whole-card treatment).
    func testCaptionStringsMatchTheCopywritingContract() {
        let live = PowerFreqModel.project(frames(clusters: [cluster("P0")])).columns[0]
        XCTAssertEqual(live.caption, "P0 · 5 cores  3.92 GHz")
        XCTAssertEqual(PowerFreqModel.caption(cluster("P0"), state: .warming), "P0 · 5 cores  ···")
        let unpaired = PowerFreqModel.project(frames(clusters: [cluster("E", coreCount: 4, table: nil)])).columns[0]
        XCTAssertEqual(unpaired.caption, "E · 4 cores  —")

        // Wave-2 finding: a cluster fully power-gated over the interval pairs its table but
        // has no active time, so `averageMegahertz` is `nil` -- a live column reading `—`,
        // not D-11's unavailable one.
        let gated = PowerFreqModel.project(frames(clusters: [cluster("P0", average: nil)])).columns[0]
        XCTAssertEqual(gated.caption, "P0 · 5 cores  —")
        XCTAssertEqual(gated.state, .live)
    }

    // MARK: - Card 3

    func testPowerFooterNamesEveryChannelWithOneTrailingWatt() {
        let model = PowerFreqModel.project(frames(energyState: .live))
        XCTAssertEqual(model.power.footer, "CPU 3.1 · GPU 0.9 · ANE 0.0 · DRAM 1.2 W")
        XCTAssertEqual(model.power.title, "PACKAGE POWER")
        XCTAssertEqual(model.power.colorToken, "accentEnergy")
        XCTAssertEqual(model.powerTooltip, PowerFreqModel.powerTooltip)
    }

    /// The four-channel total, **not** `EnergySample.watts`' `4.0 W` -- and the same number
    /// the stack's top edge reaches, which is the whole reason card 3 prints a total.
    func testPowerHeadlineIsTheFourChannelTotalAndTheStacksTopEdge() {
        let model = PowerFreqModel.project(frames(energyState: .live))
        XCTAssertEqual(model.power.headline, "5.2 W")
        XCTAssertEqual(model.powerSeries.count, 4)
        XCTAssertEqual(model.powerSeries.map(\.colorToken), ["accentCPU", "accentGPU", "accentNPU", "accentMemory"])
        assertEqual(model.powerSeries.map { $0.values[0] }, [3.1, 4.0, 4.0, 5.2])
        XCTAssertEqual(model.powerSeries[0].fill, .solid(opacity: 1.0))
        XCTAssertEqual(model.powerSeries[0].lineWidth, 0)
        XCTAssertEqual(model.powerSeries[0].capacity, 60)
        XCTAssertEqual(model.powerSeries.map(\.axis), Array(repeating: model.powerAxis!, count: 4))
    }

    func testPowerAxisFloorsAtFiveWatts() {
        let f = frames(energyState: .live, energy: energySample(cpu: 0.1, gpu: 0.1, ane: 0.1, dram: 0.1),
                       watts: [[0.1], [0.1], [0.1], [0.1]])
        let model = PowerFreqModel.project(f)
        XCTAssertGreaterThanOrEqual(model.powerAxis!.max, 5)
        XCTAssertEqual(model.powerAxisLabels, ["0.0 W", "1.2 W", "2.5 W", "3.8 W", "5.0 W"])
    }

    func testOmittingTheDRAMChannelDropsItsBandAndPrintsUnknownInTheFooter() {
        let model = PowerFreqModel.project(frames(energyState: .live, energy: energySample(dram: nil)))
        XCTAssertEqual(model.powerSeries.count, 3)
        XCTAssertEqual(model.powerSeries.map(\.colorToken), ["accentCPU", "accentGPU", "accentNPU"])
        XCTAssertEqual(model.power.footer, "CPU 3.1 · GPU 0.9 · ANE 0.0 · DRAM — W")
        XCTAssertEqual(model.power.headline, "4.0 W")
    }

    /// The two providers fail independently; the pane goes dark only when both do (PWR-05).
    /// Card 3 carries the energy frame's own state either way.
    func testPaneStateIsUnavailableOnlyWhenBothFramesAre() {
        let both = PowerFreqModel.project(frames(frequencyState: .unavailable(reason: "private APIs disabled"),
                                                 energyState: .unavailable(reason: "private APIs disabled")))
        XCTAssertTrue(both.paneState.isUnavailable)
        XCTAssertTrue(both.columns.isEmpty)
        XCTAssertEqual(both.power.headline, "—")
        XCTAssertEqual(both.power.footer, "")
        XCTAssertTrue(both.powerSeries.isEmpty)
        XCTAssertNil(both.powerAxis)
        XCTAssertTrue(both.powerAxisLabels.isEmpty)

        let energyOnly = PowerFreqModel.project(frames(frequencyState: .unavailable(reason: "key not present"),
                                                       energyState: .live))
        XCTAssertEqual(energyOnly.paneState, .live)
        XCTAssertTrue(energyOnly.columns.isEmpty)
        // Wave-3 finding: cards 1 and 2 key their whole-card §4.8 on this, not on `paneState`.
        XCTAssertTrue(energyOnly.frequencyState.isUnavailable)
        XCTAssertEqual(energyOnly.power.headline, "5.2 W")

        let warming = PowerFreqModel.project(frames(clusters: [cluster("P0")], energyState: .warming))
        XCTAssertEqual(warming.paneState, .warming)
        XCTAssertEqual(warming.columns.count, 1)
        XCTAssertEqual(warming.power.state, .warming)
        XCTAssertEqual(warming.power.headline, "···")
        XCTAssertTrue(warming.powerSeries.isEmpty)
    }

    // MARK: - §4.9's one-owner rule

    /// `SummaryModelTests`' copy reads `SummaryModel.swift` only, so this file guards its
    /// own. `wattsValue`'s `String(Format.power(watts:).dropLast(2))` is not a
    /// `String(format:` call and passes as written.
    func testProjectionUsesFormatAndNotAdHocStringFormatting() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/GlowTopCoreTests/PowerFreqModelTests.swift",
            with: "Sources/GlowTopCore/PowerFreqModel.swift"
        )
        XCTAssertTrue(path.hasSuffix("Sources/GlowTopCore/PowerFreqModel.swift"), "re-pointed, not copy-pasted")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(source.contains("String(format:"))
        XCTAssertFalse(source.contains("NumberFormatter"))
    }
}
