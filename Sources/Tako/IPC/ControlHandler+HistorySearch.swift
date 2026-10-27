import Foundation

extension ControlHandler {
    /// session_history with a query: closed sessions first (Tako's notes, then transcripts), then
    /// Claude conversations Tako never ran. Searched off the main thread; the reply says how to
    /// reopen each kind.
    func searchHistory(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        let query = request.pattern ?? ""
        let limit = min(max(request.lines ?? 10, 1), 50)
        let closed = store.closedSessions(in: request.cwd)
        let skip = Set(store.sessions.compactMap(\.spec.agentSessionId) + closed.compactMap(\.agentSessionId))
        let candidates = closed.map { spec -> HistorySearch.Candidate in
            let root = (AccountStore.shared.account(spec.account, kind: spec.kind)
                ?? AgentAccount(id: AgentAccount.defaultID, kind: spec.kind, name: "Default")).homeDirectory
            let kind = spec.kind
            let cwds = [spec.workPath, expandTilde(spec.cwd)]
            return HistorySearch.Candidate(spec: spec, kind: kind) {
                guard let id = spec.agentSessionId, isSafeIdentifier(id) else { return nil }
                return kind.adapter?.transcriptFile(id: id, cwds: cwds, root: root)
            }
        }
        // Conversations outside Tako are only looked for across all folders, under the default account.
        let projects = request.cwd == nil
            ? AgentAccount(id: AgentAccount.defaultID, kind: .claude, name: "Default").homeDirectory.appendingPathComponent("projects")
            : nil
        DispatchQueue.global(qos: .userInitiated).async {
            var budget = HistorySearch.Limits().total
            let matches = HistorySearch.search(candidates, query: query, limit: limit, budget: &budget)
            let loose = projects.map {
                HistorySearch.searchLoose(projects: $0, query: query, skip: skip, limit: limit - matches.count, budget: &budget)
            } ?? []
            let text = Self.describeSearch(query: query, matches: matches, loose: loose)
            DispatchQueue.main.async { reply(.success(text: text)) }
        }
    }

    nonisolated static func describeSearch(query: String, matches: [HistorySearch.Match], loose: [HistorySearch.LooseMatch],
                                           now: Date = Date()) -> String {
        guard !matches.isEmpty || !loose.isEmpty else { return "No past session mentions \"\(query)\"." }
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "en_US_POSIX")
        var lines: [String] = []
        if !matches.isEmpty {
            lines.append("Closed sessions matching \"\(query)\", newest first (reopen_session with the label):")
            for match in matches {
                let spec = match.spec
                var head = "@\(spec.label) [\(spec.kind.rawValue)] \(abbreviateHome(expandTilde(spec.cwd)))"
                if let closed = spec.memory?.closedAt { head += " · closed " + relative.localizedString(for: closed, relativeTo: now) }
                lines.append(head)
                lines.append("    \(match.field): \(match.snippet)")
            }
        }
        if !loose.isEmpty {
            lines.append("Claude conversations Tako didn't run (reopen_session with conversation and folder):")
            for match in loose {
                let folder = match.folder.map { abbreviateHome($0) } ?? "folder unknown"
                lines.append("\(match.conversation) · \(folder) · " + relative.localizedString(for: match.modified, relativeTo: now))
                lines.append("    transcript: \(match.snippet)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
