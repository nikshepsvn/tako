import AppKit

/// What a multi-agent harness adds on top of the terminals: turn checkpoints, forking, sending
/// one task to several agents, reopening closed agents, resuming after a rate limit, and one-click
/// project actions.
extension SessionStore {
    // MARK: - Checkpoints

    /// One serial queue per repository (worktrees share their main repository's refs).
    func checkpointQueue(for session: TerminalSession) -> DispatchQueue {
        let key = session.git?.mainRoot ?? session.spec.workPath
        if let queue = checkpointQueues[key] { return queue }
        let queue = DispatchQueue(label: "dev.tako.checkpoints." + key, qos: .utility)
        checkpointQueues[key] = queue
        return queue
    }

    /// Records a turn boundary for an agent in a Git workspace. Starts close any turn left open
    /// (an interrupt never sends Stop), so turns never overlap.
    func checkpoint(_ session: TerminalSession, phase: Checkpoints.Phase, prompt: String) {
        guard session.kind.isAgent, AppSettings.checkpointsEnabled else { return }
        let path = session.spec.workPath, id = session.id.uuidString
        let title = summarize(prompt, limit: 120) ?? "Turn"
        checkpointQueue(for: session).async { [weak session] in
            let turns = Checkpoints.turns(at: path, session: id)
            let open = turns.last.flatMap { $0.end == nil ? $0 : nil }
            switch phase {
            case .start:
                if let open { Checkpoints.capture(at: path, session: id, turn: open.index, phase: .end, prompt: open.prompt) }
                Checkpoints.capture(at: path, session: id, turn: (turns.last?.index ?? 0) + 1, phase: .start, prompt: title)
            case .end:
                guard let open else { return }
                Checkpoints.capture(at: path, session: id, turn: open.index, phase: .end, prompt: open.prompt)
            }
            let updated = Checkpoints.turns(at: path, session: id)
            DispatchQueue.main.async { [weak session] in
                MainActor.assumeIsolated { if session?.turns != updated { session?.turns = updated } }
            }
        }
    }

    /// Reads a session's recorded turns (after a restart, or when the inspector opens).
    func loadTurns(_ session: TerminalSession) {
        guard session.kind.isAgent else { return }
        let path = session.spec.workPath, id = session.id.uuidString
        checkpointQueue(for: session).async { [weak session] in
            let turns = Checkpoints.turns(at: path, session: id)
            DispatchQueue.main.async { [weak session] in
                MainActor.assumeIsolated { if session?.turns != turns { session?.turns = turns } }
            }
        }
    }

    /// Puts the agent's files back to how they were at `commit`. The agent's conversation is
    /// untouched; it's told what happened so it doesn't assume its edits are still there.
    /// `fromTurn`: revert only the files this agent changed from that turn on, so other agents'
    /// edits in the same folder survive. Nil undoes the last restore, touching only what it changed.
    func restoreCheckpoint(_ session: TerminalSession, to commit: String, label: String, fromTurn: Int?,
                           completion: @escaping @MainActor (Result<String, CheckpointError>) -> Void) {
        let path = session.spec.workPath, id = session.id.uuidString
        checkpointQueue(for: session).async { [weak self, weak session] in
            let scope = fromTurn.map { Checkpoints.touched(at: path, session: id, from: $0) }
                ?? Checkpoints.undoScope(at: path, session: id)
            let result = Checkpoints.restore(at: path, to: commit, session: id, only: scope)
            DispatchQueue.main.async { [weak self, weak session] in
                MainActor.assumeIsolated {
                    guard let session else { return }
                    if case .success = result {
                        session.record(.note, "Files restored to \(label)")
                        if session.state == .idle {
                            _ = session.deliver("Note: I restored the workspace files to \(label). Re-read any file before editing it.", from: nil)
                        }
                        self?.refreshReview(session)
                    }
                    completion(result)
                }
            }
        }
    }

    // MARK: - Fork

    /// A new Claude agent that continues this conversation from where it is now; the original
    /// carries on unchanged. Both work in the same folder.
    @discardableResult
    func fork(_ session: TerminalSession) -> Bool {
        guard session.kind == .claude, let conversation = session.spec.agentSessionId else { return false }
        var spec = LaunchSpec(label: session.label + "-fork", kind: .claude, cwd: session.spec.workPath)
        spec.labelSource = .auto
        spec.forkOf = conversation
        spec.options = session.spec.options
        spec.account = session.spec.account
        spec.baseBranch = session.spec.baseBranch
        // No port copied: two dev servers on one port collide, so the fork is given its own.
        Task { @MainActor [weak self, spec] in
            guard let self else { return }
            let fork = await self.launch(spec, resume: false)
            fork.record(.note, "Forked from @\(session.label)")
            session.record(.note, "Forked into @\(fork.label)")
        }
        return true
    }

    // MARK: - Dispatch to several agents

    /// Starts one agent per entry in `kinds` on the same task, each in its own worktree, so their
    /// results can be compared side by side and the best one merged.
    func dispatch(_ task: String, kinds: [SessionKind], cwd: String, options: AgentOptions?) {
        for (index, spec) in dispatchSpecs(task, kinds: kinds, cwd: cwd, options: options).enumerated() {
            let select = index == 0
            Task { @MainActor [weak self, spec] in
                guard let self else { return }
                await self.launch(spec, select: select, isolateIfPossible: true, task: task)
            }
        }
        if kinds.count > 1, layout == .focus { setLayout(.grid) }
    }

    /// The agents `dispatch` starts: named from the task, and sharing one race when there are several.
    func dispatchSpecs(_ task: String, kinds: [SessionKind], cwd: String, options: AgentOptions?) -> [LaunchSpec] {
        let base = labelFromTask(task)
        let mixed = Set(kinds).count > 1
        let race = kinds.count > 1 ? UUID() : nil
        return kinds.enumerated().map { index, kind in
            var label = base
            if mixed { label += "-" + kind.rawValue } else if kinds.count > 1 { label += "-\(index + 1)" }
            var spec = LaunchSpec(label: label, kind: kind, cwd: cwd)
            spec.labelSource = .auto
            spec.options = options
            spec.race = race
            return spec
        }
    }

    // MARK: - Races

    /// The other agents started on the same task.
    func raceSiblings(of session: TerminalSession) -> [TerminalSession] {
        guard let race = session.spec.race else { return [] }
        return sessions.filter { $0.id != session.id && $0.spec.race == race }
    }

    /// Keeps `winner`'s work: commits what it left uncommitted, merges its branch into the base
    /// branch, then closes the other agents and archives their worktrees (their branches stay,
    /// so nothing is lost).
    func pickWinner(_ winner: TerminalSession, completion: @escaping @MainActor (Result<String, ReviewError>) -> Void) {
        if winner.state == .working || winner.state.needsAttention {
            completion(.failure(.git("@\(winner.label) is still working; pick it once its turn ends")))
            return
        }
        guard let base = winner.spec.baseBranch, let branch = winner.git?.branch, branch != base else {
            completion(.failure(.git("@\(winner.label) isn't on its own branch")))
            return
        }
        let path = winner.spec.workPath
        let root = winner.git.map(GitInfo.mainRoot) ?? path
        let label = winner.label
        let losers = raceSiblings(of: winner).map { (session: $0, path: $0.spec.workPath, id: $0.id.uuidString,
                                                    isWorktree: $0.spec.worktreeBranch != nil || $0.spec.worktreeName != nil) }
        DispatchQueue.global(qos: .userInitiated).async {
            // A failed commit (a pre-commit hook, say) must stop here: merging only what was
            // committed and closing the others would quietly drop the winner's latest work.
            var committed: Result<String, ReviewError> = .success("")
            if !(Git.run(["status", "--porcelain"], at: path) ?? "").isEmpty {
                committed = Review.commit(at: path, message: "Work from @\(label) (Tako)")
            }
            let merged = committed.flatMap { _ in Review.merge(branch: branch, into: base, mainRoot: root) }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard case .success = merged else { completion(merged); return }
                    winner.record(.note, "Picked: merged \(branch) into \(base)")
                    winner.spec.race = nil
                    for loser in losers where self.sessions.contains(where: { $0.id == loser.session.id }) { self.close(loser.session) }
                    // Closing stops each agent; its worktree lock goes with it a moment later.
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
                        for loser in losers where loser.isWorktree {
                            _ = Review.archive(worktree: loser.path, mainRoot: root)
                            Checkpoints.prune(at: root, session: loser.id)
                        }
                    }
                    let others = losers.count
                    completion(.success("Merged \(branch) into \(base)" + (others > 0 ? "; closed \(others) other agent\(others == 1 ? "" : "s")" : "")))
                }
            }
        }
    }

    // MARK: - Recently closed

    nonisolated private static var recentlyClosedURL: URL { ControlPaths.supportDirectory.appendingPathComponent("closed.json") }

    nonisolated static func loadRecentlyClosed() -> [LaunchSpec] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: recentlyClosedURL) else { return [] }
        return (try? decoder.decode([LaunchSpec].self, from: data)) ?? []
    }

    /// Every agent but Sumi is kept for reopening, with what it did and how it ended.
    func rememberClosed(_ session: TerminalSession) {
        guard session.kind.isAgent, !session.isSumi else { return }
        var spec = session.spec
        spec.minimized = nil
        spec.asleep = nil
        var memory = spec.memory ?? SessionMemory()
        memory.closedAt = Date()
        memory.lastActiveAt = session.stateChangedAt
        memory.finalState = session.state.detail.map { "\(session.state.phrase): \($0)" } ?? session.state.phrase
        let events = session.timeline.suffix(8).map {
            $0.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        memory.events = events.isEmpty ? nil : events
        spec.memory = memory
        recentlyClosed.removeAll { $0.id == spec.id }
        recentlyClosed.insert(spec, at: 0)
        if recentlyClosed.count > 50 {
            // Out of reach for good: its checkpoints can go too.
            let dropped = recentlyClosed.suffix(from: 50)
            recentlyClosed.removeLast(recentlyClosed.count - 50)
            // An archived worktree's folder is gone, but its refs live in the shared repository:
            // prune from the main checkout (Claude worktrees keep it as cwd) when that's all that's left.
            let targets = dropped.map { (paths: [$0.workPath, expandTilde($0.cwd)], id: $0.id.uuidString) }
            pruneQueue.async {
                for target in targets {
                    guard let path = target.paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
                    Checkpoints.prune(at: path, session: target.id)
                }
            }
        }
        saveRecentlyClosed()
    }

    /// Resumes the conversation when there is one; otherwise starts a fresh agent in its folder.
    @discardableResult
    func reopen(_ spec: LaunchSpec) -> TerminalSession? {
        recentlyClosed.removeAll { $0.id == spec.id }
        saveRecentlyClosed()
        // A conversation lives with its folder; once the worktree is archived it can't resume.
        guard FileManager.default.fileExists(atPath: spec.workPath) else {
            let branch = spec.worktreeBranch.map { " Its work is on branch \($0)." } ?? ""
            lastError = "@\(spec.label)'s worktree was archived, so it can't be reopened.\(branch)"
            return nil
        }
        var spec = spec
        spec.label = sessions.contains { $0.label == spec.label } ? "" : spec.label
        return create(spec, resume: spec.canResume)
    }

    func forgetClosed() {
        recentlyClosed = []
        saveRecentlyClosed()
    }

    private func saveRecentlyClosed() {
        guard persists else { return }
        let specs = recentlyClosed
        let url = Self.recentlyClosedURL
        Self.persistQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(specs) { try? data.write(to: url, options: .atomic) }
        }
    }

    // MARK: - Rate limits

    /// When the account's limit resets, tells the agent to carry on.
    func continueAtReset(_ session: TerminalSession) {
        let limits = self.limits(for: session)
        guard let reset = [limits?.fiveHourResets, limits?.sevenDayResets].compactMap({ $0 })
            .filter({ $0 > Date() }).min() else { return }
        session.resumeAt = reset
        session.record(.note, "Will continue at \(reset.formatted(date: .omitted, time: .shortened))")
        // A minute's grace: resets land on the minute, and the first request after one can still bounce.
        // Wall time: the uptime clock stops while the Mac sleeps, which would push this past the reset.
        let delay = reset.timeIntervalSinceNow + 60
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + delay) { [weak session] in
            guard let session, session.resumeAt == reset else { return }
            session.resumeAt = nil
            _ = session.deliver("Your usage limit has reset. Continue where you left off.", from: nil)
        }
    }

    func cancelContinue(_ session: TerminalSession) {
        session.resumeAt = nil
    }

    /// The reset time to offer, when an agent stopped on a rate limit.
    func rateLimitReset(for session: TerminalSession) -> Date? {
        guard case .failed(let reason) = session.state, reason.lowercased().contains("rate") else { return nil }
        let limits = self.limits(for: session)
        return [limits?.fiveHourResets, limits?.sevenDayResets].compactMap { $0 }.filter { $0 > Date() }.min()
    }

    // MARK: - Project actions

    /// The selected session's project actions: declared ones, else ones detected from manifests.
    func projectActions(for session: TerminalSession?) -> [ProjectAction] {
        guard let session, session.kind != .browser else { return [] }
        let path = session.spec.workPath
        if let declared = ProjectConfig.load(for: path)?.actions, !declared.isEmpty { return declared }
        let root = session.git?.root ?? path
        return ProjectAction.detect(at: root)
    }

    /// Runs an action next to `session`: servers go to the shelf on the agent's own port; other
    /// commands open a shell tile that keeps the output.
    func run(_ action: ProjectAction, for session: TerminalSession) {
        let kind: SessionKind = action.isServer ? .server : .shell
        let label = normalizeLabel("\(session.label)-\(action.name)")
        if let existing = sessions.first(where: { $0.label == label && $0.kind == kind }) {
            existing.restart()
            select(existing)
            return
        }
        var spec = LaunchSpec(label: label, kind: kind, cwd: session.spec.workPath, command: action.command)
        spec.labelSource = .auto
        if action.isServer, let port = session.spec.port {
            spec.port = port
            spec.command = action.command.replacingOccurrences(of: "$PORT", with: String(port))
        }
        create(spec, select: !action.isServer)
    }

    // MARK: - Labels

    /// "fix the flaky auth tests please" → "fix-flaky-auth".
    func labelFromTask(_ task: String) -> String {
        let stop: Set<String> = ["the", "a", "an", "to", "and", "of", "in", "on", "for", "please", "can", "you", "with", "is", "it", "that", "this", "my"]
        let words = task.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) }
        return normalizeLabel(words.prefix(3).joined(separator: "-"))
    }
}
