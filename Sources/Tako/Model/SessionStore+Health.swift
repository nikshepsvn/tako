import Foundation

/// The agent lifecycle as events.jsonl and standup see it: starts, restarts, exits and failures
/// (a few per agent per day, so the log stays weeks long), whether each start reached its
/// prompt, and the morning briefing's view of what is still open now.
extension SessionStore {
    /// An agent started, or started again in the same terminal. Resumed agents (Tako's own
    /// restart restoring them) aren't news, and neither is Sumi.
    func recordAgentStart(_ session: TerminalSession, restarted: Bool) {
        guard session.kind.isAgent, !session.isSumi else { return }
        EventLog.record("agent", session: session.label, restarted ? "restarted" : "started",
                        fields: ["action": restarted ? "restarted" : "started", "agent": session.kind.rawValue])
    }

    /// From `sessionStateChanged`: notes readiness and exits for crash-loop detection, and logs
    /// how an agent stopped.
    func healthStateChanged(_ session: TerminalSession, from previous: AgentState, now: Date = Date()) {
        guard session.kind.isAgent else { return }
        switch session.state {
        case .working, .idle, .running:
            if !startupHealth.reachedReady(session.id, startedAt: session.createdAt) {
                startupHealth.sawReady(session.id, startedAt: session.createdAt)
            }
        case .exited(let code):
            startupHealth.sawExit(session.id, startedAt: session.createdAt, at: now)
            EventLog.record("agent", session: session.label, code == 0 ? "exited" : "exited with code \(code)",
                            fields: ["action": "exited", "code": Int(code)])
        case .failed(let reason):
            EventLog.record("agent", session: session.label, "failed: " + Self.clip(reason, 120), fields: ["action": "failed"])
        default:
            break
        }
    }

    /// Standup's startup notes for one agent: a start that never reached the prompt, and a
    /// crash loop. Ready and waiting are already in its state and blockers.
    func startupNotes(_ session: TerminalSession, now: Date) -> [String] {
        guard session.kind.isAgent else { return [] }
        var notes: [String] = []
        if startupHealth.isCrashLooping(session.id, now: now) {
            notes.append("CRASH-LOOPING: exited \(startupHealth.quickExitCount(session.id, now: now))× within 10 min of starting in the last hour; read_terminal it before restarting again")
        }
        if case .exited(let code) = session.state, !startupHealth.reachedReady(session.id, startedAt: session.createdAt) {
            notes.append("startup failed: exited \(code == 0 ? "" : "with code \(code) ")before reaching its prompt")
        }
        return notes
    }

    /// What the briefing reads from memory: turns finished since `since`, waits, queues and
    /// open steward warnings.
    func briefingLive(since: Date) -> Briefing.Live {
        var live = Briefing.Live()
        for session in orderedSessions where session.kind.isAgent && !session.isSumi {
            let done = session.timeline.filter { $0.kind == .done && $0.date >= since }
            if !done.isEmpty { live.finished.append((session.label, done.count, done.last?.text)) }
            if session.state.needsAttention { live.waitingOnUser.append(session.label) }
            if !session.queue.isEmpty { live.queued.append((session.label, session.queue.count)) }
        }
        live.escalations = Steward.shared.escalations.map(\.message)
        return live
    }

    /// One line for events.jsonl per plan task that ends, so the briefing can say what moved.
    func recordPlanTask(_ task: PlanTask) {
        guard task.status == .done || task.status == .failed else { return }
        EventLog.record("plan", session: task.owner, "\(task.id) \(task.status.rawValue)",
                        fields: ["task": task.id, "status": task.status.rawValue])
    }
}
