import Foundation

/// Conflict watch bookkeeping: at most one scan per repository at a time.
struct OverlapWatch {
    /// Repositories with a scan due, and the agents whose finished turns asked for it.
    var pending: [String: Set<UUID>] = [:]
    var running: Set<String> = []
    var notes = OverlapNotes()
}

/// "Conflicts with @bravo", with the files in its tooltip.
struct OverlapBadge: Equatable {
    let title: String
    let detail: String
}

extension TerminalSession {
    /// Overlapping agents by label, for list_terminals.
    var conflictsByLabel: [String: [String]]? {
        let named = overlapPartners
        return named.isEmpty ? nil : Dictionary(named.map { ($0.label, $0.files) }) { first, _ in first }
    }

    /// Agents sharing a workspace are named together: "Conflicts with @a, @b".
    var overlapBadge: OverlapBadge? {
        var workspaces: [(path: String, labels: [String], files: [String])] = []
        for partner in overlapPartners {
            if let index = workspaces.firstIndex(where: { $0.path == partner.path }) {
                workspaces[index].labels.append(partner.label)
            } else {
                workspaces.append((partner.path, [partner.label], partner.files))
            }
        }
        guard let first = workspaces.first else { return nil }
        func names(_ labels: [String]) -> String { labels.map { "@" + $0 }.joined(separator: ", ") }
        let others = workspaces.dropFirst().reduce(0) { $0 + $1.labels.count }
        let title = "Conflicts with " + names(first.labels) + (others > 0 ? " +\(others)" : "")
        let detail = workspaces.map { "Conflicts with \(names($0.labels)): " + $0.files.joined(separator: ", ") }.joined(separator: "\n")
        return OverlapBadge(title: title, detail: detail)
    }

    private var overlapPartners: [(label: String, path: String, files: [String])] {
        guard let store else { return [] }
        return store.sessions.compactMap { other in overlaps[other.id].map { (other.label, other.spec.workPath, $0) } }
    }
}

extension SessionStore {
    /// New worktrees get the main checkout's `.worktreeinclude` folders, cloned in the
    /// background; the agent starts without waiting, and the outcome lands on its timeline.
    func warmWorktree(_ session: TerminalSession) {
        let path = session.spec.workPath
        DispatchQueue.global(qos: .utility).async { [weak session] in
            let result = WorktreeInclude.warm(path)
            guard !result.copied.isEmpty || !result.failed.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if !result.copied.isEmpty { session?.record(.note, "Cloned from the main checkout: " + result.copied.joined(separator: ", ")) }
                    if !result.failed.isEmpty { session?.record(.note, "Couldn't copy from the main checkout: " + result.failed.joined(separator: ", ")) }
                }
            }
        }
    }

    /// An agent finished a turn: compare its workspace with every other live agent's in the
    /// same repository, a few seconds later so turns ending together share one scan.
    func watchOverlaps(_ session: TerminalSession, from previous: AgentState) {
        guard session.state == .idle, previous == .working, session.kind.isAgent, !session.isSumi,
              let repo = session.git?.mainRoot else { return }
        let due = overlapWatch.pending[repo] != nil
        overlapWatch.pending[repo, default: []].insert(session.id)
        if !due, !overlapWatch.running.contains(repo) { scheduleOverlapScan(repo) }
    }

    /// A closed session no longer overlaps anyone.
    func forgetOverlaps(with session: TerminalSession) {
        for other in sessions where other.overlaps[session.id] != nil { other.overlaps[session.id] = nil }
    }

    private func scheduleOverlapScan(_ repo: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated { self?.scanOverlaps(repo) }
        }
    }

    private func scanOverlaps(_ repo: String) {
        guard !overlapWatch.running.contains(repo), let finished = overlapWatch.pending.removeValue(forKey: repo) else { return }
        let live = watchedAgents.filter { $0.git?.mainRoot == repo }
        let workspaces = live.map(\.spec.workPath)
        let focus = Set(live.filter { finished.contains($0.id) }.map(\.spec.workPath))
        guard Set(workspaces).count > 1, !focus.isEmpty else { return }
        overlapWatch.running.insert(repo)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pairs = Overlaps.scan(workspaces, focus: focus)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.applyOverlaps(pairs, finished: finished)
                    self.overlapWatch.running.remove(repo)
                    if self.overlapWatch.pending[repo] != nil { self.scheduleOverlapScan(repo) }
                }
            }
        }
    }

    /// Agents the conflict watch compares: live, and not Sumi.
    private var watchedAgents: [TerminalSession] {
        sessions.filter { session in
            guard session.kind.isAgent, !session.isSumi else { return false }
            if case .exited = session.state { return false }
            return true
        }
    }

    /// Marks every agent in each conflicting workspace, and sends one note per workspace pair:
    /// from the workspace whose agents just finished, to one agent in the other, preferring one
    /// at rest, then the most recently active.
    func applyOverlaps(_ pairs: [Overlaps.Pair], finished: Set<UUID>) {
        let agents = watchedAgents
        for pair in pairs {
            let left = agents.filter { $0.spec.workPath == pair.a }, right = agents.filter { $0.spec.workPath == pair.b }
            guard !left.isEmpty, !right.isEmpty else { continue }
            let files = pair.files.isEmpty ? nil : pair.files
            for a in left {
                for b in right {
                    if a.overlaps[b.id] != files { a.overlaps[b.id] = files }
                    if b.overlaps[a.id] != files { b.overlaps[a.id] = files }
                }
            }
            guard !pair.files.isEmpty, overlapWatch.notes.shouldTell(pair.a, pair.b, files: pair.files) else { continue }
            let (authors, readers) = left.contains { finished.contains($0.id) } ? (left, right) : (right, left)
            guard let reader = readers.max(by: { ($0.atRest ? 1 : 0, $0.stateChangedAt) < ($1.atRest ? 1 : 0, $1.stateChangedAt) }) else { continue }
            let named = authors.filter { finished.contains($0.id) }.map { "@" + $0.label }.joined(separator: ", ")
            let shown = pair.files.prefix(5).joined(separator: ", ") + (pair.files.count > 5 ? " and \(pair.files.count - 5) more" : "")
            _ = reader.send("\(named) just finished changes to \(shown) that overlap yours; check before continuing.", now: false)
        }
    }
}
