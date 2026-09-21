import AppKit
import GlowTopCore
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

/// Gate 12's pane-arm instrument (§5.10, §13.7 gate 12): the offscreen render, the pixel
/// scanner, the PNG dump and the two fixtures. Moved out of `SummaryPaneView` in phase-10
/// (sub-step 2.1) so a second chart-bearing pane runs its own arm through the same code.

struct PaneAssertion {
    let name: String
    let pass: Bool
    let detail: String
}

/// A rect-scoped pixel counter over a BGRA bitmap whose rows run top-down while the rects
/// arrive in the pane's bottom-left origin space.
struct PixelScan {
    let bytes: UnsafeMutablePointer<UInt8>
    let bytesPerRow: Int
    let width: Int
    let height: Int

    func hits(in rect: CGRect, ofHex hex: String, tolerance: Int) -> Int {
        let color = Theme.cgColor(hex: hex)
        guard let comp = color.components, comp.count >= 3 else { return 0 }
        let target = (r: Int(comp[0] * 255), g: Int(comp[1] * 255), b: Int(comp[2] * 255))
        let x0 = max(Int(rect.minX), 0), x1 = min(Int(rect.maxX), width)
        let y0 = max(Int(rect.minY), 0), y1 = min(Int(rect.maxY), height)
        var count = 0
        for viewY in y0..<y1 {
            let row = height - 1 - viewY
            for x in x0..<x1 {
                let offset = row * bytesPerRow + x * 4
                if abs(Int(bytes[offset + 2]) - target.r) <= tolerance,
                   abs(Int(bytes[offset + 1]) - target.g) <= tolerance,
                   abs(Int(bytes[offset]) - target.b) <= tolerance {
                    count += 1
                }
            }
        }
        return count
    }
}

/// Renders one laid-out view offscreen into a 1× BGRA context and returns the context and a
/// pixel scanner over it.
///
/// The context is part of the return value **on purpose**, even though no caller reads
/// it directly: `PixelScan` holds a raw pointer into the context's own backing buffer
/// (`data: nil` asks `CGContext` to allocate and own it), and returning only the pointer
/// would let ARC free the context the moment this function returns, leaving `scan` a
/// dangling read into freed memory -- the caller must keep the context alive for as long
/// as it uses the scan.
@MainActor
func renderPaneOffscreen(_ view: NSView, width: Int, height: Int)
    -> (context: CGContext, scan: PixelScan)?
{
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }
    view.layer?.render(in: context)
    guard let data = context.data else { return nil }
    let scan = PixelScan(
        bytes: data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height),
        bytesPerRow: context.bytesPerRow, width: width, height: height
    )
    return (context, scan)
}

/// The bitmap behind `scan`, as a PNG, so `scripts/png-diff.swift` can compare two renders
/// of the fixed §5.10 fixture per plot rect (phase-09, 1.2). Prints one line either way.
func writeSelfCheckPNG(_ context: CGContext, to path: String) {
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil
          ),
          ({ CGImageDestinationAddImage(destination, image, nil)
             return CGImageDestinationFinalize(destination) })()
    else {
        print("selfcheck png=\(path) FAILED")
        return
    }
    print("selfcheck png=\(path) \(image.width)x\(image.height)")
}

/// §5.10's fixture. Values are arbitrary but non-zero and non-degenerate: the CPU total
/// sits mid-scale so both lit and unlit segments exist, and every history ramps so a
/// chart that renders has something to show.
func selfCheckFrames() -> SummaryFrames {
    let gb: UInt64 = 1024 * 1024 * 1024
    let now = ContinuousClock().now

    let cpu = CPUSample(
        perCore: (0..<14).map { Double($0 % 5) / 5 }, total: 0.42, user: 0.30,
        system: 0.12, idle: 0.58, nice: 0, logicalCount: 14, performanceCores: 10,
        efficiencyCores: 4
    )
    let memory = MemorySample(
        resident: 20 * gb, reclaimable: 18 * gb, free: 9 * gb, total: 48 * gb,
        active: 12 * gb, wired: 6 * gb, compressed: 2 * gb, swapUsed: gb / 2,
        pageSize: 16384, inactive: 10 * gb, purgeable: 4 * gb, speculative: 4 * gb,
        cached: 10 * gb
    )
    let disk = DiskSample(
        readBytesPerSecond: 12.4 * 1024 * 1024, writeBytesPerSecond: 3.1 * 1024 * 1024,
        readOpsPerSecond: 100, writeOpsPerSecond: 40, busyPercent: 4,
        totalBytesRead: 100 * gb, totalBytesWritten: 50 * gb, deviceCount: 2
    )
    let network = NetworkSample(
        bytesInPerSecond: 148.2 * 1024, bytesOutPerSecond: 22.6 * 1024,
        packetsInPerSecond: 90, packetsOutPerSecond: 40, totalBytesIn: 10 * gb,
        totalBytesOut: 2 * gb, errorsIn: 0, errorsOut: 0, primaryInterface: "en0",
        primaryAddress: "192.168.1.42", primaryBytesIn: 10 * gb, primaryBytesOut: 2 * gb
    )
    var rows: [ProcessRow] = []
    for index in 0..<14 {
        let resident = UInt64(index + 1) * 64 * 1024 * 1024
        rows.append(ProcessRow(pid: Int32(100 + index), name: "proc\(index)",
                               cpuPercent: Double(50 - index), residentBytes: resident,
                               threadCount: 4))
    }
    let processes = ProcessSample(rows: rows, totalCount: 839, inspectableCount: 504,
                                  enumerationMilliseconds: 5.0)

    let notBuilt = MetricState.unavailable(reason: MetricStore.notBuiltReason)
    let ramp = (0..<300).map { 0.2 + 0.4 * Double($0) / 299 }
    return SummaryFrames(
        cpu: .init(previous: cpu, current: cpu, sampledAt: now,
                   interval: SampleRate.hz10, state: .live),
        memory: .init(previous: memory, current: memory, sampledAt: now,
                      interval: SampleRate.hz10, state: .live),
        disk: .init(previous: disk, current: disk, sampledAt: now,
                    interval: SampleRate.hz4, state: .live),
        network: .init(previous: network, current: network, sampledAt: now,
                       interval: SampleRate.hz4, state: .live),
        processes: .init(previous: processes, current: processes, sampledAt: now,
                         interval: SampleRate.hz1, state: .live),
        gpu: .init(previous: nil, current: nil, sampledAt: nil,
                  interval: SampleRate.hz2, state: notBuilt),
        energy: .init(previous: nil, current: nil, sampledAt: nil,
                     interval: SampleRate.hz1, state: notBuilt),
        thermal: .init(previous: nil, current: nil, sampledAt: nil,
                      interval: SampleRate.hz1, state: notBuilt),
        frequency: .init(previous: nil, current: nil, sampledAt: nil,
                        interval: SampleRate.hz2, state: notBuilt),
        cpuTotal: ramp, cpuSystem: ramp.map { $0 * 0.3 },
        memoryHistory: Array(repeating: memory, count: 200),
        diskHistory: Array(repeating: disk, count: 100),
        networkHistory: Array(repeating: network, count: 100),
        gpuHistory: [], energyHistory: [], temperatureHistory: [], temperatureNames: [],
        powerSource: nil, thermalPressure: .nominal,
        generation: 4218,
        health: [
            ProviderHealth(id: .cpu, state: .live),
            ProviderHealth(id: .memory, state: .live),
            ProviderHealth(id: .disk, state: .live),
            ProviderHealth(id: .network, state: .live),
            ProviderHealth(id: .process, state: .live),
            ProviderHealth(id: .gpu, state: notBuilt),
            ProviderHealth(id: .npu, state: notBuilt),
            ProviderHealth(id: .energy, state: notBuilt),
            ProviderHealth(id: .thermal, state: notBuilt),
            ProviderHealth(id: .frequency, state: notBuilt),
        ]
    )
}

/// Identical base to `selfCheckFrames()` but with all five private providers `.live` and
/// synthetic, non-degenerate values -- gate 12's second fixture (assertions 6 and 7 in
/// `paneSelfCheck()`). Two fixtures, two directions: an absence assertion alone passes on
/// a blank render, so proving the right axis and the four private tiles *appear* needs a
/// fixture where they do.
func selfCheckFramesPrivateLive(thermalPressure: ThermalPressure = .nominal) -> SummaryFrames {
    let base = selfCheckFrames()
    let now = ContinuousClock().now

    let gpu = GPUSample(utilization: 0.42, source: "IOReport", uncertain: false,
                        chipName: "Apple M4 Pro", coreCount: 20, idleStateName: "IDLE")
    let energy = EnergySample(
        watts: 8.4, cpuWatts: 4.0, gpuWatts: 3.0, aneWatts: 1.4,
        contributingChannels: ["CPU Energy", "GPU", "ANE"], aneUtilization: 0.18, aneSource: "power/8W"
    )
    let thermalSensors = [
        ThermalSample.Sensor(name: "tdie1", celsius: 46), ThermalSample.Sensor(name: "tdie2", celsius: 42),
        ThermalSample.Sensor(name: "tdie3", celsius: 38), ThermalSample.Sensor(name: "tdie4", celsius: 35),
    ]
    let thermal = ThermalSample(sensors: thermalSensors, maxCelsius: 46, rejected: [])
    let frequency = FrequencySample(
        performanceMegahertz: 2200, maxMegahertz: 4500, fraction: 0.49,
        stateCount: 6, tableSource: "device-tree:voltage-states5-sram"
    )
    let temperatureRamp = (0..<60).map { 30.0 + 16.0 * Double($0) / 59 }

    return SummaryFrames(
        cpu: base.cpu, memory: base.memory, disk: base.disk, network: base.network,
        processes: base.processes,
        gpu: .init(previous: gpu, current: gpu, sampledAt: now, interval: SampleRate.hz2, state: .live),
        energy: .init(previous: energy, current: energy, sampledAt: now, interval: SampleRate.hz1, state: .live),
        thermal: .init(previous: thermal, current: thermal, sampledAt: now, interval: SampleRate.hz1, state: .live),
        frequency: .init(previous: frequency, current: frequency, sampledAt: now,
                         interval: SampleRate.hz2, state: .live),
        cpuTotal: base.cpuTotal, cpuSystem: base.cpuSystem,
        memoryHistory: base.memoryHistory, diskHistory: base.diskHistory, networkHistory: base.networkHistory,
        gpuHistory: Array(repeating: 0.42, count: 120),
        energyHistory: (0..<60).map { 6.0 + 4.0 * Double($0) / 59 },
        temperatureHistory: [
            temperatureRamp, temperatureRamp.map { $0 - 4 },
            temperatureRamp.map { $0 - 8 }, temperatureRamp.map { $0 - 11 },
        ],
        temperatureNames: ["tdie1", "tdie2", "tdie3", "tdie4"],
        powerSource: PowerSourceInfo(type: "AC Power", chargePercent: nil, timeToEmptyMinutes: nil,
                                    cycleCount: nil, wholeSystemWatts: nil),
        thermalPressure: thermalPressure,
        generation: base.generation,
        health: ProviderID.allCases.map { ProviderHealth(id: $0, state: .live) }
    )
}

/// `selfCheckFrames()` with the CPU and memory frames in `state` and their histories emptied —
/// the Performance pane's warming arm (phase-10, 5.1). `.stalled` is not exercised here:
/// §4.8's stalled headline drifts from the spec on Summary today (phase-10 override O-5).
func selfCheckFrames(cpuAndMemory state: MetricState) -> SummaryFrames {
    let base = selfCheckFrames()
    return SummaryFrames(
        cpu: .init(previous: nil, current: nil, sampledAt: nil,
                   interval: SampleRate.hz10, state: state),
        memory: .init(previous: nil, current: nil, sampledAt: nil,
                      interval: SampleRate.hz10, state: state),
        disk: base.disk, network: base.network, processes: base.processes,
        gpu: base.gpu, energy: base.energy, thermal: base.thermal, frequency: base.frequency,
        cpuTotal: [], cpuSystem: [],
        memoryHistory: [],
        diskHistory: base.diskHistory, networkHistory: base.networkHistory,
        gpuHistory: base.gpuHistory, energyHistory: base.energyHistory,
        temperatureHistory: base.temperatureHistory, temperatureNames: base.temperatureNames,
        powerSource: base.powerSource, thermalPressure: base.thermalPressure,
        generation: base.generation,
        health: base.health.map { $0.id == .cpu || $0.id == .memory ? ProviderHealth(id: $0.id, state: state) : $0 }
    )
}

// MARK: - Phase-11's fixtures (gate 12's Power & Freq arm, 5.1, D-25)

/// `count` MHz values evenly spaced from `first` to `last`. The endpoints are exact because
/// they are what the right axis and the end labels show; the step is derived from them.
private func selfCheckTable(first: Double, last: Double, count: Int) -> [Double] {
    (0..<count).map { first + (last - first) * Double($0) / Double(count - 1) }
}

/// One cluster: `DOWN` then one active state per table entry. Idle holds 0.40 of every
/// sample and the active states share 0.60 on a linear ramp -- uneven on purpose, so the
/// histogram's bars are visibly different heights and a transposed implementation fails.
/// `paired: false` is D-11's shape: no table source, the key it wanted, no MHz anywhere.
private func selfCheckCluster(
    name: String, label: String, cores: Int, table: [Double], average: Double,
    tableKey: String, paired: Bool = true
) -> ClusterFrequency {
    let weights = (1...table.count).map(Double.init)
    let total = weights.reduce(0, +)
    var states = [ClusterFrequency.State(name: "DOWN", megahertz: nil, residencyFraction: 0.40, isIdle: true)]
    for (index, megahertz) in table.enumerated() {
        states.append(ClusterFrequency.State(
            name: "V\(index)", megahertz: paired ? megahertz : nil,
            residencyFraction: 0.60 * weights[index] / total, isIdle: false
        ))
    }
    return ClusterFrequency(
        name: name, label: label, coreCount: cores, states: states,
        averageMegahertz: paired ? average : nil, maxMegahertz: paired ? table.last : nil,
        tableSource: paired ? "device-tree:\(tableKey)" : nil,
        missingTableKey: paired ? nil : tableKey
    )
}

/// `selfCheckFramesPrivateLive()` with the five defaulted `SummaryFrames` fields filled in:
/// three clusters (a 20-state P table, so 4.3's merge rule and the sparse-label rule are both
/// exercised by a rendered pixel), 120 `hz2` samples each with a sloped average so the
/// per-column right axis is checkable by eye in the dump, and four 60-sample power buffers
/// whose current values total `5.2 W`. `eClusterPaired: false` is D-11's fixture -- only the
/// `ECPU` cluster unpaired, the two P clusters unchanged.
private func selfCheckFramesPower(eClusterPaired: Bool) -> SummaryFrames {
    let base = selfCheckFramesPrivateLive()
    let now = ContinuousClock().now
    let pTable = selfCheckTable(first: 1260, last: 4512, count: 19)
    let eTable = selfCheckTable(first: 912, last: 2592, count: 7)
    let clusters = [
        selfCheckCluster(name: "PCPU", label: "P0", cores: 5, table: pTable, average: 3900,
                         tableKey: "voltage-states5-sram"),
        selfCheckCluster(name: "PCPU1", label: "P1", cores: 5, table: pTable, average: 3900,
                         tableKey: "voltage-states5-sram"),
        selfCheckCluster(name: "ECPU", label: "E", cores: 4, table: eTable, average: 1900,
                         tableKey: "voltage-states1-sram", paired: eClusterPaired),
    ]
    // The same fractions every sample (the bands are flat and present); the average ramps
    // 3200 → 3900 for P and 1400 → 1900 for E so the line is visibly sloped.
    let history = clusters.map { cluster in
        let (from, to) = cluster.label.hasPrefix("E") ? (1400.0, 1900.0) : (3200.0, 3900.0)
        return ClusterHistory(
            name: cluster.name,
            residency: Array(repeating: cluster.states.map(\.residencyFraction), count: 120),
            averageMegahertz: (0..<120).map { from + (to - from) * Double($0) / 119 }
        )
    }
    let frequency = FrequencySample(
        performanceMegahertz: 3900, maxMegahertz: 4512, fraction: 3900 / 4512, stateCount: 20,
        tableSource: "device-tree:voltage-states5-sram", clusters: clusters
    )
    // `watts` stays the three-channel sum (D-07); the pane's headline is the four-channel 5.2.
    let energy = EnergySample(
        watts: 4.0, cpuWatts: 3.1, gpuWatts: 0.9, aneWatts: 0.0,
        contributingChannels: ["CPU Energy", "GPU", "ANE", "DRAM"], aneUtilization: 0.0,
        aneSource: "power/8W", dramWatts: 1.2
    )
    func ramp(_ watts: Double) -> [Double] { (0..<60).map { watts * (0.9 + 0.2 * Double($0) / 59) } }

    return SummaryFrames(
        cpu: base.cpu, memory: base.memory, disk: base.disk, network: base.network,
        processes: base.processes, gpu: base.gpu,
        energy: .init(previous: energy, current: energy, sampledAt: now, interval: SampleRate.hz1, state: .live),
        thermal: base.thermal,
        frequency: .init(previous: frequency, current: frequency, sampledAt: now,
                         interval: SampleRate.hz2, state: .live),
        cpuTotal: base.cpuTotal, cpuSystem: base.cpuSystem,
        memoryHistory: base.memoryHistory, diskHistory: base.diskHistory, networkHistory: base.networkHistory,
        gpuHistory: base.gpuHistory, energyHistory: base.energyHistory,
        temperatureHistory: base.temperatureHistory, temperatureNames: base.temperatureNames,
        powerSource: base.powerSource, thermalPressure: base.thermalPressure,
        generation: base.generation, health: base.health,
        clusterHistory: history, cpuWattsHistory: ramp(3.1), gpuWattsHistory: ramp(0.9),
        aneWattsHistory: ramp(0.0), dramWattsHistory: ramp(1.2)
    )
}

/// The live arm's fixture: all three clusters paired, every card plotting.
func selfCheckFramesPower() -> SummaryFrames {
    selfCheckFramesPower(eClusterPaired: true)
}

/// D-11's fixture: the `ECPU` cluster alone unpaired, its neighbours live. The only way
/// that state is reachable offscreen.
func selfCheckFramesPowerColumnUnavailable() -> SummaryFrames {
    selfCheckFramesPower(eClusterPaired: false)
}

/// `selfCheckFramesPower()` with the frequency **and** energy frames in `state` and their
/// histories emptied (the five defaulted fields stay at their defaults). `.warming` and
/// `.unavailable(reason: PrivateAPI.disabledReason)` -- PWR-05's construction -- are the
/// two states gate 12 renders.
func selfCheckFramesPower(state: MetricState) -> SummaryFrames {
    let base = selfCheckFramesPower()
    return SummaryFrames(
        cpu: base.cpu, memory: base.memory, disk: base.disk, network: base.network,
        processes: base.processes, gpu: base.gpu,
        energy: .init(previous: nil, current: nil, sampledAt: nil, interval: SampleRate.hz1, state: state),
        thermal: base.thermal,
        frequency: .init(previous: nil, current: nil, sampledAt: nil, interval: SampleRate.hz2, state: state),
        cpuTotal: base.cpuTotal, cpuSystem: base.cpuSystem,
        memoryHistory: base.memoryHistory, diskHistory: base.diskHistory, networkHistory: base.networkHistory,
        gpuHistory: base.gpuHistory, energyHistory: [],
        temperatureHistory: base.temperatureHistory, temperatureNames: base.temperatureNames,
        powerSource: base.powerSource, thermalPressure: base.thermalPressure,
        generation: base.generation,
        health: base.health.map {
            $0.id == .frequency || $0.id == .energy ? ProviderHealth(id: $0.id, state: state) : $0
        }
    )
}
