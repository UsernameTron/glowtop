import Foundation

/// SPEC.md §4.10 — Simple and Technical display modes (1.2).
///
/// Technical is the dashboard exactly as §4 specifies it and as it shipped through 1.1.3.
/// Simple is a *wording* layer over the same projection: plain titles, plain headlines, a
/// one-word verdict per card and one summary sentence. No reading changes, no series changes,
/// no state changes — `simplified(frames:previous:)` takes the Technical model and returns a
/// copy with different strings, so everything §4.8 says about warming, unavailable and stalled
/// holds in both modes by construction.
public enum DisplayMode: String, Sendable, Equatable, CaseIterable {
    case simple
    case technical

    /// `UserDefaults` key, in the app's own domain beside §7.4's theme keys.
    public static let storageKey = "display.mode"

    /// A missing or unrecognised stored value is Simple: the default a new user should meet.
    public static func parse(_ stored: String?) -> DisplayMode {
        stored.flatMap(DisplayMode.init(rawValue:)) ?? .simple
    }
}

/// One card's plain-language verdict.
public struct Verdict: Sendable, Equatable {
    public enum Level: Int, Sendable, Comparable {
        case normal = 0, elevated, high, critical
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public let text: String
    public let level: Level

    public init(_ text: String, _ level: Level) {
        self.text = text
        self.level = level
    }

    /// Never the card's accent: §4.8's unavailable tiles must stay free of accent pixels, and a
    /// verdict is commentary on the reading, not part of it.
    public var colorToken: String {
        switch level {
        case .normal: "textSecondary"
        case .elevated: "warning"
        case .high: "statusDegraded"
        case .critical: "critical"
        }
    }
}

/// The verdict rules. Pure functions of values the Summary projection already holds; where
/// macOS publishes its own judgement (thermal pressure, the kernel's memory-pressure level) that
/// judgement is used as-is, and a raw percentage is only thresholded where no such signal exists.
public enum VerdictRules {
    /// The window a utilization is averaged over before it is judged, so a one-second spike
    /// does not flip a word.
    public static let smoothingSeconds = 10.0

    /// A level is entered at `enter` and only left again below `enter − deadband`. Without the
    /// band a load hovering at a threshold would flip the word every second.
    public static let deadband = 0.05

    public static func mean(_ values: [Double], last count: Int) -> Double? {
        let tail = values.suffix(max(count, 1))
        guard !tail.isEmpty else { return nil }
        return tail.reduce(0, +) / Double(tail.count)
    }

    /// `thresholds` ascending, as fractions 0–1; the result is the number of thresholds cleared.
    static func steps(_ value: Double, thresholds: [Double], previous: Int?) -> Int {
        var level = 0
        for (index, threshold) in thresholds.enumerated() {
            let held = (previous ?? 0) > index
            if value >= (held ? threshold - deadband : threshold) { level = index + 1 }
        }
        return level
    }

    public static func processor(average: Double, previous: Verdict.Level?) -> Verdict {
        switch steps(average, thresholds: [0.60, 0.85], previous: previous?.rawValue) {
        case 0: Verdict("Normal", .normal)
        case 1: Verdict("Busy", .elevated)
        default: Verdict("Very busy", .high)
        }
    }

    /// For Disks, Graphics and the AI chip: one threshold, because "busy" is the only thing a
    /// reader needs to know and none of them has an unhealthy state of its own.
    public static func utilization(average: Double, previous: Verdict.Level?) -> Verdict {
        steps(average, thresholds: [0.70], previous: previous?.rawValue) == 0
            ? Verdict("Normal", .normal) : Verdict("Busy", .elevated)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical — the kernel's own
    /// verdict and the one Activity Monitor's pressure graph colours by. When the sysctl is
    /// unreadable the fallback is §5.2.3's own pressure fraction.
    public static func memory(pressureLevel: Int?, pressureFraction: Double, previous: Verdict.Level?) -> Verdict {
        if let pressureLevel {
            switch pressureLevel {
            case 4: return Verdict("Low on memory", .critical)
            case 2: return Verdict("Getting full", .elevated)
            default: return Verdict("Normal", .normal)
            }
        }
        switch steps(pressureFraction, thresholds: [0.60, 0.80], previous: previous?.rawValue) {
        case 0: return Verdict("Normal", .normal)
        case 1: return Verdict("Getting full", .elevated)
        default: return Verdict("Low on memory", .critical)
        }
    }

    public static func thermal(_ pressure: ThermalPressure) -> Verdict {
        switch pressure {
        case .nominal: Verdict("Normal", .normal)
        case .fair: Verdict("Warm", .elevated)
        case .serious: Verdict("Hot", .high)
        case .critical: Verdict("Critical", .critical)
        }
    }

    /// The network has no unhealthy state a byte rate can reveal, so this is a description,
    /// never a warning.
    public static func network(bytesPerSecond: Double) -> Verdict {
        Verdict(bytesPerSecond >= 10 * 1024 ? "Active" : "Idle", .normal)
    }
}

/// The verdicts of one projection, kept by the caller and handed back as `previous` so the
/// deadband in `VerdictRules` has something to hold on to. Projection itself stays pure.
public struct SummaryVerdicts: Sendable, Equatable {
    public var processor: Verdict?
    public var memory: Verdict?
    public var disks: Verdict?
    public var network: Verdict?
    public var power: Verdict?
    public var graphics: Verdict?
    public var aiChip: Verdict?
    public var temperature: Verdict?

    public init() {}

    var all: [Verdict] {
        [processor, memory, disks, network, power, graphics, aiChip, temperature].compactMap { $0 }
    }
}

/// Simple mode's fixed wording, in one place.
public enum SimpleLabels {
    public static let meterCaptions = ["CPU", "SPEED", "TEMP", "GRAPHICS"]
    public static let processor = "PROCESSOR"
    public static let busiestApps = "BUSIEST APPS"
    public static let memory = "MEMORY"
    /// §4.6's order: Disks, Network, Energy, GPU, NPU, Thermals.
    public static let tiles = ["DISKS", "NETWORK", "POWER DRAW", "GRAPHICS", "AI CHIP", "TEMPERATURE"]

    /// One sentence per Summary card, in `SummaryPaneView.cardFrames()`' order: meters,
    /// processor, busiest apps, memory, then the six tiles.
    public static let explanations: [String] = [
        "Four quick gauges: how busy the processor is, how fast it is running, how warm the chip is, and how busy the graphics are.",
        "How hard the processor is working. The small bars are its individual cores; the green line is the last minute, orange is temperature, red is work done by macOS itself.",
        "The apps and background programs using the most processor right now.",
        "How much memory is in use. macOS fills spare memory on purpose to keep things fast, so a fairly full bar is normal; a red line means it has started using the disk instead.",
        "How fast your drives are reading and writing right now.",
        "How much data is coming in from and going out to the network.",
        "How much electrical power the chip is drawing. More power means more heat and, on battery, less time.",
        "How busy the graphics processor is. It rises with games, video and visual effects.",
        "How busy the chip's AI accelerator is. It is usually idle unless an app is running an AI model on this Mac.",
        "The hottest sensor on the chip. macOS slows the Mac down by itself if it gets too warm.",
    ]
}

extension CardModel {
    func relabelled(title: String, headline: String? = nil, footer: String? = nil,
                    verdict: Verdict?, explanation: String) -> CardModel {
        CardModel(
            title: title, headline: headline ?? self.headline, footer: footer ?? self.footer,
            colorToken: colorToken, state: state, series: series, axis: axis, rightAxis: rightAxis,
            verdict: state == .live ? verdict : nil, explanation: explanation
        )
    }
}

extension SummaryModel {
    /// The Simple-mode copy of a Technical projection. Returns the model and the verdicts it
    /// reached, which the caller hands back next time as `previous`.
    public func simplified(frames: SummaryFrames, previous: SummaryVerdicts?) -> (SummaryModel, SummaryVerdicts) {
        var verdicts = SummaryVerdicts()
        // §6.4's buffers fill at each provider's own rate, and §6.2 divides every rate by 10
        // behind an occluded window. A fixed sample count would then span 100 s and call it 10,
        // so the CPU card could read `Very busy` about a build that finished two minutes ago.
        // The counts are derived from the rates instead.
        func window(hz: Double) -> Int {
            max(Int(VerdictRules.smoothingSeconds * hz) / max(frames.samplingDivisor, 1), 1)
        }

        // Processor
        var cpuAverage: Double?
        if cpuOverview.state == .live {
            cpuAverage = VerdictRules.mean(frames.cpuTotal, last: window(hz: 10)) ?? frames.cpu.current?.total
            verdicts.processor = VerdictRules.processor(
                average: cpuAverage ?? 0, previous: previous?.processor?.level
            )
        }
        let cores = frames.cpu.current
        let coreFooter = cores.map { "\($0.performanceCores) fast cores · \($0.logicalCount - $0.performanceCores) efficient cores" }
        let simpleCPU = cpuOverview.relabelled(title: SimpleLabels.processor, footer: coreFooter, verdict: verdicts.processor, explanation: SimpleLabels.explanations[1])

        // Memory
        var memoryHeadline: String?
        var memoryFooter: String?
        if memory.state == .live, let sample = frames.memory.current {
            verdicts.memory = VerdictRules.memory(
                pressureLevel: sample.pressureLevel, pressureFraction: sample.pressure,
                previous: previous?.memory?.level
            )
            memoryHeadline = "\(Format.bytes(sample.resident)) of \(Format.bytes(sample.total)) in use"
            memoryFooter = "Can be freed \(Format.bytes(sample.reclaimable)) · "
                + "Free \(Format.bytes(sample.free)) · Spilled to disk \(Format.bytes(sample.swapUsed))"
        }
        let simpleMemory = memory.relabelled(title: SimpleLabels.memory, headline: memoryHeadline,
                                             footer: memoryFooter, verdict: verdicts.memory, explanation: SimpleLabels.explanations[3])

        // Tiles, §4.6's order
        var simpleTiles = tiles
        if tiles.count == 6 {
            let disk = frames.disk.current
            if tiles[0].state == .live, let disk {
                let busy = VerdictRules.mean(frames.diskHistory.map { $0.busyPercent / 100 }, last: window(hz: 4))
                    ?? disk.busyPercent / 100
                verdicts.disks = VerdictRules.utilization(average: busy, previous: previous?.disks?.level)
            }
            simpleTiles[0] = tiles[0].relabelled(
                title: SimpleLabels.tiles[0],
                headline: tiles[0].state == .live && disk != nil
                    ? SummaryModel.pairedRate("R", disk!.readBytesPerSecond, "W", disk!.writeBytesPerSecond) : nil,
                footer: tiles[0].state == .live && disk != nil
                    ? "R reading · W writing · \(disk!.deviceCount) drives" : nil,
                verdict: verdicts.disks, explanation: SimpleLabels.explanations[4]
            )

            let network = frames.network.current
            if tiles[1].state == .live, let network {
                verdicts.network = VerdictRules.network(bytesPerSecond: network.bytesInPerSecond + network.bytesOutPerSecond)
            }
            simpleTiles[1] = tiles[1].relabelled(
                title: SimpleLabels.tiles[1],
                headline: tiles[1].state == .live && network != nil
                    ? SummaryModel.pairedRate("↓", network!.bytesInPerSecond, "↑", network!.bytesOutPerSecond) : nil,
                // The footer keeps the interface and address: ↓ and ↑ are their own legend, and
                // dropping the address would be Simple mode losing information, not jargon.
                verdict: verdicts.network, explanation: SimpleLabels.explanations[5]
            )

            let thermalVerdict = VerdictRules.thermal(frames.thermalPressure)
            let onBattery = frames.powerSource.map { !$0.type.localizedCaseInsensitiveContains("AC") }
            // §4.6.3's and §4.6.6's footers are unconditional in Technical, precisely so a real
            // thermal state survives a private-API blackout; Simple keeps that property.
            simpleTiles[2] = tiles[2].relabelled(
                title: SimpleLabels.tiles[2],
                footer: onBattery.map { $0 ? "Running on battery" : "Plugged in" } ?? "Power source unknown",
                verdict: verdicts.power, explanation: SimpleLabels.explanations[6]
            )

            if tiles[3].state == .live {
                let average = VerdictRules.mean(frames.gpuHistory, last: window(hz: 2)) ?? frames.gpu.current?.utilization ?? 0
                verdicts.graphics = VerdictRules.utilization(average: average, previous: previous?.graphics?.level)
            }
            simpleTiles[3] = tiles[3].relabelled(title: SimpleLabels.tiles[3], verdict: verdicts.graphics, explanation: SimpleLabels.explanations[7])

            // §5.6.4's reading is `nil` when neither ANE path produced a number, and the tile
            // then prints `—` while its frame is still live. Coalescing that to 0 would put the
            // word `Normal` beside a reading that does not exist -- §4.8's lie in a friendlier
            // font -- so the optional is bound, not defaulted. The 10 s mean comes from
            // §6.4's ANE watts buffer over §5.6.4's provisional ceiling: the same path 2
            // arithmetic the sample itself used, so the smoothed number and the headline agree.
            if tiles[4].state == .live, frames.energy.current?.aneUtilization != nil {
                let smoothed = VerdictRules.mean(frames.aneWattsHistory, last: window(hz: 1))
                    .map { min(1, max(0, $0 / EnergyProvider.provisionalANECeilingWatts)) }
                verdicts.aiChip = VerdictRules.utilization(
                    average: smoothed ?? frames.energy.current?.aneUtilization ?? 0,
                    previous: previous?.aiChip?.level
                )
            }
            simpleTiles[4] = tiles[4].relabelled(title: SimpleLabels.tiles[4], verdict: verdicts.aiChip, explanation: SimpleLabels.explanations[8])

            if tiles[5].state == .live { verdicts.temperature = thermalVerdict }
            simpleTiles[5] = tiles[5].relabelled(
                title: SimpleLabels.tiles[5],
                footer: SimpleLabels.thermalFooter(frames.thermalPressure),
                verdict: verdicts.temperature, explanation: SimpleLabels.explanations[9]
            )
        }

        let simpleMeters = meters.enumerated().map { index, meter in
            MeterModel(
                fraction: meter.fraction, label: meter.label,
                caption: index < SimpleLabels.meterCaptions.count ? SimpleLabels.meterCaptions[index] : meter.caption,
                colorToken: meter.colorToken, state: meter.state
            )
        }
        let simpleCores = perCore.map {
            MeterModel(fraction: $0.fraction, label: $0.label, caption: $0.caption == "P" ? "F" : "E",
                       colorToken: $0.colorToken, state: $0.state)
        }

        let simpleStatus = SummaryModel.simpleStatus(status, frames: frames, verdicts: verdicts,
                                                      cpuAverage: cpuAverage)

        return (
            SummaryModel(
                meters: simpleMeters, cpuOverview: simpleCPU, perCore: simpleCores,
                processes: processes.relabelled(title: SimpleLabels.busiestApps, verdict: nil, explanation: SimpleLabels.explanations[2]),
                processRows: processRows, memory: simpleMemory, memoryMeter: memoryMeter,
                tiles: simpleTiles, status: simpleStatus
            ),
            verdicts
        )
    }

    /// §4.7 in plain words. The three §4.7 conditions that mean "do not trust the screen"
    /// (paused, stalled, readings unavailable) keep their precedence and their colour; only when
    /// everything is sampling does the sentence describe the Mac instead of the app.
    static func simpleStatus(_ technical: StatusModel, frames: SummaryFrames, verdicts: SummaryVerdicts,
                             cpuAverage: Double?) -> StatusModel {
        let phrase: String
        var token = technical.phraseToken
        switch technical.phrase {
        case "Paused":
            phrase = "Paused — press Space to resume."
        case "Sampling stalled":
            phrase = "Readings have stopped updating — press ⌘R."
        case "Native providers healthy":
            (phrase, token) = sentence(frames: frames, verdicts: verdicts, cpuAverage: cpuAverage)
        default:
            let count = frames.health.filter { $0.state.isUnavailableState }.count
            phrase = count == 1 ? "1 reading is unavailable on this Mac." : "\(count) readings are unavailable on this Mac."
        }
        return StatusModel(leading: phrase, phrase: phrase, phraseToken: token, tooltip: technical.tooltip)
    }

    /// Worst verdict wins. A busy processor names the program responsible when one program
    /// holds more than half of the load, because "what is doing this" is the next question.
    static func sentence(frames: SummaryFrames, verdicts: SummaryVerdicts,
                         cpuAverage: Double?) -> (String, String) {
        let worst = verdicts.all.map(\.level).max() ?? .normal
        guard worst > .normal else { return ("Your Mac is running normally.", "textSecondary") }
        let token = Verdict("", worst).colorToken

        if let thermal = verdicts.temperature, thermal.level == worst, thermal.level >= .high {
            return ("Your Mac is hot and is slowing itself down to cool off.", token)
        }
        if let memory = verdicts.memory, memory.level == worst {
            return (memory.level == .critical
                ? "Memory is nearly full — closing an app or two will help."
                : "Memory is getting full.", token)
        }
        if let processor = verdicts.processor, processor.level == worst {
            // The same smoothed mean the verdict was reached from, never the instantaneous
            // total: comparing a 10 s verdict against a 100 ms denominator makes the program's
            // name appear and vanish between ticks while the word above it holds steady.
            let total = (cpuAverage ?? frames.cpu.current?.total ?? 0)
                * 100 * Double(frames.cpu.current?.logicalCount ?? 1)
            if let top = frames.processes.current?.rows.first, let share = top.cpuPercent,
               total > 0, share / total > 0.5 {
                return ("\(top.name) is using most of the processor.", token)
            }
            return ("The processor is busy.", token)
        }
        if let thermal = verdicts.temperature, thermal.level == worst {
            return ("Your Mac is running warm.", token)
        }
        if verdicts.disks?.level == worst { return ("The drives are busy.", token) }
        if verdicts.graphics?.level == worst { return ("The graphics processor is busy.", token) }
        if verdicts.aiChip?.level == worst { return ("The AI chip is busy.", token) }
        return ("Your Mac is running normally.", "textSecondary")
    }
}

extension SimpleLabels {
    static func thermalFooter(_ pressure: ThermalPressure) -> String {
        switch pressure {
        case .nominal: "Cooling is keeping up"
        case .fair: "Warming up — still at full speed"
        case .serious: "macOS is slowing things down to cool off"
        case .critical: "macOS is slowing down sharply to cool off"
        }
    }
}
