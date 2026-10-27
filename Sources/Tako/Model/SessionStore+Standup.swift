import Foundation

/// Standup as rows for the interface: the same facts the Sumi `standup` tool reads (state and
/// for how long, current action, todos, diff, uncommitted files, blockers, cost), structured
/// instead of written out. The tool's text is unchanged; both read the same session state and
/// the same git probe.
struct StandupRow: Identifiable, Equatable {
    /// The order the popover lists them in: what needs the user first.
    enum Group: Int, CaseIterable, Comparable {
        case needsYou, failed, working, done

        var title: String {
            switch self {
            case .needsYou: return "Needs you"
            case .failed: return "Failed"
            case .working: return "Working"
            case .done: return "Done"
            }
        }

        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    let id: UUID
    let label: String
    let kind: SessionKind
    let state: AgentState
    let asleep: Bool
    /// When it entered its current state.
    let since: Date
    let group: Group
    var doing: String?
    var todosDone = 0
    var todosTotal = 0
    var currentTodo: String?
    var diff: DiffStat?
    var uncommitted: Int?
    var blocker: String?
    var cost: Double?
    var crashLooping = false
}

extension SessionStore {
    /// Every agent, ordered needs you, failed, working, done. Within "needs you" the one that has
    /// waited longest comes first; the rest keep the sidebar's order. `git` is `probeGit`'s
    /// result; without it the last diff the session reported stands in.
    func standupRows(git: [UUID: (stat: DiffStat?, dirty: Int?)] = [:], now: Date = Date()) -> [StandupRow] {
        let agents = orderedSessions.filter { $0.kind.isAgent && !$0.isSumi }
        let rows = agents.enumerated().map { index, session in (index, standupRow(session, git: git[session.id], now: now)) }
        return rows.sorted { lhs, rhs in
            if lhs.1.group != rhs.1.group { return lhs.1.group < rhs.1.group }
            if lhs.1.group == .needsYou, lhs.1.since != rhs.1.since { return lhs.1.since < rhs.1.since }
            return lhs.0 < rhs.0
        }.map(\.1)
    }

    /// The git probe standup runs, for the agents `standupRows` lists. Off the main thread;
    /// `completion` runs on it.
    func probeStandupGit(_ completion: @escaping @MainActor ([UUID: (stat: DiffStat?, dirty: Int?)]) -> Void) {
        let probes: [GitProbe] = orderedSessions.filter { $0.kind.isAgent && !$0.isSumi && !$0.isAsleep }
            .map { (id: $0.id, path: $0.spec.workPath, base: $0.spec.baseBranch) }
        guard !probes.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Self.probeGit(probes)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(git) } }
        }
    }

    private func standupRow(_ session: TerminalSession, git: (stat: DiffStat?, dirty: Int?)?, now: Date) -> StandupRow {
        let looping = startupHealth.isCrashLooping(session.id, now: now)
        var row = StandupRow(id: session.id, label: session.label, kind: session.kind, state: session.state,
                             asleep: session.isAsleep, since: session.stateChangedAt,
                             group: Self.standupGroup(session.state, asleep: session.isAsleep, crashLooping: looping))
        if session.state == .working { row.doing = session.activity }
        row.todosDone = session.tasks.done
        row.todosTotal = session.tasks.total
        row.currentTodo = session.tasks.current
        if let stat = git?.stat ?? session.diffStat, !stat.isEmpty { row.diff = stat }
        row.uncommitted = git?.dirty
        row.cost = session.usage.costUSD
        row.crashLooping = looping
        row.blocker = standupBlocker(session, dirty: git?.dirty, crashLooping: looping, now: now)
        return row
    }

    nonisolated static func standupGroup(_ state: AgentState, asleep: Bool, crashLooping: Bool) -> StandupRow.Group {
        if crashLooping { return .failed }
        switch state {
        case .needsInput: return .needsYou
        case .failed: return .failed
        case .exited(let code): return code == 0 ? .done : .failed
        case .working, .starting, .running: return asleep ? .done : .working
        case .idle: return .done
        }
    }

    /// The one thing standing between this agent and done, in the user's words: what it asks,
    /// why it failed, a crash loop, idle work at risk, or files another agent is changing.
    private func standupBlocker(_ session: TerminalSession, dirty: Int?, crashLooping: Bool, now: Date) -> String? {
        if crashLooping {
            return "Crash-looping: exited \(startupHealth.quickExitCount(session.id, now: now))× soon after starting in the last hour"
        }
        switch session.state {
        case .needsInput(let reason):
            let asked = session.pendingQuestion?.items.first?.question ?? session.pendingRequest ?? reason
            return asked + (session.delegation != nil ? " (Sumi handles it)" : "")
        case .failed(let reason):
            return reason
        case .exited(let code) where code != 0:
            return "Exited with code \(code)"
        case .idle where (dirty ?? 0) > 0 && now.timeIntervalSince(session.stateChangedAt) >= Self.idleWithWorkAfter:
            return "Idle with \(dirty ?? 0) uncommitted files"
        default:
            break
        }
        let overlaps = session.overlaps.keys.compactMap { id in sessions.first { $0.id == id }.map { "@" + $0.label } }.sorted()
        return overlaps.isEmpty ? nil : "Same files as " + overlaps.joined(separator: ", ")
    }
}
