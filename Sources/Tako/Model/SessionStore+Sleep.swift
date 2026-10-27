import Foundation

/// Sleeping agents: an idle agent's CLI (0.7–5 GB) quits to free its memory while its screen
/// stays; the next message, keystroke or wake resumes the same conversation in the same tile.
extension SessionStore {
    /// Only an idle agent at an empty prompt, with a conversation to resume and no subagents or
    /// background shells still running (quitting would end them), can sleep.
    func canSleep(_ session: TerminalSession) -> Bool {
        guard session.kind.isAgent, !session.isSumi, !session.isAsleep, !session.isWaking,
              session.state == .idle, session.runningSubagents.isEmpty, session.backgroundShells == 0, session.pendingMessages.isEmpty, session.inputIsEmpty,
              let id = session.spec.agentSessionId, isSafeIdentifier(id) else { return false }
        if session.kind.adapter?.canSleep(session.spec) == false { return false }
        // A conversation that never had a turn has nothing to resume.
        let hadTurn = session.summary != nil || session.timeline.contains { $0.kind == .prompt }
        return hadTurn && !session.dialogOnScreen
    }

    /// Quits the agent's CLI, keeping its screen. No-op when it can't sleep.
    func sleep(_ session: TerminalSession) {
        guard canSleep(session) else { return }
        session.fallAsleep()
        persist()
        onStatusChange?()
    }

    /// Resumes an asleep agent's conversation in the same terminal. No-op when awake.
    func wake(_ session: TerminalSession) {
        guard session.isAsleep else { return }
        session.wakeUp()
        persist()
        onStatusChange?()
    }
}
