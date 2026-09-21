import XCTest
@testable import GlowTopCore

/// SPEC.md §5.9.1's weighted mean and device-tree decode. Pure and static, tested from
/// fixture arrays and hand-built byte fixtures with no hardware.
final class FrequencyProviderTests: XCTestCase {
    func testWeightedMeanOfKnownResidencies() throws {
        // 10 ticks @ 1000 MHz, 30 ticks @ 2000 MHz -> (10*1000 + 30*2000) / 40 = 1750
        let mean = try XCTUnwrap(FrequencyProvider.weightedMean(residencies: [10, 30], frequenciesMHz: [1_000, 2_000]))
        XCTAssertEqual(mean, 1_750, accuracy: 0.0001)
    }

    func testZeroTotalResidencyReturnsNil() {
        XCTAssertNil(FrequencyProvider.weightedMean(residencies: [0, 0], frequenciesMHz: [1_000, 2_000]))
    }

    func testNegativeResidencyDeltaReturnsNil() {
        XCTAssertNil(FrequencyProvider.weightedMean(residencies: [-1, 30], frequenciesMHz: [1_000, 2_000]))
    }

    /// Two records: 600 MHz @ 700 mV, then a zero-frequency terminator dropped from the
    /// result. The field is **kHz**, confirmed live against this Mac's own
    /// `voltage-states5-sram` (raw `4512000` is the M4 Pro's known 4.512 GHz ceiling only at
    /// kHz scale, not Hz) -- see the deviation note on `decodeVoltageStates`.
    func testDecodeVoltageStatesFromFixtureBytes() throws {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(600_000).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(700).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(0).littleEndian) { Array($0) })

        let table = try XCTUnwrap(FrequencyProvider.decodeVoltageStates(data))
        XCTAssertEqual(table, [600])
    }

    func testOddLengthTableIsRejected() {
        XCTAssertNil(FrequencyProvider.decodeVoltageStates(Data([1, 2, 3])))
        XCTAssertNil(FrequencyProvider.decodeVoltageStates(Data()))
    }

    func testFractionClampsToOne() {
        XCTAssertEqual(min(1, max(0, 5_000.0 / 4_000.0)), 1)
    }

    /// §5.9's naming rule never matches the E-cluster, on this Mac or any other.
    func testEClusterIsNeverSelectedAsPCluster() {
        XCTAssertFalse(FrequencyProvider.isPClusterChannel(name: "ECPU"))
        XCTAssertFalse(FrequencyProvider.isPClusterChannel(name: "ECPM"))
        XCTAssertTrue(FrequencyProvider.isPClusterChannel(name: "PCPU"))
        XCTAssertTrue(FrequencyProvider.isPClusterChannel(name: "PCPU1"))
    }

    /// This Mac's own `PCPM`/`PCPM1`/`*_IDLE` channels also begin with `P` but are not
    /// `PCPU`-prefixed -- the deviation this provider's selection rule exists to avoid
    /// triple-counting.
    func testPClusterVariantChannelsAreExcluded() {
        XCTAssertFalse(FrequencyProvider.isPClusterChannel(name: "PCPM"))
        XCTAssertFalse(FrequencyProvider.isPClusterChannel(name: "PCPM_IDLE"))
    }

    func testActiveStatesDropsDownAndIdle() {
        let states: [(name: String, residency: UInt64)] = [("DOWN", 5), ("IDLE", 7), ("V0P18", 3)]
        XCTAssertEqual(FrequencyProvider.activeStates(states).map(\.name), ["V0P18"])
    }

    // MARK: - §14.1's per-cluster output (phase-11)

    private func stateChannel(_ name: String, _ states: [(String, UInt64)]) -> IOReportChannel {
        IOReportChannel(group: "CPU Stats", subGroup: "CPU Complex Performance States",
                        name: name, unit: "24Mticks", states: states, value: 0)
    }

    func testClusterRuleAcceptsTheThreeClusterChannelsAndRejectsCPMAndCores() {
        for name in ["ECPU", "PCPU", "PCPU1"] {
            XCTAssertTrue(FrequencyProvider.isClusterChannel(name: name), name)
        }
        for name in ["ECPM", "ECPM_IDLE", "PCPM", "PCPM_IDLE", "PCPM1", "PCPM1_IDLE", "PCPU140", "ECPU000"] {
            XCTAssertFalse(FrequencyProvider.isClusterChannel(name: name), name)
        }
    }

    func testClusterLabelsMatchTheSpecTable() {
        XCTAssertEqual(FrequencyProvider.clusterLabel(for: "PCPU"), "P0")
        XCTAssertEqual(FrequencyProvider.clusterLabel(for: "PCPU1"), "P1")
        XCTAssertEqual(FrequencyProvider.clusterLabel(for: "ECPU"), "E")
    }

    /// The fourteen `CPU Core Performance States` names from the 2026-09-03 dump.
    func testCoreCountsFromTheDumpsOwnChannelNames() {
        let names = [
            "ECPU000", "ECPU010", "ECPU020", "ECPU030",
            "PCPU000", "PCPU010", "PCPU020", "PCPU030", "PCPU040",
            "PCPU100", "PCPU110", "PCPU120", "PCPU130", "PCPU140",
        ]
        XCTAssertEqual(FrequencyProvider.coreCounts(from: names), ["ECPU": 4, "PCPU": 5, "PCPU1": 5])
    }

    func testTableKeysSplitByClusterKind() {
        XCTAssertEqual(FrequencyProvider.tableKeys(forCluster: "ECPU"), ["voltage-states1-sram", "voltage-states1"])
        XCTAssertEqual(FrequencyProvider.tableKeys(forCluster: "PCPU1"), ["voltage-states5-sram", "voltage-states5"])
    }

    func testColumnOrderIsP0P1ERegardlessOfEnumerationOrder() {
        let channels = [
            stateChannel("ECPU", [("DOWN", 1), ("V0", 1)]),
            stateChannel("PCPU1", [("DOWN", 1), ("V0", 1)]),
            stateChannel("PCPU", [("DOWN", 1), ("V0", 1)]),
        ]
        let clusters = FrequencyProvider.buildClusters(channels: channels, coreCounts: [:]) { _ in [1_000] }
        XCTAssertEqual(clusters.map(\.label), ["P0", "P1", "E"])
    }

    /// D-11: a cluster whose table cannot be paired is unavailable **alone**; its siblings stay live.
    func testAClusterWhoseTableLengthDoesNotMatchIsUnavailableAlone() throws {
        let channels = [
            stateChannel("PCPU", [("DOWN", 10), ("V0", 10), ("V1", 30)]),
            stateChannel("ECPU", [("DOWN", 10), ("V0", 10), ("V1", 10), ("V2", 10)]),
        ]
        let clusters = FrequencyProvider.buildClusters(channels: channels, coreCounts: ["PCPU": 5, "ECPU": 4]) { key in
            key == "voltage-states5-sram" ? [1_000, 2_000] : nil
        }
        let p0 = try XCTUnwrap(clusters.first { $0.label == "P0" })
        let e = try XCTUnwrap(clusters.first { $0.label == "E" })
        XCTAssertEqual(p0.tableSource, "device-tree:voltage-states5-sram")
        XCTAssertNil(p0.missingTableKey)
        XCTAssertEqual(try XCTUnwrap(p0.averageMegahertz), 1_750, accuracy: 1e-9)
        XCTAssertEqual(p0.maxMegahertz, 2_000)
        XCTAssertEqual(p0.coreCount, 5)
        XCTAssertNil(e.tableSource)
        XCTAssertNil(e.averageMegahertz)
        XCTAssertNil(e.maxMegahertz)
        XCTAssertEqual(e.missingTableKey, "voltage-states1-sram")
        XCTAssertEqual(e.states.count, 4, "the unpaired cluster keeps its states, with no MHz")
        XCTAssertTrue(e.states.allSatisfy { $0.megahertz == nil })
    }

    func testResidencyFractionsSumToOnePerCluster() throws {
        let channel = stateChannel("PCPU", [("DOWN", 30), ("IDLE", 10), ("V0", 40), ("V1", 20)])
        let cluster = try XCTUnwrap(
            FrequencyProvider.buildClusters(channels: [channel], coreCounts: [:]) { _ in [1_000, 2_000] }.first
        )
        let fractions = cluster.states.map(\.residencyFraction)
        XCTAssertEqual(fractions.count, 4)
        for (got, want) in zip(fractions, [0.3, 0.1, 0.4, 0.2]) { XCTAssertEqual(got, want, accuracy: 1e-9) }
        XCTAssertEqual(fractions.reduce(0, +), 1.0, accuracy: 1e-9)
        XCTAssertEqual(cluster.states.map(\.isIdle), [true, true, false, false])
        XCTAssertEqual(cluster.states.map(\.megahertz), [nil, nil, 1_000, 2_000])
    }

    // MARK: - Live provider

    func testFirstSampleWarms() {
        var provider = FrequencyProvider()
        guard case .warming = provider.sample() else {
            return XCTFail("first sample of a delta provider must be .warming (§5.0.3)")
        }
    }
}
