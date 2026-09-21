import XCTest
@testable import GlowTopCore

/// SPEC.md §5.6.1, §5.6.2, §5.6.5. The idle-share arithmetic and the idle-state matching rule
/// are static pure functions, so they are tested from fixture arrays with no GPU.
final class GPUProviderTests: XCTestCase {
    func testUtilizationIsOneMinusIdleShare() throws {
        let result = try XCTUnwrap(GPUProvider.utilization(idleResidencyDelta: 40, totalResidencyDelta: 100))
        XCTAssertEqual(result.value, 0.6, accuracy: 0.0001)
        XCTAssertEqual(result.uncertain, false)
    }

    func testZeroTotalResidencyReturnsNil() {
        XCTAssertNil(GPUProvider.utilization(idleResidencyDelta: 0, totalResidencyDelta: 0))
    }

    func testNegativeResidencyDeltaReturnsNil() {
        XCTAssertNil(GPUProvider.utilization(idleResidencyDelta: -5, totalResidencyDelta: 100))
        XCTAssertNil(GPUProvider.utilization(idleResidencyDelta: 5, totalResidencyDelta: -100))
    }

    /// §5.6.5: a result outside 0...1 is clamped, not rejected, and marked `uncertain`.
    func testOutOfRangeClampsAndMarksUncertain() {
        // Idle residency exceeding total is impossible on real hardware but must not crash
        // or produce a value outside 0...1.
        let result = GPUProvider.utilization(idleResidencyDelta: 150, totalResidencyDelta: 100)
        XCTAssertEqual(result?.value, 0)
        XCTAssertEqual(result?.uncertain, true)
    }

    /// §5.6.2: the idle state is matched by name, never assumed to be index 0 -- this Mac's
    /// own `GPU Performance States` channel puts it there (`OFF`), but a hardcoded index reads
    /// wrong the moment an SoC's table starts with an active state.
    func testIdleStateMatchedByNameNotIndex() throws {
        let states: [(name: String, residency: UInt64)] = [
            ("P1", 10), ("P2", 20), ("IDLE", 70),
        ]
        let result = try XCTUnwrap(GPUProvider.gpuUtilization(states: states))
        XCTAssertEqual(result.idleStateName, "IDLE")
        XCTAssertEqual(result.value, 0.3, accuracy: 0.0001)
    }

    func testFallsBackToIndexZeroWhenNoNameMatches() {
        XCTAssertEqual(GPUProvider.idleStateIndex(names: ["P1", "P2", "P3"]), 0)
    }

    // MARK: - Live provider

    func testFirstSampleWarms() {
        var provider = GPUProvider()
        guard case .warming = provider.sample() else {
            return XCTFail("first sample of a delta provider must be .warming (§5.0.3)")
        }
    }
}
