import Foundation

/// How much a session matters right now, most to least.
enum Band: String, Codable {
    /// On screen, selected, pinned, or Sumi.
    case focused
    /// Hidden, but an agent at work, or a shell or server with a live process.
    case working
    /// Hidden and waiting on the user.
    case waiting
    /// Hidden agent at rest (idle, failed or exited).
    case idle
}

enum StewardRules {
    static func band(state: AgentState, isAgent: Bool, focused: Bool) -> Band {
        if focused { return .focused }
        guard isAgent else { return .working }
        switch state {
        case .working, .starting, .running: return .working
        case .needsInput: return .waiting
        case .idle, .failed, .exited: return .idle
        }
    }

    /// Background only what nobody is waiting on; when the Mac runs hot, everything off screen.
    static func shouldLower(_ band: Band, thermal: Thermal) -> Bool {
        switch band {
        case .focused: return false
        case .working: return thermal >= .serious
        case .waiting, .idle: return true
        }
    }

    /// Half the performance cores, halved again under pressure or heat, one when critical.
    static func heavySlots(performanceCores: Int, pressure: MemoryPressure, thermal: Thermal) -> Int {
        let base = max(1, performanceCores / 2)
        if pressure == .critical || thermal == .critical { return 1 }
        if pressure == .warning || thermal == .serious { return max(1, base / 2) }
        return base
    }
}

/// Whether the Mac has room for one more agent.
enum Admission {
    static let defaultAgentFootprint: UInt64 = 512 << 20

    /// The 75th percentile of observed agent footprints with 20% to spare.
    static func estimate(_ footprints: [UInt64]) -> UInt64 {
        let sorted = footprints.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return defaultAgentFootprint * 6 / 5 }
        let index = max(0, Int((Double(sorted.count) * 0.75).rounded(.up)) - 1)
        return sorted[index] * 6 / 5
    }

    /// `reserved` launches started recently whose memory hasn't shown up yet.
    static func admits(available: UInt64, pressure: MemoryPressure, estimate: UInt64, reserved: Int = 0,
                       activeAgents: Int, maxActiveAgents: Int?) -> Bool {
        blocker(available: available, pressure: pressure, estimate: estimate, reserved: reserved,
                activeAgents: activeAgents, maxActiveAgents: maxActiveAgents) == nil
    }

    /// Why one more agent has to wait, or nil when it fits. macOS's own pressure level decides:
    /// "free" memory always looks low on a Mac (cache, compression), so headroom only counts
    /// once pressure is up.
    static func blocker(available: UInt64, pressure: MemoryPressure, estimate: UInt64, reserved: Int = 0,
                        activeAgents: Int, maxActiveAgents: Int?) -> String? {
        if let maxActiveAgents, activeAgents + reserved >= maxActiveAgents {
            return "\(maxActiveAgents) agents are already working (the cap)"
        }
        switch pressure {
        case .normal: return nil
        case .warning: return available >= estimate * UInt64(reserved + 1) ? nil : "memory is short"
        case .critical: return "memory is critically short"
        }
    }
}

/// Something the user (or Sumi) should hear about. The steward only reports it.
struct Escalation: Codable, Equatable {
    enum Kind: String, Codable {
        /// The session's tree is a memory problem (see `EscalationRules`).
        case memory
        /// The agent says it's idle while its tree keeps burning CPU.
        case idleBurning
        /// Tako itself has grown past `TakoFootprint.warnBytes`.
        case takoMemory
    }

    var sessionID: String
    var label: String
    var kind: Kind
    var footprintBytes: UInt64
    var cpuPercent: Double
    var since: Date
    var message: String
}

/// When the steward speaks up. A busy Claude Code sits at 2–4 GB, so a fixed per-agent limit
/// below that told Sumi about healthy agents every few minutes (86% of its events, mostly
/// answered "no action"). Memory is worth Sumi's attention only when the Mac is short, when an
/// agent grows well past its own normal, or when it is plainly a runaway. Everything else
/// shows on the card and in the inspector only.
struct EscalationRules {
    /// Under memory pressure, agents at least this big are named: they're what to stop first.
    var pressureFloor: UInt64 = 3 << 30
    /// An agent is "growing" past its baseline only beyond both this ratio and `growthBytes`,
    /// so a small agent doubling or a big one wobbling by a few hundred MB stays quiet.
    var growthRatio = 1.5
    var growthBytes: UInt64 = 2 << 30
    /// How quickly the baseline follows the agent: half the gap closes in this long, so a slow,
    /// normal climb over a long session moves the baseline, while a leak outruns it.
    var baselineHalfLife: TimeInterval = 30 * 60
    /// Growth only counts once the baseline has watched the agent this long; a fresh agent
    /// climbing from its first sample is just starting up.
    var baselineWarmup: TimeInterval = 10 * 60
    /// Past this, an agent is a runaway whatever its history or the pressure.
    var runawayFootprint: UInt64 = 12 << 30
    /// An idle agent whose own children (not the CLI) burn this much CPU for `burnDuration`
    /// is a runaway: a server or watcher left behind.
    var burnCPU = 15.0
    var burnDuration: TimeInterval = 5 * 60
}

/// Raises each escalation once per episode; it clears when the condition does.
struct EscalationTracker {
    var rules = EscalationRules()
    private(set) var active: [Escalation] = []
    private var burningSince: [String: Date] = [:]
    private var baselines: [String: Baseline] = [:]

    /// A session's usual footprint: an exponential average over time, not over samples, so
    /// tick cadence doesn't matter.
    struct Baseline {
        var bytes: Double
        var firstSeen: Date
        var lastSeen: Date
    }

    func baseline(_ sessionID: String) -> UInt64? { baselines[sessionID].map { UInt64($0.bytes) } }

    /// Returns the escalations raised by this sample. `cpu` is what the agent started (its
    /// children), not the CLI redrawing its screen.
    mutating func update(sessionID: String, label: String, footprint: UInt64, cpu: Double?, agentIdle: Bool,
                         pressure: MemoryPressure = .normal, now: Date) -> [Escalation] {
        let cpu = cpu ?? 0
        if agentIdle, cpu > rules.burnCPU {
            if burningSince[sessionID] == nil { burningSince[sessionID] = now }
        } else {
            burningSince[sessionID] = nil
        }
        // Judge against the baseline as it was, then fold this sample in.
        let memoryReason = memoryReason(sessionID: sessionID, label: label, footprint: footprint, pressure: pressure, now: now)
        updateBaseline(sessionID, footprint: footprint, now: now)
        var raised: [Escalation] = []
        func set(_ kind: Escalation.Kind, _ on: Bool, since: Date, _ message: @autoclosure () -> String) {
            let index = active.firstIndex { $0.sessionID == sessionID && $0.kind == kind }
            if on, index == nil {
                let escalation = Escalation(sessionID: sessionID, label: label, kind: kind, footprintBytes: footprint,
                                            cpuPercent: cpu, since: since, message: message())
                active.append(escalation)
                raised.append(escalation)
            } else if on, let index {
                active[index].footprintBytes = footprint
                active[index].cpuPercent = cpu
            } else if !on, let index {
                active.remove(at: index)
            }
        }
        set(.memory, memoryReason != nil, since: now, memoryReason ?? "")
        let burning = burningSince[sessionID].map { now.timeIntervalSince($0) >= rules.burnDuration } ?? false
        let minutes = Int(rules.burnDuration / 60)
        set(.idleBurning, burning, since: burningSince[sessionID] ?? now,
            "@\(label) is idle but the processes it started have used \(Int(cpu))% CPU for \(minutes)+ minutes")
        return raised
    }

    /// Why this footprint is worth Sumi's attention, or nil when it is just an agent at work.
    private func memoryReason(sessionID: String, label: String, footprint: UInt64, pressure: MemoryPressure, now: Date) -> String? {
        let size = Self.format(footprint)
        if footprint >= rules.runawayFootprint {
            return "@\(label) is using \(size) of memory, far beyond any normal agent"
        }
        if pressure >= .warning, footprint >= rules.pressureFloor {
            return "memory pressure is \(pressure.rawValue) and @\(label) is using \(size), one of the biggest"
        }
        guard let base = baselines[sessionID], now.timeIntervalSince(base.firstSeen) >= rules.baselineWarmup else { return nil }
        let usual = base.bytes
        let value = Double(footprint)
        guard value >= usual * rules.growthRatio, value - usual >= Double(rules.growthBytes) else { return nil }
        return "@\(label) grew to \(size), \(String(format: "%.1f", value / max(usual, 1)))× its usual \(Self.format(UInt64(usual)))"
    }

    private mutating func updateBaseline(_ sessionID: String, footprint: UInt64, now: Date) {
        guard var base = baselines[sessionID] else {
            baselines[sessionID] = Baseline(bytes: Double(footprint), firstSeen: now, lastSeen: now)
            return
        }
        let elapsed = max(0, now.timeIntervalSince(base.lastSeen))
        let keep = pow(0.5, elapsed / rules.baselineHalfLife)
        base.bytes = base.bytes * keep + Double(footprint) * (1 - keep)
        base.lastSeen = now
        baselines[sessionID] = base
    }

    private static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    mutating func forget(_ sessionID: String) {
        active.removeAll { $0.sessionID == sessionID }
        burningSince[sessionID] = nil
        baselines[sessionID] = nil
    }
}

extension StewardRules {
    /// The agent CLI, its shells and Tako's own helpers: always there, never the agent's work.
    /// `script` is what a node process runs (its argv[1]).
    static func isAgentMachinery(name: String?, path: String?, script: String? = nil) -> Bool {
        guard let name else { return true }
        if ["ht", "tako", "caffeinate", "login", "zsh", "bash", "sh", "fish"].contains(name) { return true }
        return SessionKind.agentAdapters.contains { $0.isCLIProcess(name: name, path: path, script: script) }
    }
}

/// Idle, hidden sessions whose work (not the CLI itself) has been quiet long enough to put to sleep.
struct SleepTracker {
    var after: TimeInterval = 600
    var quietCPU = 3.0
    private var quietSince: [String: Date] = [:]
    private var reported: Set<String> = []

    /// True once when a session becomes a candidate; again only after it wakes up.
    mutating func update(sessionID: String, band: Band, cpu: Double?, now: Date) -> Bool {
        guard band == .idle, let cpu, cpu < quietCPU else {
            forget(sessionID)
            return false
        }
        let since = quietSince[sessionID] ?? now
        quietSince[sessionID] = since
        guard now.timeIntervalSince(since) >= after, !reported.contains(sessionID) else { return false }
        reported.insert(sessionID)
        return true
    }

    /// The candidate could not sleep (a draft, a dialog, queued messages): offer it again after
    /// another quiet period rather than never.
    mutating func retry(_ sessionID: String, now: Date) {
        reported.remove(sessionID)
        quietSince[sessionID] = now
    }

    mutating func forget(_ sessionID: String) {
        quietSince[sessionID] = nil
        reported.remove(sessionID)
    }
}
