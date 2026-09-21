import XCTest
@testable import GlowTopCore

/// SPEC.md §4. Phase-03 sub-step 1.4.
///
/// This is where this project's recurring defect class lives: a projection that returns a
/// plausible number instead of an error. Every test here asserts against that shape rather
/// than against "does it run".
final class SummaryModelTests: XCTestCase {
    private var now: ContinuousClock.Instant { ContinuousClock().now }

    // MARK: - Fixtures

    private func cpuSample(total: Double = 0.158, system: Double = 0.03) -> CPUSample {
        CPUSample(
            perCore: [0.1, 0.9, 0.2, 0.05], total: total, user: total - system, system: system,
            idle: 1 - total, nice: 0, logicalCount: 4, performanceCores: 2, efficiencyCores: 2
        )
    }

    private func memorySample() -> MemorySample {
        // 48 GB machine: resident 20 GB, reclaimable 18.4 GB, free 9 GB.
        let gb: UInt64 = 1024 * 1024 * 1024
        let reclaimable: UInt64 = UInt64(18.4 * Double(gb))
        let speculative: UInt64 = UInt64(4.4 * Double(gb))
        return MemorySample(
            resident: 20 * gb,
            reclaimable: reclaimable,
            free: 9 * gb,
            total: 48 * gb,
            active: 12 * gb,
            wired: 6 * gb,
            compressed: 2 * gb,
            swapUsed: 0,
            pageSize: 16384,
            inactive: 10 * gb,
            purgeable: 4 * gb,
            speculative: speculative,
            cached: 10 * gb
        )
    }

    private func processSample() -> ProcessSample {
        var rows: [ProcessRow] = []
        for index in 0..<20 {
            let pid = Int32(100 + index)
            let cpu: Double? = index == 0 ? nil : Double(50 - index)
            let resident = UInt64(index + 1) * 1024 * 1024
            rows.append(ProcessRow(pid: pid, name: "proc\(index)", cpuPercent: cpu,
                                   residentBytes: resident, threadCount: 3))
        }
        return ProcessSample(rows: rows, totalCount: 839, inspectableCount: 504,
                             enumerationMilliseconds: 5.4)
    }

    private func gpuSample(utilization: Double = 0.42) -> GPUSample {
        GPUSample(utilization: utilization, source: "IOReport", uncertain: false,
                  chipName: "Apple M4 Pro", coreCount: 20, idleStateName: "IDLE")
    }

    private func energySample(watts: Double = 8.4, aneUtilization: Double? = 0.12) -> EnergySample {
        EnergySample(watts: watts, cpuWatts: 4.0, gpuWatts: 3.0, aneWatts: 1.0,
                     contributingChannels: ["CPU Energy", "GPU", "ANE"],
                     aneUtilization: aneUtilization, aneSource: "power/8W")
    }

    private func thermalSample(maxCelsius: Double = 45.0) -> ThermalSample {
        ThermalSample(sensors: [ThermalSample.Sensor(name: "tdie1", celsius: maxCelsius)],
                     maxCelsius: maxCelsius, rejected: [])
    }

    private func frequencySample(fraction: Double = 0.4) -> FrequencySample {
        FrequencySample(performanceMegahertz: 1600, maxMegahertz: 4000, fraction: fraction,
                        stateCount: 5, tableSource: "device-tree:voltage-states5-sram")
    }

    private func frame<T: Sendable>(_ value: T?, _ state: MetricState,
                                    interval: Duration = SampleRate.hz10)
        -> MetricStore.Frame<T> {
        MetricStore.Frame(previous: nil, current: value, sampledAt: value == nil ? nil : now,
                          interval: interval, state: state)
    }

    private func frames(
        cpu: MetricState = .live, memory: MetricState = .live, disk: MetricState = .live,
        network: MetricState = .live, processes: MetricState = .live,
        gpuState: MetricState = .unavailable(reason: MetricStore.notBuiltReason), gpu: GPUSample? = nil,
        energyState: MetricState = .unavailable(reason: MetricStore.notBuiltReason), energy: EnergySample? = nil,
        thermalState: MetricState = .unavailable(reason: MetricStore.notBuiltReason), thermal: ThermalSample? = nil,
        frequencyState: MetricState = .unavailable(reason: MetricStore.notBuiltReason),
        frequency: FrequencySample? = nil,
        temperatureHistory: [[Double]] = [], temperatureNames: [String] = [],
        powerSource: PowerSourceInfo? = nil, thermalPressure: ThermalPressure = .nominal,
        extraHealth: [ProviderHealth]? = nil, memoryHistory: [MemorySample] = [],
        cpuTotal: [Double]? = nil, samplingDivisor: Int = 1
    ) -> SummaryFrames {
        let health = extraHealth ?? [
            ProviderHealth(id: .cpu, state: cpu), ProviderHealth(id: .memory, state: memory),
            ProviderHealth(id: .disk, state: disk), ProviderHealth(id: .network, state: network),
            ProviderHealth(id: .process, state: processes),
            ProviderHealth(id: .gpu, state: gpuState), ProviderHealth(id: .npu, state: energyState),
            ProviderHealth(id: .energy, state: energyState),
            ProviderHealth(id: .thermal, state: thermalState),
            ProviderHealth(id: .frequency, state: frequencyState),
        ]
        return SummaryFrames(
            cpu: frame(cpu == .live ? cpuSample() : nil, cpu),
            memory: frame(memory == .live ? memorySample() : nil, memory),
            disk: frame(disk == .live ? DiskSample(
                readBytesPerSecond: 13_002_342, writeBytesPerSecond: 3_250_585,
                readOpsPerSecond: 40, writeOpsPerSecond: 12, busyPercent: 4.0,
                totalBytesRead: 1, totalBytesWritten: 1, deviceCount: 2) : nil, disk,
                interval: SampleRate.hz4),
            network: frame(network == .live ? NetworkSample(
                bytesInPerSecond: 151_756, bytesOutPerSecond: 23_142,
                packetsInPerSecond: 100, packetsOutPerSecond: 40,
                totalBytesIn: 1, totalBytesOut: 1, errorsIn: 0, errorsOut: 0,
                primaryInterface: "en0", primaryAddress: "192.168.1.42",
                primaryBytesIn: 1, primaryBytesOut: 1) : nil, network, interval: SampleRate.hz4),
            processes: frame(processes == .live ? processSample() : nil, processes,
                             interval: SampleRate.hz1),
            gpu: frame(gpuState == .live ? (gpu ?? gpuSample()) : nil, gpuState, interval: SampleRate.hz2),
            energy: frame(energyState == .live ? (energy ?? energySample()) : nil, energyState,
                         interval: SampleRate.hz1),
            thermal: frame(thermalState == .live ? (thermal ?? thermalSample()) : nil, thermalState,
                          interval: SampleRate.hz1),
            frequency: frame(frequencyState == .live ? (frequency ?? frequencySample()) : nil, frequencyState,
                            interval: SampleRate.hz2),
            cpuTotal: cpuTotal ?? [0.1, 0.2, 0.158], cpuSystem: [0.01, 0.02, 0.03],
            memoryHistory: memoryHistory, diskHistory: [], networkHistory: [],
            gpuHistory: [], energyHistory: [], temperatureHistory: temperatureHistory,
            temperatureNames: temperatureNames,
            powerSource: powerSource, thermalPressure: thermalPressure,
            generation: 4218, health: health, samplingDivisor: samplingDivisor
        )
    }

    // MARK: - §4.8's three states

    /// An unavailable metric projected as `fraction: 0` draws an empty-but-live meter and a
    /// `0.0%` headline. A GPU tile reading `0.0%` on a busy machine is indistinguishable
    /// from an idle GPU — the exact lie §4.8's table exists to prevent.
    func testUnavailableHeadlineIsEmDashNeverZero() {
        let model = SummaryModel.project(frames())
        let unbuilt = model.tiles.filter(\.state.isUnavailable)

        XCTAssertEqual(unbuilt.count, 4, "Energy, GPU 0, NPU 0, Thermals")
        for tile in unbuilt {
            XCTAssertEqual(tile.headline, "—", "\(tile.title)")
            XCTAssertNotEqual(tile.headline, "0.0%")
            XCTAssertTrue(tile.series.isEmpty, "\(tile.title) must omit its plot entirely")
        }
        for meter in model.meters.dropFirst() {
            XCTAssertNil(meter.fraction, "\(meter.caption) must carry no fraction")
            XCTAssertEqual(meter.label, "—")
        }
    }

    func testWarmingHeadlineIsEllipsisNeverZero() {
        let model = SummaryModel.project(frames(cpu: .warming))
        XCTAssertEqual(model.cpuOverview.headline, "···")
        XCTAssertEqual(model.meters[0].label, "···")
        XCTAssertNil(model.meters[0].fraction)
        XCTAssertTrue(model.cpuOverview.series.isEmpty)
    }

    /// §4.8: stalled holds the last value; the view dims it. Blanking would destroy
    /// information, and the state must survive the projection so the view can tell.
    func testStalledCarriesLastValueAndStalledState() {
        var f = frames()
        f = SummaryFrames(
            cpu: MetricStore.Frame(previous: nil, current: cpuSample(), sampledAt: now,
                                   interval: SampleRate.hz10, state: .stalled),
            memory: f.memory, disk: f.disk, network: f.network, processes: f.processes,
            gpu: f.gpu, energy: f.energy, thermal: f.thermal, frequency: f.frequency,
            cpuTotal: f.cpuTotal, cpuSystem: f.cpuSystem,
            memoryHistory: f.memoryHistory, diskHistory: f.diskHistory,
            networkHistory: f.networkHistory, gpuHistory: f.gpuHistory,
            energyHistory: f.energyHistory, temperatureHistory: f.temperatureHistory,
            temperatureNames: f.temperatureNames, powerSource: f.powerSource,
            thermalPressure: f.thermalPressure, generation: f.generation, health: f.health
        )
        let model = SummaryModel.project(f)
        XCTAssertEqual(model.cpuOverview.state, .stalled)
        XCTAssertTrue(model.cpuOverview.footer.contains("4 logical processors"),
                      "stalled keeps the last value on screen")
    }

    // MARK: - §4.7's status bar

    /// This is §5.10 visible in the status bar on a healthy machine, and it is not a bug to
    /// be quieted. Fewer than five means a not-built provider is reporting live.
    func testHealthyMachineReadsFiveProvidersUnavailableInOrange() {
        let status = SummaryModel.project(frames()).status
        XCTAssertEqual(status.phrase, "5 providers unavailable")
        XCTAssertEqual(status.phraseToken, "statusDegraded")
        XCTAssertEqual(status.leading, "5 providers unavailable · 839 processes · Generation 4218")
        XCTAssertEqual(status.tooltip.split(separator: "\n").count, 5)
        XCTAssertTrue(status.tooltip.contains("gpu: provider not built"))
    }

    func testAllProvidersLiveReadsHealthy() {
        let health = ProviderID.allCases.map { ProviderHealth(id: $0, state: .live) }
        let status = SummaryModel.project(frames(extraHealth: health)).status
        XCTAssertEqual(status.phrase, "Native providers healthy")
        XCTAssertEqual(status.phraseToken, "textSecondary")
        XCTAssertEqual(status.tooltip, "")
    }

    func testOneOrTwoUnavailableReadsYellowNotOrange() {
        var health = ProviderID.allCases.map { ProviderHealth(id: $0, state: .live) }
        health[5] = ProviderHealth(id: .gpu, state: .unavailable(reason: "no readable sensor"))
        let status = SummaryModel.project(frames(extraHealth: health)).status
        XCTAssertEqual(status.phrase, "1 providers unavailable")
        XCTAssertEqual(status.phraseToken, "warning")
    }

    /// A dead sample loop is the more urgent fact and the one no interpolating meter reveals.
    func testStalledProviderOverridesTheUnavailableCount() {
        var health = ProviderID.allCases.map {
            ProviderHealth(id: $0, state: .unavailable(reason: MetricStore.notBuiltReason))
        }
        health[0] = ProviderHealth(id: .cpu, state: .stalled)
        let status = SummaryModel.project(frames(extraHealth: health)).status
        XCTAssertEqual(status.phrase, "Sampling stalled")
        XCTAssertEqual(status.phraseToken, "critical")
    }

    func testPausedStatusReadsPausedAndHoldsGeneration() {
        let status = SummaryModel.project(frames(), paused: true).status
        XCTAssertEqual(status.leading, "Paused · Generation 4218")
        XCTAssertFalse(status.leading.contains("unavailable"),
                       "§6.8 suppresses the health phrase — nothing is sampling")
    }

    // MARK: - §4.3.3's process card

    /// About 40 % of PIDs refuse inspection unprivileged (§5.5.1). Using `inspectableCount`
    /// reports ~500 where `ps -A` counts ~840 — self-consistent, plausible, and the defect
    /// phase-02 already paid for once.
    func testProcessHeaderUsesTotalCountNotInspectableCount() {
        let model = SummaryModel.project(frames())
        XCTAssertEqual(model.processes.headline, "839 total")
        XCTAssertNotEqual(model.processes.headline, "504 total")
        XCTAssertGreaterThan(839, model.processRows.count)
    }

    func testProcessCardTakesTwelveRows() {
        XCTAssertEqual(SummaryModel.project(frames()).processRows.count, 12)
    }

    /// §5.5.2: a process on its first appearance has no baseline. Showing 0.0 % would claim
    /// a measurement that was not taken.
    func testProcessRowWithNilCpuRendersEmDash() {
        let rows = SummaryModel.project(frames()).processRows
        XCTAssertEqual(rows[0].cpu, "—")
        XCTAssertEqual(rows[1].cpu, "49.0%")
    }

    func testProcessGpuColumnIsEmDashUntilPhase031() {
        XCTAssertTrue(SummaryModel.project(frames()).processRows.allSatisfy { $0.gpu == "—" })
    }

    // MARK: - §4.5's memory card

    func testMemoryHeadlineSaysResidentNotUsed() {
        let card = SummaryModel.project(frames()).memory
        XCTAssertEqual(card.headline, "20 GB resident / 48 GB")
        XCTAssertFalse(card.headline.contains("used"), "§5.2.3")
    }

    /// §4.5's own example row shows `18.40 GB`, two decimals, which §4.9's bytes rule
    /// forbids. §4.9 wins; the spec row is amended in sub-step 4.3.
    func testMemoryFooterUsesOneDecimalPerSection49() {
        let card = SummaryModel.project(frames()).memory
        XCTAssertEqual(card.footer, "Reclaimable 18.4 GB · Free 9 GB · Swap 0 B")
        XCTAssertFalse(card.footer.contains("18.40"))
    }

    /// Raw layers overlap, so the visible ceiling is max(layer) rather than sum(layers): the
    /// machine looks far emptier than it is, and it looks like a tidy chart.
    func testMemoryLayersAreCumulativeNotRaw() {
        let history = Array(repeating: memorySample(), count: 5)
        let card = SummaryModel.project(frames(memoryHistory: history)).memory
        XCTAssertEqual(card.series.count, 5, "four stacked layers plus the unstacked swap line")

        for index in 1..<4 {
            for slot in 0..<5 {
                XCTAssertGreaterThanOrEqual(
                    card.series[index].values[slot], card.series[index - 1].values[slot],
                    "layer \(index) must sit above layer \(index - 1) at slot \(slot)"
                )
            }
        }
    }

    /// §4.5: swap is an event worth noticing, not a fraction to blend in.
    func testSwapIsAnUnstackedLineNotAFifthBand() {
        let history = Array(repeating: memorySample(), count: 3)
        let swap = SummaryModel.project(frames(memoryHistory: history)).memory.series[4]
        XCTAssertNil(swap.fill, "no fill — a filled swap band double-counts memory in use")
        XCTAssertEqual(swap.lineWidth, 1.0)
        XCTAssertEqual(swap.colorToken, "critical")
    }

    func testMemoryMeterFractionMatchesResidentOverTotal() {
        let meter = SummaryModel.project(frames()).memoryMeter
        XCTAssertEqual(meter.fraction!, 20.0 / 48.0, accuracy: 1e-9)
    }

    // MARK: - §4.3.1's Clock, Temp, and GPU meters

    /// §5.9.3: the label is `Auto` whenever a reading exists -- there is no user-selectable
    /// governor on this platform -- and `—` when not.
    func testClockMeterReadsAutoWhenLiveAndEmDashWhenNot() {
        let live = SummaryModel.project(
            frames(frequencyState: .live, frequency: frequencySample(fraction: 0.4))
        )
        XCTAssertEqual(live.meters[1].label, "Auto")
        XCTAssertEqual(live.meters[1].fraction!, 0.4, accuracy: 1e-9)

        let dead = SummaryModel.project(frames())
        XCTAssertEqual(dead.meters[1].label, "—")
        XCTAssertNil(dead.meters[1].fraction)
    }

    /// §5.8.3's 0-110 scale: one lit segment is 2.75 °C.
    func testTempMeterUsesTheZeroToOneHundredTenScale() {
        let model = SummaryModel.project(frames(thermalState: .live, thermal: thermalSample(maxCelsius: 55)))
        XCTAssertEqual(model.meters[2].fraction!, 0.5, accuracy: 1e-9)
    }

    /// §5.8.3's red-above-100°C rule is a token swap in the model, never a colour override in
    /// the view (§7.1's boundary).
    func testTempMeterSwitchesToCriticalTokenAboveOneHundred() {
        let hot = SummaryModel.project(frames(thermalState: .live, thermal: thermalSample(maxCelsius: 105)))
        XCTAssertEqual(hot.meters[2].colorToken, "critical")

        let normal = SummaryModel.project(frames(thermalState: .live, thermal: thermalSample(maxCelsius: 45)))
        XCTAssertEqual(normal.meters[2].colorToken, "accentThermal")
    }

    func testGpuMeterReadsUtilizationWhenLive() {
        let model = SummaryModel.project(frames(gpuState: .live, gpu: gpuSample(utilization: 0.73)))
        XCTAssertEqual(model.meters[3].fraction!, 0.73, accuracy: 1e-9)
        XCTAssertEqual(model.meters[3].label, "73.0%")
    }

    // MARK: - §4.4's overlay chart

    /// §4.4: an unavailable series takes its line AND its axis with it. A right-hand 0-110
    /// scale beside a chart with nothing plotted on it invites the reader to map the green
    /// line onto °C.
    func testCpuOverviewCarriesTwoSeriesAndNoRightAxis() {
        let card = SummaryModel.project(frames()).cpuOverview
        XCTAssertEqual(card.series.count, 2)
        XCTAssertEqual(card.series[0].colorToken, "accentCPU")
        XCTAssertEqual(card.series[1].colorToken, "accentKernel")
        XCTAssertFalse(card.series.contains { $0.axis == .celsius })
        XCTAssertEqual(card.axis, .percent)
        XCTAssertNil(card.rightAxis)
    }

    /// The failure this sub-step guards against: emitting the temperature series with a
    /// borrowed `capacity: 600` would compress 60 samples into the rightmost tenth of the
    /// plot. Both series must plot against the same 60-second width.
    func testTemperatureSeriesAndCpuSeriesSpanTheSameSixtySeconds() {
        let history = (0..<60).map { Double($0) }
        let card = SummaryModel.project(
            frames(thermalState: .live, thermal: thermalSample(maxCelsius: 59), temperatureHistory: [history])
        ).cpuOverview

        XCTAssertEqual(card.series.count, 3)
        let temperature = card.series[2]
        XCTAssertEqual(temperature.axis, .celsius)
        XCTAssertEqual(temperature.capacity, 60)
        XCTAssertEqual(temperature.values, history)
        XCTAssertEqual(card.rightAxis, .celsius)
    }

    /// §4.4: no thermal frame, no line, no axis -- omitted together, not independently.
    func testTemperatureSeriesIsAbsentWhenThermalIsUnavailable() {
        let card = SummaryModel.project(frames()).cpuOverview
        XCTAssertEqual(card.series.count, 2)
        XCTAssertFalse(card.series.contains { $0.axis == .celsius })
    }

    func testRightAxisIsNilWhenTheTemperatureSeriesIsAbsent() {
        XCTAssertNil(SummaryModel.project(frames()).cpuOverview.rightAxis)
    }

    /// The kernel series wired to `cpuTotal` draws two identical traces stacked on each
    /// other, which reads as a rendering artefact rather than as the wrong series.
    func testKernelSeriesIsSystemTimeNotTotal() {
        let card = SummaryModel.project(frames()).cpuOverview
        XCTAssertEqual(card.series[0].values, [10, 20, 15.800000000000001].map { $0 })
        XCTAssertEqual(card.series[1].values.last!, 3.0, accuracy: 1e-9)
        XCTAssertNotEqual(card.series[0].values, card.series[1].values)
    }

    func testSeriesValuesArePointsNotFractions() {
        let card = SummaryModel.project(frames()).cpuOverview
        XCTAssertEqual(card.series[0].values.last!, 15.8, accuracy: 1e-9,
                       "§4.4's left axis is 0-100, so values are points")
    }

    // MARK: - §4.6's tiles

    func testDiskFooterNamesDeviceCountNotAVolume() {
        let disks = SummaryModel.project(frames()).tiles[0]
        XCTAssertEqual(disks.footer, "2 devices · 4.0% busy")
        XCTAssertFalse(disks.footer.contains("Macintosh HD"), "§5.3 sources no volume name")
    }

    /// §4.6.1's `R 12.4 · W 3.1 MB/s` — the only place two numbers share a line.
    func testDiskHeadlineStripsTheRepeatedUnitSuffix() {
        let disks = SummaryModel.project(frames()).tiles[0]
        XCTAssertEqual(disks.headline, "R 12.4 · W 3.1 MB/s")
    }

    func testMismatchedUnitsKeepBothSuffixes() {
        XCTAssertEqual(SummaryModel.pairedRate("R", 13_002_342, "W", 948), "R 12.4 MB/s · W 948 B/s")
    }

    func testNetworkFooterNamesTheInterfaceAndAddress() {
        let network = SummaryModel.project(frames()).tiles[1]
        XCTAssertEqual(network.headline, "R 148.2 · S 22.6 KB/s")
        XCTAssertEqual(network.footer, "en0 · 192.168.1.42")
    }

    func testTilesAreInSection46Order() {
        let titles = SummaryModel.project(frames()).tiles.map(\.title)
        XCTAssertEqual(titles, ["DISKS", "NETWORK", "ENERGY", "GPU 0", "NPU 0", "THERMALS"])
    }

    /// §5.7.2's promise: the power source "is reliable even when the wattage is not". The
    /// footer is built from the sidecars, never from the energy provider's own payload, so it
    /// must survive while the headline above it reads `—`.
    func testEnergyFooterSurvivesAnUnavailableWattage() {
        let source = PowerSourceInfo(type: "AC Power", chargePercent: nil, timeToEmptyMinutes: nil,
                                     cycleCount: nil, wholeSystemWatts: nil)
        let energyTile = SummaryModel.project(
            frames(powerSource: source, thermalPressure: .nominal)
        ).tiles[2]

        XCTAssertEqual(energyTile.headline, "—")
        XCTAssertEqual(energyTile.footer, "Thermals nominal · AC Power")
    }

    /// §5.8.4's promise: a real pressure state survives even when every raw sensor is
    /// unreadable -- this is why the sidecar is not part of `ThermalSample`'s payload.
    func testThermalsFooterSurvivesUnreadableSensors() {
        let thermalsTile = SummaryModel.project(frames(thermalPressure: .fair)).tiles[5]
        XCTAssertEqual(thermalsTile.headline, "—")
        XCTAssertEqual(thermalsTile.footer, "Fair thermal pressure")
    }

    /// §5.6.4: neither ANE path produced a number -- `—`, not `0.0%`, which would claim a
    /// reading of a genuinely idle Neural Engine that was never actually measured.
    func testNpuHeadlineIsEmDashWhenAneUtilizationIsNil() {
        let npuTile = SummaryModel.project(
            frames(energyState: .live, energy: energySample(aneUtilization: nil))
        ).tiles[4]
        XCTAssertEqual(npuTile.headline, "—")
    }

    // MARK: - §4.3.2's per-core strip

    func testPerCoreCarriesClusterCaptionsFromTheSampleCounts() {
        let perCore = SummaryModel.project(frames()).perCore
        XCTAssertEqual(perCore.map(\.caption), ["P", "P", "E", "E"])
        XCTAssertEqual(perCore[1].fraction!, 0.9, accuracy: 1e-9)
    }

    /// §4.9 exists so no two panes format one quantity differently, which only holds if one
    /// file decides. A `String(format:)` here is a second formatter.
    func testProjectionUsesFormatAndNotAdHocStringFormatting() throws {
        let path = #filePath.replacingOccurrences(
            of: "Tests/GlowTopCoreTests/SummaryModelTests.swift",
            with: "Sources/GlowTopCore/SummaryModel.swift"
        )
        let source = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(source.contains("String(format:"))
        XCTAssertFalse(source.contains("NumberFormatter"))
    }

    // MARK: - §14.10's Performance projection

    /// The Summary half of this assertion is what makes it about the omission rather than
    /// about an absent fixture: an absence-only check passes when nothing was there to omit.
    func testPerformanceOmitsTheThermalSeriesEvenWhenThermalIsLive() {
        let f = frames(thermalState: .live, thermal: thermalSample(),
                       temperatureHistory: [[40, 41, 42]], temperatureNames: ["tdie"])
        XCTAssertEqual(SummaryModel.project(f).cpuOverview.series.count, 3)
        let performance = PerformanceModel.project(f)
        XCTAssertEqual(performance.cpuSeries.count, 2)
        XCTAssertFalse(performance.cpuSeries.contains { $0.colorToken == "accentThermal" })
    }

    func testPerformanceCPUSeriesAreUtilizationThenKernel() {
        let series = PerformanceModel.project(frames()).cpuSeries
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].colorToken, "accentCPU")
        XCTAssertEqual(series[0].lineWidth, 1.5)
        XCTAssertEqual(series[0].fill, .gradient(topOpacity: 0.22))
        XCTAssertEqual(series[0].capacity, 600)
        XCTAssertEqual(series[1].colorToken, "accentKernel")
        XCTAssertEqual(series[1].lineWidth, 1.0)
        XCTAssertNil(series[1].fill)
    }

    func testPerformanceCPUSeriesAreEmptyWhenNotLive() {
        let performance = PerformanceModel.project(frames(cpu: .warming))
        XCTAssertTrue(performance.cpuSeries.isEmpty)
        XCTAssertEqual(performance.cpuHeadline, "···")
        XCTAssertEqual(performance.cpuFooter, "")
    }

    func testPerformancePerCoreMatchesTheSampleAndItsClusterCounts() {
        let performance = PerformanceModel.project(frames())
        XCTAssertEqual(performance.perCore.count, 4)
        XCTAssertEqual(performance.performanceCores, 2)
        XCTAssertEqual(performance.perCore.map(\.caption), ["P", "P", "E", "E"])
        XCTAssertEqual(performance.perCore.count - performance.performanceCores, 2)
    }

    func testPerformanceHeadlineIsSummarysCPUHeadline() {
        for f in [frames(), frames(cpu: .warming)] {
            XCTAssertEqual(PerformanceModel.project(f).cpuHeadline,
                           SummaryModel.project(f).cpuOverview.headline)
        }
    }

    func testPerformanceMemoryCardIsSummarysVerbatim() {
        let f = frames(memoryHistory: [memorySample(), memorySample(), memorySample()])
        let summary = SummaryModel.project(f)
        let performance = PerformanceModel.project(f)
        XCTAssertEqual(summary.memory.series.count, 5)
        XCTAssertEqual(performance.memory, summary.memory)
        XCTAssertEqual(performance.memoryMeter, summary.memoryMeter)
    }

    /// §4.9's no-space rule, checked as a literal.
    func testPerformanceFooterUsesFormatsPercentageRule() {
        XCTAssertEqual(PerformanceModel.project(frames()).cpuFooter,
                       "Total 15.8% · System 3.0%")
    }

    // MARK: - §4.10 Simple mode (1.2)

    func testDisplayModeParseDefaultsToSimple() {
        XCTAssertEqual(DisplayMode.parse(nil), .simple)
        XCTAssertEqual(DisplayMode.parse("nonsense"), .simple)
        XCTAssertEqual(DisplayMode.parse("technical"), .technical)
    }

    func testProcessorVerdictBoundariesAndDeadband() {
        XCTAssertEqual(VerdictRules.processor(average: 0.59, previous: nil).text, "Normal")
        XCTAssertEqual(VerdictRules.processor(average: 0.60, previous: nil).text, "Busy")
        XCTAssertEqual(VerdictRules.processor(average: 0.85, previous: nil).text, "Very busy")
        // Held: 0.57 stays Busy once Busy, and only drops below 0.55.
        XCTAssertEqual(VerdictRules.processor(average: 0.57, previous: .elevated).text, "Busy")
        XCTAssertEqual(VerdictRules.processor(average: 0.54, previous: .elevated).text, "Normal")
        // Not held: 0.57 coming from Normal is still Normal.
        XCTAssertEqual(VerdictRules.processor(average: 0.57, previous: .normal).text, "Normal")
        XCTAssertEqual(VerdictRules.processor(average: 0.82, previous: .high).text, "Very busy")
    }

    func testMemoryVerdictPrefersTheKernelsLevelAndFallsBack() {
        XCTAssertEqual(VerdictRules.memory(pressureLevel: 1, pressureFraction: 0.95, previous: nil).text, "Normal")
        XCTAssertEqual(VerdictRules.memory(pressureLevel: 2, pressureFraction: 0.1, previous: nil).text, "Getting full")
        XCTAssertEqual(VerdictRules.memory(pressureLevel: 4, pressureFraction: 0.1, previous: nil).level, .critical)
        XCTAssertEqual(VerdictRules.memory(pressureLevel: nil, pressureFraction: 0.30, previous: nil).text, "Normal")
        XCTAssertEqual(VerdictRules.memory(pressureLevel: nil, pressureFraction: 0.65, previous: nil).text, "Getting full")
        XCTAssertEqual(VerdictRules.memory(pressureLevel: nil, pressureFraction: 0.85, previous: nil).text, "Low on memory")
    }

    func testThermalAndNetworkVerdicts() {
        XCTAssertEqual(VerdictRules.thermal(.nominal).text, "Normal")
        XCTAssertEqual(VerdictRules.thermal(.fair).text, "Warm")
        XCTAssertEqual(VerdictRules.thermal(.serious).text, "Hot")
        XCTAssertEqual(VerdictRules.thermal(.critical).level, .critical)
        XCTAssertEqual(VerdictRules.network(bytesPerSecond: 100).text, "Idle")
        XCTAssertEqual(VerdictRules.network(bytesPerSecond: 500_000).level, .normal)
    }

    func testTechnicalProjectionCarriesNoVerdicts() {
        let model = SummaryModel.project(frames())
        XCTAssertNil(model.cpuOverview.verdict)
        XCTAssertNil(model.memory.verdict)
        XCTAssertTrue(model.tiles.allSatisfy { $0.verdict == nil })
        XCTAssertEqual(model.cpuOverview.title, "CPU OVERVIEW")
    }

    func testSimpleModeRelabelsWithoutChangingAnyReading() {
        let live = frames(gpuState: .live, energyState: .live, thermalState: .live, frequencyState: .live,
                          frequency: frequencySample())
        let technical = SummaryModel.project(live)
        let (simple, verdicts) = technical.simplified(frames: live, previous: nil)

        XCTAssertEqual(simple.cpuOverview.title, "PROCESSOR")
        XCTAssertEqual(simple.processes.title, "BUSIEST APPS")
        XCTAssertEqual(simple.memory.headline, "20 GB of 48 GB in use")
        XCTAssertEqual(simple.tiles.map(\.title), ["DISKS", "NETWORK", "POWER DRAW", "GRAPHICS", "AI CHIP", "TEMPERATURE"])
        XCTAssertEqual(simple.meters.map(\.caption), ["CPU", "SPEED", "TEMP", "GRAPHICS"])
        XCTAssertEqual(simple.tiles[0].headline, technical.tiles[0].headline)
        XCTAssertEqual(simple.tiles[1].headline, "↓ 148.2 · ↑ 22.6 KB/s")
        XCTAssertEqual(simple.tiles[1].footer, technical.tiles[1].footer)
        XCTAssertNil(simple.tiles[2].verdict)
        XCTAssertEqual(simple.status.leading, "Your Mac is running normally.")
        XCTAssertEqual(verdicts.processor?.text, "Normal")
        XCTAssertEqual(simple.memory.verdict?.text, "Normal")

        // The readings themselves: identical values, series, states and fractions.
        XCTAssertEqual(simple.cpuOverview.headline, technical.cpuOverview.headline)
        XCTAssertEqual(simple.cpuOverview.series, technical.cpuOverview.series)
        XCTAssertEqual(simple.memory.series, technical.memory.series)
        XCTAssertEqual(simple.meters.map(\.fraction), technical.meters.map(\.fraction))
        XCTAssertEqual(simple.meters.map(\.label), technical.meters.map(\.label))
        XCTAssertEqual(simple.tiles.map(\.state), technical.tiles.map(\.state))
        XCTAssertEqual(simple.tiles.map(\.series), technical.tiles.map(\.series))
        XCTAssertEqual(simple.tiles[2].headline, technical.tiles[2].headline)
        XCTAssertEqual(simple.processRows, technical.processRows)

        // No engineering vocabulary anywhere a Simple-mode reader looks.
        let text = ([simple.cpuOverview, simple.processes, simple.memory] + simple.tiles)
            .flatMap { [$0.title, $0.headline, $0.footer, $0.verdict?.text ?? ""] }
            + [simple.status.leading] + simple.meters.map(\.caption)
        for word in ["resident", "NPU", "GPU", "PID", "provider", "Generation", "Swap", "thermal pressure"] {
            XCTAssertFalse(text.contains { $0.localizedCaseInsensitiveContains(word) }, "Simple mode still says \(word)")
        }
    }

    func testSimpleModeGivesNoVerdictOnACardThatIsNotLive() {
        let some = frames()   // GPU, energy, thermal and frequency unavailable
        let (simple, _) = SummaryModel.project(some).simplified(frames: some, previous: nil)
        XCTAssertNil(simple.tiles[3].verdict)
        XCTAssertNil(simple.tiles[5].verdict)
        XCTAssertEqual(simple.tiles[3].headline, Format.unknown)
        XCTAssertEqual(simple.status.leading, "5 readings are unavailable on this Mac.")

        let warming = frames(cpu: .warming)
        let (warm, _) = SummaryModel.project(warming).simplified(frames: warming, previous: nil)
        XCTAssertNil(warm.cpuOverview.verdict)
    }

    func testSimpleSentenceNamesHeatAndKeepsStalledAndPausedAhead() {
        let hot = frames(gpuState: .live, energyState: .live, thermalState: .live, frequencyState: .live,
                         frequency: frequencySample(), thermalPressure: .serious)
        let (simple, _) = SummaryModel.project(hot).simplified(frames: hot, previous: nil)
        XCTAssertEqual(simple.tiles[5].verdict?.text, "Hot")
        XCTAssertEqual(simple.status.leading, "Your Mac is hot and is slowing itself down to cool off.")
        XCTAssertEqual(simple.status.phraseToken, "statusDegraded")

        let (paused, _) = SummaryModel.project(hot, paused: true).simplified(frames: hot, previous: nil)
        XCTAssertEqual(paused.status.leading, "Paused — press Space to resume.")
    }

    // MARK: - §4.10 fixes from the 1.2 adversarial review

    func testAIChipGetsNoVerdictWhenItsReadingIsMissing() {
        // A live energy frame whose ANE reading is nil: the tile prints `—`, so a confident
        // `Normal` beside it would be §4.8's lie in a friendlier font.
        let noANE = frames(gpuState: .live, energyState: .live,
                           energy: energySample(aneUtilization: nil),
                           thermalState: .live, frequencyState: .live, frequency: frequencySample())
        let (simple, verdicts) = SummaryModel.project(noANE).simplified(frames: noANE, previous: nil)
        XCTAssertEqual(simple.tiles[4].headline, Format.unknown)
        XCTAssertNil(simple.tiles[4].verdict)
        XCTAssertNil(verdicts.aiChip)
    }

    func testVerdictWindowsScaleWithTheOcclusionDivisor() {
        // §6.2 divides every provider's rate by 10 behind an occluded window. A fixed sample
        // count would then average 100 s of history and call it 10 -- a finished build still
        // reading `Very busy` a minute later.
        let idleNow = Array(repeating: 0.95, count: 90) + Array(repeating: 0.02, count: 10)
        let busy = frames(gpuState: .live, energyState: .live, thermalState: .live,
                          frequencyState: .live, frequency: frequencySample(), cpuTotal: idleNow)
        let (full, _) = SummaryModel.project(busy).simplified(frames: busy, previous: nil)
        XCTAssertEqual(full.cpuOverview.verdict?.text, "Very busy", "100 samples at 10 Hz is 10 s of a busy machine")

        let occluded = frames(gpuState: .live, energyState: .live, thermalState: .live,
                              frequencyState: .live, frequency: frequencySample(),
                              cpuTotal: idleNow, samplingDivisor: 10)
        let (slow, _) = SummaryModel.project(occluded).simplified(frames: occluded, previous: nil)
        XCTAssertEqual(slow.cpuOverview.verdict?.text, "Normal",
                       "at 1 Hz the last 10 s is the last 10 samples, which are idle")
    }

    func testThermalAndPowerFootersSurviveAPrivateAPIBlackout() {
        // §4.6.3 and §4.6.6 make these footers unconditional so a real thermal state survives
        // §13.7.3's blackout; Simple mode must not quietly gate them on the tile being live.
        let blackout = frames(thermalPressure: .serious)   // energy and thermal unavailable
        let (simple, _) = SummaryModel.project(blackout).simplified(frames: blackout, previous: nil)
        XCTAssertTrue(simple.tiles[5].state.isUnavailable)
        XCTAssertEqual(simple.tiles[5].footer, "macOS is slowing things down to cool off")
        XCTAssertFalse(simple.tiles[2].footer.isEmpty)
        XCTAssertNil(simple.tiles[5].verdict, "still no verdict on a reading that does not exist")
    }

    func testBusySentenceNamesAProgramFromTheSmoothedLoad() {
        // The denominator is the same 10 s mean the verdict came from, so the program's name
        // cannot appear and vanish between ticks while the word above it holds steady.
        var rows = [ProcessRow(pid: 900, name: "compiler", cpuPercent: 900, residentBytes: 1024, threadCount: 8)]
        rows.append(ProcessRow(pid: 901, name: "other", cpuPercent: 4, residentBytes: 1024, threadCount: 1))
        let hot = SummaryFrames(
            cpu: frame(cpuSample(total: 0.92, system: 0.2), .live),
            memory: frame(memorySample(), .live), disk: frame(nil, .unavailable(reason: "x")),
            network: frame(nil, .unavailable(reason: "x")),
            processes: frame(ProcessSample(rows: rows, totalCount: 500, inspectableCount: 300,
                                           enumerationMilliseconds: 4), .live, interval: SampleRate.hz1),
            gpu: frame(nil, .unavailable(reason: "x")), energy: frame(nil, .unavailable(reason: "x")),
            thermal: frame(nil, .unavailable(reason: "x")), frequency: frame(nil, .unavailable(reason: "x")),
            cpuTotal: Array(repeating: 0.92, count: 100), cpuSystem: Array(repeating: 0.2, count: 100),
            memoryHistory: [], diskHistory: [], networkHistory: [], gpuHistory: [], energyHistory: [],
            temperatureHistory: [], temperatureNames: [], powerSource: nil, thermalPressure: .nominal,
            generation: 1,
            health: [ProviderHealth(id: .cpu, state: .live), ProviderHealth(id: .memory, state: .live),
                     ProviderHealth(id: .process, state: .live)]
        )
        let (simple, _) = SummaryModel.project(hot).simplified(frames: hot, previous: nil)
        XCTAssertEqual(simple.cpuOverview.verdict?.text, "Very busy")
        XCTAssertEqual(simple.status.leading, "compiler is using most of the processor.")
    }
}
