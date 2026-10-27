import XCTest
@testable import Hyperterm

/// The worker agents' coordination tools: wait_for, agent_changes, team_board, server_logs and
/// notify_user. Stores are previews, so nothing is written to the app's own support folder.
@MainActor
final class AgentToolsTests: XCTestCase {
    // MARK: - MCP definitions

    func testDefinitionsMapToTheirRequests() throws {
        let names = agentToolDefinitions.compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["wait_for", "agent_changes", "team_board", "server_logs", "notify_user"])
        for name in names { XCTAssertNotNil(agentToolRequest(name, [:]), name) }
        XCTAssertNil(agentToolRequest("list_terminals", [:]), "other tools stay with the server's own switch")

        let wait = try XCTUnwrap(agentToolRequest("wait_for", ["terminal": "@api", "pattern": "ready", "timeout": 30]))
        XCTAssertEqual(wait.cmd, .wait)
        XCTAssertEqual(wait.target, "@api")
        XCTAssertEqual(wait.pattern, "ready")
        XCTAssertEqual(agentToolSocketTimeout(wait), 45, "the socket outlasts the wait")
        XCTAssertTrue(agentToolBlocks("wait_for"))
        XCTAssertFalse(agentToolBlocks("team_board"))

        let board = try XCTUnwrap(agentToolRequest("team_board", ["action": "claim", "paths": "src/a.ts", "minutes": 30, "since": 4]))
        XCTAssertEqual(board.text, "claim")
        XCTAssertEqual(board.paths, ["src/a.ts"], "a lone path is taken as a list")
        XCTAssertEqual(board.timeout, 30)
        XCTAssertEqual(board.since, "4")

        let logs = try XCTUnwrap(agentToolRequest("server_logs", ["terminal": "web", "grep": "GET", "errors": true, "since": "abc", "lines": 20]))
        XCTAssertEqual([logs.pattern, logs.since], ["GET", "abc"])
        XCTAssertEqual(logs.flag, true)
        XCTAssertEqual(logs.lines, 20)
        XCTAssertNil(agentToolSocketTimeout(logs))
    }

    /// Every agent pays for these definitions on every turn.
    func testDefinitionsStayWithinTheirTokenBudget() throws {
        let bytes = try JSONSerialization.data(withJSONObject: agentToolDefinitions).count
        XCTAssertLessThan(bytes, 2900, "about 700 tokens for all five tools")
    }

    // MARK: - wait_for

    func testDoneAnswersAtOnceForAnAgentAlreadyAtRest() {
        let (store, me, api) = fixture()
        let replies = Replies()
        handler(store, me).handle(wait("api"), reply: replies.add)
        XCTAssertEqual(replies.texts.count, 1)
        XCTAssertTrue(replies.texts[0].hasPrefix("@api is idle"), replies.texts[0])
        XCTAssertTrue(store.agentTools.waits.isEmpty)
        _ = api
    }

    func testDoneWaitsForTheTurnAndItsSubagents() {
        let (store, me, api) = fixture(apiState: .working)
        let replies = Replies()
        handler(store, me).handle(wait("api"), reply: replies.add)
        XCTAssertTrue(replies.texts.isEmpty)

        api.runningSubagents = ["a1": Subagent(type: "Explore", startedAt: Date())]
        api.summary = "Added /orders"
        api.apply(.processStarted, source: "test", force: .idle)
        XCTAssertTrue(replies.texts.isEmpty, "a subagent still runs")

        store.applyHook(source: "claude", session: api, json: ["hook_event_name": "SubagentStop", "agent_id": "a1"], sentAt: nil)
        XCTAssertEqual(replies.texts, ["@api is idle · Added /orders"])
        XCTAssertTrue(store.agentTools.waits.isEmpty)
    }

    func testDoneAlsoEndsWhenTheAgentBlocksOnTheUser() {
        let (store, me, api) = fixture(apiState: .working)
        let replies = Replies()
        handler(store, me).handle(wait("api"), reply: replies.add)
        api.apply(.processStarted, source: "test", force: .needsInput("Allow rm?"))
        XCTAssertEqual(replies.texts, ["@api is needs-input (Allow rm?)"])
    }

    func testExitedGoalIgnoresIdle() {
        let (store, me, api) = fixture(apiState: .working)
        let replies = Replies()
        var request = wait("api")
        request.text = "exited"
        handler(store, me).handle(request, reply: replies.add)
        api.apply(.processStarted, source: "test", force: .idle)
        XCTAssertTrue(replies.texts.isEmpty)
        api.apply(.processStarted, source: "test", force: .exited(1))
        XCTAssertEqual(replies.texts, ["@api is exited (exit 1)"])
    }

    func testClosingTheTargetEndsItsWaits() {
        let (store, me, api) = fixture(apiState: .working)
        let replies = Replies()
        handler(store, me).handle(wait("api"), reply: replies.add)
        store.agentToolsSessionClosed(api)
        XCTAssertEqual(replies.texts, ["@api was closed"])
    }

    func testAWaitTimesOutWithTheCurrentState() {
        let (store, me, api) = fixture(apiState: .working)
        let done = expectation(description: "timed out")
        let replies = Replies()
        store.startWait(on: api, caller: me.id, goal: .done, regex: nil, timeout: 0.05) { response in
            replies.add(response)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(replies.texts, ["timed out after 0 s; @api is working"])
        XCTAssertTrue(store.agentTools.waits.isEmpty)
    }

    func testPatternWaitsMatchOnlyLinesPrintedAfterTheCall() {
        let (store, me, api) = fixture()
        var output = "booting\nready on :3000"
        store.agentTools.outputReader = { _, _ in output }
        var request = wait("api")
        request.pattern = "ready|error"
        let replies = Replies()
        handler(store, me).handle(request, reply: replies.add)
        XCTAssertNotNil(store.agentTools.outputPoll, "output waits poll while they last")

        store.pollOutputWaits()
        XCTAssertTrue(replies.texts.isEmpty, "the ready line was there before the wait")
        output += "\nGET / 200\nTypeError: boom\n\n"
        store.pollOutputWaits()
        XCTAssertEqual(replies.texts, ["@api printed: TypeError: boom"])
        XCTAssertNil(store.agentTools.outputPoll, "the poll stops with the last output wait")
    }

    func testLogsFilterAndResumeFromTheCursor() throws {
        let (store, me, _) = fixture()
        var output = "GET /a 200\nGET /b 500\nError: db down\n    at connect (db.js:9)"
        store.agentTools.outputReader = { _, _ in output }
        var request = ControlRequest(cmd: .logs)
        request.target = "api"
        request.flag = true
        let first = try XCTUnwrap(response(store, me, request).text)
        XCTAssertTrue(first.hasPrefix("Error: db down\n    at connect (db.js:9)\n── @api is idle · cursor "), first)
        let cursor = try XCTUnwrap(first.components(separatedBy: "cursor ").last?.components(separatedBy: " ").first)

        output += "\nGET /c 200\nGET /d 200"
        request.flag = nil
        request.since = cursor
        request.pattern = "GET"
        let next = try XCTUnwrap(response(store, me, request).text)
        XCTAssertTrue(next.hasPrefix("GET /c 200\nGET /d 200\n──"), next)
    }

    func testWaitRulesFollowRead() {
        let shell = TerminalSession(spec: LaunchSpec(label: "sh", kind: .shell, cwd: "/workspace/atlas"), resume: false)
        let (store, me, _) = fixture(extra: [shell])
        let replies = Replies()
        handler(store, me).handle(wait("me"), reply: replies.add)
        handler(store, me).handle(wait("sh"), reply: replies.add)
        var bad = wait("api")
        bad.text = "soon"
        handler(store, me).handle(bad, reply: replies.add)
        XCTAssertEqual(replies.errors, [
            "that's you; wait on another terminal",
            "@sh is a shell; agents can't read shells",
            "until must be done, needs-input or exited (or pass a pattern)",
        ])
    }

    // MARK: - team_board

    func testClaimsRefuseOverlapsAndAskTheHolderOnce() {
        let (store, me, api) = fixture(apiState: .working)
        XCTAssertEqual(board(store, api, "claim", paths: ["src/auth/**"]).text, "claimed for 120 min: src/auth/**")

        let refused = board(store, me, "claim", paths: ["src/auth/login.ts", "README.md"])
        XCTAssertEqual(refused.text, """
        claimed for 120 min: README.md
        not claimed: src/auth/login.ts is held by @api (src/auth/**)
        Each holder was told you want it. Work elsewhere for now, or send_message them to agree who goes first.
        """)
        XCTAssertEqual(api.pendingMessages.count, 1, "queued for the end of its turn")
        XCTAssertTrue(api.pendingMessages[0].hasPrefix("Message from @me (via Tako's team board)"), "framed as an agent's message")
        _ = board(store, me, "claim", paths: ["src/auth/login.ts"])
        XCTAssertEqual(api.pendingMessages.count, 1, "a retry doesn't ask again")

        XCTAssertEqual(handler(store, me).listedInfo(api).claims, ["src/auth/**"], "list_terminals shows claims")
        XCTAssertEqual(board(store, api, "release").text, "released src/auth/**")
        XCTAssertEqual(board(store, me, "claim", paths: ["src/auth/login.ts"]).text, "claimed for 120 min: src/auth/login.ts")
    }

    func testClaimsEndWhenTheirAgentExits() {
        let (store, me, _) = fixture()
        _ = board(store, me, "claim", paths: ["/workspace/atlas/Sources/App.swift"])
        XCTAssertEqual(store.claims(of: me), ["Sources/App.swift"], "absolute paths become relative to the workspace")
        me.apply(.processStarted, source: "test", force: .exited(0))
        XCTAssertNil(store.claims(of: me))
    }

    func testClaimPathsMustStayInTheWorkspace() {
        let (store, me, _) = fixture()
        XCTAssertEqual(board(store, me, "claim", paths: ["../other/x"]).error, "../other/x isn't a path inside your workspace")
        XCTAssertEqual(board(store, me, "claim", paths: ["/etc/hosts"]).error, "/etc/hosts isn't a path inside your workspace")
        XCTAssertEqual(board(store, me, "claim").error, "pass the paths to claim")
    }

    func testNotesAreSignedAndReadSinceACount() {
        let (store, me, api) = fixture()
        XCTAssertEqual(board(store, me, "note", text: "POST /orders takes {sku, qty}").text, "posted note 1 to the atlas board")
        _ = board(store, api, "note", text: "orders table has a qty column now")
        let all = board(store, api, "read").text ?? ""
        XCTAssertTrue(all.contains("1. @me, "), all)
        XCTAssertTrue(all.contains(": POST /orders takes {sku, qty}"), all)
        XCTAssertTrue(all.hasSuffix("No files claimed."), all)

        var since = ControlRequest(cmd: .board)
        since.text = "read"
        since.since = "1"
        let newer = response(store, me, since).text ?? ""
        XCTAssertFalse(newer.contains("POST /orders"), newer)
        XCTAssertTrue(newer.contains("2. @api"), newer)
        XCTAssertEqual(board(store, me, "note").error, "a note needs text")
    }

    func testOverlapRules() {
        XCTAssertTrue(ClaimPath.overlaps("src/auth", "src/auth/login.ts"), "a folder holds its files")
        XCTAssertFalse(ClaimPath.overlaps("src/auth", "src/authz.ts"))
        XCTAssertTrue(ClaimPath.overlaps("src/*.ts", "src/a/b.ts"), "* crosses folders: claims err on overlap")
        XCTAssertTrue(ClaimPath.overlaps("src", "src/**/*.ts"))
        XCTAssertFalse(ClaimPath.overlaps("docs/**", "src/a.ts"))
        XCTAssertTrue(ClaimPath.overlaps("src/**", "src/api/*.ts"))
        XCTAssertEqual(ClaimPath.normalize("./src/auth/", root: nil), "src/auth")
        XCTAssertNil(ClaimPath.normalize("/workspace/atlas", root: "/workspace/atlas"))
        XCTAssertNil(ClaimPath.normalize("a.ts\nrm -rf ~", root: nil), "a path can't carry a second line into a message")
    }

    // MARK: - server_logs

    func testCursorReturnsOnlyNewerLines() {
        let first = ["boot", "", "GET /a 200", "GET /b 200"]
        let cursor = LogTail.cursor(first)
        XCTAssertEqual(LogTail.after(cursor, in: first + ["GET /c 500", ""]), ["GET /c 500", ""])
        XCTAssertEqual(LogTail.after(cursor, in: ["GET /c 500"]), nil, "scrolled away")
        XCTAssertEqual(LogTail.after("0", in: ["x"]), ["x"], "no output yet means everything is new")
        XCTAssertEqual(LogTail.lines("a\nb\n\n  \n"), ["a", "b"])
    }

    func testErrorsKeepTheirStackTraces() {
        let lines = ["ready on :3000", "TypeError: x is undefined", "    at f (a.js:1)", "    at g (b.js:2)",
                     "GET / 200", "    indented and unrelated", "Build failed", "npm ERR! code 1", "0 errors"]
        XCTAssertEqual(LogTail.errors(lines), ["TypeError: x is undefined", "    at f (a.js:1)", "    at g (b.js:2)", "Build failed",
                                               "npm ERR! code 1"])
        XCTAssertNotNil(LogTail.regex("GET /api("), "a broken regex falls back to the literal text")
    }

    func testLogsFollowReadsRules() {
        let shell = TerminalSession(spec: LaunchSpec(label: "sh", kind: .shell, cwd: "/workspace/atlas"), resume: false)
        let (store, me, _) = fixture(extra: [shell])
        var request = ControlRequest(cmd: .logs)
        request.target = "sh"
        XCTAssertEqual(response(store, me, request).error, "@sh is a shell; agents can't read shells")
        request.target = "api"
        request.flag = true
        let text = response(store, me, request).text ?? ""
        XCTAssertTrue(text.hasSuffix("(pass as since for newer lines) ──"), text)
    }

    // MARK: - notify_user

    func testNotifyIsRateLimitedPerAgent() {
        let (store, me, _) = fixture()
        var request = ControlRequest(cmd: .notify)
        request.text = "PR is ready\nfor review"
        XCTAssertEqual(response(store, me, request).text, "the user was notified")
        XCTAssertEqual(me.timeline.last?.text, "Notified the user: PR is ready for review")
        XCTAssertTrue(response(store, me, request).error?.hasPrefix("you notified the user") == true)
        request.text = " "
        store.agentTools.lastNotified = [:]
        XCTAssertEqual(response(store, me, request).error, "say what the user should know")
    }

    // MARK: - agent_changes

    func testChangesReportCommitsFilesAndPatch() throws {
        let repo = NSTemporaryDirectory() + "agent-changes-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: repo) }
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertNotNil(Git.run(["init", "-q", "-b", "main"], at: repo))
        try "one\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        commit(repo, "first")
        XCTAssertNotNil(Git.run(["checkout", "-q", "-b", "tako/api"], at: repo))
        try "one\ntwo\n".write(toFile: repo + "/a.txt", atomically: true, encoding: .utf8)
        commit(repo, "add two")
        try "new\n".write(toFile: repo + "/b.txt", atomically: true, encoding: .utf8)

        let report = AgentChanges.report(at: repo, base: "main", uncommitted: false, patch: true, paths: [])
        XCTAssertTrue(report.contains("branch tako/api"), report)
        XCTAssertTrue(report.contains("Commits since main:"), report)
        XCTAssertTrue(report.contains(" add two"), report)
        XCTAssertTrue(report.contains("Changes since main, uncommitted included: 2 files, +2 −0"), report)
        XCTAssertTrue(report.contains("+two"), report)

        let uncommitted = AgentChanges.report(at: repo, base: "main", uncommitted: true, patch: false, paths: ["a.txt"])
        XCTAssertTrue(uncommitted.hasSuffix("Uncommitted changes: none in a.txt."), uncommitted)
        XCTAssertTrue(AgentChanges.report(at: repo + "/nope", base: nil, uncommitted: false, patch: false, paths: [])
            .hasSuffix("isn't a Git repository with commits, so there are no changes to show."))
    }

    func testChangesOfANonAgentAreRefused() {
        let server = TerminalSession(spec: LaunchSpec(label: "web", kind: .server, cwd: "/workspace/atlas"), resume: false)
        let (store, me, _) = fixture(extra: [server])
        var request = ControlRequest(cmd: .changes)
        request.target = "web"
        let replies = Replies()
        handler(store, me).handle(request, reply: replies.add)
        XCTAssertEqual(replies.errors, ["@web is a server, not an agent with a workspace"])
    }

    // MARK: - Helpers

    private func fixture(apiState: AgentState = .idle, extra: [TerminalSession] = []) -> (SessionStore, TerminalSession, TerminalSession) {
        let me = agent("me"), api = agent("api", state: apiState)
        let store = SessionStore(previewSessions: [me, api] + extra, previewLayout: .grid)
        me.store = store
        api.store = store
        return (store, me, api)
    }

    private func agent(_ label: String, state: AgentState = .idle) -> TerminalSession {
        let session = TerminalSession(spec: LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas"), resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }

    private func handler(_ store: SessionStore, _ caller: TerminalSession) -> ControlHandler {
        ControlHandler(store: store, caller: .session(caller.id.uuidString))
    }

    private func wait(_ target: String) -> ControlRequest {
        var request = ControlRequest(cmd: .wait)
        request.target = target
        return request
    }

    private func board(_ store: SessionStore, _ caller: TerminalSession, _ action: String,
                       paths: [String]? = nil, text: String? = nil) -> ControlResponse {
        var request = ControlRequest(cmd: .board)
        request.text = action
        request.paths = paths
        request.label = text
        return response(store, caller, request)
    }

    private func response(_ store: SessionStore, _ caller: TerminalSession, _ request: ControlRequest) -> ControlResponse {
        let replies = Replies()
        handler(store, caller).handle(request, reply: replies.add)
        return replies.all.first ?? .failure("no reply")
    }

    private func commit(_ repo: String, _ message: String) {
        XCTAssertNotNil(Git.run(["add", "-A"], at: repo))
        XCTAssertNotNil(Git.run(["commit", "-q", "-m", message], at: repo, environment: Git.identity))
    }
}

/// Replies a handler sent, in order.
private final class Replies: @unchecked Sendable {
    private(set) var all: [ControlResponse] = []
    var texts: [String] { all.compactMap(\.text) }
    var errors: [String] { all.compactMap(\.error) }

    func add(_ response: ControlResponse) { all.append(response) }
}
