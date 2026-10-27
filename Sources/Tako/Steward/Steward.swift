import AppKit
import Combine

/// What the user lets the steward do, kept in UserDefaults.
struct StewardPolicy: Codable, Equatable {
    /// Agents allowed at work at once; nil leaves it to memory.
    var maxActiveAgents: Int?
    /// Session labels or ids treated as focused: never backgrounded.
    var pinned: Set<String> = []

    private static let key = "stewardPolicy"

    static func load(_ defaults: UserDefaults = .standard) -> StewardPolicy {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(StewardPolicy.self, from: $0) } ?? StewardPolicy()
    }

    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }
}

/// The machine and every session as the steward sees them, for Sumi.
struct MachineStatus: Codable, Equatable {
    struct Session: Codable, Equatable {
        var id: String
        var label: String
        var band: Band
        var footprintBytes: UInt64
        var cpuPercent: Double?
        var lowered: Bool
        var escalation: Escalation?
    }

    var pressure: MemoryPressure
    var thermal: Thermal
    var lowPower: Bool
    var freeBytes: UInt64
    var totalBytes: UInt64
    var admissionOK: Bool
    var queuedLaunches: Int
    var heavySlotsUsed: Int
    var heavySlotsTotal: Int
    var heavyWaiting: Int
    var sessions: [Session]
    /// Tako's Chromium, shared by every browser tile.
    var browserProcesses = 0
    var browserBytes: UInt64 = 0
    /// Tako's own footprint, browsers excluded.
    var takoBytes: UInt64 = 0
}

/// Keeps the Mac responsive while agents run, without an LLM: measures each session's process
/// tree on every inspector tick, backgrounds what nobody is waiting on, admits new agents only
/// when memory allows, rations heavy jobs, and reports runaways and sleepers to whoever listens.
@MainActor
final class Steward: ObservableObject {
    static let shared = Steward()

    struct Sample: Equatable {
        var footprint: UInt64
        var cpuPercent: Double?
        var band: Band
        var lowered: Bool
    }

    private(set) var samples: [UUID: Sample] = [:] {
        didSet {
            let next = samples.mapValues(Readout.init)
            if readouts != next { readouts = next }
        }
    }
    /// What the inspector shows for each session. CPU differs on every tick, so only a change to
    /// the shown text redraws the row.
    @Published private(set) var readouts: [UUID: Readout] = [:]

    struct Readout: Equatable {
        var text: String
        var lowered: Bool

        init(_ sample: Sample) {
            var parts = [ByteCountFormatter.string(fromByteCount: Int64(sample.footprint), countStyle: .memory)]
            if let cpu = sample.cpuPercent { parts.append("\(Int(cpu.rounded()))% CPU") }
            if sample.lowered { parts.append("background") }
            text = parts.joined(separator: " · ")
            lowered = sample.lowered
        }
    }
    /// Open escalations, one per session and kind; each clears when its condition does.
    var escalations: [Escalation] { escalationTracker.active + [tako.warning].compactMap { $0 } }
    /// Called once per new escalation. The steward never acts on it.
    var onEscalation: ((Escalation) -> Void)?
    /// Called once when an idle, hidden session has been quiet for `sleepAfter`.
    /// Returns whether the session fell asleep; when not, the steward offers it again later.
    var onSleepCandidate: ((TerminalSession) -> Bool)?
    var policy = StewardPolicy.load() {
        didSet { policy.save(); rebalance() }
    }
    var sleepAfter: TimeInterval {
        get { sleepTracker.after }
        set { sleepTracker.after = newValue }
    }

    private weak var store: SessionStore?
    private var trees: [UUID: Set<pid_t>] = [:]
    private var meters: [UUID: CPUMeter] = [:]
    /// CPU of what an agent started (builds, servers, tests), leaving out the CLI itself, its
    /// shells and Tako's helpers: an idle Claude still redraws its screen at a few percent.
    private var workMeters: [UUID: CPUMeter] = [:]
    private var lowered: [UUID: Set<pid_t>] = [:]
    private var escalationTracker = EscalationTracker()
    private var tako = TakoFootprint()
    /// Tako's own footprint at the last tick, for the inspector and `ht machine`.
    @Published private(set) var takoBytes: UInt64 = 0
    private var sleepTracker = SleepTracker()
    private var heavy = HeavyQueue(capacity: 1)
    private var launches: [() -> Void] = []
    /// Launches let through recently whose memory hasn't shown up in a sample yet.
    private var reservations: [Date] = []
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observers: Set<AnyCancellable> = []

    init() { updateHeavyCapacity() }

    func start(store: SessionStore) {
        self.store = store
        store.$selectedID.combineLatest(store.$layout).dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebalance() } }
            .store(in: &observers)
        // An agent starting or finishing work changes its band.
        store.$sessions
            .map { sessions in Publishers.MergeMany(sessions.map { $0.$state.dropFirst().map { _ in () } }) }
            .switchToLatest()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.rebalance() } }
            .store(in: &observers)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.conditionsChanged() }
            .store(in: &observers)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.conditionsChanged() } }
        source.resume()
        pressureSource = source
    }

    // MARK: - Tick

    /// One inspector tick: sample every session's tree, then band, prioritize and report.
    func update(_ snapshots: [String: ProcessSnapshot]) {
        guard let store else { return }
        let now = Date()
        let clock = ProcessInfo.processInfo.systemUptime
        let thermal = Thermal(ProcessInfo.processInfo.thermalState)
        let focused = focusedIDs(store)
        let awake = heldAwakeIDs(store)
        let pressure = MemoryPressure.current()
        var next: [UUID: Sample] = [:]
        for session in store.sessions {
            let key = session.id.uuidString
            guard let tree = snapshots[key]?.pids, !tree.isEmpty else {
                forget(session.id)
                continue
            }
            trees[session.id] = tree
            var footprint: UInt64 = 0
            var times: [pid_t: UInt64] = [:]
            var work: [pid_t: UInt64] = [:]
            for pid in tree {
                guard let usage = ProcessUsage.read(pid) else { continue }
                footprint += usage.footprint
                times[pid] = usage.cpuNanoseconds
                let name = ProcessUsage.name(pid)
                let script = name == "node" ? ProcessInspector.shared.arguments(pid)?.dropFirst().first : nil
                if !StewardRules.isAgentMachinery(name: name, path: ProcessUsage.path(pid), script: script) {
                    work[pid] = usage.cpuNanoseconds
                }
            }
            let cpu = meters[session.id, default: CPUMeter()].update(times, at: clock)
            let workCPU = workMeters[session.id, default: CPUMeter()].update(work, at: clock)
            let band = band(of: session, focused: focused)
            let isLowered = prioritize(session.id, lower: StewardRules.shouldLower(band, thermal: thermal))
            next[session.id] = Sample(footprint: footprint, cpuPercent: cpu, band: band, lowered: isLowered)

            let agentIdle = session.kind.isAgent && session.state == .idle && session.runningSubagents.isEmpty
            // Children's CPU, not the CLI's: an idle Claude redrawing its screen isn't a runaway.
            for escalation in escalationTracker.update(sessionID: key, label: session.label, footprint: footprint,
                                                       cpu: workCPU, agentIdle: agentIdle, pressure: pressure, now: now) {
                onEscalation?(escalation)
            }
            let sleepBand = StewardRules.band(state: session.state, isAgent: true, focused: awake.contains(session.id))
            if session.kind.isAgent, sleepTracker.update(sessionID: key, band: sleepBand, cpu: workCPU, now: now) {
                if onSleepCandidate?(session) != true { sleepTracker.retry(key, now: now) }
            }
        }
        let live = Set(store.sessions.map(\.id))
        for id in Set(trees.keys).union(meters.keys).subtracting(live) { forget(id) }
        if samples != next { samples = next }
        measureTako(now: now)
        conditionsChanged()
    }

    private func measureTako(now: Date) {
        if let warning = tako.update(TakoFootprint.current(), now: now) { onEscalation?(warning) }
        // Published in 64 MB steps so the readout doesn't redraw on every tick.
        let rounded = (tako.bytes >> 26) << 26
        if takoBytes != rounded { takoBytes = rounded }
    }

    /// Between ticks: keeps each sampled session's tree current, so children started since the
    /// last tick are backgrounded with it.
    func refreshTrees(_ snapshots: [String: ProcessSnapshot]) {
        var changed = false
        for (id, tree) in trees {
            guard let pids = snapshots[id.uuidString]?.pids, !pids.isEmpty, pids != tree else { continue }
            trees[id] = pids
            changed = true
        }
        if changed { rebalance() }
    }

    private func forget(_ id: UUID) {
        meters[id] = nil
        workMeters[id] = nil
        if lowered.removeValue(forKey: id) != nil {
            for pid in trees[id] ?? [] { Priority.restore(pid) }
        }
        trees[id] = nil
        escalationTracker.forget(id.uuidString)
        sleepTracker.forget(id.uuidString)
    }

    /// On screen, selected, Sumi, or pinned by the policy.
    private func focusedIDs(_ store: SessionStore) -> Set<UUID> {
        heldAwakeIDs(store).union(store.visibleIDs)
    }

    /// What sleep leaves alone: the selected tile, Sumi and pinned sessions. A tile that
    /// is merely on screen can sleep, since it keeps showing its last screen and wakes on a key.
    private func heldAwakeIDs(_ store: SessionStore) -> Set<UUID> {
        var ids = Set<UUID>()
        if let selected = store.selectedID { ids.insert(selected) }
        // A detached window that is on screen is being watched even when it isn't the selection.
        for session in store.sessions where session.isDetached && session.surface.window?.isVisible == true {
            ids.insert(session.id)
        }
        for session in store.sessions where session.isSumi || policy.pinned.contains(session.label)
            || policy.pinned.contains(session.id.uuidString) {
            ids.insert(session.id)
        }
        return ids
    }

    private func band(of session: TerminalSession, focused: Set<UUID>) -> Band {
        StewardRules.band(state: session.state, isAgent: session.kind.isAgent, focused: focused.contains(session.id))
    }

    /// Re-bands from the last sample when focus moves, so a session brought on screen is
    /// restored now rather than at the next tick.
    private func rebalance() {
        guard let store else { return }
        let thermal = Thermal(ProcessInfo.processInfo.thermalState)
        let focused = focusedIDs(store)
        var next = samples
        for session in store.sessions {
            guard var sample = next[session.id] else { continue }
            sample.band = band(of: session, focused: focused)
            sample.lowered = prioritize(session.id, lower: StewardRules.shouldLower(sample.band, thermal: thermal))
            next[session.id] = sample
        }
        if samples != next { samples = next }
    }

    /// Backgrounds a tree's processes not yet lowered (new descendants included), or restores the
    /// whole tree, children that inherited the background state included. Returns whether lowered.
    private func prioritize(_ id: UUID, lower: Bool) -> Bool {
        let tree = trees[id] ?? []
        if lower {
            var done = lowered[id] ?? []
            for pid in tree.subtracting(done) where !Priority.isExempt(pid) {
                if Priority.lower(pid) { done.insert(pid) }
            }
            lowered[id] = done.intersection(tree)
            return true
        }
        if lowered.removeValue(forKey: id) != nil {
            for pid in tree { Priority.restore(pid) }
        }
        return false
    }

    private func conditionsChanged() {
        updateHeavyCapacity()
        heavy.reap()
        drainLaunches()
        // Thermal state decides what is backgrounded.
        rebalance()
    }

    private func updateHeavyCapacity() {
        heavy.setCapacity(StewardRules.heavySlots(performanceCores: HostMemory.performanceCores,
                                                  pressure: MemoryPressure.current(),
                                                  thermal: Thermal(ProcessInfo.processInfo.thermalState)))
    }

    // MARK: - Admission

    /// Whether one more agent fits: memory pressure is normal, the free headroom covers the
    /// typical agent's footprint (p75 × 1.2) for it and any launch still warming up, and the
    /// policy's agent cap isn't reached.
    func canLaunchAgent() -> Bool { launchBlocker() == nil }

    /// Why a new agent would wait right now, or nil. Sumi doesn't count toward the cap,
    /// and a launch stops being reserved once its session is starting (it's counted there).
    func launchBlocker() -> String? {
        reservations.removeAll { Date().timeIntervalSince($0) > 10 }
        let sessions = (store?.sessions ?? []).filter { $0.kind.isAgent && !$0.isSumi }
        let footprints = sessions.compactMap { samples[$0.id]?.footprint }
        let active = sessions.filter { $0.state == .working || $0.state == .starting }.count
        let recent = sessions.filter { Date().timeIntervalSince($0.createdAt) < 10 }.count
        return Admission.blocker(available: HostMemory.availableBytes(), pressure: MemoryPressure.current(),
                                 estimate: Admission.estimate(footprints), reserved: max(0, reservations.count - recent),
                                 activeAgents: active, maxActiveAgents: policy.maxActiveAgents)
    }

    /// Runs `work` now when an agent fits, otherwise in order once headroom returns.
    func enqueueLaunch(_ work: @escaping () -> Void) {
        launches.append(work)
        drainLaunches()
    }

    var queuedLaunches: Int { launches.count }

    /// Starts queued launches that fit now. Cheap, so it runs on every poll, not only on a tick.
    func drainLaunches() {
        while !launches.isEmpty, canLaunchAgent() {
            reservations.append(Date())
            launches.removeFirst()()
        }
    }

    // MARK: - Heavy jobs

    /// `ht heavy`: acquire replies once a slot is free; the slot frees on release or when the
    /// holder process exits. The holder is the kernel's peer pid when the server knows it, so a
    /// caller can't lease or release slots for other processes; `request.pid` is the fallback.
    func handleHeavy(_ request: ControlRequest, peer: pid_t? = nil, reply: @escaping ControlServer.Reply) {
        let pid: pid_t
        if let peer, peer > 0 {
            pid = peer
        } else if let raw = request.pid, raw > 0 {
            pid = pid_t(raw)
        } else {
            reply(.failure("heavy needs the holder's pid")); return
        }
        switch request.text ?? "acquire" {
        case "acquire":
            guard HeavyQueue.isAlive(pid) else { reply(.failure("no such process")); return }
            heavy.reap()
            heavy.acquire(pid, ancestors: HeavyQueue.ancestors(of: pid)) { reply(.success(text: "granted")) }
        case "release":
            heavy.release(pid)
            reply(.success())
        default:
            reply(.failure("heavy takes acquire or release"))
        }
    }

    // MARK: - Status

    func status() -> MachineStatus {
        let sessions = (store?.sessions ?? []).compactMap { session -> MachineStatus.Session? in
            guard let sample = samples[session.id] else { return nil }
            let key = session.id.uuidString
            return MachineStatus.Session(id: key, label: session.label, band: sample.band, footprintBytes: sample.footprint,
                                         cpuPercent: sample.cpuPercent, lowered: sample.lowered,
                                         escalation: escalations.first { $0.sessionID == key })
        }
        let browser = ProcessUsage.browserProcesses()
        var status = MachineStatus(pressure: MemoryPressure.current(), thermal: Thermal(ProcessInfo.processInfo.thermalState),
                             lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                             freeBytes: HostMemory.availableBytes(), totalBytes: HostMemory.totalBytes,
                             admissionOK: canLaunchAgent(), queuedLaunches: launches.count,
                             heavySlotsUsed: heavy.holders.count, heavySlotsTotal: heavy.capacity,
                             heavyWaiting: heavy.waiting, sessions: sessions)
        status.browserProcesses = browser.count
        status.browserBytes = browser.footprint
        status.takoBytes = tako.bytes
        return status
    }
}
