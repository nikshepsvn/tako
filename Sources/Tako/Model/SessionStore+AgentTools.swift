import Foundation

/// Bookkeeping for the worker agents' coordination tools: waits held open on another terminal,
/// each project's team board, and the notification rate limit.
struct AgentToolsState {
    var waits: [UUID: AgentWait] = [:]
    /// Ticks only while some wait is watching output; nothing polls otherwise.
    var outputPoll: Timer?
    /// Team boards by project: the main checkout's path, shared by its worktrees.
    var boards: [String: TeamBoard] = [:]
    /// Project keys of workspaces Git hadn't been inspected for yet.
    var projectKeys: [String: String] = [:]
    var lastNotified: [UUID: Date] = [:]
    /// Claim holders already asked to make room, so a retry doesn't message them again.
    var askedHolders: [String: Date] = [:]
    /// Tests stand in for a terminal's output here.
    var outputReader: ((TerminalSession, Int) -> String)?
}

/// An agent blocked in wait_for. The reply goes out once, on the goal, a timeout, or a close.
struct AgentWait {
    enum Goal: String {
        case done, needsInput = "needs-input", exited, output
    }

    let target: UUID
    let caller: UUID?
    let goal: Goal
    let regex: NSRegularExpression?
    /// Output waits: how far the target's output has been checked.
    var cursor: String
    /// Set for one target of a wait on several (SessionStore+WaitGroup), which counts once.
    var group: UUID? = nil
    let reply: ControlServer.Reply
}

extension SessionStore {
    static let waitCapPerCaller = 8
    static let outputPollInterval: TimeInterval = 1
    static let notifyInterval: TimeInterval = 30
    /// How much of a terminal an output wait looks back over on each tick.
    static let outputWindow = 400

    // MARK: - Waits

    /// Holds `reply` until `target` reaches `goal`. Already there answers at once, so waiting on
    /// several agents in turn never blocks on one that finished first.
    func startWait(on target: TerminalSession, caller: UUID?, goal: AgentWait.Goal, regex: NSRegularExpression?,
                   timeout: TimeInterval, reply: @escaping ControlServer.Reply) {
        if goal != .output, let outcome = waitOutcome(target, goal: goal) {
            reply(.success(text: outcome))
            return
        }
        if goal == .output, case .exited = target.state {
            reply(.success(text: "@\(target.label) has exited (\(target.state.detail ?? "")); nothing more will print"))
            return
        }
        if let refusal = waitCapRefusal(caller) { return reply(refusal) }
        let id = registerWait(on: target, caller: caller, goal: goal, regex: regex, group: nil, reply: reply)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let wait = self.agentTools.waits.removeValue(forKey: id) else { return }
                let now = self.sessions.first { $0.id == wait.target }.map(self.describeForWait) ?? "it was closed"
                wait.reply(.success(text: "timed out after \(Int(timeout)) s; \(now)"))
            }
        }
    }

    /// The refusal for a caller already holding the most waits; a wait on several counts once.
    func waitCapRefusal(_ caller: UUID?) -> ControlResponse? {
        guard let caller else { return nil }
        let open = Set(agentTools.waits.filter { $0.value.caller == caller }.map { $0.value.group ?? $0.key })
        guard open.count >= Self.waitCapPerCaller else { return nil }
        return .failure("you already have \(Self.waitCapPerCaller) waits open; let one finish first")
    }

    /// Holds `reply` until the target's state or output answers it; the caller times it out.
    func registerWait(on target: TerminalSession, caller: UUID?, goal: AgentWait.Goal, regex: NSRegularExpression?,
                      group: UUID?, reply: @escaping ControlServer.Reply) -> UUID {
        let id = UUID()
        let cursor = goal == .output ? LogTail.cursor(LogTail.lines(recentOutput(of: target, lines: Self.outputWindow))) : ""
        agentTools.waits[id] = AgentWait(target: target.id, caller: caller, goal: goal, regex: regex, cursor: cursor, group: group, reply: reply)
        if goal == .output { ensureOutputPoll() }
        return id
    }

    /// Why a wait is over, or nil while it isn't. `done` is the turn ending: idle with no
    /// subagent or queued message left, failed, exited, or blocked on the user (waiting longer
    /// there helps nobody). Servers and shells are done when they exit.
    func waitOutcome(_ session: TerminalSession, goal: AgentWait.Goal) -> String? {
        let state = session.state
        switch goal {
        case .done:
            switch state {
            case .idle where session.kind.isAgent && session.runningSubagents.isEmpty && session.pendingMessages.isEmpty,
                 .failed, .exited, .needsInput:
                return describeForWait(session)
            default:
                return nil
            }
        case .needsInput:
            return state.needsAttention ? describeForWait(session) : nil
        case .exited:
            if case .exited = state { return describeForWait(session) }
            return nil
        case .output:
            return nil
        }
    }

    /// "@api is idle · Added /orders · 3 files changed, +40 −2", for whoever was waiting.
    func describeForWait(_ session: TerminalSession) -> String {
        var text = "@\(session.label) is \(session.isAsleep ? "asleep" : session.state.key)"
        if let detail = session.state.detail { text += " (\(detail))" }
        if let summary = session.agentStatus ?? session.summary { text += " · " + summary }
        if let stat = session.diffStat, stat.files > 0 {
            text += " · \(stat.files) file\(stat.files == 1 ? "" : "s") changed, +\(stat.added) −\(stat.removed) (agent_changes shows them)"
        }
        return text
    }

    /// A session's state moved: answer the waits it satisfies. Its claims end when it exits.
    func agentToolsStateChanged(_ session: TerminalSession) {
        for (id, wait) in agentTools.waits where wait.target == session.id {
            if wait.goal == .output {
                checkOutputWait(id)
                guard agentTools.waits[id] != nil, case .exited = session.state else { continue }
                finishWait(id, "@\(session.label) exited (\(session.state.detail ?? "")) without printing a match")
            } else if let outcome = waitOutcome(session, goal: wait.goal) {
                finishWait(id, outcome)
            }
        }
        if case .exited = session.state { releaseAllClaims(of: session) }
    }

    /// A closed session ends the waits on it, and the waits it held; its claims go too.
    func agentToolsSessionClosed(_ session: TerminalSession) {
        for (id, wait) in agentTools.waits where wait.target == session.id || wait.caller == session.id {
            finishWait(id, "@\(session.label) was closed")
        }
        releaseAllClaims(of: session)
        claimIndex.register(session.id, nil)
        agentTools.lastNotified[session.id] = nil
    }

    private func finishWait(_ id: UUID, _ text: String) {
        guard let wait = agentTools.waits.removeValue(forKey: id) else { return }
        wait.reply(.success(text: text))
    }

    /// What a terminal printed last: its screen and scrollback, or, asleep, the screen it left.
    func recentOutput(of session: TerminalSession, lines: Int) -> String {
        if let reader = agentTools.outputReader { return reader(session, lines) }
        if let kept = session.asleepScreen {
            return kept.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
        return session.surface.readText(lastLines: lines)
    }

    private func ensureOutputPoll() {
        guard agentTools.outputPoll == nil else { return }
        agentTools.outputPoll = Timer.scheduledTimer(withTimeInterval: Self.outputPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOutputWaits() }
        }
    }

    func pollOutputWaits() {
        let ids = agentTools.waits.filter { $0.value.goal == .output }.map(\.key)
        for id in ids { checkOutputWait(id) }
        if !agentTools.waits.values.contains(where: { $0.goal == .output }) {
            agentTools.outputPoll?.invalidate()
            agentTools.outputPoll = nil
        }
    }

    /// Matches the lines printed since the wait last looked. A cursor that scrolled away means
    /// more printed than the window holds: every line in it is new.
    private func checkOutputWait(_ id: UUID) {
        guard let wait = agentTools.waits[id], let regex = wait.regex,
              let target = sessions.first(where: { $0.id == wait.target }) else { return }
        let lines = LogTail.lines(recentOutput(of: target, lines: Self.outputWindow))
        let fresh = LogTail.after(wait.cursor, in: lines) ?? lines
        if let hit = fresh.first(where: { LogTail.matches(regex, $0) }) {
            finishWait(id, "@\(target.label) printed: \(hit.trimmingCharacters(in: .whitespaces))")
            return
        }
        agentTools.waits[id]?.cursor = LogTail.cursor(lines)
    }

    // MARK: - Team board

    /// The project a session works in: its main checkout, so every worktree shares one board.
    func projectKey(for session: TerminalSession) -> String {
        if let root = session.git?.mainRoot { return root }
        let path = session.spec.workPath
        if let known = agentTools.projectKeys[path] { return known }
        let key = Review.mainRoot(of: path) ?? path
        agentTools.projectKeys[path] = key
        return key
    }

    /// Paths agents pass are relative to their own workspace root, which mirrors the project's.
    func workspaceRoot(of session: TerminalSession) -> String {
        session.git?.root ?? session.spec.workPath
    }

    /// The board for `key`, its notes loaded from the repository on first use.
    func board(_ key: String) -> TeamBoard {
        var board = agentTools.boards[key] ?? TeamBoard()
        if !board.loaded {
            board.loaded = true
            if persists, let file = Self.boardFile(key), let data = FileManager.default.contents(atPath: file) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                board.notes = (try? decoder.decode([BoardNote].self, from: data)) ?? []
            }
        }
        board.dropExpired()
        agentTools.boards[key] = board
        return board
    }

    /// Notes live in the repository's Git folder: shared by its worktrees, never committed,
    /// and kept across restarts. Outside a repository the board lives in memory only.
    static func boardFile(_ key: String) -> String? {
        let git = (key as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: git, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return (git as NSString).appendingPathComponent("tako-board.json")
    }

    func postNote(_ text: String, by session: TerminalSession) -> String {
        let key = projectKey(for: session)
        var board = board(key)
        board.add(BoardNote(author: session.label, text: text, date: Date()))
        agentTools.boards[key] = board
        session.record(.note, "Posted to the team board")
        if persists, let file = Self.boardFile(key) {
            let notes = board.notes
            Self.persistQueue.async {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try? encoder.encode(notes).write(to: URL(fileURLWithPath: file), options: .atomic)
            }
        }
        return "posted note \(board.notes.count) to the \(Self.projectName(key)) board"
    }

    /// Notes after the first `since`, then who holds which files.
    func readBoard(for session: TerminalSession, since: Int) -> String {
        let key = projectKey(for: session)
        let board = board(key)
        var lines: [String] = []
        let shown = board.notes.enumerated().dropFirst(max(0, since)).suffix(50)
        if board.notes.isEmpty {
            lines.append("No notes on the \(Self.projectName(key)) board yet.")
        } else if shown.isEmpty {
            lines.append("No notes after \(since) (there are \(board.notes.count)).")
        } else {
            lines.append("Notes \(shown.first!.offset + 1)–\(board.notes.count) on the \(Self.projectName(key)) board:")
            for (index, note) in shown {
                lines.append("\(index + 1). @\(note.author), \(note.date.formatted(date: .abbreviated, time: .shortened)): \(note.text)")
            }
        }
        let byOwner = Dictionary(grouping: board.claims, by: \.ownerLabel)
        lines.append(byOwner.isEmpty ? "No files claimed." : "Claims:")
        for owner in byOwner.keys.sorted() {
            lines.append("  @\(owner)\(owner == session.label ? " (you)" : ""): " + byOwner[owner]!.map(\.path).joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }

    func claimFiles(_ paths: [String], by session: TerminalSession, minutes: Int) -> String {
        let key = projectKey(for: session)
        var board = board(key)
        let result = board.claim(paths, owner: session.id, label: session.label, until: Date().addingTimeInterval(TimeInterval(minutes * 60)))
        agentTools.boards[key] = board
        syncClaimIndex()
        var lines: [String] = []
        if !result.claimed.isEmpty {
            lines.append("claimed for \(minutes) min: " + result.claimed.joined(separator: ", "))
        }
        var asked: Set<UUID> = []
        for refusal in result.refused {
            guard !refusal.holders.isEmpty else {
                lines.append("not claimed: \(refusal.path) (you hold \(TeamBoard.claimCap) claims; release some)")
                continue
            }
            let holders = refusal.holders.map { "@\($0.ownerLabel) (\($0.path))" }.joined(separator: ", ")
            lines.append("not claimed: \(refusal.path) is held by \(holders)")
            for holder in refusal.holders where asked.insert(holder.owner).inserted {
                askToRelease(holder, for: session, path: refusal.path)
            }
        }
        if !asked.isEmpty {
            lines.append("Each holder was told you want it. Work elsewhere for now, or send_message them to agree who goes first.")
        }
        return lines.joined(separator: "\n")
    }

    /// The holder hears once per path and claimant: as an agent's message, since the claimant chose the path.
    private func askToRelease(_ claim: FileClaim, for claimant: TerminalSession, path: String, now: Date = Date()) {
        let key = "\(claimant.id)|\(claim.owner)|\(claim.path)"
        agentTools.askedHolders = agentTools.askedHolders.filter { now.timeIntervalSince($0.value) < 600 }
        guard agentTools.askedHolders[key] == nil, let holder = sessions.first(where: { $0.id == claim.owner }) else { return }
        agentTools.askedHolders[key] = now
        let message = agentMessagePrefix + "\(claimant.label) (via Tako's team board): I'd like to edit \(path), which you claimed as \(claim.path). "
            + "If you're done with it, release it (team_board release)."
        _ = holder.send(message, now: false)
    }

    func releaseFiles(_ paths: [String]?, by session: TerminalSession) -> String {
        let key = projectKey(for: session)
        var board = board(key)
        let released = board.release(paths, owner: session.id)
        agentTools.boards[key] = board
        syncClaimIndex()
        return released.isEmpty ? "you held none of those" : "released " + released.joined(separator: ", ")
    }

    private func releaseAllClaims(of session: TerminalSession) {
        for key in agentTools.boards.keys where agentTools.boards[key]?.claims.contains(where: { $0.owner == session.id }) == true {
            agentTools.boards[key]?.release(nil, owner: session.id)
        }
        if !claimIndex.isEmpty { syncClaimIndex() }
    }

    /// A session's live claims, for list_terminals.
    func claims(of session: TerminalSession, now: Date = Date()) -> [String]? {
        let held = agentTools.boards.values.flatMap(\.claims).filter { $0.owner == session.id && $0.expires > now }.map(\.path)
        return held.isEmpty ? nil : held
    }

    /// `task` with the team board of the project at `folder` after it, when the board has notes
    /// or live claims; otherwise `task` unchanged. Git finds the project off main.
    func withTeamBoard(_ task: String, folder: String) async -> String {
        let path = (expandTilde(folder) as NSString).standardizingPath
        let key: String
        if let known = agentTools.projectKeys[path] {
            key = known
        } else if let main = sessions.first(where: { $0.git?.root == path })?.git?.mainRoot {
            key = main
        } else {
            key = await Task.detached(priority: .userInitiated) { Review.mainRoot(of: path) ?? path }.value
            agentTools.projectKeys[path] = key
        }
        guard let section = board(key).briefSection(project: Self.projectName(key)) else { return task }
        return task + "\n\n" + section
    }

    static func projectName(_ key: String) -> String {
        (key as NSString).lastPathComponent
    }

    // MARK: - Notifications

    /// An agent's explicit heads-up: a banner even while Tako is active, at most one per agent
    /// every `notifyInterval`, so a looping agent can't flood the user.
    func notifyUser(_ text: String, from session: TerminalSession, now: Date = Date()) -> Result<String, DelegationError> {
        if let last = agentTools.lastNotified[session.id], now.timeIntervalSince(last) < Self.notifyInterval {
            return .failure(DelegationError("you notified the user \(Int(now.timeIntervalSince(last))) s ago; put further news in set_status"))
        }
        agentTools.lastNotified[session.id] = now
        session.record(.note, "Notified the user: \(text)")
        if !userIsLooking(at: session) { session.unread = true }
        if notifiesUser { notifier.post(session: session, title: "@\(session.label)", body: text, foreground: true, kind: .note) }
        onStatusChange?()
        return .success("the user was notified")
    }
}
