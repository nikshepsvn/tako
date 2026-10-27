import Foundation

/// Read-mostly views of v2 state for the interface: the team board, remembered approvals, the
/// sessions waiting on the user, and Tako's stray processes. Nothing here changes behavior;
/// each accessor reads what the tools already keep.
extension SessionStore {
    /// The project's board as it stands: live claims (expired ones dropped) and its notes.
    func teamBoard(for session: TerminalSession) -> TeamBoard {
        board(projectKey(for: session))
    }

    /// Requests the user answered in this project, newest first.
    func rememberedApprovals(for session: TerminalSession) -> [(key: String, record: ApprovalMemory.Record)] {
        let keys = sumiBrain.approvals.projects[approvalProject(session)] ?? [:]
        return keys.sorted { $0.value.lastAt > $1.value.lastAt }.map { (key: $0.key, record: $0.value) }
    }

    /// Stops answering `key` from memory in this project; the next such request asks again.
    func forgetApproval(_ key: String, for session: TerminalSession) {
        _ = sumiBrain.approvals.forget(project: approvalProject(session), key: key)
        objectWillChange.send()
    }

    /// Sessions that need the user, longest waiting first: who the coalesced badge stands for.
    var waitingSessions: [TerminalSession] {
        sessions.filter { $0.state.needsAttention && !$0.isSumi }.sorted { $0.stateChangedAt < $1.stateChangedAt }
    }

    /// Lists what Tako started whose terminal is gone, off the main thread.
    func scanOrphans(_ completion: @escaping @MainActor ([OrphanProcess]) -> Void) {
        let live = Set(sessions.map(\.id.uuidString))
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Orphans.scan(live: live)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(found) } }
        }
    }
}

extension TerminalSession {
    /// The oldest message still waiting for this agent, and whether its sender was told it's stale.
    var queueSummary: (count: Int, oldest: Date?, stale: Bool) {
        (queue.count, queue.map(\.queuedAt).min(), queue.contains { $0.staleNoticed })
    }
}
