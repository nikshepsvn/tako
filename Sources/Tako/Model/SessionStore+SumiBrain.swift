import Foundation

/// Sumi's view of the whole desk in one call (standup), its plan board, its memory, and what it
/// learns from the user's own approvals. The state lives in `SumiBrain`; this is how the store
/// feeds it and acts on it.
extension SessionStore {
    // MARK: - Standup

    /// Above this long idle with uncommitted files, an agent's work counts as at risk.
    static let idleWithWorkAfter: TimeInterval = 20 * 60

    /// One line (plus a short second one) per agent: state and for how long, what it's doing or
    /// last did, todo progress, diff against its base, uncommitted files, tests, cost, context,
    /// blockers and file overlaps. Git is read fresh off the main thread, so the numbers are now's.
    /// With `since`, a briefing of what happened from then (see `Briefing`) comes first.
    func standup(only labels: [String]? = nil, since: String? = nil, now: Date = Date(),
                 completion: @escaping @MainActor (String) -> Void) {
        let start = since.map { Briefing.start($0, last: sumiBrain.lastStandup, now: now) }
        sumiBrain.lastStandup = now
        let live = start.flatMap { $0 }.map { briefingLive(since: $0) }
        let wanted = labels.map { Set($0.compactMap { find($0)?.id }) }
        let agents = orderedSessions.filter { session in
            !session.isSumi && session.kind != .browser && (wanted?.contains(session.id) ?? true)
        }
        let probes: [GitProbe] = agents.filter(\.kind.isAgent).map { (id: $0.id, path: $0.spec.workPath, base: $0.spec.baseBranch) }
        DispatchQueue.global(qos: .userInitiated).async {
            let git = Self.probeGit(probes)
            var briefing: String?
            if let since {
                if let start = start.flatMap({ $0 }), let live {
                    briefing = Briefing.describe(since: start, now: now, events: EventLog.read(since: start), live: live)
                } else {
                    briefing = "since: couldn't read \"\(since)\"; pass \"last\", a duration like \"8h\" or an ISO time"
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let standup = self.describeStandup(agents, git: git, now: now)
                    completion(briefing.map { $0 + "\n\n" + standup } ?? standup)
                }
            }
        }
    }

    typealias GitProbe = (id: UUID, path: String, base: String?)

    /// Each agent's diff against its base and its uncommitted file count, read fresh and in
    /// parallel. Blocking: call it off the main thread.
    nonisolated static func probeGit(_ probes: [GitProbe]) -> [UUID: (stat: DiffStat?, dirty: Int?)] {
        var git: [UUID: (stat: DiffStat?, dirty: Int?)] = [:]
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: probes.count) { index in
            let probe = probes[index]
            let status = Git.run(["status", "--porcelain"], at: probe.path)
            let result = (Review.diffStat(at: probe.path, base: probe.base),
                          status.map { $0.split(separator: "\n").count })
            lock.lock(); git[probe.id] = result; lock.unlock()
        }
        return git
    }

    func describeStandup(_ agents: [TerminalSession], git: [UUID: (stat: DiffStat?, dirty: Int?)], now: Date) -> String {
        var counts: [String: Int] = [:]
        for agent in agents where agent.kind.isAgent { counts[agent.isAsleep ? "asleep" : agent.state.key, default: 0] += 1 }
        var head = agents.isEmpty ? "No terminals." : "\(agents.filter(\.kind.isAgent).count) agents: "
            + counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        if let limits = rateLimits?.current(at: now), limits.highest > 0 {
            head += " · Claude limits 5h \(Int(limits.fiveHourPercent ?? 0))%, 7d \(Int(limits.sevenDayPercent ?? 0))%"
        }
        let cost = agents.compactMap(\.usage.costUSD).reduce(0, +)
        if cost > 0 { head += String(format: " · $%.2f this session", cost) }
        var lines = [head]
        lines += agents.map { standupLine($0, git: git[$0.id], now: now) }
        if !sumiBrain.plan.tasks.isEmpty { lines.append(sumiBrain.plan.describe(now: now)) }
        let warnings = Steward.shared.escalations.filter { warning in agents.contains { $0.id.uuidString == warning.sessionID } }
        if !warnings.isEmpty { lines.append("Steward: " + warnings.map(\.message).joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    private func standupLine(_ session: TerminalSession, git: (stat: DiffStat?, dirty: Int?)?, now: Date) -> String {
        let since = Self.duration(now.timeIntervalSince(session.stateChangedAt))
        var line = "@\(session.label) [\(session.kind.rawValue)] " + (session.isAsleep ? "asleep" : session.state.key) + " \(since)"
        if let branch = session.git?.branch { line += " · \(branch)" }
        if !session.ports.isEmpty { line += " · " + session.ports.map { ":\($0)" }.joined(separator: " ") }
        guard session.kind.isAgent else {
            if case .exited(let code) = session.state, code != 0 { line += " · CRASHED (exit \(code))" }
            return line
        }
        if let doing = session.activity, session.state == .working { line += " · doing: " + Self.clip(doing, 70) }
        if session.tasks.total > 0 {
            line += " · todos \(session.tasks.done)/\(session.tasks.total)"
            if let current = session.tasks.current { line += " (\(Self.clip(current, 40)))" }
        }
        if !session.runningSubagents.isEmpty { line += " · \(session.runningSubagents.count) subagents" }
        if let stat = git?.stat ?? session.diffStat, !stat.isEmpty { line += " · " + stat.text }
        if let dirty = git?.dirty, dirty > 0 { line += " · \(dirty) uncommitted" }
        if let tests = session.testEvidence { line += " · tests " + (tests.passed ? "pass" : "FAIL") + " \(Self.duration(now.timeIntervalSince(tests.date))) ago" }
        if let cost = session.usage.costUSD { line += String(format: " · $%.2f", cost) }
        if let context = session.usage.contextPercent, context >= 50 { line += " · context \(Int(context))%" }
        var notes: [String] = []
        if let last = Self.turnSummary(session) { notes.append("last: " + Self.clip(last, 160)) }
        if let status = session.agentStatus { notes.append("status: " + Self.clip(status, 80)) }
        notes += startupNotes(session, now: now)
        notes += blockers(session, dirty: git?.dirty, now: now)
        return notes.isEmpty ? line : line + "\n    " + notes.joined(separator: " · ")
    }

    /// What stands between this agent and done that Sumi or the user could act on.
    private func blockers(_ session: TerminalSession, dirty: Int?, now: Date) -> [String] {
        var found: [String] = []
        let idleFor = now.timeIntervalSince(session.stateChangedAt)
        switch session.state {
        case .needsInput(let reason):
            found.append("BLOCKED \(Self.duration(idleFor)): " + Self.clip(waitDescription(session, reason: reason), 200)
                + (session.delegation != nil ? " (you handle it)" : ""))
        case .failed(let reason): found.append("FAILED: " + Self.clip(reason, 120))
        case .idle where (dirty ?? 0) > 0 && idleFor >= Self.idleWithWorkAfter:
            found.append("idle with \(dirty ?? 0) uncommitted files")
        default: break
        }
        let overlaps = session.overlaps.compactMap { id, files in
            sessions.first { $0.id == id }.map { "@\($0.label) (" + files.prefix(3).joined(separator: ", ") + (files.count > 3 ? ", …" : "") + ")" }
        }
        if !overlaps.isEmpty { found.append("same files as " + overlaps.sorted().joined(separator: ", ")) }
        if let task = sumiBrain.plan.tasks.first(where: { owns($0, session) && $0.status == .running }) {
            found.append("plan \(task.id): \(Self.clip(task.title, 50))")
        }
        return found
    }

    /// What the agent said at the end of its last turn. A summary that is still the prompt (a
    /// turn with no closing message, or one started by a channel event) says nothing about the
    /// result, so the last recorded finish stands in, or nothing.
    static func turnSummary(_ session: TerminalSession) -> String? {
        if let summary = session.summary, !summary.hasPrefix("› "), !summary.hasPrefix("<") { return summary }
        return session.timeline.last { $0.kind == .done }?.text
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h\(s % 3600 / 60 > 0 ? "\(s % 3600 / 60)m" : "")" }
        return "\(s / 86_400)d"
    }

    nonisolated static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    // MARK: - Plan

    private func owns(_ task: PlanTask, _ session: TerminalSession) -> Bool {
        if let id = task.ownerID { return id == session.id }
        return task.owner.map { find($0)?.id == session.id } ?? false
    }

    private func liveOwner(_ task: PlanTask) -> TerminalSession? {
        if let id = task.ownerID, let session = sessions.first(where: { $0.id == id }) { return session }
        return task.owner.flatMap(find).flatMap { $0.kind.isAgent && !$0.isSumi ? $0 : nil }
    }

    /// The plan tool: show, add (or replace) tasks, update one, remove one, or clear.
    func planCommand(_ args: [String: Any]) -> Result<String, PlanError> {
        let action = args["action"] as? String ?? "show"
        var plan = sumiBrain.plan
        var reply: String
        switch action {
        case "show":
            return .success(plan.describe())
        case "add":
            if let goal = args["goal"] as? String, !goal.isEmpty { plan.goal = goal }
            let incoming = (args["tasks"] as? [[String: Any]] ?? []).map(planTask)
            guard !incoming.isEmpty || args["goal"] != nil else { return .failure(PlanError("pass tasks: [{title, owner?, deps?, brief?, folder?}]")) }
            for task in incoming where task.title.isEmpty { return .failure(PlanError("every task needs a title")) }
            switch plan.upsert(incoming) {
            case .success(let ids): reply = "added \(ids.joined(separator: ", "))"
            case .failure(let error): return .failure(error)
            }
        case "update":
            guard let id = args["id"] as? String, let index = plan.tasks.firstIndex(where: { $0.id == id }) else {
                return .failure(PlanError("no task \(args["id"] as? String ?? "(none)"); plan show lists them"))
            }
            if let raw = args["status"] as? String {
                guard let status = PlanTask.Status(rawValue: raw) else { return .failure(PlanError("status is todo, running, done, failed or blocked")) }
                if plan.tasks[index].status != status { recordPlanTask(PlanTask(id: id, title: "", owner: plan.tasks[index].owner, status: status)) }
                plan.tasks[index].status = status
                if status == .todo { plan.tasks[index].announced = false }
            }
            if let owner = args["owner"] as? String {
                let session = find(owner)
                plan.tasks[index].owner = session?.label ?? normalizeLabel(owner)
                plan.tasks[index].ownerID = session?.id
            }
            if let note = args["note"] as? String { plan.tasks[index].note = note.isEmpty ? nil : Self.clip(note, 200) }
            if let brief = args["brief"] as? String { plan.tasks[index].brief = brief }
            reply = "updated \(id)"
        case "remove":
            guard let id = args["id"] as? String, plan.remove(id) else { return .failure(PlanError("no task \(args["id"] as? String ?? "(none)")")) }
            reply = "removed \(id)"
        case "clear":
            plan = SumiPlan()
            sumiBrain.plan = plan
            return .success("plan cleared")
        default:
            return .failure(PlanError("action is show, add, update, remove or clear"))
        }
        sumiBrain.plan = plan
        let moved = advancePlan()
        return .success(([reply] + moved).joined(separator: "\n") + "\n" + sumiBrain.plan.describe())
    }

    private func planTask(_ object: [String: Any]) -> PlanTask {
        let ownerName = (object["owner"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let owner = ownerName.flatMap(find)
        return PlanTask(
            id: normalizeLabel(object["id"] as? String ?? ""),
            title: Self.clip(object["title"] as? String ?? "", 120),
            owner: owner?.label ?? ownerName.map(normalizeLabel),
            ownerID: owner?.id,
            deps: (object["deps"] as? [String] ?? []).map(normalizeLabel),
            status: (object["status"] as? String).flatMap(PlanTask.Status.init) ?? .todo,
            brief: (object["brief"] as? String).flatMap { $0.isEmpty ? nil : sanitizeMessage($0) },
            folder: (object["folder"] as? String).map { expandTilde($0) },
            kind: object["kind"] as? String)
    }

    /// Starts every task whose dependencies are done: briefs a live owner, or starts an agent in
    /// the task's folder. Returns one line per step, for Sumi.
    @discardableResult
    func advancePlan() -> [String] {
        var plan = sumiBrain.plan
        var moved: [String] = []
        for ready in plan.ready {
            guard let index = plan.tasks.firstIndex(where: { $0.id == ready.id }) else { continue }
            var task = plan.tasks[index]
            if let owner = liveOwner(task) {
                task.owner = owner.label
                task.ownerID = owner.id
                task.status = .running
                // Already at it (it was briefed when it started): its current turn counts.
                task.ownerWorked = owner.state == .working && task.brief == nil
                if let brief = task.brief {
                    _ = owner.deliver(agentMessagePrefix + "sumi (plan task \(task.id)): " + brief, from: "sumi")
                    moved.append("\(task.id) ready: briefed @\(owner.label)")
                } else {
                    moved.append("\(task.id) running on @\(owner.label)")
                }
            } else if let folder = task.folder, FileManager.default.fileExists(atPath: folder) {
                task.status = .running
                task.ownerWorked = false
                startPlanAgent(task, in: folder)
                moved.append("\(task.id) ready: starting an agent in \(abbreviateHome(folder))")
            } else if !task.announced {
                task.announced = true
                moved.append("\(task.id) is ready but has no live owner or folder: plan update it with an owner")
            }
            plan.tasks[index] = task
        }
        if plan != sumiBrain.plan { sumiBrain.plan = plan }
        return moved
    }

    /// A ready task with no one to do it: an agent of its own, briefed with the task, the way
    /// start_agent starts one, through the steward's queue.
    private func startPlanAgent(_ task: PlanTask, in folder: String) {
        let kind = task.kind.flatMap(SessionKind.init(rawValue:)).flatMap { $0.isAgent ? $0 : nil } ?? Self.sumiKind
        let brief = task.brief ?? task.title
        let id = task.id
        Steward.shared.enqueueLaunch { Task { @MainActor [weak self] in
            guard let self else { return }
            var spec = LaunchSpec(label: normalizeLabel(id + "-" + self.labelFromTask(task.title)), kind: kind, cwd: folder)
            spec.labelSource = .agent
            spec.options = AppSettings.defaultMode.map { AgentOptions(mode: $0) }
            let briefed = await self.withTeamBoard(brief, folder: folder)
            let child = await self.launch(spec, select: false, isolateIfPossible: true, task: briefed)
            child.record(.note, "Started by Sumi's plan (\(id))")
            self.showOpenedBySumi([child])
            guard let index = self.sumiBrain.plan.tasks.firstIndex(where: { $0.id == id }) else { return }
            self.sumiBrain.plan.tasks[index].owner = child.label
            self.sumiBrain.plan.tasks[index].ownerID = child.id
        } }
    }

    /// An owner's turn moving the plan: its finish completes the task it was running, a failure
    /// or exit fails it, and finished tasks start the ones waiting on them. Sumi hears each step.
    func planSawStateChange(_ session: TerminalSession, from previous: AgentState) {
        guard session.kind.isAgent, !session.isSumi,
              let index = sumiBrain.plan.tasks.firstIndex(where: { owns($0, session) && $0.status == .running }) else { return }
        var plan = sumiBrain.plan
        var task = plan.tasks[index]
        task.owner = session.label
        var news: String?
        switch session.state {
        case .working:
            task.ownerWorked = true
        case .idle where previous == .working && session.runningSubagents.isEmpty && task.ownerWorked:
            task.status = .done
            task.note = Self.turnSummary(session).map { "finished: " + Self.clip($0, 160) }
            news = "\(task.id) done (@\(session.label)" + (task.note.map { ", \($0)" } ?? "") + ")"
        case .failed(let reason):
            task.status = .failed
            task.note = "failed: " + Self.clip(reason, 120)
            news = "\(task.id) failed on @\(session.label): \(reason)"
        case .exited:
            task.status = .failed
            task.note = "owner exited"
            news = "\(task.id) failed: @\(session.label) exited"
        default: break
        }
        plan.tasks[index] = task
        sumiBrain.plan = plan
        guard let news else { return }
        recordPlanTask(task)
        let moved = advancePlan()
        let open = sumiBrain.plan.tasks.filter { $0.status != .done }.count
        let tail = open == 0 ? " · plan complete: wrap up with the user" : ""
        if sumi != nil { addToSumiDigest(SumiEvent(label: "plan", kind: .plan(([news] + moved).joined(separator: "; ") + tail))) }
    }

    // MARK: - Event feed

    /// A memory warning repeats only once it has grown by this much, or after `stewardQuiet`.
    static let stewardGrowth: UInt64 = 1 << 30
    static let stewardQuiet: TimeInterval = 30 * 60

    /// The steward raises a warning once per episode, but a reading that hovers at the limit
    /// starts a new episode every few minutes. Sumi hears a warning again only when it is
    /// materially worse or it has been quiet for a while.
    func stewardWarningIsNews(_ escalation: Escalation, now: Date = Date()) -> Bool {
        let key = escalation.sessionID + "|" + escalation.kind.rawValue
        if let told = sumiBrain.stewardTold[key], now.timeIntervalSince(told.at) < Self.stewardQuiet,
           escalation.kind == .idleBurning || escalation.footprintBytes < told.bytes + Self.stewardGrowth {
            return false
        }
        sumiBrain.stewardTold[key] = (now, escalation.footprintBytes)
        return true
    }

    /// How long an agent Sumi follows may wait on the user before Sumi hears about it.
    static let longWaitAfter: TimeInterval = 5 * 60

    /// Agents Sumi watches, plans with, or was told about: it hears their crashes and long waits.
    func sumiFollows(_ session: TerminalSession) -> Bool {
        sumiWatches[session.id] != nil || sumiBrain.repeatWatches[session.id] != nil
            || sumiBrain.plan.tasks.contains { owns($0, session) && $0.status == .running }
    }

    /// Events beyond the watched finish: a server that crashed, and a wait on the user that has
    /// gone on for minutes. Outside Phone Mode the user handles their own waits; Sumi hears only
    /// so it can nudge them or unblock the agent's dependents.
    func extraSumiEvents(_ session: TerminalSession, from previous: AgentState) -> [SumiEvent] {
        var events: [SumiEvent] = []
        if session.kind == .server, case .exited(let code) = session.state, code != 0, previous == .running {
            let tail = session.surface.readText(lastLines: 4).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(2).joined(separator: " / ")
            events.append(SumiEvent(label: session.label, kind: .serverCrashed(code: code, tail: Self.clip(tail, 200))))
        }
        if case .needsInput(let reason) = session.state, !isPhoneModeOn, session.delegation == nil,
           sumiFollows(session), !TerminalSession.isUsersOwn(reason) {
            scheduleLongWaitCheck(session, reason: reason)
        }
        if !session.state.needsAttention { sumiBrain.longWaitsTold[session.id] = nil }
        return events
    }

    private func scheduleLongWaitCheck(_ session: TerminalSession, reason: String) {
        let since = session.stateChangedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longWaitAfter) { [weak self, weak session] in
            guard let self, let session else { return }
            self.checkLongWait(session, reason: reason, since: since)
        }
    }

    /// Still on the same wait, with no one handling it: Sumi hears once per wait.
    func checkLongWait(_ session: TerminalSession, reason: String, since: Date, now: Date = Date()) {
        guard session.state == .needsInput(reason), session.stateChangedAt == since, session.delegation == nil,
              !isPhoneModeOn, sumiBrain.longWaitsTold[session.id] != reason, sumi != nil else { return }
        sumiBrain.longWaitsTold[session.id] = reason
        let minutes = Int(now.timeIntervalSince(since) / 60)
        addToSumiDigest(SumiEvent(label: session.label, kind: .waitingLong(waitDescription(session, reason: reason), minutes: minutes)))
    }

    /// After a finish: what the agent leaves behind that Sumi should know before chaining on.
    func finishFacts(_ session: TerminalSession) -> String? {
        var facts: [String] = []
        if let stat = session.diffStat, !stat.isEmpty { facts.append(stat.text) }
        if let tests = session.testEvidence, Date().timeIntervalSince(tests.date) < 3600, !tests.passed { facts.append("last test run FAILED") }
        if !session.overlaps.isEmpty {
            facts.append("same files as " + session.overlaps.keys.compactMap { id in sessions.first { $0.id == id }.map { "@" + $0.label } }.sorted().joined(separator: ", "))
        }
        return facts.isEmpty ? nil : facts.joined(separator: " · ")
    }

    // MARK: - Approvals the user taught

    /// Where a session's learned answers live: its repository's main checkout, so worktrees share.
    func approvalProject(_ session: TerminalSession) -> String {
        session.git?.mainRoot ?? session.spec.workPath
    }

    /// The user answered a permission request themselves (or said so on their phone): remember it
    /// for the project. Risky requests aren't learned.
    func learnAnswer(_ session: TerminalSession, approval: PendingApproval, answer: PromptAnswer) {
        guard !sumiBrain.sumiAnswering, !session.isSumi,
              RiskyRequest.reason(tool: approval.toolName, request: approval.request, workspace: session.spec.workPath) == nil,
              let key = ApprovalMemory.key(tool: approval.toolName, request: approval.request) else { return }
        sumiBrain.approvals.learn(project: approvalProject(session), key: key, answer: answer)
    }

    /// A session handed to Sumi asks for something the user always allows in this project, and
    /// it isn't risky: Tako answers as the user did, and Sumi only hears it happened.
    func approveAsUserAlwaysDoes(_ session: TerminalSession) -> String? {
        guard let approval = approvals[session.id],
              RiskyRequest.reason(tool: approval.toolName, request: approval.request, workspace: session.spec.workPath) == nil,
              let key = ApprovalMemory.key(tool: approval.toolName, request: approval.request),
              sumiBrain.approvals.allows(project: approvalProject(session), key: key) else { return nil }
        sumiBrain.sumiAnswering = true
        defer { sumiBrain.sumiAnswering = false }
        guard case .success = answer(session, .approve) else { return nil }
        session.record(.note, "Approved as you always do here: \(key)")
        return key
    }

    /// "the user approved Bash(pnpm test) 3× here" for a wait Sumi is told about.
    func approvalPrecedent(_ session: TerminalSession) -> String? {
        guard let approval = approvals[session.id],
              let key = ApprovalMemory.key(tool: approval.toolName, request: approval.request),
              let record = sumiBrain.approvals.record(project: approvalProject(session), key: key) else { return nil }
        return "the user has \(ApprovalMemory.precedent(record)) \(key) in this project"
    }

    // MARK: - Memory

    /// What Sumi remembers about the project at `folder`, plus the commands Tako finds there, for
    /// start_agent's reply: the brief it writes next can use them without a lookup.
    func projectBrief(for folder: String) -> String {
        let folder = (expandTilde(folder) as NSString).standardizingPath
        var parts: [String] = []
        let key = sumiBrain.memory.projectKey(for: folder)
        if let key, let facts = sumiBrain.memory.describeProject(key) { parts.append(facts) }
        let known = Set((key.flatMap { sumiBrain.memory.projects[$0] } ?? []).compactMap(\.topic))
        if !known.contains("test") || !known.contains("build") {
            let actions = ProjectConfig.load(for: folder)?.actions ?? ProjectAction.detect(at: folder)
            let detected = actions.filter { !$0.isServer }.prefix(4).map { "\($0.name.lowercased()): \($0.command)" }
            if !detected.isEmpty { parts.append("  - detected " + detected.joined(separator: ", ")) }
        }
        guard !parts.isEmpty else { return "" }
        return "\nWhat you know about \(abbreviateHome(key ?? folder)) (put what the agent needs in its brief):\n" + parts.joined(separator: "\n")
    }

    /// The remember tool: add or forget one entry.
    func rememberCommand(_ args: [String: Any]) -> Result<String, PlanError> {
        guard let section = (args["section"] as? String).flatMap(SumiMemory.Section.init) else {
            return .failure(PlanError("section is project, preference or lesson"))
        }
        let text = (args["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure(PlanError("text is empty")) }
        var project: String?
        if section == .project {
            guard let folder = args["project"] as? String, !folder.isEmpty else { return .failure(PlanError("a project fact needs project (its folder)")) }
            let path = (expandTilde(folder) as NSString).standardizingPath
            project = sumiBrain.memory.projectKey(for: path) ?? path
        }
        if args["forget"] as? Bool == true {
            if section == .project, let project, text == "*" {
                let gone = sumiBrain.approvals.forget(project: project, key: nil)
                return .success("forgot \(gone) learned approvals for \(abbreviateHome(project))")
            }
            let gone = sumiBrain.memory.forget(text, section: section, project: project)
            return .success(gone == 0 ? "nothing matched" : "forgot \(gone)")
        }
        let topic = (args["topic"] as? String).flatMap { SumiMemory.topics.contains($0) ? $0 : nil }
        if SessionStore.looksSecret(text) { return .failure(PlanError("that looks like a secret; never store secrets")) }
        sumiBrain.memory.remember(text, section: section, project: project, topic: topic ?? (section == .project ? "note" : nil))
        return .success("remembered" + (project.map { " for \(abbreviateHome($0))" } ?? ""))
    }

    /// The recall tool: preferences, lessons, and one project's facts and learned approvals; with
    /// no project, the projects Sumi knows.
    func recall(project folder: String?) -> String {
        let memory = sumiBrain.memory
        var lines: [String] = []
        if !memory.preferences.isEmpty { lines += ["User preferences:", SumiMemory.describe(memory.preferences)] }
        if !memory.lessons.isEmpty { lines += ["Lessons:", SumiMemory.describe(memory.lessons)] }
        if let folder, !folder.isEmpty {
            let path = (expandTilde(folder) as NSString).standardizingPath
            let brief = projectBrief(for: path)
            lines.append(brief.isEmpty ? "Nothing known about \(abbreviateHome(path)) yet." : brief.trimmingCharacters(in: .newlines))
            let root = sessions.first { $0.spec.workPath.hasPrefix(path) }.map(approvalProject) ?? path
            if let learned = sumiBrain.approvals.describe(project: root) { lines += ["The user's past answers here:", learned] }
        } else if !memory.projects.isEmpty {
            lines.append("Projects: " + memory.projects.keys.sorted().map(abbreviateHome).joined(separator: ", "))
        }
        return lines.isEmpty ? "Nothing remembered yet. Use remember when you learn something durable." : lines.joined(separator: "\n")
    }

    /// Tokens and keys don't belong in a notes file the whole Mac can read.
    static func looksSecret(_ text: String) -> Bool {
        let patterns = [#"\b(sk|pk|rk)[-_][A-Za-z0-9_-]{16,}"#, #"\bgh[pousr]_[A-Za-z0-9]{20,}"#, #"\bAKIA[0-9A-Z]{16}\b"#,
                        #"-----BEGIN [A-Z ]*PRIVATE KEY"#, #"\b(password|passwd|api[_-]?key|token)\s*[:=]\s*\S{6,}"#]
        return patterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
}

extension SessionStore {
    /// Whether the request a handed-over session waits on is one the user always allows here.
    func learnedAlways(_ session: TerminalSession) -> Bool {
        guard let approval = approvals[session.id],
              RiskyRequest.reason(tool: approval.toolName, request: approval.request, workspace: session.spec.workPath) == nil,
              let key = ApprovalMemory.key(tool: approval.toolName, request: approval.request) else { return false }
        return sumiBrain.approvals.allows(project: approvalProject(session), key: key)
    }
}
