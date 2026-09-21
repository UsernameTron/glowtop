import Foundation

/// The value→plot mapping every chart in the app shares. SPEC.md §4.4, §4.5, §4.6.
///
/// Eight charts, one routine. The alternative writes the scroll offset, the axis mapping, the
/// clipping and the gradient caching eight times, and gives §6.6's "charts scroll, they do not
/// interpolate" eight places to be got wrong.
///
/// Nothing here imports CoreGraphics: `PlotRect` is four Doubles, so the mapping is exercised
/// by `swift test` with no window and no context.

/// A chart's value axis. §4.4 has two of them on one plot.
public struct ChartAxis: Sendable, Equatable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    /// §4.4's left axis.
    public static let percent = ChartAxis(min: 0, max: 100)
    /// §4.4's right axis and §4.6.6's.
    public static let celsius = ChartAxis(min: 0, max: 110)

    /// 0 at `min`, 1 at `max`, **clamped**.
    ///
    /// The clamp is not defensive tidiness: an unclamped 154 °C reading normalises to 1.4 and
    /// draws a line above its own card and into the neighbouring one, where it is read as the
    /// neighbour's data. §5.6.5 range-checks at the provider; this range-checks at the plot.
    public func normalise(_ value: Double) -> Double {
        guard max > min else { return 0 }
        return Swift.min(Swift.max((value - min) / (max - min), 0), 1)
    }
}

/// A rectangle in points, bottom-left origin. Whether the drawing context is flipped is the
/// App target's business and nothing here knows about it.
public struct PlotRect: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// How a series is filled beneath its line.
public enum Fill: Sendable, Equatable {
    /// §4.4's utilization: a gradient from `topOpacity` at the line down to 0 at the baseline.
    case gradient(topOpacity: Double)
    /// §4.5's stacked layers: a flat fill of the band between this path and the one below.
    case solid(opacity: Double)
}

/// One line on one chart. SPEC.md §4.4's table, generalised.
public struct SeriesDescriptor: Sendable, Equatable {
    /// Oldest first, in **native units** — percent points, °C, bytes per second, bytes.
    /// Never pre-normalised: a series carrying 0-1 values cannot be re-axised and cannot be
    /// range-checked against the quantity it claims to be.
    public let values: [Double]
    public let axis: ChartAxis
    /// A `Theme` property name, never a hex literal. §7.2.
    public let colorToken: String
    public let opacity: Double
    public let lineWidth: Double
    /// `nil` solid; `[3, 2]` for §4.6.1's write series and §4.6.2's sent series.
    public let dash: [Double]?
    public let fill: Fill?
    /// The ring buffer's capacity (§6.4), not `values.count`. A partly-filled buffer must plot
    /// against the full 60 s width rather than stretch across it.
    public let capacity: Int

    public init(
        values: [Double], axis: ChartAxis, colorToken: String, opacity: Double = 1.0,
        lineWidth: Double, dash: [Double]? = nil, fill: Fill? = nil, capacity: Int
    ) {
        self.values = values
        self.axis = axis
        self.colorToken = colorToken
        self.opacity = opacity
        self.lineWidth = lineWidth
        self.dash = dash
        self.fill = fill
        self.capacity = capacity
    }
}

public enum ChartSeries {
    /// One point per sample, newest at the right edge.
    ///
    /// x is indexed against `capacity`, not `values.count`: a buffer holding 10 of 600 samples
    /// occupies the rightmost 10/600 of the plot and leaves the rest empty, which is §3.6
    /// item 3's "charts fill left-to-right as history accumulates". Indexing against
    /// `values.count` instead draws a fully-populated chart four seconds after launch — a
    /// picture that is a lie about its own time base, and one that looks right.
    ///
    /// `scrollOffset` is the continuous sub-sample shift in points (§6.6 rule 4): the x-offset
    /// advances smoothly between samples and each plotted point sits at its measured value.
    /// No smoothing, no resampling, no averaging of adjacent slots — that would flatten
    /// exactly the single-sample spikes worth seeing.
    public static func points(
        _ descriptor: SeriesDescriptor, in rect: PlotRect, scrollOffset: Double = 0
    ) -> [(x: Double, y: Double)] {
        let capacity = descriptor.capacity
        guard capacity > 1, !descriptor.values.isEmpty else { return [] }
        let step = rect.width / Double(capacity - 1)
        let firstSlot = capacity - descriptor.values.count

        return descriptor.values.enumerated().map { index, value in
            let x = rect.x + step * Double(firstSlot + index) - scrollOffset
            let y = rect.y + rect.height * descriptor.axis.normalise(value)
            return (x: x, y: y)
        }
    }

    /// Points of plot width per sample. The caller multiplies this by §6.6's interpolation
    /// fraction to get `scrollOffset`.
    public static func sampleWidth(in rect: PlotRect, capacity: Int) -> Double {
        guard capacity > 1 else { return 0 }
        return rect.width / Double(capacity - 1)
    }

    /// An axis for the byte-rate charts (§4.6.1, §4.6.2), which have no fixed ceiling.
    ///
    /// Max across every series, rounded up to the next 1, 2 or 5 × 10ⁿ, with a floor of
    /// 1 KB/s. The floor is the whole point: without it an idle interface's 40 B/s of
    /// background chatter auto-scales to full height, and an idle network looks saturated —
    /// a plausible picture built from correct numbers, which is this project's recurring
    /// defect shape.
    public static func autoScale(_ series: [SeriesDescriptor], floor: Double = 1024) -> ChartAxis {
        let peak = series.flatMap(\.values).max() ?? 0
        return ChartAxis(min: 0, max: Swift.max(niceCeiling(peak), floor))
    }

    /// The next 1, 2 or 5 × 10ⁿ at or above `value`.
    static func niceCeiling(_ value: Double) -> Double {
        guard value > 0, value.isFinite else { return 0 }
        let exponent = (log10(value)).rounded(.down)
        let magnitude = pow(10, exponent)
        let mantissa = value / magnitude
        let stepped: Double = if mantissa <= 1 { 1 } else if mantissa <= 2 { 2 }
            else if mantissa <= 5 { 5 } else { 10 }
        return stepped * magnitude
    }
}
