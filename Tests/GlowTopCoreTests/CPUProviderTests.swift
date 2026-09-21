import Darwin
import XCTest
@testable import GlowTopCore

/// SPEC.md §13.5 items 1-3.
final class CPUProviderTests: XCTestCase {
    /// [user, system, idle, nice] in CPU_STATE_* order.
    private func core(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32 = 0) -> [UInt32] {
        var states = [UInt32](repeating: 0, count: Int(CPU_STATE_MAX))
        states[Int(CPU_STATE_USER)] = user
        states[Int(CPU_STATE_SYSTEM)] = system
        states[Int(CPU_STATE_IDLE)] = idle
        states[Int(CPU_STATE_NICE)] = nice
        return states
    }

    func testAllIdleReadsZero() {
        let before = [core(user: 100, system: 50, idle: 1000)]
        let after = [core(user: 100, system: 50, idle: 1100)]

        let delta = CPUProvider.utilization(previous: before, current: after)

        XCTAssertEqual(delta?.perCore, [0.0])
        XCTAssertEqual(delta?.total ?? -1, 0.0, accuracy: 0.0001)
    }

    func testFullyBusyReadsOne() {
        let before = [core(user: 100, system: 50, idle: 1000)]
        let after = [core(user: 200, system: 50, idle: 1000)]

        let delta = CPUProvider.utilization(previous: before, current: after)

        XCTAssertEqual(delta?.perCore, [1.0])
        XCTAssertEqual(delta?.total ?? -1, 1.0, accuracy: 0.0001)
    }

    func testThirtySeventyUserIdleSplit() {
        let before = [core(user: 0, system: 0, idle: 0)]
        let after = [core(user: 30, system: 0, idle: 70)]

        let delta = CPUProvider.utilization(previous: before, current: after)

        XCTAssertEqual(delta?.perCore.first ?? -1, 0.30, accuracy: 0.0001)
        XCTAssertEqual(delta?.user ?? -1, 0.30, accuracy: 0.0001)
        XCTAssertEqual(delta?.idle ?? -1, 0.70, accuracy: 0.0001)
    }

    /// SPEC.md §5.1.2: the aggregate is tick-weighted, not the mean of the per-core
    /// figures. A busy core that accumulated more ticks must pull the total toward it.
    func testAggregateIsTickWeightedNotTheMeanOfPerCore() {
        let before = [core(user: 0, system: 0, idle: 0), core(user: 0, system: 0, idle: 0)]
        // Core 0: 100 busy of 100 ticks. Core 1: 0 busy of 900 ticks.
        let after = [core(user: 100, system: 0, idle: 0), core(user: 0, system: 0, idle: 900)]

        let delta = CPUProvider.utilization(previous: before, current: after)

        XCTAssertEqual(delta?.perCore ?? [], [1.0, 0.0])
        // Mean of perCore would be 0.5; the tick-weighted figure is 100/1000.
        XCTAssertEqual(delta?.total ?? -1, 0.10, accuracy: 0.0001)
    }

    /// SPEC.md §5.0.4: a decreasing unsigned counter is a wrap, not negative work.
    func testWrappedCounterIsRejected() {
        let before = [core(user: 4_294_967_200, system: 0, idle: 0)]
        let after = [core(user: 40, system: 0, idle: 100)]

        XCTAssertNil(CPUProvider.utilization(previous: before, current: after))
    }

    func testZeroLengthIntervalIsRejected() {
        let ticks = [core(user: 100, system: 50, idle: 1000)]

        XCTAssertNil(CPUProvider.utilization(previous: ticks, current: ticks))
    }

    func testCoreCountChangeIsRejected() {
        let before = [core(user: 0, system: 0, idle: 0)]
        let after = [core(user: 10, system: 0, idle: 90), core(user: 10, system: 0, idle: 90)]

        XCTAssertNil(CPUProvider.utilization(previous: before, current: after))
    }

    func testSharesSumToOne() {
        let before = [core(user: 0, system: 0, idle: 0, nice: 0)]
        let after = [core(user: 25, system: 15, idle: 55, nice: 5)]

        let delta = CPUProvider.utilization(previous: before, current: after)
        let sum = (delta?.user ?? 0) + (delta?.system ?? 0) + (delta?.idle ?? 0) + (delta?.nice ?? 0)

        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    /// SPEC.md §5.1.5: perCore length must equal hw.logicalcpu exactly.
    func testCoreCountMatchesSysctl() throws {
        let expected = try XCTUnwrap(Sysctl.integer("hw.logicalcpu"))
        var provider = CPUProvider()

        _ = provider.sample()          // establishes the delta baseline
        Thread.sleep(forTimeInterval: 0.15)
        let snapshot = provider.sample()

        let sample = try XCTUnwrap(snapshot.payload, "second sample should produce a value")
        XCTAssertEqual(sample.perCore.count, expected)
        XCTAssertEqual(sample.logicalCount, expected)
        XCTAssertEqual(sample.performanceCores + sample.efficiencyCores, expected)
    }

    /// SPEC.md §5.0.3: below 50 ms the tick delta approaches zero; the provider must not
    /// divide by a near-zero denominator.
    func testSampleTakenTooSoonDoesNotProduceNonsense() throws {
        var provider = CPUProvider()
        _ = provider.sample()
        Thread.sleep(forTimeInterval: 0.15)
        _ = provider.sample()

        let immediate = provider.sample()   // no sleep: well under 50 ms

        if let sample = immediate.payload {
            XCTAssertGreaterThanOrEqual(sample.total, 0)
            XCTAssertLessThanOrEqual(sample.total, 1)
            for value in sample.perCore {
                XCTAssertGreaterThanOrEqual(value, 0)
                XCTAssertLessThanOrEqual(value, 1)
            }
        }
    }

    func testFirstSampleIsWarming() {
        var provider = CPUProvider()

        guard case .warming = provider.sample() else {
            return XCTFail("first sample must be .warming — it only establishes a baseline")
        }
    }

    func testLiveSampleStaysInRange() throws {
        var provider = CPUProvider()
        _ = provider.sample()
        Thread.sleep(forTimeInterval: 0.15)

        let sample = try XCTUnwrap(provider.sample().payload)

        XCTAssertGreaterThanOrEqual(sample.total, 0)
        XCTAssertLessThanOrEqual(sample.total, 1)
        XCTAssertFalse(sample.perCore.contains { $0 < 0 || $0 > 1 })
    }
}
