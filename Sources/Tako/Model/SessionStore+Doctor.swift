import Foundation

/// Gathers `Doctor`'s inputs: what only the main actor knows first, then the files (a day of
/// events.jsonl, the worktree ledger, Claude's config) off it. On demand only: nothing here
/// runs unless the user or Sumi asks.
extension SessionStore {
    /// `ledger` and `claudeConfig` are only ever read.
    func doctor(now: Date = Date(), ledger: URL = WorktreeLedger.url,
                claudeConfig: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json"),
                completion: @escaping @MainActor (String) -> Void) {
        var snapshot = Doctor.Snapshot()
        snapshot.now = now
        let steward = Steward.shared
        snapshot.uptime = steward.uptime
        snapshot.footprint = TakoFootprint.current()
        snapshot.notifications = notifier.counts
        let agents = sessions.filter(\.kind.isAgent)
        snapshot.agents = agents.map { ($0.label, $0.kind.rawValue, $0.isAsleep) }
        snapshot.crashLooping = agents.filter { startupHealth.isCrashLooping($0.id, now: now) }.map(\.label)
        let helpers = steward.helperCounts()
        for agent in agents { if let count = helpers[agent.id] { snapshot.helpers[agent.label] = count } }
        let browser = ProcessUsage.browserProcesses()
        snapshot.browser = (AgentBrowser.shared.isRunning, browser.count, browser.footprint)
        let live = Set(sessions.map(\.spec.workPath))
        let channelsOn = Self.channelsEnabled
        let htPath = AgentIntegration.htPath
        DispatchQueue.global(qos: .utility).async {
            snapshot.idleWorktrees = WorktreeLedger.load(from: ledger)
                .filter { !live.contains($0.path) && FileManager.default.fileExists(atPath: $0.path) }.map(\.created)
            let config = try? Data(contentsOf: claudeConfig)
            snapshot.channels = Doctor.channels(enabled: channelsOn, claudeConfig: config, htPath: htPath)
            let report = Doctor.report(snapshot, events: EventLog.read(since: now.addingTimeInterval(-Doctor.window)))
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(report) } }
        }
    }
}
