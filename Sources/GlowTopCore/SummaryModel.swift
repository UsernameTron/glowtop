import Foundation

/// The store→view projection for the Summary pane. SPEC.md §4.
///
/// One pure function of frames and history. Every number on the pane goes through `Format`
/// here, and **no formatting decision lives in `GlowTopApp`** — §4.9 opens by saying no two
/// panes format the same quantity differently, and the only way to hold that is for one file
/// to decide. It also means every §4.8 state and every §4.7 phrase is testable with no window.

/// §4.8's three appearances, plus live. Mirrors `MetricState`.
public enum CardState: Sendable, Equatable {
    case live
    /// Provider is alive; a delta needs two samples and only one exists. Headline `···`.
    case warming
    /// Cannot read this hardware on this machine. Headline `—`, plot area omitted entirely.
    case unavailable(reason: String)
    /// No sample in over 2 s. Holds the last value at 35 % opacity — dimming rather than
    /// blanking, because blanking destroys information and full strength is a lie.
    case stalled

    public init(_ state: MetricState) {
        switch state {
        case .live: self = .live
        case .warming: self = .warming
        case .unavailable(let reason): self = .unavailable(reason: reason)
        case .stalled: self = .stalled
        }
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// One segmented meter. §4.3.1, §4.3.2's strip, §4.5's horizontal bar.
public struct MeterModel: Sendable, Equatable {
    /// `nil` unless live. Never 0 for an unavailable metric: a zero-height lit run is
    /// indistinguishable from a real zero, which is §4.8's central failure.
    public let fraction: Double?
    public let label: String
    public let caption: String
    public let colorToken: String
    public let state: CardState

    public init(fraction: Double?, label: String, caption: String, colorToken: String, state: CardState) {
        self.fraction = fraction
        self.label = label
        self.caption = caption
        self.colorToken = colorToken
        self.state = state
    }
}

/// One card. §4.2's chrome plus whatever the card draws inside it.
public struct CardModel: Sendable, Equatable {
    public let title: String
    public let headline: String
    public let footer: String
    public let colorToken: String
    public let state: CardState
    public let series: [SeriesDescriptor]
    /// `nil` for charts on a fixed axis (§4.4's 0-100). Set for the auto-scaled byte-rate
    /// tiles so the view does not re-derive it.
    public let axis: ChartAxis?
    /// §4.4's right-hand axis, set to `.celsius` when and only when the temperature series is
    /// present -- both driven from one expression at the call site so a chart cannot end up
    /// with an axis and no line, or a line with no axis.
    public let rightAxis: ChartAxis?
    /// §4.10: Simple mode's one-word judgement. Always `nil` in Technical, and `nil` in Simple
    /// for any card that is not live -- a verdict on a reading that does not exist would be
    /// §4.8's violation in a friendlier font.
    public let verdict: Verdict?
    /// §4.10: Simple mode's hover sentence; empty in Technical.
    public let explanation: String

    public init(
        title: String, headline: String, footer: String, colorToken: String,
        state: CardState, series: [SeriesDescriptor] = [], axis: ChartAxis? = nil,
        rightAxis: ChartAxis? = nil, verdict: Verdict? = nil, explanation: String = ""
    ) {
        self.verdict = verdict
        self.explanation = explanation
        self.title = title
        self.headline = headline
        self.footer = footer
        self.colorToken = colorToken
        self.state = state
        self.series = series
        self.axis = axis
        self.rightAxis = rightAxis
    }
}

/// One row of §4.3.3's card, already formatted.
public struct ProcessRowModel: Sendable, Equatable {
    public let pid: Int32
    public let pidText: String
    public let name: String
    public let cpu: String
    public let gpu: String
    public let memory: String

    public init(pid: Int32, pidText: String, name: String, cpu: String, gpu: String, memory: String) {
        self.pid = pid
        self.pidText = pidText
        self.name = name
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
    }
}

/// §4.7's status bar.
public struct StatusModel: Sendable, Equatable {
    /// The whole leading string, e.g. `Native providers healthy · 1138 processes · Generation 4218`.
    public let leading: String
    /// The health phrase alone, which is the part that carries a colour.
    public let phrase: String
    public let phraseToken: String
    /// One line per unavailable provider, naming it and its §5.0.5 reason.
    public let tooltip: String

    public init(leading: String, phrase: String, phraseToken: String, tooltip: String) {
        self.leading = leading
        self.phrase = phrase
        self.phraseToken = phraseToken
        self.tooltip = tooltip
    }
}

public struct SummaryModel: Sendable, Equatable {
    /// §4.3.1, in order: CPU, Clock, Temp, GPU.
    public let meters: [MeterModel]
    public let cpuOverview: CardModel
    /// §4.3.2's strip, one per logical core.
    public let perCore: [MeterModel]
    public let processes: CardModel
    public let processRows: [ProcessRowModel]
    public let memory: CardModel
    public let memoryMeter: MeterModel
    /// §4.6's six, in order: Disks, Network, Energy, GPU 0, NPU 0, Thermals.
    public let tiles: [CardModel]
    public let status: StatusModel

    public init(
        meters: [MeterModel], cpuOverview: CardModel, perCore: [MeterModel],
        processes: CardModel, processRows: [ProcessRowModel], memory: CardModel,
        memoryMeter: MeterModel, tiles: [CardModel], status: StatusModel
    ) {
        self.meters = meters
        self.cpuOverview = cpuOverview
        self.perCore = perCore
        self.processes = processes
        self.processRows = processRows
        self.memory = memory
        self.memoryMeter = memoryMeter
        self.tiles = tiles
        self.status = status
    }
}

// MARK: - Projection

extension SummaryModel {
    /// §4.4's right-hand axis gridlines, alongside `SummaryPaneView`'s own `cpuGridlines` for
    /// the left axis. Consumed only when `cpuOverview.rightAxis` is non-nil.
    public static let cpuRightGridlines: [Double] = [0, 55, 110]

    /// §4.5's timeline layers 3 and 4, named literally in §4.5 with no §7.2 token.
    public static let memoryCompressedToken = "specLiteral.memoryCompressed"
    public static let memoryCachedToken = "specLiteral.memoryCached"

    public static func project(
        _ frames: SummaryFrames, paused: Bool = false
    ) -> SummaryModel {
        let cpuState = CardState(frames.cpu.state)
        let cpu = frames.cpu.current
        let frequencyState = CardState(frames.frequency.state)
        let frequency = frames.frequency.current
        let thermalState = CardState(frames.thermal.state)
        let thermal = frames.thermal.current
        let gpuState = CardState(frames.gpu.state)
        let gpu = frames.gpu.current

        // §4.3.1's four meters. §5.9.3: Clock's label is `Auto` whenever a reading exists --
        // there is no user-selectable governor on this platform. §5.8.3's red-above-100°C
        // rule is a token swap here, not a colour override in the view (§7.1's boundary).
        let meters: [MeterModel] = [
            MeterModel(
                fraction: cpuState == .live ? cpu?.total : nil,
                label: cpuState == .live ? Format.percent(fraction: cpu?.total ?? 0) : placeholder(cpuState),
                caption: "CPU", colorToken: "accentCPU", state: cpuState
            ),
            MeterModel(
                fraction: frequencyState == .live ? frequency?.fraction : nil,
                label: frequencyState == .live ? "Auto" : placeholder(frequencyState),
                caption: "CLOCK", colorToken: "accentClock", state: frequencyState
            ),
            MeterModel(
                fraction: thermalState == .live ? thermal.map { ChartAxis.celsius.normalise($0.maxCelsius) } : nil,
                label: thermalState == .live ? Format.temperature(celsius: thermal?.maxCelsius ?? 0)
                    : placeholder(thermalState),
                caption: "TEMP",
                colorToken: thermalState == .live && (thermal?.maxCelsius ?? 0) > 100
                    ? "critical" : "accentThermal",
                state: thermalState
            ),
            MeterModel(
                fraction: gpuState == .live ? gpu?.utilization : nil,
                label: gpuState == .live ? Format.percent(fraction: gpu?.utilization ?? 0) : placeholder(gpuState),
                caption: "GPU", colorToken: "accentGPU", state: gpuState
            ),
        ]

        // §4.3.2's two series plus §4.4's temperature series, which arrives only when the
        // thermal frame is live -- an unavailable series takes its line AND its right-hand
        // axis with it ("no flat line at zero, which would read as a real measurement of
        // zero"), so both are omitted together, driven from the same condition.
        var cpuSeries: [SeriesDescriptor] = cpuState == .live ? [
            SeriesDescriptor(
                values: frames.cpuTotal.map { $0 * 100 }, axis: .percent,
                colorToken: "accentCPU", lineWidth: 1.5,
                fill: .gradient(topOpacity: 0.22), capacity: 600
            ),
            SeriesDescriptor(
                values: frames.cpuSystem.map { $0 * 100 }, axis: .percent,
                colorToken: "accentKernel", lineWidth: 1.0, capacity: 600
            ),
        ] : []
        var cpuRightAxis: ChartAxis?
        if thermalState == .live, let hottest = frames.temperatureHistory.first, !hottest.isEmpty {
            cpuSeries.append(SeriesDescriptor(
                values: hottest, axis: .celsius, colorToken: "accentThermal",
                lineWidth: 1.5, capacity: 60
            ))
            cpuRightAxis = .celsius
        }

        let cpuOverview = CardModel(
            title: "CPU OVERVIEW",
            headline: cpuState == .live ? Format.percent(fraction: cpu?.total ?? 0) : placeholder(cpuState),
            footer: cpu.map { "\($0.logicalCount) logical processors · Speed Apple managed" } ?? "",
            colorToken: "accentCPU",
            state: cpuState,
            series: cpuSeries,
            axis: .percent,
            rightAxis: cpuRightAxis
        )

        let perCore: [MeterModel] = (cpu?.perCore ?? []).enumerated().map { index, value in
            MeterModel(
                fraction: cpuState == .live ? value : nil, label: "",
                caption: index < (cpu?.performanceCores ?? 0) ? "P" : "E",
                colorToken: "accentCPU", state: cpuState
            )
        }

        let (processes, processRows) = projectProcesses(frames.processes)
        let (memoryCard, memoryMeter) = projectMemory(frames)
        let tiles = projectTiles(frames)
        let status = projectStatus(frames, paused: paused)

        return SummaryModel(
            meters: meters, cpuOverview: cpuOverview, perCore: perCore,
            processes: processes, processRows: processRows, memory: memoryCard,
            memoryMeter: memoryMeter, tiles: tiles, status: status
        )
    }

    /// §4.8's headline column: `···` warming, `—` unavailable. Never `0`.
    static func placeholder(_ state: CardState) -> String {
        state == .warming ? "···" : Format.unknown
    }

    // MARK: Processes

    static func projectProcesses(
        _ frame: MetricStore.Frame<ProcessSample>
    ) -> (CardModel, [ProcessRowModel]) {
        let state = CardState(frame.state)
        let sample = frame.current

        // `totalCount`, never `inspectableCount`. About 40 % of PIDs refuse inspection
        // unprivileged (§5.5.1), so the inspectable figure is self-consistent, plausible, and
        // covers 60 % of the machine — the defect phase-02 already paid for once.
        let headline = sample.map { "\(Format.count($0.totalCount)) total" } ?? placeholder(state)

        let rows = (sample?.rows.prefix(12) ?? []).map { row in
            ProcessRowModel(
                pid: row.pid,
                pidText: String(row.pid),
                name: row.name,
                cpu: row.cpuPercent.map { Format.percent(points: $0) } ?? Format.unknown,
                // §4.3.3's GPU column. Per-process GPU is phase-03.1's research item; until
                // there is a source it reads `—` rather than 0.0 %.
                gpu: row.gpuPercent.map { Format.percent(points: $0) } ?? Format.unknown,
                memory: Format.bytes(row.residentBytes)
            )
        }

        return (
            CardModel(title: "TOP CPU PROCESSES", headline: headline, footer: "",
                      colorToken: "accentCPU", state: state),
            Array(rows)
        )
    }

    // MARK: Memory

    static func projectMemory(_ frames: SummaryFrames) -> (CardModel, MeterModel) {
        let state = CardState(frames.memory.state)
        let sample = frames.memory.current
        let fraction = sample.flatMap { $0.total > 0 ? Double($0.resident) / Double($0.total) : nil }

        let headline: String
        let footer: String
        if state == .live, let sample {
            // §5.2.3: the word is "resident", never "used".
            headline = "\(Format.bytes(sample.resident)) resident / \(Format.bytes(sample.total))"
            footer = "Reclaimable \(Format.bytes(sample.reclaimable)) · "
                + "Free \(Format.bytes(sample.free)) · Swap \(Format.bytes(sample.swapUsed))"
        } else {
            headline = placeholder(state)
            footer = ""
        }

        // §4.5's four layers, emitted **cumulative**. Stacking is a property of the values,
        // not of the renderer: the renderer fills the band between adjacent paths without
        // knowing what stacking is. Raw values would overlap, so the visible ceiling would be
        // max(layer) rather than sum(layers) and the machine would look far emptier than it
        // is — while looking like a tidy chart.
        let history = frames.memoryHistory
        let axis = ChartAxis(min: 0, max: Double(sample?.total ?? 1))
        let layers: [(token: String, opacity: Double, value: (MemorySample) -> UInt64)] = [
            ("accentMemory", 0.90, { $0.wired }),
            ("accentMemory", 0.60, { $0.wired &+ $0.active }),
            (memoryCompressedToken, 0.55, { $0.wired &+ $0.active &+ $0.compressed }),
            (memoryCachedToken, 0.40, { $0.wired &+ $0.active &+ $0.compressed &+ $0.reclaimable }),
        ]

        var series: [SeriesDescriptor] = []
        if state == .live, !history.isEmpty {
            series = layers.map { layer in
                SeriesDescriptor(
                    values: history.map { Double(layer.value($0)) }, axis: axis,
                    colorToken: layer.token, opacity: layer.opacity, lineWidth: 0,
                    fill: .solid(opacity: layer.opacity), capacity: 600
                )
            }
            // §4.5: swap is not stacked. It is an event worth noticing, not a fraction to
            // blend in, so it is a 1 pt line on the same axis drawn above the fills.
            series.append(SeriesDescriptor(
                values: history.map { Double($0.swapUsed) }, axis: axis,
                colorToken: "critical", lineWidth: 1.0, capacity: 600
            ))
        }

        return (
            CardModel(title: "MEMORY UTILIZATION", headline: headline, footer: footer,
                      colorToken: "accentMemory", state: state, series: series, axis: axis),
            MeterModel(fraction: state == .live ? fraction : nil, label: "", caption: "",
                       colorToken: "accentMemory", state: state)
        )
    }

    // MARK: Tiles

    static func projectTiles(_ frames: SummaryFrames) -> [CardModel] {
        let gpuState = CardState(frames.gpu.state)
        let gpu = frames.gpu.current
        let thermalState = CardState(frames.thermal.state)
        let thermal = frames.thermal.current

        // §4.6.1. §4.6.1's example footer names a volume (`Macintosh HD`) that §5.3 cannot
        // source: the provider sums every IOBlockStorageDriver on the machine and carries no
        // statfs. Labelling a whole-machine total with one volume's name is a wrong number
        // rather than a missing one, so the footer names the device count instead.
        let diskState = CardState(frames.disk.state)
        let disk = frames.disk.current
        let diskSeries: [SeriesDescriptor] = diskState == .live && !frames.diskHistory.isEmpty ? [
            SeriesDescriptor(values: frames.diskHistory.map(\.readBytesPerSecond), axis: .percent,
                             colorToken: "accentDisk", lineWidth: 1.5, capacity: 240),
            SeriesDescriptor(values: frames.diskHistory.map(\.writeBytesPerSecond), axis: .percent,
                             colorToken: "accentDisk", opacity: 0.6, lineWidth: 1.5,
                             dash: [3, 2], capacity: 240),
        ] : []
        let diskAxis = ChartSeries.autoScale(diskSeries)
        let disks = CardModel(
            title: "DISKS",
            headline: diskState == .live && disk != nil
                ? pairedRate("R", disk!.readBytesPerSecond, "W", disk!.writeBytesPerSecond)
                : placeholder(diskState),
            footer: diskState == .live && disk != nil
                ? "\(disk!.deviceCount) devices · \(Format.percent(points: disk!.busyPercent)) busy"
                : "",
            colorToken: "accentDisk", state: diskState,
            series: diskSeries.map { rescaled($0, to: diskAxis) }, axis: diskAxis
        )

        let networkState = CardState(frames.network.state)
        let network = frames.network.current
        let networkSeries: [SeriesDescriptor] = networkState == .live && !frames.networkHistory.isEmpty ? [
            SeriesDescriptor(values: frames.networkHistory.map(\.bytesInPerSecond), axis: .percent,
                             colorToken: "accentNetwork", lineWidth: 1.5, capacity: 240),
            SeriesDescriptor(values: frames.networkHistory.map(\.bytesOutPerSecond), axis: .percent,
                             colorToken: "accentNetwork", opacity: 0.6, lineWidth: 1.5,
                             dash: [3, 2], capacity: 240),
        ] : []
        let networkAxis = ChartSeries.autoScale(networkSeries)
        let networkTile = CardModel(
            title: "NETWORK",
            headline: networkState == .live && network != nil
                ? pairedRate("R", network!.bytesInPerSecond, "S", network!.bytesOutPerSecond)
                : placeholder(networkState),
            footer: networkState == .live && network != nil
                ? "\(network!.primaryInterface) · \(network!.primaryAddress ?? Format.unknown)"
                : "",
            colorToken: "accentNetwork", state: networkState,
            series: networkSeries.map { rescaled($0, to: networkAxis) }, axis: networkAxis
        )

        // §5.6-5.9, phase-03.1.

        // §4.6.3. The footer is built from the public sidecars, never from the energy
        // provider's own payload, so it reads a real thermal state and power source straight
        // through the blackout while the headline above it reads `—` (§5.7.2's and §5.8.4's
        // promise; the discretion table's reason both sidecars live on `SummaryFrames`).
        let energyState = CardState(frames.energy.state)
        let energy = frames.energy.current
        let energyRawSeries: [SeriesDescriptor] = energyState == .live && !frames.energyHistory.isEmpty ? [
            SeriesDescriptor(values: frames.energyHistory, axis: .percent, colorToken: "accentEnergy",
                             lineWidth: 1.5, fill: .gradient(topOpacity: 0.20), capacity: 60),
        ] : []
        let energyAxis = ChartSeries.autoScale(energyRawSeries, floor: 1)
        let energyTile = CardModel(
            title: "ENERGY",
            headline: energyState == .live ? Format.power(watts: energy?.watts ?? 0) : placeholder(energyState),
            footer: "\(thermalPressureShortLabel(frames.thermalPressure)) · \(frames.powerSource?.type ?? Format.unknown)",
            colorToken: "accentEnergy", state: energyState,
            series: energyRawSeries.map { rescaled($0, to: energyAxis) }, axis: energyAxis
        )

        // §4.6.4. Footer degrades to the chip name alone when `coreCount` is nil (§5.6.6):
        // omitted rather than guessed, same rule `GPUProvider` already applies.
        let gpuSeries: [SeriesDescriptor] = gpuState == .live && !frames.gpuHistory.isEmpty ? [
            SeriesDescriptor(values: frames.gpuHistory.map { $0 * 100 }, axis: .percent,
                             colorToken: "accentGPU", lineWidth: 1.5,
                             fill: .gradient(topOpacity: 0.22), capacity: 120),
        ] : []
        let gpuTile = CardModel(
            title: "GPU 0",
            headline: gpuState == .live ? Format.percent(fraction: gpu?.utilization ?? 0) : placeholder(gpuState),
            footer: gpuState == .live ? gpuFooter(gpu) : "",
            colorToken: "accentGPU", state: gpuState, series: gpuSeries, axis: .percent
        )

        // §4.6.5. `.npu` mirrors `.energy`'s slot exactly (discretion table: one IOReport
        // subscription, two tiles). §6.4 carries no ANE-utilization history buffer -- only
        // the headline wattage sum is buffered -- so this tile's chart is empty until a
        // future phase adds one; fabricating a line from `energyHistory` would plot the
        // system's total wattage as if it were the ANE's share.
        let npuState = CardState(frames.energy.state)
        let aneUtilization = energy?.aneUtilization
        let npuTile = CardModel(
            title: "NPU 0",
            headline: npuState == .live ? (aneUtilization.map { Format.percent(fraction: $0) } ?? Format.unknown)
                : placeholder(npuState),
            footer: npuState == .live ? npuFooter(gpu?.chipName) : "",
            colorToken: "accentNPU", state: npuState
        )

        // §4.6.6. Up to four orange lines, hottest at full opacity -- `temperatureHistory` is
        // already ordered by the identity `MetricStore` fixed on first live sample, so index
        // order is opacity order.
        let thermalOpacities: [Double] = [1.0, 0.75, 0.55, 0.40]
        let thermalSeries: [SeriesDescriptor] = thermalState == .live
            ? frames.temperatureHistory.enumerated().map { index, values in
                SeriesDescriptor(
                    values: values, axis: .celsius, colorToken: "accentThermal",
                    opacity: thermalOpacities[min(index, thermalOpacities.count - 1)],
                    lineWidth: 1.5, capacity: 60
                )
            } : []
        // The footer is unconditional -- §5.8.4's promise is that a real pressure state
        // survives even when every raw sensor is unreadable (discretion table), so it must
        // not be gated on `thermalState` the way the headline and chart are.
        let thermalsTile = CardModel(
            title: "THERMALS",
            headline: thermalState == .live ? Format.temperature(celsius: thermal?.maxCelsius ?? 0)
                : placeholder(thermalState),
            footer: frames.thermalPressure.footerText,
            colorToken: "accentThermal", state: thermalState, series: thermalSeries, axis: .celsius
        )

        return [disks, networkTile, energyTile, gpuTile, npuTile, thermalsTile]
    }

    /// §4.6.3's compact form, distinct from `ThermalPressure.footerText`'s full sentence
    /// (§4.6.6's own footer) -- SPEC.md's own example pairs `Thermals nominal` with the power
    /// source on the Energy tile.
    static func thermalPressureShortLabel(_ pressure: ThermalPressure) -> String {
        switch pressure {
        case .nominal: return "Thermals nominal"
        case .fair: return "Thermals fair"
        case .serious: return "Thermals serious"
        case .critical: return "Thermals critical"
        }
    }

    static func gpuFooter(_ sample: GPUSample?) -> String {
        guard let sample, let chipName = sample.chipName else { return "" }
        guard let coreCount = sample.coreCount else { return chipName }
        return "\(chipName) · \(coreCount) cores"
    }

    /// §5.6.4: "The core count in the footer comes from the SoC identification (§9.2), not
    /// from IOReport" -- IOReport carries no ANE core count on any Mac. A small table keyed
    /// on the brand string, the same shape §5.6.6 describes for GPU cores; omitted from the
    /// footer when the brand string does not match a known chip. Longer variant names
    /// (`M4 Pro`) are checked before their shorter prefix (`M4`) since the brand string
    /// contains both.
    static func npuFooter(_ chipName: String?) -> String {
        guard let chipName else { return "" }
        let aneCores: [(String, Int)] = [
            ("M1 Ultra", 32), ("M1 Max", 16), ("M1 Pro", 16), ("M1", 16),
            ("M2 Ultra", 32), ("M2 Max", 16), ("M2 Pro", 16), ("M2", 16),
            ("M3 Ultra", 32), ("M3 Max", 16), ("M3 Pro", 16), ("M3", 16),
            ("M4 Max", 16), ("M4 Pro", 16), ("M4", 16),
        ]
        guard let cores = aneCores.first(where: { chipName.contains($0.0) })?.1 else { return "" }
        return "Apple Neural Engine · \(cores) cores"
    }

    static func rescaled(_ descriptor: SeriesDescriptor, to axis: ChartAxis) -> SeriesDescriptor {
        SeriesDescriptor(
            values: descriptor.values, axis: axis, colorToken: descriptor.colorToken,
            opacity: descriptor.opacity, lineWidth: descriptor.lineWidth,
            dash: descriptor.dash, fill: descriptor.fill, capacity: descriptor.capacity
        )
    }

    /// §4.6.1's `R 12.4 · W 3.1 MB/s` — one unit suffix when both scale the same way, two
    /// when they do not. The only place in the app where two numbers share a line, and the
    /// `R`/`W` prefixes carry the distinction because a legend would not fit.
    static func pairedRate(_ firstLabel: String, _ first: Double,
                           _ secondLabel: String, _ second: Double) -> String {
        let a = Format.byteRate(first)
        let b = Format.byteRate(second)
        let unitA = a.split(separator: " ").last.map(String.init) ?? ""
        let unitB = b.split(separator: " ").last.map(String.init) ?? ""
        if unitA == unitB {
            let mantissa = a.split(separator: " ").first.map(String.init) ?? a
            return "\(firstLabel) \(mantissa) · \(secondLabel) \(b)"
        }
        return "\(firstLabel) \(a) · \(secondLabel) \(b)"
    }

    // MARK: Status

    static func projectStatus(_ frames: SummaryFrames, paused: Bool) -> StatusModel {
        let generation = "Generation \(frames.generation)"

        // §6.8: a paused dashboard says so and holds its generation; the health phrase is
        // suppressed because nothing is sampling to be healthy about.
        if paused {
            return StatusModel(leading: "Paused · \(generation)", phrase: "Paused",
                               phraseToken: "textSecondary", tooltip: "")
        }

        let unavailable = frames.health.filter { $0.state.isUnavailableState }
        let stalled = frames.health.contains { $0.state == .stalled }

        let phrase: String
        let token: String
        if stalled {
            // Overrides the unavailable count: a dead sample loop is the more urgent fact,
            // and it is the one no interpolating meter would reveal.
            phrase = "Sampling stalled"
            token = "critical"
        } else if unavailable.isEmpty {
            phrase = "Native providers healthy"
            token = "textSecondary"
        } else {
            phrase = "\(unavailable.count) providers unavailable"
            token = unavailable.count <= 2 ? "warning" : "statusDegraded"
        }

        let processCount = frames.processes.current.map { "\(Format.count($0.totalCount)) processes" }
        let leading = [phrase, processCount, generation].compactMap { $0 }.joined(separator: " · ")

        let tooltip = unavailable.map { health -> String in
            if case .unavailable(let reason) = health.state {
                return "\(health.id.rawValue): \(reason)"
            }
            return health.id.rawValue
        }.joined(separator: "\n")

        return StatusModel(leading: leading, phrase: phrase, phraseToken: token, tooltip: tooltip)
    }
}

extension MetricState {
    var isUnavailableState: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

// MARK: - §14.10's Performance projection

/// The store→view projection for §14.10's Performance pane.
///
/// A **subset of `SummaryModel`**, not a second projection: `project` below calls
/// `SummaryModel.project` and re-exposes what §14.10's three cards draw. Nothing is
/// re-derived from the frames, so a change to §4.4's series table or §4.5's stacking
/// reaches both panes at once, and "the memory card is Summary's, verbatim" is a
/// statement a diff can check rather than a claim a reader has to trust.
public struct PerformanceModel: Sendable, Equatable {
    /// §4.3.2's meters, one per logical core, in kernel index order. `SummaryModel`'s.
    public let perCore: [MeterModel]
    /// §5.1.4. The E count is `perCore.count - performanceCores` — derived, never carried
    /// as a second field, so the two cannot disagree.
    public let performanceCores: Int
    /// Card 1's headline. Identical to `SummaryModel.cpuOverview.headline`.
    public let cpuHeadline: String
    public let cpuState: CardState
    /// §4.4's utilization and kernel series, **without** the temperature series and
    /// without its right-hand axis (§14.10). Exactly two descriptors when the CPU frame
    /// is live, and empty otherwise — §4.8 omits the plot rather than flat-lining it.
    public let cpuSeries: [SeriesDescriptor]
    /// Card 2's footer. §4.9's percentage rule, through `Format`.
    public let cpuFooter: String
    /// Card 3, whole: §4.5's headline, footer, stacked series and axis. Summary's card.
    public let memory: CardModel
    /// Projected because `projectMemory` returns it; §14.10's card 3 does not draw a
    /// meter (§4.5's belongs to the Summary pane) and no view reads this today.
    public let memoryMeter: MeterModel
    /// §4.10: the three card titles and the two cluster words, so the view holds no wording.
    public let titles: [String]
    public let clusterWords: (performance: String, efficiency: String)

    public static func == (a: PerformanceModel, b: PerformanceModel) -> Bool {
        a.perCore == b.perCore && a.performanceCores == b.performanceCores
            && a.cpuHeadline == b.cpuHeadline && a.cpuState == b.cpuState
            && a.cpuSeries == b.cpuSeries && a.cpuFooter == b.cpuFooter && a.memory == b.memory
            && a.memoryMeter == b.memoryMeter && a.titles == b.titles
            && a.clusterWords == b.clusterWords
    }

    public init(
        perCore: [MeterModel], performanceCores: Int, cpuHeadline: String,
        cpuState: CardState, cpuSeries: [SeriesDescriptor], cpuFooter: String,
        memory: CardModel, memoryMeter: MeterModel,
        titles: [String] = ["PER-CORE UTILIZATION", "CPU HISTORY", "MEMORY HISTORY"],
        clusterWords: (performance: String, efficiency: String) = ("P", "E")
    ) {
        self.titles = titles
        self.clusterWords = clusterWords
        self.perCore = perCore
        self.performanceCores = performanceCores
        self.cpuHeadline = cpuHeadline
        self.cpuState = cpuState
        self.cpuSeries = cpuSeries
        self.cpuFooter = cpuFooter
        self.memory = memory
        self.memoryMeter = memoryMeter
    }

    public static func project(
        _ frames: SummaryFrames, paused: Bool = false, mode: DisplayMode = .technical
    ) -> PerformanceModel {
        var summary = SummaryModel.project(frames, paused: paused)
        if mode == .simple { summary = summary.simplified(frames: frames, previous: nil).0 }
        let cpu = frames.cpu.current
        let state = CardState(frames.cpu.state)

        // §14.10 omits the temperature series and its axis. `SummaryModel.project`
        // builds utilization and kernel in one array literal and *appends* the thermal
        // descriptor afterwards, only when the thermal frame is live — so the first two
        // are the two §14.10 wants, in §4.4's own order, and `prefix(2)` is the whole
        // omission. `cpuOverview.rightAxis` is simply not read: §4.4 requires a series
        // and its axis to be omitted together, and here they are.
        //
        // Adding an omit-thermal flag to `SummaryModel.project` was the alternative and
        // is rejected: it changes a projection this phase has to be able to prove
        // unchanged, to save one `prefix`.
        let series = Array(summary.cpuOverview.series.prefix(2))

        let footer: String = if state == .live, let cpu {
            mode == .simple
                ? "All apps \(Format.percent(fraction: cpu.total)) · "
                    + "of which macOS itself \(Format.percent(fraction: cpu.system))"
                : "Total \(Format.percent(fraction: cpu.total)) · "
                    + "System \(Format.percent(fraction: cpu.system))"
        } else { "" }

        return PerformanceModel(
            perCore: summary.perCore,
            performanceCores: cpu?.performanceCores ?? 0,
            cpuHeadline: summary.cpuOverview.headline,
            cpuState: state,
            cpuSeries: series,
            cpuFooter: footer,
            memory: summary.memory,
            memoryMeter: summary.memoryMeter,
            titles: mode == .simple
                ? ["EACH PROCESSOR CORE", "PROCESSOR, LAST MINUTE", "MEMORY, LAST MINUTE"]
                : ["PER-CORE UTILIZATION", "CPU HISTORY", "MEMORY HISTORY"],
            clusterWords: mode == .simple ? ("Fast", "Efficient") : ("P", "E")
        )
    }
}
