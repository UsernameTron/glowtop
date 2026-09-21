import XCTest
@testable import GlowTopCore

/// SPEC.md §4.4, §4.5, §4.6, §6.6. Phase-03 sub-step 1.3.
final class ChartSeriesTests: XCTestCase {
    private let plot = PlotRect(x: 100, y: 50, width: 600, height: 150)

    // MARK: - Axis

    func testPercentAxisMapsZeroToBottomAndHundredToTop() {
        XCTAssertEqual(ChartAxis.percent.normalise(0), 0, accuracy: 1e-9)
        XCTAssertEqual(ChartAxis.percent.normalise(50), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ChartAxis.percent.normalise(100), 1, accuracy: 1e-9)
    }

    func testCelsiusAxisMapsOneHundredTenToTop() {
        XCTAssertEqual(ChartAxis.celsius.normalise(0), 0, accuracy: 1e-9)
        XCTAssertEqual(ChartAxis.celsius.normalise(55), 0.5, accuracy: 1e-9)
        XCTAssertEqual(ChartAxis.celsius.normalise(110), 1, accuracy: 1e-9)
    }

    /// Unclamped, a 154 °C reading normalises to 1.4 and draws into the neighbouring card,
    /// where it is read as the neighbour's data.
    func testValueAboveAxisMaxClampsRatherThanOverrunsPlot() {
        XCTAssertEqual(ChartAxis.celsius.normalise(154), 1, accuracy: 1e-9)
        XCTAssertEqual(ChartAxis.percent.normalise(1400), 1, accuracy: 1e-9)
        XCTAssertEqual(ChartAxis.percent.normalise(-12), 0, accuracy: 1e-9)
    }

    func testZeroWidthAxisReturnsZeroRatherThanNaN() {
        XCTAssertEqual(ChartAxis(min: 5, max: 5).normalise(5), 0)
    }

    // MARK: - Point mapping

    func testFullBufferSpansThePlotEdgeToEdge() {
        let d = SeriesDescriptor(values: Array(repeating: 0, count: 600), axis: .percent,
                                 colorToken: "accentCPU", lineWidth: 1.5, capacity: 600)
        let points = ChartSeries.points(d, in: plot)
        XCTAssertEqual(points.first!.x, 100, accuracy: 1e-9)
        XCTAssertEqual(points.last!.x, 700, accuracy: 1e-9)
    }

    /// §3.6 item 3: charts fill left-to-right as history accumulates. Indexing x against
    /// `values.count` instead of `capacity` draws a fully-populated chart four seconds after
    /// launch — a lie about its own time base, and one that looks right.
    func testShortHistoryPlotsAgainstTheRightEdgeNotStretched() {
        let d = SeriesDescriptor(values: Array(repeating: 0, count: 10), axis: .percent,
                                 colorToken: "accentCPU", lineWidth: 1.5, capacity: 600)
        let points = ChartSeries.points(d, in: plot)
        let step = 600.0 / 599.0
        XCTAssertEqual(points.count, 10)
        XCTAssertEqual(points.first!.x, 100 + step * 590, accuracy: 1e-9)
        XCTAssertEqual(points.last!.x, 700, accuracy: 1e-9)
    }

    func testYIsBottomLeftOriginSoHigherValuesSitHigher() {
        let d = SeriesDescriptor(values: [0, 100], axis: .percent,
                                 colorToken: "accentCPU", lineWidth: 1.5, capacity: 2)
        let points = ChartSeries.points(d, in: plot)
        XCTAssertEqual(points[0].y, 50, accuracy: 1e-9, "0 % sits at the bottom of a bottom-left rect")
        XCTAssertEqual(points[1].y, 200, accuracy: 1e-9, "100 % sits at its top")
    }

    /// §6.6 rule 4: the offset advances continuously and each point keeps its measured value.
    func testScrollOffsetShiftsExactlyOneSampleWidthPerInterval() {
        let d = SeriesDescriptor(values: Array(repeating: 42, count: 600), axis: .percent,
                                 colorToken: "accentCPU", lineWidth: 1.5, capacity: 600)
        let width = ChartSeries.sampleWidth(in: plot, capacity: 600)
        XCTAssertEqual(width, 600.0 / 599.0, accuracy: 1e-9)

        let atRest = ChartSeries.points(d, in: plot)
        let halfway = ChartSeries.points(d, in: plot, scrollOffset: width * 0.5)
        let full = ChartSeries.points(d, in: plot, scrollOffset: width)

        XCTAssertEqual(atRest.last!.x - halfway.last!.x, width * 0.5, accuracy: 1e-9)
        XCTAssertEqual(atRest.last!.x - full.last!.x, width, accuracy: 1e-9)
        XCTAssertEqual(atRest.last!.y, halfway.last!.y, "the value does not interpolate — only x moves")
    }

    func testEmptySeriesPlotsNothingRatherThanCrashing() {
        let d = SeriesDescriptor(values: [], axis: .percent, colorToken: "accentCPU",
                                 lineWidth: 1.5, capacity: 600)
        XCTAssertTrue(ChartSeries.points(d, in: plot).isEmpty)
    }

    // MARK: - Auto scale

    /// Without the floor, an idle interface's 40 B/s of background chatter plots at full
    /// height and an idle network looks saturated.
    func testAutoScaleFloorsAtOneKilobytePerSecond() {
        let d = SeriesDescriptor(values: [12, 40, 8], axis: .percent, colorToken: "accentNetwork",
                                 lineWidth: 1.5, capacity: 240)
        XCTAssertEqual(ChartSeries.autoScale([d]).max, 1024, accuracy: 1e-9)
    }

    func testAutoScaleRoundsToOneTwoOrFive() {
        XCTAssertEqual(ChartSeries.niceCeiling(1), 1, accuracy: 1e-9)
        XCTAssertEqual(ChartSeries.niceCeiling(1.4), 2, accuracy: 1e-9)
        XCTAssertEqual(ChartSeries.niceCeiling(3), 5, accuracy: 1e-9)
        XCTAssertEqual(ChartSeries.niceCeiling(6), 10, accuracy: 1e-9)
        XCTAssertEqual(ChartSeries.niceCeiling(12_000), 20_000, accuracy: 1e-9)
        XCTAssertEqual(ChartSeries.niceCeiling(0), 0)
    }

    func testAutoScaleTakesThePeakAcrossEverySeries() {
        let read = SeriesDescriptor(values: [1_000_000], axis: .percent, colorToken: "accentDisk",
                                    lineWidth: 1.5, capacity: 240)
        let write = SeriesDescriptor(values: [3_000_000], axis: .percent, colorToken: "accentDisk",
                                     lineWidth: 1.5, capacity: 240)
        XCTAssertEqual(ChartSeries.autoScale([read, write]).max, 5_000_000, accuracy: 1e-9)
    }

    /// Descriptors carry token names so phase-05's editor can repaint every chart. A hex
    /// literal here is a colour the theme system cannot reach.
    func testDescriptorsCarryTokenNamesNotColours() {
        let source = try? String(
            contentsOfFile: #filePath.replacingOccurrences(
                of: "Tests/GlowTopCoreTests/ChartSeriesTests.swift",
                with: "Sources/GlowTopCore/ChartSeries.swift"
            ),
            encoding: .utf8
        )
        XCTAssertNotNil(source)
        XCTAssertFalse(source!.contains("#39FF14"), "ChartSeries.swift must carry no hex colours")
    }
}
