import XCTest
@testable import GlowTopCore

/// SPEC.md §13.5 items 5, 6, 9.
final class RingBufferTests: XCTestCase {
    func testNeverExceedsCapacityAndKeepsNewest() {
        var buffer = RingBuffer<Int>(capacity: 10)
        for value in 1...20 { buffer.append(value) }

        XCTAssertEqual(buffer.count, 10)
        XCTAssertEqual(buffer.capacity, 10)
        XCTAssertEqual(buffer.elements, Array(11...20))
        XCTAssertEqual(buffer.newest, 20)
    }

    func testPartiallyFilledPreservesOrder() {
        var buffer = RingBuffer<Int>(capacity: 5)
        buffer.append(1)
        buffer.append(2)

        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.elements, [1, 2])
        XCTAssertEqual(buffer.newest, 2)
    }

    func testEmptyBufferHasNoElements() {
        let buffer = RingBuffer<Double>(capacity: 600)

        XCTAssertEqual(buffer.count, 0)
        XCTAssertTrue(buffer.elements.isEmpty)
        XCTAssertNil(buffer.newest)
    }
}

final class InterpolationTests: XCTestCase {
    func testEndpointsAndMidpoint() {
        XCTAssertEqual(Interpolation.value(from: 0.2, to: 0.8, fraction: 0), 0.2, accuracy: 0.0001)
        XCTAssertEqual(Interpolation.value(from: 0.2, to: 0.8, fraction: 1), 0.8, accuracy: 0.0001)
        XCTAssertEqual(Interpolation.value(from: 0.2, to: 0.8, fraction: 0.5), 0.5, accuracy: 0.0001)
    }

    /// SPEC.md §6.6: a late sample holds at the current value. Extrapolation invents data.
    func testFractionClampsRatherThanExtrapolating() {
        XCTAssertEqual(Interpolation.value(from: 0.2, to: 0.8, fraction: 2), 0.8, accuracy: 0.0001)
        XCTAssertEqual(Interpolation.value(from: 0.2, to: 0.8, fraction: -1), 0.2, accuracy: 0.0001)
    }

    func testFractionFromClock() {
        let start = ContinuousClock().now
        let halfway = start.advanced(by: .milliseconds(50))
        let late = start.advanced(by: .milliseconds(250))

        XCTAssertEqual(
            Interpolation.fraction(now: halfway, sampledAt: start, interval: .milliseconds(100)),
            0.5, accuracy: 0.01
        )
        XCTAssertEqual(
            Interpolation.fraction(now: late, sampledAt: start, interval: .milliseconds(100)),
            1.0, accuracy: 0.0001
        )
    }
}

final class SampleIntervalTests: XCTestCase {
    func testClassifiesTooSoonUsableAndStale() {
        let start = ContinuousClock().now

        XCTAssertEqual(
            SampleInterval.classify(from: start, to: start.advanced(by: .milliseconds(10))),
            .toosoon
        )
        XCTAssertEqual(
            SampleInterval.classify(from: start, to: start.advanced(by: .seconds(6))),
            .stale
        )
        guard case .usable(let seconds) = SampleInterval.classify(
            from: start, to: start.advanced(by: .milliseconds(100))
        ) else {
            return XCTFail("100 ms should be a usable interval")
        }
        XCTAssertEqual(seconds, 0.1, accuracy: 0.001)
    }
}

/// SPEC.md §5.2.3: memory is defined from named vm_statistics64 fields, and the parts
/// must account for the whole.
final class MemoryProviderTests: XCTestCase {
    func testTotalMatchesSysctl() throws {
        let expected = try XCTUnwrap(Sysctl.uint64("hw.memsize"))
        var provider = MemoryProvider()

        let sample = try XCTUnwrap(provider.sample().payload)

        XCTAssertEqual(sample.total, expected)
    }

    func testCompositionDoesNotExceedTotal() throws {
        var provider = MemoryProvider()

        let sample = try XCTUnwrap(provider.sample().payload)

        XCTAssertLessThanOrEqual(
            sample.resident + sample.reclaimable + sample.free,
            sample.total + sample.pageSize * 8
        )
        XCTAssertGreaterThan(sample.resident, 0)
        XCTAssertGreaterThan(sample.pageSize, 0)
    }

    func testPressureIsAFraction() throws {
        var provider = MemoryProvider()

        let sample = try XCTUnwrap(provider.sample().payload)

        XCTAssertGreaterThanOrEqual(sample.pressure, 0)
        XCTAssertLessThanOrEqual(sample.pressure, 1)
    }

    /// SPEC.md §5.2.1: page size is read, never hardcoded.
    func testPageSizeMatchesSysctl() throws {
        let expected = try XCTUnwrap(Sysctl.integer("hw.pagesize"))
        var provider = MemoryProvider()

        let sample = try XCTUnwrap(provider.sample().payload)

        XCTAssertEqual(Int(sample.pageSize), expected)
    }
}
