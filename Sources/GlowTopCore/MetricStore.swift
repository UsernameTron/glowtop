import Foundation

/// One provider's identity and state, for §4.7's status phrase.
///
/// A struct rather than the `(ProviderID, MetricState)` tuple this replaced: a tuple array is
/// not `Sendable` across an isolation boundary under strict concurrency, and the old shape
/// only compiled because nothing ever crossed one with it. `SummaryFrames` does.
public struct ProviderHealth: Sendable, Equatable {
    public let id: ProviderID
    public let state: MetricState

    public init(id: ProviderID, state: MetricState) {
        self.id = id
        self.state = state
    }
}

/// One cluster's §6.4 history, for §14.1's cards 1 and 2. One struct rather than three
/// parallel arrays on `SummaryFrames`, because three arrays can disagree in length and
/// one cannot -- the same reason `temperatureNames` and `temperatureHistory` are kept
/// in lockstep by one identity rule.
public struct ClusterHistory: Sendable, Equatable {
    /// The IOReport channel name, e.g. `PCPU1`. Identity, never an index.
    public let name: String
    /// Oldest first. Each element is that sample's per-state residency fractions, in
    /// `ClusterFrequency.states`' order (idle first, then active ascending).
    public let residency: [[Double]]
    /// Oldest first. §5.9.1's weighted mean over active states, this cluster's own.
    public let averageMegahertz: [Double]

    public init(name: String, residency: [[Double]], averageMegahertz: [Double]) {
        self.name = name
        self.residency = residency
        self.averageMegahertz = averageMegahertz
    }
}

/// Everything the Summary pane reads, gathered in one actor entry.
///
/// The alternative is five `await`s plus the histories on every 100 ms tick — 50 uncontended
/// actor hops a second where one will do. Phase-02 recorded that as worth adding "when a
/// single view reads more than two metrics"; the Summary pane reads five plus history.
public struct SummaryFrames: Sendable {
    public let cpu: MetricStore.Frame<CPUSample>
    public let memory: MetricStore.Frame<MemorySample>
    public let disk: MetricStore.Frame<DiskSample>
    public let network: MetricStore.Frame<NetworkSample>
    public let processes: MetricStore.Frame<ProcessSample>
    public let gpu: MetricStore.Frame<GPUSample>
    public let energy: MetricStore.Frame<EnergySample>
    public let thermal: MetricStore.Frame<ThermalSample>
    public let frequency: MetricStore.Frame<FrequencySample>

    /// Oldest first. SPEC.md §6.4.
    public let cpuTotal: [Double]
    /// §4.4's kernel series is `CPUSample.system`.
    public let cpuSystem: [Double]
    public let memoryHistory: [MemorySample]
    public let diskHistory: [DiskSample]
    public let networkHistory: [NetworkSample]
    /// §6.4: 60 s at 500 ms, raw utilization 0-1.
    public let gpuHistory: [Double]
    /// §6.4: 60 s at 1 s, watts.
    public let energyHistory: [Double]
    /// §6.4's "x 4 sensors", keyed by `temperatureNames`' fixed identity.
    public let temperatureHistory: [[Double]]
    public let temperatureNames: [String]

    /// §5.7.2 and §5.8.4 -- public, unaffected by §13.7.3's flag (discretion table).
    public let powerSource: PowerSourceInfo?
    public let thermalPressure: ThermalPressure

    public let generation: UInt64
    public let health: [ProviderHealth]
    /// §6.2's occlusion divisor at the moment these frames were taken: 1 normally, 10 behind a
    /// minimized or fully occluded window. §4.10's verdict windows are expressed in seconds and
    /// scale their sample counts by it, so "the last 10 s" stays 10 s of wall clock rather than
    /// becoming 100 s of history while the window is covered.
    public let samplingDivisor: Int

    /// §14.1's per-cluster histories, one entry per cluster, in `FrequencySample.clusters`'
    /// order. Empty until the frequency provider produces a live sample with clusters.
    public let clusterHistory: [ClusterHistory]
    /// §6.4: 60 s at 1 s, watts, per §5.6.3 channel. Oldest first. A channel absent from a
    /// sample appends 0; the projection omits its band and prints §4.9's unknown rather
    /// than drawing a zero (phase-11 Phase 0's discretion table).
    public let cpuWattsHistory: [Double]
    public let gpuWattsHistory: [Double]
    public let aneWattsHistory: [Double]
    public let dramWattsHistory: [Double]

    /// The five phase-11 parameters are the only defaulted ones on this initializer: of its
    /// six construction sites, five (gate 12's fixtures and `SummaryModelTests`) have nothing
    /// to say about cluster history or per-channel watts, and a default is what keeps those
    /// five diffs from existing (phase-11 override O-2).
    public init(
        cpu: MetricStore.Frame<CPUSample>, memory: MetricStore.Frame<MemorySample>,
        disk: MetricStore.Frame<DiskSample>, network: MetricStore.Frame<NetworkSample>,
        processes: MetricStore.Frame<ProcessSample>, gpu: MetricStore.Frame<GPUSample>,
        energy: MetricStore.Frame<EnergySample>, thermal: MetricStore.Frame<ThermalSample>,
        frequency: MetricStore.Frame<FrequencySample>, cpuTotal: [Double], cpuSystem: [Double],
        memoryHistory: [MemorySample], diskHistory: [DiskSample],
        networkHistory: [NetworkSample], gpuHistory: [Double], energyHistory: [Double],
        temperatureHistory: [[Double]], temperatureNames: [String],
        powerSource: PowerSourceInfo?, thermalPressure: ThermalPressure,
        generation: UInt64, health: [ProviderHealth], samplingDivisor: Int = 1,
        clusterHistory: [ClusterHistory] = [], cpuWattsHistory: [Double] = [],
        gpuWattsHistory: [Double] = [], aneWattsHistory: [Double] = [],
        dramWattsHistory: [Double] = []
    ) {
        self.samplingDivisor = samplingDivisor
        self.clusterHistory = clusterHistory
        self.cpuWattsHistory = cpuWattsHistory
        self.gpuWattsHistory = gpuWattsHistory
        self.aneWattsHistory = aneWattsHistory
        self.dramWattsHistory = dramWattsHistory
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.network = network
        self.processes = processes
        self.gpu = gpu
        self.energy = energy
        self.thermal = thermal
        self.frequency = frequency
        self.cpuTotal = cpuTotal
        self.cpuSystem = cpuSystem
        self.memoryHistory = memoryHistory
        self.diskHistory = diskHistory
        self.networkHistory = networkHistory
        self.gpuHistory = gpuHistory
        self.energyHistory = energyHistory
        self.temperatureHistory = temperatureHistory
        self.temperatureNames = temperatureNames
        self.powerSource = powerSource
        self.thermalPressure = thermalPressure
        self.generation = generation
        self.health = health
    }
}

/// Which pane is on screen. SPEC.md §3.3.
public enum PaneID: String, Sendable, CaseIterable {
    case summary
    /// §14.10's pane. Samples nothing of its own — §3.3 exempts Summary's providers, which is every provider this store owns.
    case performance
    case processes
    case systemInfo
    case startupApps
    case users
    case services
    /// §14.1's pane, the first of §3.2's `PRO` block to ship. Samples nothing of its own --
    /// §3.3 exempts Summary's providers, and both providers this pane reads are Summary's.
    case power
    /// §14.5's pane. Samples the machine's socket table -- the one provider in this app that
    /// is **not** exempted by §3.3 and is **not** a `MetricProvider` either (D-07): it samples
    /// only while this case is `activePane`, on `slowLoop()`'s existing tick, and carries no
    /// `ProviderID` so it never appears in `health()`.
    case connections
    /// §14.3's pane. Samples nothing -- `InstalledAppsReader` is pane-owned (D-18).
    case installedApps
    /// §14.6's pane. Samples nothing through this store: the volume read is a pane-owned
    /// one-shot and the directory walk is a detached task the pane owns and cancels (D-08).
    /// No `Slot`, no `ingest`, no accessor, no `ProviderID` -- a capacity figure has no
    /// current value between reads and §4.8's stall rule would misfire on every idle minute.
    case diskSpace
    /// §7.3's editor. Samples nothing (`ProcessesPaneController`'s peers check `activePane`
    /// against their own case, never exhaustively, so this case adds no switch to update).
    case colors
}

/// Holds the last two snapshots per metric plus 60 seconds of history, and owns the
/// sample loops. SPEC.md §6.1 and §6.3: the sampler writes, the renderer reads, and
/// neither waits for the other.
public actor MetricStore {
    /// What a view needs to draw one interpolated frame: two samples and when the newer
    /// one was taken. SPEC.md §6.6.
    public struct Frame<Payload: Sendable>: Sendable {
        public let previous: Payload?
        public let current: Payload?
        public let sampledAt: ContinuousClock.Instant?
        public let interval: Duration
        public let state: MetricState

        /// `Frame<CPUSample>.State` still spells the same thing it did before `MetricState`
        /// was hoisted out; see the note on `MetricState` for why the hoist was necessary.
        public typealias State = MetricState

        /// Public so gate 12's pane arm can build §5.10's fixture outside this module.
        public init(previous: Payload?, current: Payload?,
                    sampledAt: ContinuousClock.Instant?, interval: Duration,
                    state: MetricState) {
            self.previous = previous
            self.current = current
            self.sampledAt = sampledAt
            self.interval = interval
            self.state = state
        }
    }

    /// The four fields every metric needs, written once instead of once per metric.
    /// Internal rather than private so tests can drive the state machine directly.
    struct Slot<Payload: Sendable>: Sendable {
        let interval: Duration
        var previous: Payload?
        var current: Payload?
        var sampledAt: ContinuousClock.Instant?
        var state: MetricState = .warming

        init(_ interval: Duration) { self.interval = interval }

        mutating func store(_ snapshot: Snapshot<Payload>) {
            switch snapshot {
            case .value(let payload, let timestamp):
                previous = current
                current = payload
                sampledAt = timestamp
                state = .live
            case .warming:
                // `current` is deliberately kept: §4.8 separates warming from stalled by
                // appearance, not by discarding the last good value.
                state = .warming
            case .unavailable(let reason):
                state = .unavailable(reason: reason)
            }
        }

        /// `.stalled` is computed here and never written by a loop — a dead loop cannot
        /// mark itself dead. SPEC.md §4.8.
        func frame() -> Frame<Payload> {
            var state = self.state
            if state == .live, let sampledAt,
               sampledAt.duration(to: ContinuousClock().now) > .seconds(2) {
                state = .stalled
            }
            return Frame(
                previous: previous, current: current, sampledAt: sampledAt,
                interval: interval, state: state
            )
        }
    }

    private var cpu = Slot<CPUSample>(SampleRate.hz10)
    private var memory = Slot<MemorySample>(SampleRate.hz10)
    private var disk = Slot<DiskSample>(SampleRate.hz4)
    private var network = Slot<NetworkSample>(SampleRate.hz4)
    private var processes = Slot<ProcessSample>(SampleRate.hz1)
    private var gpu = Slot<GPUSample>(SampleRate.hz2)
    private var energy = Slot<EnergySample>(SampleRate.hz1)
    private var thermal = Slot<ThermalSample>(SampleRate.hz1)
    private var frequency = Slot<FrequencySample>(SampleRate.hz2)
    /// §14.5's socket table. No history buffer -- a socket table has nothing to accumulate
    /// (D-10), and sampled only while `.connections` is `activePane` (§3.3).
    private var connections = Slot<ConnectionsSample>(SampleRate.hz1)

    /// History. SPEC.md §6.4: fixed capacity, 60 s span — so capacity is 60 × the rate.
    public private(set) var cpuTotalHistory = RingBuffer<Double>(capacity: 600)
    /// §4.4's kernel series. §6.4 gives user, system and kernel their own buffers; only
    /// system is plotted by any §4 chart, and a buffer nothing reads is 4.8 KB of RSS and a
    /// line of upkeep for a chart that does not exist.
    public private(set) var cpuSystemHistory = RingBuffer<Double>(capacity: 600)
    /// `CPUSample` is projected to `Double` because it carries a per-core array and 600 of
    /// those would be 600 heap allocations. `MemorySample` is flat, so it goes in whole.
    public private(set) var memoryHistory = RingBuffer<MemorySample>(capacity: 600)
    /// 60 s at 4 Hz.
    public private(set) var diskHistory = RingBuffer<DiskSample>(capacity: 240)
    public private(set) var networkHistory = RingBuffer<NetworkSample>(capacity: 240)
    /// 60 s at 500 ms, raw utilization 0-1 -- `SummaryModel` converts to points.
    public private(set) var gpuHistory = RingBuffer<Double>(capacity: 120)
    /// 60 s at 1 s, watts.
    public private(set) var energyHistory = RingBuffer<Double>(capacity: 60)
    /// §6.4 and §14.1: per-cluster DVFS residency fractions, 60 s at the frequency
    /// provider's own 500 ms. Identity is `clusterNames`, fixed the way `temperatureNames`
    /// is -- rebuilt only when the sample's cluster list stops matching, so two clusters
    /// enumerating in a different order does not swap which history is which.
    public private(set) var clusterNames: [String] = []
    public private(set) var clusterResidencyHistory: [RingBuffer<[Double]>] = []
    public private(set) var clusterMegahertzHistory: [RingBuffer<Double>] = []
    /// §6.4: 60 s at 1 s, per §5.6.3 channel. §4.6.3's tile keeps reading `energyHistory`.
    public private(set) var cpuWattsHistory = RingBuffer<Double>(capacity: 60)
    public private(set) var gpuWattsHistory = RingBuffer<Double>(capacity: 60)
    public private(set) var aneWattsHistory = RingBuffer<Double>(capacity: 60)
    public private(set) var dramWattsHistory = RingBuffer<Double>(capacity: 60)
    /// §6.4's "x 4 sensors". `temperatureNames` fixes identity from the first live sample's
    /// top four hottest sensors and is rebuilt only when one of those names drops out of the
    /// matched set -- keyed by name rather than rank so two sensors trading places under
    /// load does not swap which history line is which.
    public private(set) var temperatureHistory: [RingBuffer<Double>] = []
    public private(set) var temperatureNames: [String] = []

    /// §5.7.2 and §5.8.4's public sidecars, read every 1 Hz pass and unaffected by §13.7.3's
    /// flag -- kept off every private provider's payload so both survive the blackout
    /// (discretion table).
    public private(set) var powerSource: PowerSourceInfo?
    public private(set) var thermalPressure: ThermalPressure = ThermalPressure.current()

    /// Monotonic counter for the 10 Hz pass, shown in the status bar. SPEC.md §4.7: if this
    /// stops advancing, that loop is dead, and smoothly interpolating meters would not
    /// reveal it. It tracks the 100 ms pass only — with several loops running, a live 1 Hz
    /// loop must not make a dead 10 Hz one look healthy. Per-provider liveness is
    /// `Frame.state == .stalled`.
    public private(set) var generation: UInt64 = 0

    private var loops: [Task<Void, Never>] = []

    /// §6.2: when the window is occluded, sampling drops to 1 Hz for all providers.
    ///
    /// A divisor on the *samples*, not on the timer's period, and not a stop. Stopping would
    /// re-warm every delta provider each time the window is covered, so switching apps and
    /// back would show `···`. Lengthening the sleep looked equivalent and is not: the loop
    /// reads the scale before it sleeps, so un-occluding would not take effect until the
    /// already-scheduled 1 s deadline fired, and the window would sit frozen for up to a
    /// second after the user brought it forward. The timer keeps its 100 ms cadence and nine
    /// ticks in ten do nothing; what §6.2 exists to stop is the syscalls and the compositing,
    /// and both are stopped.
    private var samplingDivisor: Int = 1

    /// §3.3. Which pane is visible, written by `PaneHostView.show(_:)`.
    ///
    /// Its one reader is `slowLoop()`'s `processes.detail` gate, and one reader is the whole
    /// of §3.3's store-side obligation: every provider this store owns is Summary's, and §3.3
    /// exempts Summary from suspension explicitly. The reader panes (System Info, Startup
    /// Apps, Users, Services) suspend through their own `paneDidResignVisible` hooks, not
    /// through here.
    public private(set) var activePane: PaneID = .summary

    public init() {}

    /// One background Task per distinct sample interval, not one per provider (SPEC.md §6.3).
    public func start() {
        guard loops.isEmpty else { return }
        loops = [fastLoop(), mediumLoop(), gpuLoop(), slowLoop()]
    }

    /// Cancels every loop and waits for each to leave its body. Cancellation alone is not
    /// enough: a loop already past its sleep will still finish the iteration it is in and
    /// land one more `ingest`, so `stop()` would not actually mean stopped. Awaiting here is
    /// safe — `await` releases the actor, so an in-flight `ingest` can complete rather than
    /// deadlocking against us.
    public func stop() async {
        let running = loops
        loops = []
        for loop in running { loop.cancel() }
        for loop in running { await loop.value }
    }

    /// §6.8's Space. Suspends the sample loops; the display link is the view's to stop.
    ///
    /// Providers are task locals constructed inside each loop body, so a stopped-and-restarted
    /// loop constructs fresh ones and every delta baseline goes with them — which is exactly
    /// §6.8's "resuming discards every provider's delta baseline". There is deliberately no
    /// separate baseline-clearing path: a second mechanism for the same guarantee is a second
    /// place for it to be wrong.
    public func pause() async { await stop() }

    public func resume() { start() }

    /// §3.5's ⌘R. `stop()` cancels, and `Task.sleep(until:)` returns immediately on
    /// cancellation, so this returns in milliseconds unless a `sample()` is mid-flight
    /// (≤19 ms for §5.5.4's enumeration). Delta providers re-warm, so the first post-⌘R value
    /// arrives one interval later — §3.5 says so as of phase-03.
    public func forceSample() async {
        await stop()
        start()
    }

    /// §6.2. 1 = normal, 10 = the 1 Hz occluded rate applied to every loop.
    public func setOccluded(_ occluded: Bool) {
        samplingDivisor = occluded ? 10 : 1
    }

    /// §3.3. `PaneHostView.show(_:)` is the only caller.
    public func setActivePane(_ pane: PaneID) {
        activePane = pane
    }

    /// True on the ticks that actually sample. §6.2.
    func samples(tick: UInt64) -> Bool {
        samplingDivisor == 1 || tick % UInt64(samplingDivisor) == 0
    }

    /// 100 ms: CPU and memory (§5.0.2).
    ///
    /// `Task.detached`, never `Task { }`: an unstructured Task created inside an actor method
    /// inherits that actor's isolation, which would run every `sample()` on the actor. The
    /// providers are held as task locals rather than as stored properties of this actor for
    /// the same reason — `sample()` is `mutating`, and a mutating call on an actor's stored
    /// property can only run on that actor, which would drag every syscall into the critical
    /// section that readers and the other loops need. Held here they are still touched by
    /// exactly one task, so §5.0.1's "no internal locking" guarantee is intact.
    private func fastLoop() -> Task<Void, Never> {
        Task.detached { [weak self] in
            var cpu = CPUProvider()
            var memory = MemoryProvider()
            var deadline = ContinuousClock().now
            var tick: UInt64 = 0
            while !Task.isCancelled {
                deadline = await Self.nextTick(after: deadline, by: SampleRate.hz10)
                guard let self, !Task.isCancelled else { return }
                tick &+= 1
                guard await self.samples(tick: tick) else { continue }
                let cpuSnapshot = cpu.sample()
                let memorySnapshot = memory.sample()
                await self.ingest(cpu: cpuSnapshot, memory: memorySnapshot)
            }
        }
    }

    /// 250 ms: network, and disk once it lands (§5.0.2).
    private func mediumLoop() -> Task<Void, Never> {
        Task.detached { [weak self] in
            var disk = DiskProvider()
            var network = NetworkProvider()
            var deadline = ContinuousClock().now
            var tick: UInt64 = 0
            while !Task.isCancelled {
                deadline = await Self.nextTick(after: deadline, by: SampleRate.hz4)
                guard let self, !Task.isCancelled else { return }
                tick &+= 1
                guard await self.samples(tick: tick) else { continue }
                let diskSnapshot = disk.sample()
                let networkSnapshot = network.sample()
                await self.ingest(disk: diskSnapshot, network: networkSnapshot)
            }
        }
    }

    /// 500 ms: GPU and frequency (§6.3's fourth and last loop). Structured exactly like
    /// `mediumLoop()` -- detached rather than structured, providers as task locals,
    /// `samples(tick:)` honoured for §6.2's occlusion divisor.
    private func gpuLoop() -> Task<Void, Never> {
        Task.detached { [weak self] in
            var gpu = GPUProvider()
            var frequency = FrequencyProvider()
            var deadline = ContinuousClock().now
            var tick: UInt64 = 0
            while !Task.isCancelled {
                deadline = await Self.nextTick(after: deadline, by: SampleRate.hz2)
                guard let self, !Task.isCancelled else { return }
                tick &+= 1
                guard await self.samples(tick: tick) else { continue }
                let gpuSnapshot = gpu.sample()
                let frequencySnapshot = frequency.sample()
                await self.ingest(gpu: gpuSnapshot, frequency: frequencySnapshot)
            }
        }
    }

    /// 1000 ms: the process table, energy, thermals, and the two public sidecars (§5.0.2).
    ///
    /// This loop is the reason providers are task locals rather than actor storage. The
    /// process enumeration walks every PID on the machine and §5.5.4 requires it off the main
    /// actor; here it runs on no actor at all, and the store is entered only to store the
    /// finished result. The sidecars are read here for the same reason:
    /// `IOPSCopyPowerSourcesInfo` allocates and walks a list, which does not belong on the
    /// actor either.
    private func slowLoop() -> Task<Void, Never> {
        Task.detached { [weak self] in
            var processes = ProcessProvider()
            var energy = EnergyProvider()
            var thermal = ThermalProvider()
            var connectionsProvider = ConnectionsProvider()
            var deadline = ContinuousClock().now
            var tick: UInt64 = 0
            while !Task.isCancelled {
                deadline = await Self.nextTick(after: deadline, by: SampleRate.hz1)
                guard let self, !Task.isCancelled else { return }
                tick &+= 1
                guard await self.samples(tick: tick) else { continue }
                // §3.3's per-pane sampling rule, at its one wiring site. `sample()` gates
                // the extra `proc_pid_rusage` call on this flag (2.1).
                processes.detail = await self.activePane == .processes
                let processSnapshot = processes.sample()
                let energySnapshot = energy.sample()
                let thermalSnapshot = thermal.sample()
                let powerSource = PowerSource.current()
                let pressure = ThermalPressure.current()
                // D-10/D-11: sampled only while Connections is visible, and at 1 Hz (this
                // loop's own tick) -- CONN-05's warm-median reading landed in the ≤ 25 ms
                // band, so the pane's cadence is every tick, not every second one.
                let connectionsSnapshot: Snapshot<ConnectionsSample>? =
                    (await self.activePane == .connections) ? connectionsProvider.sample() : nil
                await self.ingest(
                    processes: processSnapshot, energy: energySnapshot, thermal: thermalSnapshot,
                    powerSource: powerSource, pressure: pressure, connections: connectionsSnapshot
                )
            }
        }
    }

    /// Each deadline is computed from the previous deadline, not from "now", so intervals do
    /// not drift; a tick late by more than one interval is dropped rather than run back to
    /// back. SPEC.md §6.3. `static` members of an actor are nonisolated, so this sleeps on
    /// the global executor without hopping onto the actor.
    static func nextTick(
        after previous: ContinuousClock.Instant, by interval: Duration
    ) async -> ContinuousClock.Instant {
        let clock = ContinuousClock()
        var next = previous.advanced(by: interval)
        if next < clock.now { next = clock.now.advanced(by: interval) }
        try? await Task.sleep(until: next, clock: clock)
        return next
    }

    /// The only actor-isolated work in the sample path: store results and append history.
    private func ingest(cpu cpuSnapshot: Snapshot<CPUSample>, memory memorySnapshot: Snapshot<MemorySample>) {
        cpu.store(cpuSnapshot)
        memory.store(memorySnapshot)

        if case .value(let sample, _) = cpuSnapshot {
            cpuTotalHistory.append(sample.total)
            cpuSystemHistory.append(sample.system)
        }
        if case .value(let sample, _) = memorySnapshot {
            memoryHistory.append(sample)
        }

        generation &+= 1
    }

    private func ingest(disk diskSnapshot: Snapshot<DiskSample>, network networkSnapshot: Snapshot<NetworkSample>) {
        disk.store(diskSnapshot)
        if case .value(let sample, _) = diskSnapshot { diskHistory.append(sample) }
        network.store(networkSnapshot)
        if case .value(let sample, _) = networkSnapshot { networkHistory.append(sample) }
    }

    private func ingest(gpu gpuSnapshot: Snapshot<GPUSample>, frequency frequencySnapshot: Snapshot<FrequencySample>) {
        gpu.store(gpuSnapshot)
        if case .value(let sample, _) = gpuSnapshot { gpuHistory.append(sample.utilization) }
        frequency.store(frequencySnapshot)
        if case .value(let sample, _) = frequencySnapshot { ingestClusters(sample) }
    }

    /// §6.4's identity rule for clusters, `temperatureIdentity`'s twin: keep the current
    /// names while the sample still carries all of them, and rebuild only when it does not.
    /// Pure and static, so the rule is testable from fixture samples with no hardware.
    static func clusterIdentity(current names: [String], sample: FrequencySample) -> [String] {
        let present = Set(sample.clusters.map(\.name))
        guard names.isEmpty || !Set(names).isSubset(of: present) else { return names }
        return sample.clusters.map(\.name)
    }

    /// `ingestTemperature`'s twin for §14.1's two cluster buffers. §6.4's `60 × rate` at
    /// `SampleRate.hz2` is 120, the capacity `gpuHistory` carries for the same rate.
    private func ingestClusters(_ sample: FrequencySample) {
        let names = Self.clusterIdentity(current: clusterNames, sample: sample)
        if names != clusterNames {
            clusterNames = names
            clusterResidencyHistory = names.map { _ in RingBuffer<[Double]>(capacity: 120) }
            clusterMegahertzHistory = names.map { _ in RingBuffer<Double>(capacity: 120) }
        }
        for (index, name) in clusterNames.enumerated() {
            guard let cluster = sample.clusters.first(where: { $0.name == name }) else { continue }
            clusterResidencyHistory[index].append(cluster.states.map(\.residencyFraction))
            clusterMegahertzHistory[index].append(cluster.averageMegahertz ?? 0)
        }
    }

    private func ingest(
        processes snapshot: Snapshot<ProcessSample>, energy energySnapshot: Snapshot<EnergySample>,
        thermal thermalSnapshot: Snapshot<ThermalSample>, powerSource: PowerSourceInfo?,
        pressure: ThermalPressure, connections connectionsSnapshot: Snapshot<ConnectionsSample>? = nil
    ) {
        processes.store(snapshot)
        if let connectionsSnapshot { connections.store(connectionsSnapshot) }

        energy.store(energySnapshot)
        if case .value(let sample, _) = energySnapshot {
            energyHistory.append(sample.watts)
            // Phase-11's discretion table: `?? 0` in the buffer; the projection omits the band
            // and prints §4.9's `—` when the *current* sample's channel is nil.
            cpuWattsHistory.append(sample.cpuWatts ?? 0)
            gpuWattsHistory.append(sample.gpuWatts ?? 0)
            aneWattsHistory.append(sample.aneWatts ?? 0)
            dramWattsHistory.append(sample.dramWatts ?? 0)
        }

        thermal.store(thermalSnapshot)
        if case .value(let sample, _) = thermalSnapshot { ingestTemperature(sample) }

        self.powerSource = powerSource
        self.thermalPressure = pressure
    }

    /// §6.4's temperature-buffer identity rule: fix `names` from the first live sample's top
    /// four hottest sensors, and rebuild only when one of those names is no longer among the
    /// matched set -- re-ranking on every sample instead would let two sensors trading places
    /// swap which history line is which. Pure and static, so the identity rule is testable
    /// from fixture samples with no hardware.
    static func temperatureIdentity(current names: [String], sample: ThermalSample) -> [String] {
        let matched = Set(sample.sensors.map(\.name))
        guard names.isEmpty || !Set(names).isSubset(of: matched) else { return names }
        return Array(sample.sensors.prefix(4).map(\.name))
    }

    private func ingestTemperature(_ sample: ThermalSample) {
        let names = Self.temperatureIdentity(current: temperatureNames, sample: sample)
        if names != temperatureNames {
            temperatureNames = names
            temperatureHistory = names.map { _ in RingBuffer<Double>(capacity: 60) }
        }
        for (index, name) in temperatureNames.enumerated() {
            guard let celsius = sample.sensors.first(where: { $0.name == name })?.celsius else { continue }
            temperatureHistory[index].append(celsius)
        }
    }

    public func cpuFrame() -> Frame<CPUSample> { cpu.frame() }
    public func memoryFrame() -> Frame<MemorySample> { memory.frame() }
    public func diskFrame() -> Frame<DiskSample> { disk.frame() }
    public func networkFrame() -> Frame<NetworkSample> { network.frame() }
    public func processFrame() -> Frame<ProcessSample> { processes.frame() }
    public func connectionsFrame() -> Frame<ConnectionsSample> { connections.frame() }

    public func snapshotGeneration() -> UInt64 { generation }

    /// Everything the Summary pane reads, in one actor entry. SPEC.md §6.3.
    public func summaryFrames() -> SummaryFrames {
        SummaryFrames(
            cpu: cpu.frame(), memory: memory.frame(), disk: disk.frame(),
            network: network.frame(), processes: processes.frame(),
            gpu: gpu.frame(), energy: energy.frame(), thermal: thermal.frame(),
            frequency: frequency.frame(),
            cpuTotal: cpuTotalHistory.elements,
            cpuSystem: cpuSystemHistory.elements,
            memoryHistory: memoryHistory.elements,
            diskHistory: diskHistory.elements,
            networkHistory: networkHistory.elements,
            gpuHistory: gpuHistory.elements,
            energyHistory: energyHistory.elements,
            temperatureHistory: temperatureHistory.map(\.elements),
            temperatureNames: temperatureNames,
            powerSource: powerSource, thermalPressure: thermalPressure,
            generation: generation,
            health: health(),
            samplingDivisor: samplingDivisor,
            clusterHistory: zip(clusterNames, zip(clusterResidencyHistory, clusterMegahertzHistory))
                .map { ClusterHistory(name: $0.0, residency: $0.1.0.elements, averageMegahertz: $0.1.1.elements) },
            cpuWattsHistory: cpuWattsHistory.elements,
            gpuWattsHistory: gpuWattsHistory.elements,
            aneWattsHistory: aneWattsHistory.elements,
            dramWattsHistory: dramWattsHistory.elements
        )
    }

    /// §4.7's status phrase needs every provider's state at once, which is what `MetricState`
    /// being a top-level type buys.
    ///
    /// All ten of §5.10's rows, not the five that are built: a status bar that counts only
    /// the providers that exist reports a healthy machine while four tiles read `—`, which is
    /// the pane looking healthier than it is.
    public func health() -> [ProviderHealth] {
        // §5.6.4's ANE rides `EnergySample` -- one IOReport subscription, two tiles -- so
        // `.npu` mirrors the energy slot's state rather than carrying a second copy of one
        // number that could disagree with its own source.
        [
            ProviderHealth(id: .cpu, state: cpu.frame().state),
            ProviderHealth(id: .memory, state: memory.frame().state),
            ProviderHealth(id: .disk, state: disk.frame().state),
            ProviderHealth(id: .network, state: network.frame().state),
            ProviderHealth(id: .process, state: processes.frame().state),
            ProviderHealth(id: .gpu, state: gpu.frame().state),
            ProviderHealth(id: .npu, state: energy.frame().state),
            ProviderHealth(id: .energy, state: energy.frame().state),
            ProviderHealth(id: .thermal, state: thermal.frame().state),
            ProviderHealth(id: .frequency, state: frequency.frame().state),
        ]
    }

    /// §5.0.5's vocabulary, and gate 12's sentinel: `SummaryPaneView.selfCheckFrames()` builds
    /// a not-built tile from it, and `SummaryFramesTests` asserts `health()` never returns it.
    /// No provider produces it any more — that is what the tests check, not that it is unused.
    public static let notBuiltReason = "provider not built"
}
