import CoreGraphics
import Foundation
import GlowTopCore
import Metal
import Vision

// CLI smoke path from SPEC.md §13.6: every provider's numbers get checked against a
// system tool rather than trusted. Prints JSON lines at the provider's nominal rate
// until interrupted.

/// JSON shape for the `channels` subcommand -- SPEC.md §5.6.1's discovery instrument, and
/// what makes "which channel did you actually read" answerable in the phase record.
private struct ChannelJSON: Encodable {
    let group: String
    let subGroup: String
    let name: String
    let unit: String
}

// MARK: - §13.6's controlled inputs (1.3)
//
// Written before the providers they check (phase-02's recorded lesson): a Metal compute
// loop for GPU, a Vision inference loop for the ANE, and `yes` × `hw.logicalcpu` for
// sustained CPU load, which serves both the thermal and frequency checks. Every generator
// tears down in a `defer` on every path out, including `SIGINT` -- `killall yes` is not the
// teardown; the PIDs are tracked and terminated directly.

/// One Metal compute pipeline, dispatched in a tight loop on a background thread while
/// running. The kernel is a source string compiled with `makeLibrary(source:options:)` --
/// no `.metal` file, no build-system change.
private final class MetalLoad: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let buffer: MTLBuffer
    private var thread: Thread?
    private var running = false

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void glowtopSpin(device float *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
            float v = buf[id];
            for (int i = 0; i < 4096; i++) { v = v * 1.0000001f + 1.0f; }
            buf[id] = v;
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let function = library.makeFunction(name: "glowtopSpin"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let buffer = device.makeBuffer(length: (1 << 20) * MemoryLayout<Float>.size, options: .storageModeShared)
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.buffer = buffer
    }

    func start() {
        guard !running else { return }
        running = true
        let thread = Thread { [self] in
            let width = pipeline.maxTotalThreadsPerThreadgroup
            let elementCount = buffer.length / MemoryLayout<Float>.size
            let threadsPerGroup = MTLSize(width: width, height: 1, depth: 1)
            let groups = MTLSize(width: (elementCount + width - 1) / width, height: 1, depth: 1)
            while running {
                guard let cmd = queue.makeCommandBuffer(), let encoder = cmd.makeComputeCommandEncoder() else { break }
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
                encoder.endEncoding()
                cmd.commit()
                cmd.waitUntilCompleted()
            }
        }
        thread.start()
        self.thread = thread
    }

    func stop() {
        running = false
        thread = nil
    }
}

/// `VNGenerateImageFeaturePrintRequest` over a synthesised 640×640 image, looped on a
/// background thread. A real on-device model inference with no model file, no download and
/// no dependency -- honours the ANE's locked controlled-input decision literally.
private final class VisionLoad: @unchecked Sendable {
    private let image: CGImage?
    private var thread: Thread?
    private var running = false

    init() {
        image = Self.makeSyntheticImage()
    }

    func start() {
        guard !running, let image else { return }
        running = true
        let thread = Thread { [self] in
            while running {
                let request = VNGenerateImageFeaturePrintRequest()
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])
            }
        }
        thread.start()
        self.thread = thread
    }

    func stop() {
        running = false
        thread = nil
    }

    private static func makeSyntheticImage() -> CGImage? {
        let side = 640
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1)
        context.fillEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        return context.makeImage()
    }
}

/// `yes > /dev/null`, one per logical core -- §5.8's controlled input for die temperature
/// and §5.9's for P-cluster frequency. PIDs are tracked and terminated directly; `terminate()`
/// sends `SIGTERM` to each child, and every child is waited on so none is left a zombie.
private final class YesLoad {
    private var processes: [Process] = []

    func start() {
        guard processes.isEmpty else { return }
        let coreCount = Sysctl.integer("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<max(1, coreCount) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            processes.append(process)
        }
    }

    func stop() {
        for process in processes where process.isRunning {
            process.terminate()
        }
        for process in processes {
            process.waitUntilExit()
        }
        processes.removeAll()
    }
}

/// Toggles a generator on for `seconds`, off for `seconds`, repeating for the run's length.
/// `isActive` is read at each emitted sample, so `"load":true`/`"load":false` lines come
/// from the **same** probe invocation -- SPEC.md §13.7.1: arms run rotated, never all of one
/// then all of the other.
private final class LoadRunner: @unchecked Sendable {
    enum Kind { case gpu, npu, cpu }

    private let kind: Kind
    private(set) var isActive = false
    private var timer: DispatchSourceTimer?
    private var metal: MetalLoad?
    private var vision: VisionLoad?
    private var yes: YesLoad?

    init(kind: Kind) {
        self.kind = kind
    }

    func start(burstSeconds: Double) {
        isActive = true
        beginBurst()
        let source = DispatchSource.makeTimerSource(queue: .global())
        source.schedule(deadline: .now() + burstSeconds, repeating: burstSeconds)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            isActive.toggle()
            isActive ? beginBurst() : endBurst()
        }
        source.resume()
        timer = source
    }

    /// Cancels the toggle timer and tears down whichever generator is currently running.
    /// Safe to call more than once (a normal exit and a `SIGINT` can both reach this).
    func stop() {
        timer?.cancel()
        timer = nil
        endBurst()
        isActive = false
    }

    private func beginBurst() {
        switch kind {
        case .gpu:
            let load = metal ?? MetalLoad()
            metal = load
            load?.start()
        case .npu:
            let load = vision ?? VisionLoad()
            vision = load
            load.start()
        case .cpu:
            let load = yes ?? YesLoad()
            yes = load
            load.start()
        }
    }

    private func endBurst() {
        switch kind {
        case .gpu: metal?.stop()
        case .npu: vision?.stop()
        case .cpu: yes?.stop()
        }
    }
}

/// Set only while a `--load` run's generator is active, so the `SIGINT` handler below can
/// tear it down. A Ctrl-C'd probe must not leave `yes` (or a Metal/Vision loop) running.
nonisolated(unsafe) private var activeLoadRunner: LoadRunner?

signal(SIGINT) { _ in
    activeLoadRunner?.stop()
    exit(130)
}

let arguments = CommandLine.arguments

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]

func emit(_ object: some Encodable, load: Bool? = nil) {
    guard let data = try? encoder.encode(object) else { return }
    guard let load else {
        guard let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
        return
    }
    // §13.6: a real provider's sample gains a `"load"` field when streamed under `--load`,
    // so the interleaved arm reads from the same JSON shape as every other field rather than
    // a second, differently-shaped line.
    guard var merged = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    merged["load"] = load
    guard let mergedData = try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys]),
          let line = String(data: mergedData, encoding: .utf8)
    else { return }
    print(line)
    fflush(stdout)
}

func emitState(_ state: String, reason: String? = nil) {
    let payload = reason.map { "{\"state\":\"\(state)\",\"reason\":\"\($0)\"}" }
        ?? "{\"state\":\"\(state)\"}"
    print(payload)
    fflush(stdout)
}

// Not a `ProviderID`: a separate string compare, checked before the guard below, so the
// dispatch switch further down stays exhaustive over `ProviderID` with no `default:`.
if arguments.count >= 2, arguments[1] == "channels" {
    if PrivateAPI.disabled {
        emitState("unavailable", reason: PrivateAPI.disabledReason)
        exit(1)
    }
    guard let raw = IOReport.copyAll() else {
        emitState("unavailable", reason: "IOReport subscription failed")
        exit(1)
    }
    for channel in IOReport.decodeChannels(raw) {
        emit(ChannelJSON(group: channel.group, subGroup: channel.subGroup, name: channel.name, unit: channel.unit))
    }
    IOReport.releaseRaw(raw)
    exit(0)
}

/// One flat JSON object, every §9.2 row, so §13.6's new rows are cross-checkable from a
/// terminal (`sysctl`, `sw_vers`) rather than only from a window. Field names are picked to
/// read close to §9.2's own row names.
private struct SysInfoJSON: Encodable {
    let modelName: String
    let modelIdentifier: String
    let chip: String
    let totalCores: String
    let gpuCores: String
    let neuralEngineCores: String
    let memory: String
    let serialNumber: String
    let hardwareUUID: String
    let macOSVersion: String
    let build: String
    let kernel: String
    let uptime: String
    let bootVolume: String
    let computerName: String
    let memoryInUse: String
    let memoryPressure: String
    let swapUsed: String
    let bootVolumeCapacity: String
    let version: String
    let ownCPURSS: String
    let frameRate: String
    let providers: String
}

/// Not a `ProviderID`: §9's readers have no sample loop either, so `sysinfo` is a one-shot
/// string compare beside `channels` and `actions` rather than a case the streaming dispatch
/// switch below has to carry.
if arguments.count >= 2, arguments[1] == "sysinfo" {
    func value(_ rows: [SystemInfo.Row], _ label: String) -> String {
        rows.first(where: { $0.label == label })?.value ?? Format.unknown
    }

    let staticRows = SystemInfoReader.staticRows()
    var memoryProvider = MemoryProvider()
    let memorySample: MemorySample
    if case .value(let sample, _) = memoryProvider.sample() {
        memorySample = sample
    } else {
        memorySample = MemorySample(
            resident: 0, reclaimable: 0, free: 0, total: 0, active: 0, wired: 0,
            compressed: 0, swapUsed: 0, pageSize: 0, inactive: 0, purgeable: 0,
            speculative: 0, cached: 0
        )
    }
    var reader = SystemInfoReader()
    // No `MetricStore` in a one-shot CLI: the Providers/Frame-rate rows have nothing live to
    // read from, and render `—` honestly rather than a fabricated number (§4.8).
    let live = reader.liveRows(memory: memorySample, health: [], frameRate: nil)

    let json = SysInfoJSON(
        modelName: value(staticRows.hardware, "Model name"),
        modelIdentifier: value(staticRows.hardware, "Model identifier"),
        chip: value(staticRows.hardware, "Chip"),
        totalCores: value(staticRows.hardware, "Total cores"),
        gpuCores: value(staticRows.hardware, "GPU cores"),
        neuralEngineCores: value(staticRows.hardware, "Neural Engine cores"),
        memory: value(staticRows.hardware, "Memory"),
        serialNumber: value(staticRows.hardware, "Serial number"),
        hardwareUUID: value(staticRows.hardware, "Hardware UUID"),
        macOSVersion: value(staticRows.software, "macOS version"),
        build: value(staticRows.software, "Build"),
        kernel: value(staticRows.software, "Kernel"),
        uptime: live.uptime.value,
        bootVolume: value(staticRows.software, "Boot volume"),
        computerName: value(staticRows.software, "Computer name"),
        memoryInUse: value(live.memoryAndStorage, "Memory in use"),
        memoryPressure: value(live.memoryAndStorage, "Memory pressure"),
        swapUsed: value(live.memoryAndStorage, "Swap used"),
        bootVolumeCapacity: value(live.memoryAndStorage, "Boot volume capacity / free"),
        version: value(live.glowTop, "Version"),
        ownCPURSS: value(live.glowTop, "Own CPU / RSS"),
        frameRate: value(live.glowTop, "Frame rate"),
        providers: value(live.glowTop, "Providers")
    )
    emit(json)
    exit(0)
}

// Not a `ProviderID` either -- §8.5's write path has no sample loop, so it is a separate
// string compare beside `channels` rather than a case the dispatch switch below has to carry.
if arguments.count >= 2, arguments[1] == "actions" {
    if arguments.contains("--guardrail-check") {
        // Issues no signal: the guardrail returns before the signal syscall runs at all,
        // which is the property this flag demonstrates. This is how 5.3's guardrail
        // acceptance path is run without a window.
        let result = ProcessActions.attempt(pid: 1, name: "launchd", uid: 0, signal: .term)
        print("result=\(result.rawValue)")
        fflush(stdout)
        exit(0)
    }

    let url = ProcessActions.logURL
    print("path=\(url.path)")
    if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
       let permissions = attributes[.posixPermissions] as? NSNumber {
        print("mode=\(String(permissions.uint16Value, radix: 8))")
    } else {
        print("mode=—")
    }
    if let contents = try? String(contentsOf: url, encoding: .utf8) {
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.suffix(5) { print(line) }
    }
    fflush(stdout)
    exit(0)
}

/// §11's two sections, one JSON object, so §13.6's cross-checks (`dscl`, `who`) are runnable
/// from a terminal.
private struct UsersJSON: Encodable {
    struct AccountJSON: Encodable {
        let name: String
        let fullName: String
        let uid: UInt32
        let group: String
        let homeDirectory: String
        let shell: String
        let admin: Bool
    }
    struct SessionJSON: Encodable {
        let user: String
        let kind: String
        let line: String
        let host: String
        let elapsed: String
    }
    let accounts: [AccountJSON]
    let sessions: [SessionJSON]
}

// Not a `ProviderID`: §11's readers have no sample loop either, so `users` is a one-shot
// string compare beside `sysinfo`/`startup`.
if arguments.count >= 2, arguments[1] == "users" {
    let accounts = UsersReader.readAccounts().map {
        UsersJSON.AccountJSON(
            name: $0.name, fullName: $0.fullName, uid: $0.uid, group: $0.group,
            homeDirectory: $0.homeDirectory, shell: $0.shell, admin: $0.admin
        )
    }
    let sessions = UsersReader.readSessions().map {
        UsersJSON.SessionJSON(user: $0.user, kind: $0.kind.rawValue, line: $0.line, host: $0.host, elapsed: $0.elapsedText)
    }
    emit(UsersJSON(accounts: accounts, sessions: sessions))
    exit(0)
}

/// One flat JSON object per §10.2 job, so §13.6's new cross-checks are runnable from a
/// terminal. Field names mirror `LaunchdJob`'s own.
private struct LaunchdJobJSON: Encodable {
    let label: String
    let type: String
    let program: String
    let runAtLoad: Bool?
    let keepAlive: String?
    let path: String
    let enabled: Bool?
}

// Not a `ProviderID`: §10's readers have no sample loop either, so `startup` is a one-shot
// string compare beside `sysinfo` rather than a case the streaming dispatch switch carries.
if arguments.count >= 2, arguments[1] == "startup" {
    // 2.1/3.2: the pane's Enabled column reads the override store, not just the plist's own
    // `Disabled` key -- this arm must thread the same store through, or the §13.6 Enabled-
    // column cross-check would be comparing the pane against an instrument that disagrees
    // with it by construction (4.1).
    let (overrides, overrideNote) = LaunchdOverrides.read()
    let inventory = LaunchdReader.read(overrides: overrides)
    for job in inventory.jobs {
        emit(LaunchdJobJSON(
            label: job.label, type: job.type, program: job.program,
            runAtLoad: job.runAtLoad, keepAlive: job.keepAlive, path: job.path, enabled: job.enabled
        ))
    }
    // 4.2 took outcome B: the BTM store fails its own honesty rule on the reference machine
    // (question 3 -- see `LoginItemsReader.swift`), so this always reads `.unavailable`.
    switch LoginItemsReader.read() {
    case .unavailable(let reason):
        print("login-items: unavailable (\(reason))")
    }
    for note in inventory.footerNotes {
        print("footer: \(note)")
    }
    if let overrideNote {
        print("footer: \(overrideNote)")
    }
    fflush(stdout)
    exit(0)
}

/// One flat JSON object per `InstalledApp`, so §13.6's `du`/`codesign`/`lipo`/`plutil` cross-
/// check is runnable field by field from a terminal.
private struct InstalledAppJSON: Encodable {
    let bundlePath: String
    let name: String
    let version: String?
    let bundleIdentifier: String?
    let allocatedBytes: UInt64?
    let signingIdentity: String?
    let architectures: [String]
    let isUnparseable: Bool
}

// Not a `ProviderID`: D-18's reader has no sample loop either, so `apps` is a one-shot string
// compare beside `startup`, copying its shape exactly -- no streaming loop, one pass, exit.
if arguments.count >= 2, arguments[1] == "apps" {
    let scan = InstalledAppsReader.scan()
    for app in scan.apps.sorted(by: { ($0.allocatedBytes ?? 0) > ($1.allocatedBytes ?? 0) }) {
        emit(InstalledAppJSON(
            bundlePath: app.bundlePath, name: app.name, version: app.version,
            bundleIdentifier: app.bundleIdentifier, allocatedBytes: app.allocatedBytes,
            signingIdentity: app.signingIdentity, architectures: app.architectures,
            isUnparseable: app.isUnparseable
        ))
    }
    for root in scan.unreadableRoots {
        print("footer: \(root) is unreadable")
    }
    print("scanned \(scan.scannedCount) bundles in \(String(format: "%.1f", scan.millisecondsElapsed)) ms")
    fflush(stdout)
    exit(0)
}

/// One flat JSON object per §12.2 row, so §13.6's cross-check (`launchctl list <label>`
/// exact-PID agreement over the overlap) is runnable from a terminal.
private struct ServiceRowJSON: Encodable {
    let label: String
    let type: String
    let program: String
    let status: String
    let pid: Int32?
}

// Not a `ProviderID`: §12's model has no sample loop either, so `services` is a one-shot
// string compare beside `startup`/`users`.
if arguments.count >= 2, arguments[1] == "services" {
    var processProvider = ProcessProvider()
    // ProcessProvider is delta-based (§5.0.3): its first sample always returns `.warming`,
    // with no baseline yet to diff against. A one-shot inventory needs a real process table
    // to correlate running state against, so warm it with a throwaway sample first.
    _ = processProvider.sample()
    Thread.sleep(forTimeInterval: 0.2)
    let processes: [ProcessRow]
    if case .value(let sample, _) = processProvider.sample() {
        processes = sample.rows
    } else {
        processes = []
    }
    let jobs = LaunchdReader.read().jobs
    for row in ServicesModel.correlate(jobs: jobs, processes: processes) {
        emit(ServiceRowJSON(label: row.label, type: row.type, program: row.program, status: row.status.rawValue, pid: row.pid))
    }
    fflush(stdout)
    exit(0)
}

/// One flat JSON object per `SocketRow`, so §13.6's `lsof -nP -i` cross-check is runnable
/// field by field from a terminal.
private struct SocketRowJSON: Encodable {
    let pid: Int32
    let fd: Int32
    let processName: String
    let transport: String
    let isIPv6: Bool
    let localAddress: String
    let localPort: Int
    let remoteAddress: String
    let remotePort: Int
    let tcpState: Int?
    let tcpStateName: String?
    let scopeInterface: String
}

private struct ConnectionsSampleJSON: Encodable {
    let rows: [SocketRowJSON]
    let pidCount: Int
    let inspectedPIDCount: Int
    let enumerationMilliseconds: Double
}

// D-07/F-3: `ConnectionsProvider` is not a `MetricProvider` and carries no `ProviderID`, so
// `stream<P: MetricProvider>` below cannot be reused for it -- this arm copies that loop's
// body without the generic constraint. `--count` parsed locally: the global `limit` further
// down the file is not yet in scope this early. No `--load` arm (§13.6 names no controlled
// input for socket enumeration).
if arguments.count >= 2, arguments[1] == "connections" {
    var connectionsLimit = Int.max
    if let flag = arguments.firstIndex(of: "--count"), arguments.count > flag + 1,
       let value = Int(arguments[flag + 1]) {
        connectionsLimit = value
    }
    var provider = ConnectionsProvider()
    var connectionsEmitted = 0
    while connectionsEmitted < connectionsLimit {
        switch provider.sample() {
        case .value(let sample, _):
            let json = ConnectionsSampleJSON(
                rows: sample.rows.map { row in
                    SocketRowJSON(
                        pid: row.pid, fd: row.fd, processName: row.processName,
                        transport: row.transport.rawValue, isIPv6: row.isIPv6,
                        localAddress: row.localAddress, localPort: row.localPort,
                        remoteAddress: row.remoteAddress, remotePort: row.remotePort,
                        tcpState: row.tcpState,
                        tcpStateName: row.tcpState.map(ConnectionsProvider.tcpStateName),
                        scopeInterface: row.scopeInterface
                    )
                },
                pidCount: sample.pidCount, inspectedPIDCount: sample.inspectedPIDCount,
                enumerationMilliseconds: sample.enumerationMilliseconds
            )
            emit(json)
            connectionsEmitted += 1
        case .warming:
            // Never reached -- 2.1's provider has no delta state, so its first sample is
            // always `.value`.
            emitState("warming")
        case .unavailable(let reason):
            emitState("unavailable", reason: reason)
            exit(1)
        }
        Thread.sleep(forTimeInterval: 1.0) // SampleRate.hz1's own interval, spelled out here
    }
    exit(0)
}

/// One flat JSON object per `VolumeInfo`, so §13.6's `df`/`diskutil` cross-check is runnable
/// field by field from a terminal.
private struct VolumeJSON: Encodable {
    let name: String
    let path: String
    let capacityBytes: UInt64
    let freeBytes: UInt64
    let importantUsageFreeBytes: UInt64?
    let isRemovable: Bool
    let isInternal: Bool
    let isRootFileSystem: Bool
}

/// One flat JSON object per `DirectoryChild`, so §13.6's `du`/`ls` cross-check is runnable
/// field by field from a terminal.
private struct DirectoryChildJSON: Encodable {
    let name: String
    let path: String
    let isDirectory: Bool
    let readable: Bool
    let allocatedBytes: UInt64?
    let apparentBytes: UInt64?
    let entries: Int
}

// D-08: `DiskSpaceReader` is not a `MetricProvider` and carries no `ProviderID`, so
// `stream<P: MetricProvider>` below cannot be reused -- this arm is a one-shot string compare
// beside `connections`, parsing its own `--volumes` flag and path argument: the global
// argument parsing further down the file is not yet in scope this early (F-12).
if arguments.count >= 2, arguments[1] == "disk-space" {
    if arguments.contains("--volumes") {
        for volume in DiskSpaceReader.volumes() {
            emit(VolumeJSON(
                name: volume.name, path: volume.path, capacityBytes: volume.capacityBytes,
                freeBytes: volume.freeBytes, importantUsageFreeBytes: volume.importantUsageFreeBytes,
                isRemovable: volume.isRemovable, isInternal: volume.isInternal,
                isRootFileSystem: volume.isRootFileSystem
            ))
        }
        fflush(stdout)
        exit(0)
    }
    let path = arguments.count >= 3 && !arguments[2].hasPrefix("--")
        ? arguments[2]
        : FileManager.default.homeDirectoryForCurrentUser.path
    let result = DiskSpaceReader.children(of: URL(fileURLWithPath: path))
    for child in result.children {
        emit(DirectoryChildJSON(
            name: child.name, path: child.path, isDirectory: child.isDirectory,
            readable: child.readable, allocatedBytes: child.allocatedBytes,
            apparentBytes: child.apparentBytes, entries: child.entries
        ))
    }
    if let reason = result.rootUnavailableReason {
        print("footer: \(path) is unreadable — \(reason)")
    }
    let entries = result.children.reduce(0) { $0 + $1.entries }
    print("sized \(result.sizedCount) children, \(entries) entries in "
          + String(format: "%.1f", result.millisecondsElapsed) + " ms")
    fflush(stdout)
    exit(0)
}

/// One JSON object per verb call, so REG-02's D-13 sequence and §14.4's sheet text are both
/// readable field by field from a terminal, against the independent `print` reading's own
/// exit status and `pid =` line at the same instant.
private struct JobActionJSON: Encodable {
    let label: String
    let verb: String
    let type: String
    let path: String
    let sheetMessageText: String
    let sheetInformativeText: String
    let result: String
    let pid: Int32?
    let logLine: String
}

// Not a `ProviderID`: §14.4's write actions have no sample loop either, so `job` is a
// one-shot string compare beside `disk-space`, parsing its own two arguments (F-5). The verb
// argument is mapped through `JobVerb(rawValue:)` and then a fixed four-case `switch` to one
// of `JobActions`' four public functions -- never a passthrough (ACT-07), so this arm can
// never become a generic argv wrapper.
if arguments.count >= 2, arguments[1] == "job" {
    guard arguments.count >= 4, let verb = JobVerb(rawValue: arguments[2]) else {
        FileHandle.standardError.write(Data("usage: glowtop-probe job <enable|disable|start|stop> <label>\n".utf8))
        exit(2)
    }
    let label = arguments[3]

    let (overrides, _) = LaunchdOverrides.read()
    let inventory = LaunchdReader.read(overrides: overrides)
    guard let job = inventory.jobs.first(where: { $0.label == label }) else {
        print("label \(label) not found")
        exit(1)
    }

    let sheetText = JobActions.sheetText(for: job, verb: verb)
    let outcome: JobOutcome
    switch verb {
    case .enable: outcome = JobActions.enable(job)
    case .disable: outcome = JobActions.disable(job)
    case .start: outcome = JobActions.start(job)
    case .stop: outcome = JobActions.stop(job)
    }

    emit(JobActionJSON(
        label: job.label, verb: verb.rawValue, type: job.type, path: job.path,
        sheetMessageText: sheetText.messageText, sheetInformativeText: sheetText.informativeText,
        result: outcome.result.rawValue, pid: outcome.pid, logLine: outcome.logLine
    ))
    exit(0)
}

guard arguments.count >= 2, let provider = ProviderID(rawValue: arguments[1]) else {
    let names = ProviderID.allCases.map(\.rawValue).joined(separator: ", ")
    FileHandle.standardError.write(Data("usage: glowtop-probe <channels, \(names)> [--count N]\n".utf8))
    exit(2)
}

var limit = Int.max
if let flag = arguments.firstIndex(of: "--count"), arguments.count > flag + 1,
   let value = Int(arguments[flag + 1]) {
    limit = value
}

/// `--load <seconds>` -- SPEC.md §13.6, on the `gpu`, `npu`, `thermal` and `frequency`
/// subcommands only.
var loadBurstSeconds: Double?
if let flag = arguments.firstIndex(of: "--load"), arguments.count > flag + 1,
   let value = Double(arguments[flag + 1]) {
    loadBurstSeconds = value
}

var emitted = 0

/// One streaming loop for every provider. The per-provider arms used to be verbatim
/// duplicates of each other; with five providers that is five copies of the same eight lines
/// and five chances for one of them to drift.
///
/// Cadence is the provider's own `nominalInterval` (§5.0.2) rather than a hardcoded 0.1 s, so
/// `network` streams at its 4 Hz and `process` at its 1 Hz without this needing to know which
/// is which.
///
/// `@MainActor` because top-level bindings in `main.swift` (`emitted`, `limit`, `emit`) are
/// main-actor isolated under strict concurrency, and this runs on that thread anyway.
///
/// `loadKind` wires §13.6's controlled input in for the `gpu`, `npu`, `thermal` and
/// `frequency` subcommands: when `--load <seconds>` is present, a `LoadRunner` starts
/// alongside the real provider and every emitted sample gains a `"load"` field from the
/// **same** invocation (§13.7.1 — never two runs compared across time). `nil` for providers
/// §13.6 names no controlled input for (`energy`'s package-power headline).
@MainActor
private func stream<P: MetricProvider>(_ provider: P, loadKind: LoadRunner.Kind? = nil) where P.Payload: Encodable {
    var provider = provider
    let (seconds, attoseconds) = provider.nominalInterval.components
    let interval = Double(seconds) + Double(attoseconds) * 1e-18

    var runner: LoadRunner?
    if let loadKind, let burstSeconds = loadBurstSeconds {
        let r = LoadRunner(kind: loadKind)
        activeLoadRunner = r
        r.start(burstSeconds: burstSeconds)
        runner = r
    }

    while emitted < limit {
        switch provider.sample() {
        case .value(let sample, _):
            emit(sample, load: runner?.isActive)
            emitted += 1
        case .warming:
            emitState("warming")
        case .unavailable(let reason):
            // `exit(_:)` skips pending `defer`s -- teardown runs explicitly here rather than
            // deferred (1.3's recorded failure shape, one level removed: an `exit` rather
            // than a `return` skipping it).
            runner?.stop()
            activeLoadRunner = nil
            emitState("unavailable", reason: reason)
            exit(1)
        }
        Thread.sleep(forTimeInterval: interval)
    }

    runner?.stop()
    activeLoadRunner = nil
}

// No `default:` — `ProviderID.allCases` drives the usage line, so the enum growing must be
// a compile error here rather than a silent fallthrough that prints nothing.
switch provider {
case .cpu: stream(CPUProvider())
case .memory: stream(MemoryProvider())
case .disk: stream(DiskProvider())
case .network: stream(NetworkProvider())
case .process:
    var processProvider = ProcessProvider()
    // 2.1: exercises the gated `proc_pid_rusage` call from a terminal, no window needed.
    processProvider.detail = arguments.contains("--detail")
    stream(processProvider)
// SPEC.md §5.6-5.9, phase-03.1. Named here so the usage line stays honest about what the
// app knows exists, and so the probe answers for them the same way the status bar does.
// `energy` has no `--load` arm -- §13.6 names no controlled input for package power.
case .energy: stream(EnergyProvider())
case .gpu: stream(GPUProvider(), loadKind: .gpu)
case .npu: stream(EnergyProvider(), loadKind: .npu)
case .thermal: stream(ThermalProvider(), loadKind: .cpu)
case .frequency: stream(FrequencyProvider(), loadKind: .cpu)
}
