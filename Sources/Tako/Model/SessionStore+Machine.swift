import Foundation

/// The machine as the footer's machine popover shows it: Tako's memory and its trend, the
/// browser, the agents, memory pressure and MCP helpers. Read from what the steward already
/// samples, and only when the popover opens; nothing here acts.
struct MachineReadout {
    var takoBytes: UInt64 = 0
    var uptime: TimeInterval = 0
    var pressure = MemoryPressure.normal
    var freeBytes: UInt64 = 0
    var totalBytes: UInt64 = 0
    var browser = (running: false, processes: 0, bytes: UInt64(0))
    var agentCount = 0
    var agentBytes: UInt64 = 0
    /// The three heaviest agents.
    var topAgents: [(label: String, bytes: UInt64)] = []
    /// Tako's MCP helpers per agent, most first.
    var helpers: [(label: String, count: Int)] = []

    /// Tako's footprint over the last day, from the hourly lines in events.jsonl.
    struct Trend: Equatable {
        var start: UInt64
        var peak: UInt64
        var growing: Bool
    }

    static func trend(_ events: [LoggedEvent], now: UInt64) -> Trend? {
        let readings = events.filter { $0.kind == "footprint" }.compactMap { $0.double("footprint").map { UInt64($0) } }
        guard let first = readings.first else { return nil }
        return Trend(start: first, peak: max(readings.max() ?? 0, now), growing: now > first + Doctor.growthLimit)
    }
}

extension SessionStore {
    /// What the steward knows now. Cheap enough for a popover opening: the steward's last
    /// samples, one process listing for the browser, and the helpers in each agent's tree.
    func machineReadout(steward: Steward = .shared) -> MachineReadout {
        let status = steward.status()
        var readout = MachineReadout()
        readout.takoBytes = status.takoBytes
        readout.uptime = steward.uptime
        readout.pressure = status.pressure
        readout.freeBytes = status.freeBytes
        readout.totalBytes = status.totalBytes
        readout.browser = (AgentBrowser.shared.isRunning, status.browserProcesses, status.browserBytes)
        let agents = sessions.filter(\.kind.isAgent)
        let ids = Set(agents.map(\.id.uuidString))
        let measured = status.sessions.filter { ids.contains($0.id) }
        readout.agentCount = agents.count
        readout.agentBytes = measured.map(\.footprintBytes).reduce(0, +)
        readout.topAgents = measured.sorted { $0.footprintBytes > $1.footprintBytes }.prefix(3).map { ($0.label, $0.footprintBytes) }
        let counts = steward.helperCounts()
        readout.helpers = agents.compactMap { agent in counts[agent.id].map { (agent.label, $0) } }
            .filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        return readout
    }

    /// Tako's footprint trend over the last day, read from events.jsonl off the main thread.
    func loadFootprintTrend(now: UInt64, _ completion: @escaping @MainActor (MachineReadout.Trend?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let trend = MachineReadout.trend(EventLog.read(since: Date().addingTimeInterval(-Doctor.window)), now: now)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(trend) } }
        }
    }
}
