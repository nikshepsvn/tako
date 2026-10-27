import XCTest
@testable import Tako

/// Status detection fixes: held approvals, per-account rate limits, the Claude registry, agent
/// liveness, and waking while the CLI is still quitting. Stores are previews; nothing is persisted.
@MainActor
final class ReleaseFixesStatusTests: XCTestCase {
    // MARK: - Held approvals and parallel tools

    func testAParallelReadFinishingKeepsTheHeldBashApproval() {
        let (store, api) = fixture()
        var released = false
        let bash: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "pnpm prisma migrate dev"]]
        store.registerApproval(for: api, source: "claude", payload: json(bash)) { _ in released = true }
        XCTAssertTrue(api.hasHookApproval)
        XCTAssertTrue(api.state.needsAttention)

        store.applyHook(source: "claude", session: api, json: ["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_input": ["file_path": "/tmp/a.swift"]], sentAt: nil)
        store.applyHook(source: "claude", session: api, json: ["hook_event_name": "PostToolUse", "tool_name": "Read", "tool_input": ["file_path": "/tmp/a.swift"]], sentAt: nil)
        XCTAssertTrue(api.hasHookApproval, "the Read ran alongside; Bash is still at its dialog")
        XCTAssertTrue(api.state.needsAttention)
        XCTAssertEqual(api.pendingRequest.map { $0.contains("prisma") }, true)
        XCTAssertFalse(released)

        var done = bash
        done["hook_event_name"] = "PostToolUse"
        store.applyHook(source: "claude", session: api, json: done, sentAt: nil)
        XCTAssertFalse(api.hasHookApproval, "the held Bash itself ran: answered in the terminal")
        XCTAssertEqual(api.state, .working)
        XCTAssertTrue(released, "the held hook is released")
    }

    func testStopStillReleasesAHeldApproval() {
        let (store, api) = fixture()
        store.registerApproval(for: api, source: "claude", payload: json(["tool_name": "Bash", "tool_input": ["command": "make"]])) { _ in }
        store.applyHook(source: "claude", session: api, json: ["hook_event_name": "Stop"], sentAt: nil)
        XCTAssertFalse(api.hasHookApproval)
        XCTAssertEqual(api.state, .idle)
    }

    func testHeldToolCallMatchesByIdElseByNameAndInput() {
        let held = HeldToolCall(json: ["tool_name": "Bash", "tool_use_id": "toolu_1", "tool_input": ["command": "make"]])
        XCTAssertTrue(held.matches(["tool_name": "Bash", "tool_use_id": "toolu_1", "tool_input": ["command": "other"]]))
        XCTAssertFalse(held.matches(["tool_name": "Bash", "tool_use_id": "toolu_2", "tool_input": ["command": "make"]]))
        XCTAssertTrue(held.matches(["tool_name": "Bash", "tool_input": ["command": "make"]]))
        XCTAssertFalse(held.matches(["tool_name": "Bash", "tool_input": ["command": "make test"]]))
        XCTAssertFalse(held.matches(["tool_name": "Read", "tool_input": ["command": "make"]]))
        XCTAssertTrue(held.matches([:]), "a payload naming no tool can't be told apart")
        XCTAssertTrue(held.matches(["tool_name": "Bash", "tool_input": ["command": "make", "timeout": 60]]), "extra keys are fine")
        XCTAssertFalse(held.matches(["tool_name": "Bash", "tool_input": [:]]), "a held key missing")
    }

    func testAnsweringAHeldQuestionReleasesItThoughItsInputGainedAnswers() {
        let (store, api) = fixture()
        var released = false
        let questions: [[String: Any]] = [["question": "Which database?", "header": "DB", "multiSelect": false,
                                           "options": [["label": "Postgres", "description": "SQL"], ["label": "Mongo", "description": "Docs"]]]]
        let ask: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "AskUserQuestion", "tool_input": ["questions": questions]]
        store.registerApproval(for: api, source: "claude", payload: json(ask)) { _ in released = true }
        XCTAssertTrue(api.hasHookApproval)

        store.applyHook(source: "claude", session: api, json: [
            "hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion",
            "tool_input": ["questions": questions, "answers": ["Which database?": "Postgres"], "annotations": [:]],
        ], sentAt: nil)
        XCTAssertFalse(api.hasHookApproval, "the question was answered in the terminal")
        XCTAssertNil(api.pendingQuestion)
        XCTAssertEqual(api.state, .working)
        XCTAssertTrue(released)
    }

    func testOnlyReadOnlyToolsRunAlongsideAHeldBash() {
        let (store, api) = fixture()
        var released = false
        let bash: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": "rm -rf build"]]
        store.registerApproval(for: api, source: "claude", payload: json(bash)) { _ in released = true }

        store.applyHook(source: "claude", session: api, json: ["hook_event_name": "PostToolUse", "tool_name": "Read", "tool_input": ["file_path": "/tmp/a.swift"]], sentAt: nil)
        XCTAssertTrue(api.hasHookApproval, "a Read runs in parallel")
        XCTAssertTrue(api.state.needsAttention)

        // Denied in the terminal; Claude carries on with an edit.
        store.applyHook(source: "claude", session: api, json: ["hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": ["file_path": "/tmp/a.swift"]], sentAt: nil)
        XCTAssertFalse(api.hasHookApproval, "an Edit from the same agent means the Bash was settled")
        XCTAssertFalse(api.state.needsAttention)
        XCTAssertTrue(released)
    }

    func testAnotherAgentsToolKeepsTheHeldApproval() {
        let (store, api) = fixture()
        let bash: [String: Any] = ["hook_event_name": "PermissionRequest", "tool_name": "Bash", "agent_id": "agent-a", "tool_input": ["command": "make deploy"]]
        store.registerApproval(for: api, source: "claude", payload: json(bash)) { _ in }

        store.applyHook(source: "claude", session: api, json: [
            "hook_event_name": "PostToolUse", "tool_name": "Edit", "agent_id": "agent-b", "tool_input": ["file_path": "/tmp/a.swift"],
        ], sentAt: nil)
        XCTAssertTrue(api.hasHookApproval, "a different subagent's edit says nothing about agent-a's dialog")
        XCTAssertTrue(api.state.needsAttention)
        XCTAssertEqual(api.pendingRequest.map { $0.contains("deploy") }, true)
    }

    // MARK: - Rate limits per account

    func testRateLimitResetComesFromTheSessionsAccount() {
        var spec = LaunchSpec(label: "api", kind: .claude, cwd: "/tmp")
        spec.account = "work"
        let api = track(TerminalSession(spec: spec, resume: false))
        let other = track(TerminalSession(spec: LaunchSpec(label: "web", kind: .claude, cwd: "/tmp"), resume: false))
        let store = SessionStore(previewSessions: [api, other], previewLayout: .grid)
        let mine = Date().addingTimeInterval(3600), global = Date().addingTimeInterval(7200)
        store.accountLimits["claude/work"] = RateLimits(fiveHourPercent: 100, fiveHourResets: mine)
        store.rateLimits = RateLimits(fiveHourPercent: 100, fiveHourResets: global)

        for session in [api, other] {
            store.applyHook(source: "claude", session: session, json: ["hook_event_name": "StopFailure", "error": "rate_limit"], sentAt: nil)
        }
        XCTAssertEqual(store.rateLimitReset(for: api), mine)
        XCTAssertEqual(store.rateLimitReset(for: other), global, "no reading for its account yet: the last one")
    }

    // MARK: - Claude registry

    func testRegistryBusyOlderThanTheLastHookIsStale() {
        let now = Date()
        let stop = now.addingTimeInterval(-10)
        XCTAssertTrue(registryBusyIsStale(writtenAt: stop.addingTimeInterval(-1), lastHookAt: stop, now: now))
        XCTAssertFalse(registryBusyIsStale(writtenAt: stop.addingTimeInterval(5), lastHookAt: stop, now: now), "written after: real activity")
        XCTAssertTrue(registryBusyIsStale(writtenAt: now.addingTimeInterval(-0.5), lastHookAt: now.addingTimeInterval(-1), now: now),
                      "within a few seconds of the Stop")
        XCTAssertFalse(registryBusyIsStale(writtenAt: nil, lastHookAt: .distantPast, now: now), "no hooks: the registry is all there is")
    }

    // MARK: - Agent liveness

    func testAnNpmClaudeCountsAsTheAgentCLI() {
        typealias Entry = ProcessInspector.ProcessEntry
        let gone: pid_t = 0x7FFF_FFF0
        func entry(_ name: String) -> Entry { Entry(pid: gone, ppid: 1, name: name, startSeconds: 0, start: 0) }

        let npm = ProcessInspector.agentCLIs(entry: entry("node"), argv: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"])
        XCTAssertEqual(npm, ["claude"])
        XCTAssertEqual(ProcessInspector.agentCLIs(entry: entry("2.1.289"), argv: ["claude", "--resume"]), ["claude"])
        XCTAssertEqual(ProcessInspector.agentCLIs(entry: entry("codex"), argv: nil), ["codex"])
        XCTAssertEqual(ProcessInspector.agentCLIs(entry: entry("node"), argv: ["node", "/tmp/server.js"]), [])
        XCTAssertEqual(ProcessInspector.agentCLIs(entry: entry("git"), argv: ["git", "status"]), [])
    }

    // MARK: - Waking while the CLI quits

    func testWakingWhileTheCLIIsQuittingHoldsTheResumeUntilItHasGone() {
        let session = agent()
        session.fallAsleep()
        session.wakeUp()
        XCTAssertTrue(session.resumeAwaitsExit, "a key right after /exit: the CLI may still be running")
        session.cliExitSeen()
        XCTAssertFalse(session.resumeAwaitsExit)
    }

    func testACLIThatNeverQuitStaysAwakeWithoutTheResume() {
        let session = agent()
        session.fallAsleep()
        session.wakeUp()
        session.cliStayedRunning()
        XCTAssertFalse(session.resumeAwaitsExit)
        XCTAssertFalse(session.isWaking)
        XCTAssertEqual(session.state, .idle)
    }

    func testAnAgentWhoseCLIQuitWakesAtOnce() {
        let session = agent()
        session.fallAsleep()
        session.cliExitSeen()
        session.wakeUp()
        XCTAssertFalse(session.resumeAwaitsExit)

        var spec = LaunchSpec(label: "restored", kind: .claude, cwd: "/tmp")
        spec.asleep = true
        let restored = track(TerminalSession(spec: spec, resume: true))
        restored.wakeUp()
        XCTAssertFalse(restored.resumeAwaitsExit, "restored asleep: no CLI ran")
    }

    // MARK: - Fixtures

    private func fixture() -> (SessionStore, TerminalSession) {
        let api = agent()
        let store = SessionStore(previewSessions: [api], previewLayout: .focus)
        return (store, api)
    }

    private func agent() -> TerminalSession {
        let session = track(TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/tmp"), resume: false))
        session.summary = "Fixed the login bug"
        session.apply(.processStarted, source: "test", force: .working)
        return session
    }

    private func json(_ object: [String: Any]) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), as: UTF8.self)
    }

    /// Ends the session after the test, before its launch command would be typed.
    private func track(_ session: TerminalSession) -> TerminalSession {
        addTeardownBlock { @MainActor in session.terminate() }
        return session
    }
}
