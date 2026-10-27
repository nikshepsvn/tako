import Foundation

/// Keeps `claimIndex` in step with the team boards and answers edit hooks from it (ClaimAdvisor).
extension SessionStore {
    /// Copies the boards' live claims into the index. While any exist, every agent's workspace is
    /// registered too; with none, the index empties and hooks go back to costing nothing.
    func syncClaimIndex(now: Date = Date()) {
        var byProject: [String: [FileClaim]] = [:]
        for (key, board) in agentTools.boards {
            let live = board.claims.filter { $0.expires > now }
            if !live.isEmpty { byProject[key] = live }
        }
        claimIndex.setClaims(byProject)
        guard !byProject.isEmpty else { return }
        for session in sessions where session.kind.isAgent { registerClaimWorkspace(session) }
    }

    /// Where `session` works, as known without asking Git: hooks keep it current, so an agent
    /// started after a claim, or whose worktree Git reported later, is checked too.
    func registerClaimWorkspace(_ session: TerminalSession) {
        guard session.kind.isAgent, !claimIndex.isEmpty else { return }
        let path = session.spec.workPath
        let project = session.git?.mainRoot ?? agentTools.projectKeys[path] ?? path
        claimIndex.register(session.id, ClaimIndex.Workspace(project: project, root: workspaceRoot(of: session)))
    }

    /// A PreToolUse hook's reply when it edits someone else's claim, from any thread. The
    /// holders hear about it on main.
    nonisolated func adviseEditHook(sessionID: String, payload: Data) -> Data? {
        guard let editor = UUID(uuidString: sessionID),
              let advice = claimIndex.advise(editor: editor, payload: payload) else { return nil }
        let hits = advice.hits
        if Thread.isMainThread {
            MainActor.assumeIsolated { tellClaimHolders(hits, editor: editor) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.tellClaimHolders(hits, editor: editor) } }
        }
        return advice.reply
    }

    /// Each holder hears once per claim and editor (ClaimIndex debounces), as an agent's message
    /// queued for the end of its turn, like a claim request.
    private func tellClaimHolders(_ hits: [ClaimIndex.Hit], editor: UUID) {
        guard let editing = sessions.first(where: { $0.id == editor }) else { return }
        for (owner, mine) in Dictionary(grouping: hits, by: \.claim.owner) {
            guard let holder = sessions.first(where: { $0.id == owner }) else { continue }
            let what = mine.map { "\($0.path) (your claim \($0.claim.path))" }.joined(separator: ", ")
            let message = agentMessagePrefix + "\(editing.label) (via Tako's team board): heads-up, I'm editing \(what). "
                + "If that clashes with your work, send_message me."
            _ = holder.send(message, now: false)
            editing.record(.note, "Edited inside @\(holder.label)'s claim: " + mine.map(\.path).joined(separator: ", "))
        }
    }
}
