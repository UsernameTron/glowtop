import Foundation

/// The store→view projection for §14.1's Power & Freq pane. SPEC.md §14.1.
///
/// Projects **beside** `SummaryModel.project`, not through it: every series on this pane
/// is computed from `SummaryFrames` fields the Summary pane does not read (phase-10's
/// handoff). What it does share is §4.9's one-owner rule — every string below goes
/// through `Format`, and this file carries its own copy of the grep test that holds it,
/// because `SummaryModelTests`' copy reads `SummaryModel.swift` only.

/// One bar of §14.1's card 2. `share` is 0...1 of wall time over the buffer's current
/// span; `label` is `nil` on a bar the sparse rule does not label.
public struct HistogramBin: Sendable, Equatable {
    public let share: Double
    public let opacity: Double
    public let label: String?

    public init(share: Double, opacity: Double, label: String?) {
        self.share = share
        self.opacity = opacity
        self.label = label
    }
}

/// Everything cards 1 and 2 need for one cluster, so the view reads and never derives.
public struct ClusterColumn: Sendable, Equatable {
    /// `P0`, `P1`, `E` -- §14.1's locked identity, and the key the view aligns by.
    public let label: String
    /// `P0 · 5 cores  3.92 GHz`, or `···`/`—` in place of the value per §4.8.
    public let caption: String
    /// `accentClock` for P clusters, `accentGPU` for E (§14.1). A §7.2 token name.
    public let accentToken: String
    /// Card 1's stacked bands, **cumulative**, idle first at 8 % then active states
    /// ascending on the ramp. Empty when this column is not live.
    public let residencySeries: [SeriesDescriptor]
    /// Card 1's average-frequency line on this column's own right axis. `nil` when the
    /// column is not live or the table did not pair.
    public let averageSeries: SeriesDescriptor?
    /// This column's right axis, `0...maxMegahertz`. `nil` when there is no line.
    public let megahertzAxis: ChartAxis?
    /// The three right-axis tick labels, bottom to top: `0`, `max/2`, `max`, through
    /// §4.9's frequency rule. Empty when `megahertzAxis` is `nil`.
    public let megahertzLabels: [String]
    /// Card 2's bars, ascending MHz with DOWN/IDLE leftmost. Empty when not live.
    public let bins: [HistogramBin]
    /// §4.8 for this column alone (D-11). `.unavailable` carries `No {key} table`.
    public let state: CardState
    /// The centred body text a non-live column shows: `No voltage-states1-sram table`
    /// when unavailable, `""` otherwise.
    public let unavailableText: String

    public init(
        label: String, caption: String, accentToken: String,
        residencySeries: [SeriesDescriptor], averageSeries: SeriesDescriptor?,
        megahertzAxis: ChartAxis?, megahertzLabels: [String], bins: [HistogramBin],
        state: CardState, unavailableText: String
    ) {
        self.label = label
        self.caption = caption
        self.accentToken = accentToken
        self.residencySeries = residencySeries
        self.averageSeries = averageSeries
        self.megahertzAxis = megahertzAxis
        self.megahertzLabels = megahertzLabels
        self.bins = bins
        self.state = state
        self.unavailableText = unavailableText
    }
}

public struct PowerFreqModel: Sendable, Equatable {
    /// §14.1's locked column order, P0 then P1 then E, regardless of enumeration order.
    public let columns: [ClusterColumn]
    /// Card 2's footer: the buffer's actual span, `12 s` growing to `60 s`.
    public let spanFooter: String
    /// §4.8 for the pane as a whole -- `.unavailable` only under §13.7.3's flag or a
    /// failed subscription (PWR-05); a single column's failure is `ClusterColumn.state`.
    public let paneState: CardState
    /// §4.8 for cards 1 and 2 as whole cards: the **frequency** frame's own state, the way
    /// `power.state` is the energy frame's. Wave-3 finding: when the frequency subscription
    /// alone fails, `paneState` reads live (energy still works) and `columns` is empty, so
    /// the view had nothing to draw `Unavailable on this Mac` from. The two providers fail
    /// independently and each card pair reads its own.
    public let frequencyState: CardState
    /// Card 3's chrome and §4.8 state, through `CardChrome.applyCardText` like every other
    /// card in the app. Its `state` is the **energy** frame's, not the frequency frame's:
    /// the two providers fail independently and a reader is entitled to see the one that
    /// still works. The bands live on `powerSeries`, not on `power.series`.
    public let power: CardModel
    /// Card 3's four cumulative bands, bottom to top CPU, GPU, ANE, DRAM (§14.1). Empty
    /// when the energy frame is not live.
    public let powerSeries: [SeriesDescriptor]
    /// `ChartSeries.autoScale` over the four, floor 5 W. `nil` when there is nothing to plot.
    public let powerAxis: ChartAxis?
    /// The five left-axis tick labels, bottom to top, through §4.9's power rule.
    public let powerAxisLabels: [String]
    /// §5.6.3's private-API provenance note (the `uncertain` tag was lifted in 1.1.2), for the
    /// card's tooltip.
    public let powerTooltip: String

    public init(
        columns: [ClusterColumn], spanFooter: String, paneState: CardState,
        frequencyState: CardState, power: CardModel, powerSeries: [SeriesDescriptor],
        powerAxis: ChartAxis?, powerAxisLabels: [String], powerTooltip: String
    ) {
        self.columns = columns
        self.spanFooter = spanFooter
        self.paneState = paneState
        self.frequencyState = frequencyState
        self.power = power
        self.powerSeries = powerSeries
        self.powerAxis = powerAxis
        self.powerAxisLabels = powerAxisLabels
        self.powerTooltip = powerTooltip
    }

    /// `paused` is accepted and carried, not read: §6.8's pause stops the display link and
    /// the loops, and the projection of a paused pane is the last projection, which is
    /// correct. Stated so it does not read as an oversight.
    public static func project(_ frames: SummaryFrames, paused: Bool = false) -> PowerFreqModel {
        // §4.8's whole-card treatment: when the frequency frame is not live the columns and
        // their captions are omitted entirely, and the view draws its centred
        // `Unavailable on this Mac` from the card's own state.
        let frequencyState = CardState(frames.frequency.state)
        let energyState = CardState(frames.energy.state)
        let columns = frequencyState == .live ? projectColumns(frames) : []
        let (power, powerSeries, powerAxis, powerAxisLabels) = projectPower(frames)

        // The whole-pane rule: the two providers fail independently and the pane must not
        // go dark because one did. Under `GLOWTOP_DISABLE_PRIVATE=1` **both** are
        // unavailable and all three cards read `Unavailable on this Mac` (PWR-05, D-27),
        // which is the case this rule is written for.
        let paneState: CardState = if frequencyState.isUnavailable && energyState.isUnavailable {
            frequencyState
        } else if frequencyState == .warming || energyState == .warming {
            .warming
        } else {
            .live
        }

        return PowerFreqModel(
            columns: columns,
            spanFooter: spanFooter(sampleCount: frames.clusterHistory.first?.residency.count ?? 0),
            paneState: paneState, frequencyState: frequencyState,
            power: power, powerSeries: powerSeries, powerAxis: powerAxis,
            powerAxisLabels: powerAxisLabels, powerTooltip: powerTooltip
        )
    }

    // MARK: - The ramp, stated once and used twice (cards 1 and 2)

    /// §4.3.1's unlit tone, reused rather than a second unlit convention invented.
    static let idleOpacity = 0.08

    /// §14.1's opacity ramp. `rank` is 0 for the lowest **active** state; `activeCount` is
    /// how many active states there are. DOWN/IDLE does not go through here -- it is
    /// `idleOpacity`. `25 + rank / (N − 1) × 75` percent; a single active state is 100.
    static func rampOpacity(rank: Int, activeCount: Int) -> Double {
        guard activeCount > 1 else { return 1.0 }
        return (25 + (Double(rank) / Double(activeCount - 1)) * 75) / 100
    }

    /// One opacity per state, in `states`' order: `idleOpacity` for idle states, the ramp
    /// for active ones ranked among active states only.
    static func opacities(for states: [ClusterFrequency.State]) -> [Double] {
        let activeCount = states.filter { !$0.isIdle }.count
        var activeRank = 0
        return states.map { state in
            if state.isIdle { return idleOpacity }
            defer { activeRank += 1 }
            return rampOpacity(rank: activeRank, activeCount: activeCount)
        }
    }

    // MARK: - The histogram arithmetic

    /// §14.1's card 2: each state's share of wall time over the buffer's current span.
    ///
    ///     share[s] = ( Σ over buffered samples of fraction_i[s] ) / n
    ///
    /// Every sample's fractions sum to 1 by construction (they are residency shares of one
    /// interval), so the shares sum to 1 and the bars total 100 % -- which is what makes
    /// "a mostly-asleep cluster looks asleep" (D-13) true with no normalisation step. Every
    /// sample is one `hz2` tick, so interval weighting is a no-op with a divide in it and is
    /// not done. A sample whose state count differs from `stateCount` is **skipped**: a
    /// `voltage-states` table change mid-buffer would otherwise index out of range.
    /// Returns an empty array when nothing is countable.
    static func histogramShares(_ residency: [[Double]], stateCount: Int) -> [Double] {
        let usable = residency.filter { $0.count == stateCount }
        guard !usable.isEmpty, stateCount > 0 else { return [] }
        var sums = [Double](repeating: 0, count: stateCount)
        for sample in usable {
            for (index, fraction) in sample.enumerated() { sums[index] += fraction }
        }
        return sums.map { $0 / Double(usable.count) }
    }

    /// §14.1: at or below 8 bars, label the first, the middle and the last; above 8, label
    /// every 4th (`index % 4 == 0`) plus the last.
    static func labelledIndices(barCount: Int) -> Set<Int> {
        guard barCount > 0 else { return [] }
        if barCount <= 8 { return [0, barCount / 2, barCount - 1] }
        return Set((0..<barCount).filter { $0 % 4 == 0 }).union([barCount - 1])
    }

    /// §14.1's card-2 footer. The buffer is `hz2`, so 120 samples is 60 s and 24 is 12 s.
    /// Rounded rather than truncated so 23 samples reads `12 s`, not `11 s`.
    static func spanFooter(sampleCount: Int) -> String {
        "\(min(60, Int((Double(sampleCount) * 0.5).rounded()))) s"
    }

    // MARK: - Cards 1 and 2

    /// The Copywriting Contract's column caption: `{label} · {N} cores  {value}`, with the
    /// two spaces before the value in the literal (D-14). Live: §4.9's frequency rule, or
    /// `Format.unknown` when the cluster spent the whole interval power-gated and has no
    /// average to show -- a live column with no active time, not D-11's unavailable one.
    /// Warming: `···`. Unavailable: `Format.unknown`.
    static func caption(_ cluster: ClusterFrequency, state: CardState) -> String {
        let value = state == .live
            ? cluster.averageMegahertz.map { Format.frequency(megahertz: $0) } ?? Format.unknown
            : SummaryModel.placeholder(state)
        return "\(cluster.label) · \(cluster.coreCount) cores  \(value)"
    }

    /// One `ClusterColumn` per entry of the live frame's `clusters`, in that array's order
    /// (the provider already sorted it P0, P1, E).
    static func projectColumns(_ frames: SummaryFrames) -> [ClusterColumn] {
        (frames.frequency.current?.clusters ?? []).map { cluster in
            // D-11: this column alone is unavailable when its table did not pair. The
            // reason is §5.0.5's, the same one the provider returns one scope up.
            let state: CardState = cluster.tableSource == nil
                ? .unavailable(reason: "key not present") : .live
            let live = state == .live
            let accent = cluster.label.hasPrefix("E") ? "accentGPU" : "accentClock"
            // By name, never by index (§6.4's identity rule for the cluster buffers).
            let history = frames.clusterHistory.first { $0.name == cluster.name }
            let stateCount = cluster.states.count
            let stateOpacities = opacities(for: cluster.states)

            // D-12, D-13, D-17: one cumulative band per state, idle first at 8 % then the
            // ramp. Cumulative in the values, exactly as `projectMemory` builds §4.5's --
            // the renderer fills between adjacent paths and knows nothing of stacking.
            var residencySeries: [SeriesDescriptor] = []
            let usable = live ? (history?.residency ?? []).filter { $0.count == stateCount } : []
            if !usable.isEmpty {
                var cumulative = [[Double]](repeating: [], count: stateCount)
                for sample in usable {
                    var running = 0.0
                    for (index, fraction) in sample.enumerated() {
                        running += fraction
                        cumulative[index].append(running * 100)
                    }
                }
                residencySeries = zip(cumulative, stateOpacities).map { values, opacity in
                    SeriesDescriptor(
                        values: values, axis: .percent, colorToken: accent, opacity: opacity,
                        lineWidth: 0, fill: .solid(opacity: opacity), capacity: 120
                    )
                }
            }

            // D-14: the average line on this column's own right axis -- per column, never
            // shared, because each cluster's table maximum is its own.
            let megahertzAxis = live ? cluster.maxMegahertz.map { ChartAxis(min: 0, max: $0) } : nil
            let averageSeries = megahertzAxis.map { axis in
                SeriesDescriptor(
                    values: history?.averageMegahertz ?? [], axis: axis, colorToken: accent,
                    lineWidth: 1.5, capacity: 120
                )
            }
            let megahertzLabels = megahertzAxis.map { axis in
                [0, axis.max / 2, axis.max].map { Format.frequency(megahertz: $0) }
            } ?? []

            // D-15: the bars, in the states' own order (idle first, then ascending), which
            // is already the locked "DOWN/IDLE leftmost, then ascending MHz". A labelled
            // idle bar prints `Format.unknown` rather than a frequency it does not have.
            let shares = live ? histogramShares(history?.residency ?? [], stateCount: stateCount) : []
            let labelled = labelledIndices(barCount: shares.count)
            let bins = shares.indices.map { index in
                HistogramBin(
                    share: shares[index], opacity: stateOpacities[index],
                    label: labelled.contains(index)
                        ? cluster.states[index].megahertz.map { Format.frequency(megahertz: $0) } ?? Format.unknown
                        : nil
                )
            }

            return ClusterColumn(
                label: cluster.label,
                caption: caption(cluster, state: state),
                accentToken: accent,
                residencySeries: residencySeries,
                averageSeries: averageSeries,
                megahertzAxis: megahertzAxis,
                megahertzLabels: megahertzLabels,
                bins: bins,
                state: state,
                unavailableText: live ? "" : "No \(cluster.missingTableKey ?? "voltage-states") table"
            )
        }
    }

    // MARK: - Card 3

    /// §5.6.3 as amended for 1.1.2: the `uncertain` tag is lifted, the API is still private.
    static let powerTooltip = "Package power is read via a private, undocumented API. "
        + "Its unit was confirmed against `powermetrics` on 2026-09-21 (CPU and GPU, "
        + "second by second); the app itself never runs `powermetrics` and never asks for root."

    /// §14.1's card 3. `Format.power` produces `8.4 W`; the footer's own `W` appears once at
    /// the end, so each channel's value goes through a one-decimal helper rather than
    /// `Format.power` -- which would print four `W`s. The helper is `Format.power` with its
    /// suffix dropped, spelled once here rather than four times inline.
    static func wattsValue(_ watts: Double?) -> String {
        guard let watts else { return Format.unknown }
        return String(Format.power(watts: watts).dropLast(2))   // drops " W"
    }

    static func projectPower(
        _ frames: SummaryFrames
    ) -> (card: CardModel, series: [SeriesDescriptor], axis: ChartAxis?, labels: [String]) {
        let state = CardState(frames.energy.state)
        let sample = frames.energy.current
        // D-03, D-05: bottom to top CPU, GPU, ANE, DRAM -- the footer's left-to-right order.
        let channels: [(name: String, token: String, current: Double?, history: [Double])] = [
            ("CPU", "accentCPU", sample?.cpuWatts, frames.cpuWattsHistory),
            ("GPU", "accentGPU", sample?.gpuWatts, frames.gpuWattsHistory),
            ("ANE", "accentNPU", sample?.aneWatts, frames.aneWattsHistory),
            ("DRAM", "accentMemory", sample?.dramWatts, frames.dramWattsHistory),
        ]

        // The headline is the stack's top edge -- the four-channel total, DRAM included
        // (D-03) -- and deliberately not `EnergySample.watts`, §4.6.3's three-channel sum
        // (D-07): a headline built from that while the stack includes DRAM is wrong by
        // exactly one band, always, and looks right. Stalled holds the last value, which
        // `CardChrome.applyCardText` dims (§4.8).
        let total = channels.reduce(0) { $0 + ($1.current ?? 0) }
        let headline = (state == .live || state == .stalled) && sample != nil
            ? Format.power(watts: total) : SummaryModel.placeholder(state)
        let footer = state == .live && sample != nil
            ? channels.map { "\($0.name) \(wattsValue($0.current))" }.joined(separator: " · ") + " W"
            : ""

        // Cumulative in the values, exactly as `projectMemory` builds §4.5's. A channel
        // whose *current* sample is `nil` is omitted entirely and the layers above close up
        // beneath it -- `wattsValue` prints `—` for it in the footer, so the reader sees one
        // absence in two places rather than a zero-height band that reads as "measured
        // zero". Truncated to the shortest history first, so a channel that started one
        // tick late cannot mis-align the stack.
        var series: [SeriesDescriptor] = []
        var axis: ChartAxis?
        let present = channels.filter { $0.current != nil }
        let length = present.map(\.history.count).min() ?? 0
        if state == .live, length > 0 {
            var running = [Double](repeating: 0, count: length)
            let raw = present.map { channel -> SeriesDescriptor in
                running = zip(running, channel.history.suffix(length)).map(+)
                return SeriesDescriptor(
                    values: running, axis: .percent, colorToken: channel.token, opacity: 1.0,
                    lineWidth: 0, fill: .solid(opacity: 1.0), capacity: 60
                )
            }
            // `floor: 5`, not `autoScale`'s default: that default is the byte-rate charts'
            // 1024, against which a 4 W machine plots one pixel tall.
            let scale = ChartSeries.autoScale(raw, floor: 5)
            series = raw.map { SummaryModel.rescaled($0, to: scale) }
            axis = scale
        }
        let labels = axis.map { axis in
            [0, 0.25, 0.5, 0.75, 1.0].map { Format.power(watts: axis.max * $0) }
        } ?? []

        let card = CardModel(title: "PACKAGE POWER", headline: headline, footer: footer,
                             colorToken: "accentEnergy", state: state)
        return (card, series, axis, labels)
    }
}
