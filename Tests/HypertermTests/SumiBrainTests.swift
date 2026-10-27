import XCTest
@testable import Hyperterm

/// Sumi's board, memory, learned approvals and event feed. Preview stores keep the brain in
/// memory, so nothing here writes to the app's support folder.
@MainActor
final class SumiBrainTests: XCTestCase {
    // MARK: - Plan

    func testPlanRejectsUnknownDependenciesAndLoops() {
        var plan = SumiPlan()
        guard case .failure(let missing) = plan.upsert([task("b", deps: ["a"])]) else { return XCTFail("unknown dep accepted") }
        XCTAssertTrue(missing.description.contains("a"), missing.description)
        XCTAssertTrue(plan.tasks.isEmpty, "a rejected batch changes nothing")

        guard case .success = plan.upsert([task("a"), task("b", deps: ["a"])]) else { return XCTFail() }
        guard case .failure(let loop) = plan.upsert([task("a", deps: ["b"])]) else { return XCTFail("cycle accepted") }
        XCTAssertTrue(loop.description.contains("loop"), loop.description)
        XCTAssertEqual(plan.task("a")?.deps, [], "the loop wasn't kept")
        XCTAssertEqual(plan.ready.map(\.id), ["a"])
    }

    func testPlanGivesTasksIdsAndKeepsStatusWhenReplaced() {
        var plan = SumiPlan()
        guard case .success(let ids) = plan.upsert([task(""), task("")]) else { return XCTFail() }
        XCTAssertEqual(ids, ["t1", "t2"])
        plan.tasks[0].status = .running
        _ = plan.upsert([PlanTask(id: "t1", title: "renamed")])
        XCTAssertEqual(plan.task("t1")?.status, .running, "replacing a task's text doesn't reset its progress")
        XCTAssertEqual(plan.task("t1")?.title, "renamed")
        XCTAssertTrue(plan.remove("t1"))
        XCTAssertEqual(plan.tasks.map(\.id), ["t2"])
    }

    func testOwnersFinishingRunThePlanAndSumiHears() throws {
        let api = agent("api", state: .working), web = agent("web", state: .needsInput("busy"))
        let sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, web, sumi], previewLayout: .grid)

        let added = try store.planCommand(["action": "add", "goal": "orders", "tasks": [
            ["id": "api", "title": "Add /orders", "owner": "api"],
            ["id": "web", "title": "Use /orders", "owner": "web", "deps": ["api"], "brief": "the /orders endpoint is ready; wire the page to it"],
        ]]).get()
        XCTAssertTrue(added.contains("api running on @api"), added)
        XCTAssertEqual(store.sumiBrain.plan.task("web")?.status, .todo)
        XCTAssertTrue(web.pendingMessages.isEmpty, "not briefed before its dependency is done")

        set(api, .idle, from: .working, store)

        XCTAssertEqual(store.sumiBrain.plan.task("api")?.status, .done)
        XCTAssertEqual(store.sumiBrain.plan.task("web")?.status, .running)
        XCTAssertEqual(web.pendingMessages.count, 1)
        XCTAssertTrue(web.pendingMessages[0].contains("plan task web"), web.pendingMessages[0])
        XCTAssertTrue(web.pendingMessages[0].contains("wire the page"), web.pendingMessages[0])

        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))
        let report = sumi.pendingMessages.joined()
        XCTAssertTrue(report.contains("plan: api done"), report)
        XCTAssertTrue(report.contains("briefed @web"), report)
    }

    func testABriefedOwnerCompletesItsTaskOnlyAfterWorkingOnIt() throws {
        let api = agent("api", state: .needsInput("busy")), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        _ = try store.planCommand(["action": "add", "tasks": [["id": "fix", "title": "Fix", "owner": "api", "brief": "fix it"]]]).get()
        XCTAssertEqual(api.pendingMessages.count, 1)

        // The turn it was already in ends: that wasn't this task.
        set(api, .idle, from: .working, store)
        XCTAssertEqual(store.sumiBrain.plan.task("fix")?.status, .running)

        set(api, .working, from: .idle, store)
        set(api, .idle, from: .working, store)
        XCTAssertEqual(store.sumiBrain.plan.task("fix")?.status, .done)
    }

    func testAnOwnerThatExitsFailsItsTaskAndDependentsWait() throws {
        let api = agent("api", state: .working), web = agent("web", state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        _ = try store.planCommand(["action": "add", "tasks": [
            ["id": "a", "title": "A", "owner": "api"], ["id": "b", "title": "B", "owner": "web", "deps": ["a"], "brief": "go"],
        ]]).get()

        set(api, .exited(1), from: .working, store)

        XCTAssertEqual(store.sumiBrain.plan.task("a")?.status, .failed)
        XCTAssertEqual(store.sumiBrain.plan.task("b")?.status, .todo)
        XCTAssertTrue(web.pendingMessages.isEmpty)
        XCTAssertTrue(store.sumiBrain.plan.describe().contains("after a"))
    }

    func testAReadyTaskWithNoOneToDoItIsAnnouncedOnce() throws {
        let store = SessionStore(previewSessions: [], previewLayout: .grid)
        let first = try store.planCommand(["action": "add", "tasks": [["id": "x", "title": "X", "owner": "ghost"]]]).get()
        XCTAssertTrue(first.contains("no live owner"), first)
        XCTAssertTrue(store.advancePlan().isEmpty, "said once")
        XCTAssertEqual(store.sumiBrain.plan.task("x")?.status, .todo)
    }

    // MARK: - Standup

    func testStandupShowsBlockersProgressOverlapsAndThePlan() throws {
        let api = agent("api", state: .working), web = agent("web", state: .needsInput("Allow Bash(pnpm migrate)?"))
        let idle = agent("docs", state: .idle)
        let store = SessionStore(previewSessions: [api, web, idle], previewLayout: .grid)
        api.activity = "Edit src/orders.ts"
        api.tasks = TaskProgress(subjects: ["1": "Route", "2": "Tests"], completed: ["1"], order: ["1", "2"])
        api.overlaps[web.id] = ["src/api.ts"]
        api.usage.costUSD = 1.5
        api.testEvidence = TestEvidence(passed: false, summary: "2 failed", date: Date())
        idle.summary = "› fix the docs"
        _ = try store.planCommand(["action": "add", "tasks": [["id": "o", "title": "Orders", "owner": "api"]]]).get()

        let later = Date().addingTimeInterval(SessionStore.idleWithWorkAfter + 60)
        let text = store.describeStandup([api, web, idle], git: [
            api.id: (DiffStat(added: 40, removed: 2, files: 3), 3),
            idle.id: (DiffStat(added: 5, removed: 0, files: 1), 1),
        ], now: later)

        XCTAssertTrue(text.hasPrefix("3 agents: "), text)
        XCTAssertTrue(text.contains("doing: Edit src/orders.ts"), text)
        XCTAssertTrue(text.contains("todos 1/2 (Tests)"), text)
        XCTAssertTrue(text.contains("+40 −2 · 3 files · 3 uncommitted"), text)
        XCTAssertTrue(text.contains("tests FAIL"), text)
        XCTAssertTrue(text.contains("same files as @web (src/api.ts)"), text)
        XCTAssertTrue(text.contains("plan o: Orders"), text)
        XCTAssertTrue(text.contains("BLOCKED"), text)
        XCTAssertTrue(text.contains("idle with 1 uncommitted files"), text)
        XCTAssertFalse(text.contains("fix the docs"), "a prompt echo isn't a result")
        XCTAssertTrue(text.contains("$1.50"), text)
    }

    func testTurnSummarySkipsPromptEchoesAndChannelTags() {
        let api = agent("api")
        api.summary = "› <channel source=\"hyperterm\">"
        XCTAssertNil(SessionStore.turnSummary(api))
        api.record(.done, "Shipped the fix")
        XCTAssertEqual(SessionStore.turnSummary(api), "Shipped the fix")
        api.summary = "All green."
        XCTAssertEqual(SessionStore.turnSummary(api), "All green.")
    }

    // MARK: - Event feed

    func testStewardWarningsRepeatOnlyWhenWorseOrAfterAQuietSpell() {
        let store = SessionStore(previewSessions: [], previewLayout: .grid)
        let now = Date()
        func memory(_ gb: Double) -> Escalation {
            Escalation(sessionID: "s", label: "api", kind: .memory, footprintBytes: UInt64(gb * 1_073_741_824),
                       cpuPercent: 0, since: now, message: "using \(gb) GB")
        }
        XCTAssertTrue(store.stewardWarningIsNews(memory(3.1), now: now))
        XCTAssertFalse(store.stewardWarningIsNews(memory(3.3), now: now.addingTimeInterval(300)), "hovering at the limit")
        XCTAssertTrue(store.stewardWarningIsNews(memory(4.3), now: now.addingTimeInterval(400)), "a gigabyte worse")
        XCTAssertFalse(store.stewardWarningIsNews(memory(4.4), now: now.addingTimeInterval(500)))
        XCTAssertTrue(store.stewardWarningIsNews(memory(4.4), now: now.addingTimeInterval(500 + SessionStore.stewardQuiet)))
    }

    func testARepeatingWatchReArmsAndAFinishCarriesItsDiff() {
        let api = agent("api", state: .idle), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        store.sumiWatches[api.id] = "relay it"
        store.sumiBrain.repeatWatches[api.id] = "relay it"
        api.summary = "Done."
        api.diffStat = DiffStat(added: 3, removed: 1, files: 1)

        store.reportToSumi(api, from: .working)

        XCTAssertEqual(store.sumiWatches[api.id], "relay it", "re-armed for the next turn")
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))
        let report = sumi.pendingMessages.joined()
        XCTAssertTrue(report.contains("@api finished: Done. [+3 −1 · 1 file]"), report)
    }

    func testALongWaitIsToldOnceAndOnlyWhileUnchanged() {
        let api = agent("api", state: .needsInput("Allow Bash(make)?")), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        let since = api.stateChangedAt

        store.checkLongWait(api, reason: "Allow Bash(make)?", since: since, now: since.addingTimeInterval(SessionStore.longWaitAfter))
        store.checkLongWait(api, reason: "Allow Bash(make)?", since: since, now: since.addingTimeInterval(SessionStore.longWaitAfter * 2))
        store.checkLongWait(api, reason: "something else", since: since)

        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))
        let report = sumi.pendingMessages.joined()
        XCTAssertTrue(report.contains("@api has waited 5 min on the user: Allow Bash(make)?"), report)
        XCTAssertEqual(report.components(separatedBy: "has waited").count, 2, "once per wait")
    }

    func testNewEventLinesStayOnOneLine() {
        let lines = [
            SumiEvent(label: "web", kind: .serverCrashed(code: 1, tail: "EADDRINUSE :3000")).line,
            SumiEvent(label: "plan", kind: .plan("a done; b ready")).line,
            SumiEvent(label: "api", kind: .autoApproved("Bash(pnpm test)")).line,
        ]
        XCTAssertTrue(lines[0].contains("@web (server) crashed with exit 1: EADDRINUSE :3000"), lines[0])
        XCTAssertEqual(lines[1], "plan: a done; b ready")
        XCTAssertTrue(lines[2].contains("as the user always does"), lines[2])
        XCTAssertFalse(SumiDigest.message(lines.map { SumiEvent(label: "x", kind: .plan($0)) }).contains("\n"))
    }

    // MARK: - Learned approvals

    func testApprovalKeysAreTheWholeCommand() {
        XCTAssertEqual(ApprovalMemory.key(tool: "Bash", request: "pnpm test --filter api"), "Bash(pnpm test --filter api)")
        XCTAssertEqual(ApprovalMemory.key(tool: "Bash", request: "git   status -s"), "Bash(git status -s)", "whitespace normalized")
        XCTAssertEqual(ApprovalMemory.key(tool: "Bash", request: "make build"), "Bash(make build)")
        XCTAssertEqual(ApprovalMemory.key(tool: "Edit", request: "/repo/a.ts"), "Edit")
        // One approved script never covers another, or the same runner with more arguments.
        let test = ApprovalMemory.key(tool: "Bash", request: "npm run test")
        XCTAssertEqual(test, "Bash(npm run test)")
        for other in ["npm run deploy", "npm run test -- --update", "npm run", "make deploy", "cargo run", "go run ./x"] {
            XCTAssertNotEqual(ApprovalMemory.key(tool: "Bash", request: other), test, other)
        }
        var memory = ApprovalMemory()
        memory.learn(project: "/repo", key: test!, answer: .always)
        XCTAssertFalse(memory.allows(project: "/repo", key: ApprovalMemory.key(tool: "Bash", request: "npm run deploy")!))
        XCTAssertFalse(memory.allows(project: "/repo", key: ApprovalMemory.key(tool: "Bash", request: "npm run test:e2e")!))
    }

    func testCommandsThatCanHideWhatTheyRunHaveNoKey() {
        let rejected = [
            // Leading environment assignments.
            "CI=1 git status", "LD_PRELOAD=/tmp/x.so make test", "PATH=/tmp:$PATH npm test",
            // Programs given by path.
            "./run-tests", "/tmp/npm test", "bin/build", "~/x",
            // Chaining, pipes, redirection, substitution, background, newlines.
            "pnpm test; rm x", "pnpm test && git push", "a || b", "ls | sh", "echo `id`", "echo $(id)",
            "ls > out", "cat < in", "sleep 1 &", "make\ntest", "echo 'x'", "echo \"x\"", "ls *",
            // Interpreters, wrappers and code runners.
            "bash -c ls", "sh x", "zsh", "python3 script.py", "python -c print", "node x.js", "ruby x", "perl -e 1",
            "env ls", "xargs rm", "eval ls", "sudo ls", "npx vitest", "bunx x", "uvx ruff", "deno run x",
            "pnpm dlx create-x", "npm exec x", "yarn dlx x", "bun x y", "timeout 5 ls", "nohup make",
        ]
        for command in rejected {
            XCTAssertNil(ApprovalMemory.key(tool: "Bash", request: command), command)
        }
    }

    func testAlwaysIsRememberedPerProjectUntilDenied() {
        var memory = ApprovalMemory()
        memory.learn(project: "/repo", key: "Bash(pnpm test)", answer: .approve)
        XCTAssertFalse(memory.allows(project: "/repo", key: "Bash(pnpm test)"))
        memory.learn(project: "/repo", key: "Bash(pnpm test)", answer: .always)
        XCTAssertTrue(memory.allows(project: "/repo", key: "Bash(pnpm test)"))
        XCTAssertFalse(memory.allows(project: "/other", key: "Bash(pnpm test)"))
        memory.learn(project: "/repo", key: "Bash(pnpm test)", answer: .deny)
        XCTAssertFalse(memory.allows(project: "/repo", key: "Bash(pnpm test)"), "a later no takes it back")
        XCTAssertEqual(ApprovalMemory.precedent(memory.record(project: "/repo", key: "Bash(pnpm test)")!), "approved 2×, denied 1×")
    }

    func testTheUsersAnswersAreLearnedButSumisAndRiskyOnesAreNot() {
        let api = agent("api", state: .needsInput("Allow?"))
        let store = SessionStore(previewSessions: [api], previewLayout: .grid)
        let project = store.approvalProject(api)

        store.learnAnswer(api, approval: approval("pnpm test"), answer: .always)
        XCTAssertTrue(store.sumiBrain.approvals.allows(project: project, key: "Bash(pnpm test)"))

        store.learnAnswer(api, approval: approval("git push origin main"), answer: .always)
        XCTAssertNil(store.sumiBrain.approvals.record(project: project, key: "Bash(git push origin main)"), "risky: never learned")

        store.sumiBrain.sumiAnswering = true
        store.learnAnswer(api, approval: approval("make build"), answer: .always)
        store.sumiBrain.sumiAnswering = false
        XCTAssertNil(store.sumiBrain.approvals.record(project: project, key: "Bash(make build)"), "Sumi's own answers aren't the user's")
    }

    func testAHandledSessionIsAnsweredAsTheUserAlwaysDoesButNeverForRiskyRequests() {
        let api = agent("api", state: .needsInput("Allow?"))
        let store = SessionStore(previewSessions: [api], previewLayout: .grid)
        let project = store.approvalProject(api)
        store.sumiBrain.approvals.learn(project: project, key: "Bash(pnpm test --watch=false)", answer: .always)
        // Even if a risky request's key were ever learned, RiskyRequest still leaves it for the user.
        store.sumiBrain.approvals.learn(project: project, key: "Bash(git push origin main)", answer: .always)

        let decided = Box()
        store.approvals[api.id] = approval("pnpm test --watch=false", reply: { decided.text = $0.text })
        XCTAssertTrue(store.learnedAlways(api))
        XCTAssertEqual(store.approveAsUserAlwaysDoes(api), "Bash(pnpm test --watch=false)")
        XCTAssertTrue(decided.text?.contains("allow") == true, decided.text ?? "no reply")
        XCTAssertNil(store.approvals[api.id])
        store.approvals[api.id] = approval("pnpm test --watch=true")
        XCTAssertFalse(store.learnedAlways(api), "a different argument is a different request")

        store.approvals[api.id] = approval("git push origin main")
        XCTAssertFalse(store.learnedAlways(api))
        XCTAssertNil(store.approveAsUserAlwaysDoes(api))
        XCTAssertNotNil(store.approvals[api.id], "left for the user")
    }

    // MARK: - Memory

    func testMemoryKeepsOneCommandPerTopicDedupesAndStaysBounded() {
        var memory = SumiMemory()
        memory.remember("pnpm test", section: .project, project: "/repo", topic: "test")
        memory.remember("pnpm vitest run", section: .project, project: "/repo", topic: "test")
        memory.remember("Use server actions", section: .project, project: "/repo", topic: "convention")
        memory.remember("use server actions!", section: .project, project: "/repo", topic: "convention")
        XCTAssertEqual(memory.projects["/repo"]?.map(\.text), ["use server actions!", "pnpm vitest run"])
        XCTAssertEqual(memory.projectKey(for: "/repo/.claude/worktrees/x"), "/repo")

        for index in 0..<(SumiMemory.sectionCap + 5) { memory.remember("pref \(index)", section: .preference, project: nil, topic: nil) }
        XCTAssertEqual(memory.preferences.count, SumiMemory.sectionCap)
        XCTAssertEqual(memory.preferences.first?.text, "pref \(SumiMemory.sectionCap + 4)", "newest first; oldest dropped")
        XCTAssertEqual(memory.forget("pref 3", section: .preference, project: nil), 5, "pref 30 to 34 contain it")
    }

    func testRememberRefusesSecretsAndRecallBriefsAProject() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sumi-brain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"scripts": {"dev": "vite", "test": "vitest"}}"#.write(to: folder.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let store = SessionStore(previewSessions: [], previewLayout: .grid)

        guard case .failure = store.rememberCommand(["section": "preference", "text": "api_key = sk-abcdefghijklmnopqrstu"]) else {
            return XCTFail("a secret was stored")
        }
        _ = try store.rememberCommand(["section": "project", "project": folder.path, "topic": "stack", "text": "Vite + React"]).get()
        _ = try store.rememberCommand(["section": "preference", "text": "Prefers small PRs"]).get()

        let brief = store.projectBrief(for: folder.path)
        XCTAssertTrue(brief.contains("stack: Vite + React"), brief)
        XCTAssertTrue(brief.contains("test: npm run test"), "detected, since no test command is remembered: \(brief)")
        XCTAssertFalse(brief.contains("dev:"), "servers aren't commands to brief")
        let recalled = store.recall(project: folder.path)
        XCTAssertTrue(recalled.contains("Prefers small PRs"), recalled)
        XCTAssertTrue(recalled.contains("Vite + React"), recalled)
    }

    // MARK: - Helpers

    private final class Box: @unchecked Sendable { var text: String? }

    private func approval(_ command: String, reply: @escaping ControlServer.Reply = { _ in }) -> PendingApproval {
        PendingApproval(source: "claude", toolName: "Bash", summary: "Bash(\(command))", request: command, suggestions: nil, reply: reply)
    }

    private func task(_ id: String, deps: [String] = []) -> PlanTask {
        PlanTask(id: id, title: "Task \(id)", deps: deps)
    }

    /// A state change as the store sees it, without the app's notifications.
    private func set(_ session: TerminalSession, _ state: AgentState, from previous: AgentState, _ store: SessionStore) {
        session.apply(.processStarted, source: "test", force: state)
        store.reportToSumi(session, from: previous)
    }

    private func agent(_ label: String, sumi: Bool = false, state: AgentState = .idle) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if sumi { spec.sumi = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }
}
