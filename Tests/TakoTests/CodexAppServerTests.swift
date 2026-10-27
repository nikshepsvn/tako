import XCTest
@testable import Tako

/// Codex approvals over its app-server. Messages below were captured from a live codex-cli
/// 0.160.1 app-server with the TUI attached over `--remote` and a second client following.
@MainActor
final class CodexAppServerTests: XCTestCase {
    private let commandRequest = #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","threadId":"01a11599-e26c-7e20-96c4-dbbcdba209cb","turnId":"01a11599-e287-7d50-a5fe-ceb57ba76455","itemId":"exec-b1121499-1ddd-4e42-b58f-1b4de663c0f8","startedAtMs":1791363777788,"environmentId":"local","reason":"Do you want to allow creating x.txt in the current directory?","command":"/bin/zsh -lc 'touch x.txt'","cwd":"/tmp/work","commandActions":[{"type":"unknown","command":"touch x.txt"}],"proposedExecpolicyAmendment":["touch","x.txt"],"availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":["touch","x.txt"]}},"cancel"]}}"#

    private func approval(_ json: String) throws -> CodexAppServer.Approval {
        guard case .approval(let approval) = CodexAppServer.parse(Data(json.utf8)) else { throw XCTSkip("not an approval") }
        return approval
    }

    private func hookOutput(_ behavior: String, always: Any? = nil) -> String {
        var decision: [String: Any] = ["behavior": behavior]
        if let always { decision["updatedPermissions"] = [["type": "codexDecision", "decision": always]] }
        let data = try! JSONSerialization.data(withJSONObject: ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]])
        return String(decoding: data, as: UTF8.self)
    }

    func testCommandApprovalBecomesAHookShapedRequest() throws {
        let request = try approval(commandRequest)
        XCTAssertEqual(request.id, .number(0))
        XCTAssertEqual(request.threadID, "01a11599-e26c-7e20-96c4-dbbcdba209cb")
        XCTAssertEqual(request.kind, .command)
        XCTAssertEqual(request.command, "touch x.txt", "Codex's login shell around the command is dropped")
        let payload = request.hookPayload
        XCTAssertEqual(payload["tool_name"] as? String, "Bash")
        XCTAssertEqual((payload["tool_input"] as? [String: Any])?["command"] as? String, "touch x.txt")
        XCTAssertEqual(payload["cwd"] as? String, "/tmp/work")
        XCTAssertEqual(AgentText.describeTool(name: "Bash", input: payload["tool_input"] as? [String: Any] ?? [:], cwd: nil), "Bash: touch x.txt")
    }

    func testDecisionsMapToWhatCodexOffers() throws {
        let request = try approval(commandRequest)
        XCTAssertEqual(request.decision(hookOutput: hookOutput("allow")) as? String, "accept")
        // This request offers no "decline", so a denial cancels it.
        XCTAssertEqual(request.decision(hookOutput: hookOutput("deny")) as? String, "cancel")
        // "Always" is Codex's proposed rule for commands like it.
        let always = try XCTUnwrap(request.alwaysDecision as? [String: Any])
        XCTAssertNotNil(always["acceptWithExecpolicyAmendment"])
        let chosen = request.decision(hookOutput: hookOutput("allow", always: always)) as? [String: Any]
        XCTAssertEqual((chosen?["acceptWithExecpolicyAmendment"] as? [String: Any])?["execpolicy_amendment"] as? [String], ["touch", "x.txt"])
        // No decision leaves the request to the terminal.
        XCTAssertNil(request.decision(hookOutput: nil))
        XCTAssertNil(request.decision(hookOutput: ""))
    }

    func testFileChangeUsesItsDefaultDecisions() throws {
        let json = #"{"method":"item/fileChange/requestApproval","id":"r-7","params":{"threadId":"t-1234","turnId":"u","itemId":"call_1","startedAtMs":1,"reason":"needs write access"}}"#
        let request = try approval(json)
        XCTAssertEqual(request.id, .text("r-7"))
        XCTAssertEqual(request.kind, .fileChange)
        XCTAssertEqual(request.decision(hookOutput: hookOutput("deny")) as? String, "decline")
        XCTAssertEqual(request.alwaysDecision as? String, "acceptForSession")
        XCTAssertEqual(request.hookPayload["tool_name"] as? String, "Edit")
        var withPath = request
        withPath.paths = ["/tmp/work/a.swift"]
        XCTAssertEqual((withPath.hookPayload["tool_input"] as? [String: Any])?["file_path"] as? String, "/tmp/work/a.swift")
    }

    func testNotificationsTakoFollows() {
        guard case .resolved(let id) = CodexAppServer.parse(Data(#"{"method":"serverRequest/resolved","params":{"threadId":"t-1234","requestId":0}}"#.utf8)) else {
            return XCTFail("resolved")
        }
        XCTAssertEqual(id, .number(0))
        guard case .threadStarted(let thread) = CodexAppServer.parse(Data(#"{"method":"thread/started","params":{"thread":{"id":"01a11599-e26c-7e20","ephemeral":false,"parentThreadId":null}}}"#.utf8)) else {
            return XCTFail("thread started")
        }
        XCTAssertEqual(thread, "01a11599-e26c-7e20")
        // Codex's ephemeral helper threads and subagents aren't the conversation.
        guard case .other = CodexAppServer.parse(Data(#"{"method":"thread/started","params":{"thread":{"id":"h-1234","ephemeral":true,"parentThreadId":null}}}"#.utf8)) else {
            return XCTFail("ephemeral")
        }
        guard case .other = CodexAppServer.parse(Data(#"{"method":"thread/started","params":{"thread":{"id":"s-1234","ephemeral":false,"parentThreadId":"t-1234"}}}"#.utf8)) else {
            return XCTFail("subagent")
        }
        guard case .fileChange(let item, let paths) = CodexAppServer.parse(Data(#"{"method":"item/started","params":{"item":{"type":"fileChange","id":"call_1","changes":[{"path":"/tmp/work/a.swift","kind":{"type":"update"},"diff":""}],"status":"inProgress"},"threadId":"t-1234","turnId":"u","startedAtMs":1}}"#.utf8)) else {
            return XCTFail("file change")
        }
        XCTAssertEqual(item, "call_1")
        XCTAssertEqual(paths, ["/tmp/work/a.swift"])
        // Requests Tako doesn't map stay with the TUI.
        guard case .other = CodexAppServer.parse(Data(#"{"method":"item/tool/requestUserInput","id":3,"params":{"threadId":"t-1234","questions":[]}}"#.utf8)) else {
            return XCTFail("question")
        }
    }

    func testUnwrapShell() {
        XCTAssertEqual(CodexAppServer.unwrapShell("/bin/zsh -lc 'echo '\\''hi'\\'''"), "echo 'hi'")
        XCTAssertEqual(CodexAppServer.unwrapShell("/bin/bash -lc 'ls -la'"), "ls -la")
        XCTAssertEqual(CodexAppServer.unwrapShell("git status"), "git status")
    }

    func testAppServerApprovalIsHeldAndAnsweredLikeAHook() throws {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .codex, cwd: "/tmp/work"), resume: false)
        addTeardownBlock { @MainActor in session.terminate() }
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        let request = try approval(commandRequest)
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: request.hookPayload), as: UTF8.self)
        final class Box: @unchecked Sendable { var text: String?; var calls = 0 }
        let box = Box()
        store.registerApproval(for: session, source: CodexAppServer.source, payload: payload) { box.text = $0.text; box.calls += 1 }
        XCTAssertEqual(session.state, .needsInput("Bash: touch x.txt"))
        XCTAssertEqual(store.approvals[session.id]?.request, "touch x.txt", "Sumi's guard sees the whole command")
        _ = store.answer(session, .always)
        XCTAssertEqual(box.calls, 1)
        XCTAssertNotNil((request.decision(hookOutput: box.text) as? [String: Any])?["acceptWithExecpolicyAmendment"],
                        "Always reaches Codex as its own rule: \(box.text ?? "")")
    }

    func testCodexHookStepsAsideForCommandsWhileTakoFollowsTheServer() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .codex, cwd: "/tmp"), resume: false)
        addTeardownBlock { @MainActor in session.terminate() }
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        let server = CodexAppServer(url: URL(string: "ws://127.0.0.1:9")!, token: "t")
        addTeardownBlock { @MainActor in server.close() }
        store.codexServers[session.id] = server
        let bash = #"{"session_id":"01a110ad-7491-7af1-b340-da8605e1c16e","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"touch x"}}"#
        final class Box: @unchecked Sendable { var responses: [ControlResponse] = [] }
        let box = Box()
        // Not following a thread yet: the hook is held as before.
        store.registerApproval(for: session, source: "codex", payload: bash) { box.responses.append($0) }
        XCTAssertTrue(session.hasHookApproval)
        store.dropApproval(for: session)
        box.responses.removeAll()
        // Following a brand-new thread is refused until its rollout exists, then retried when it
        // changes status (captured from 0.160.1).
        let thread = "01a110ad-7491-7af1-b340-da8605e1c16e"
        server.follow(thread)
        server.handle(Data(#"{"error":{"code":-32600,"message":"no rollout found for thread id 01a110ad-7491-7af1-b340-da8605e1c16e"},"id":1}"#.utf8))
        XCTAssertFalse(server.follows(thread))
        store.registerApproval(for: session, source: "codex", payload: bash) { box.responses.append($0) }
        XCTAssertTrue(session.hasHookApproval, "not followed yet: the hook still holds")
        store.dropApproval(for: session)
        box.responses.removeAll()
        server.handle(Data(#"{"method":"thread/status/changed","params":{"threadId":"01a110ad-7491-7af1-b340-da8605e1c16e","status":{"type":"active","activeFlags":[]}}}"#.utf8))
        server.handle(Data(#"{"id":2,"result":{"thread":{"id":"01a110ad-7491-7af1-b340-da8605e1c16e"}}}"#.utf8))
        XCTAssertTrue(server.follows(thread))
        XCTAssertFalse(server.follows("another-thread"))
        store.registerApproval(for: session, source: "codex", payload: bash) { box.responses.append($0) }
        XCTAssertEqual(box.responses.count, 1)
        XCTAssertNil(box.responses.first?.text, "released with no decision, so Codex asks its app-server clients")
        XCTAssertFalse(session.hasHookApproval)
        // MCP tool calls aren't mapped over the app-server: their hook still holds.
        let mcp = #"{"session_id":"01a110ad-7491-7af1-b340-da8605e1c16e","hook_event_name":"PermissionRequest","tool_name":"mcp__tako__list_sessions","tool_input":{}}"#
        store.registerApproval(for: session, source: "codex", payload: mcp) { box.responses.append($0) }
        XCTAssertTrue(session.hasHookApproval)
    }

    func testServerReportDoesNotCountAsAHook() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .codex, cwd: "/tmp"), resume: false)
        addTeardownBlock { @MainActor in session.terminate() }
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        // Missing token file: nothing attaches, and the trust and sign-in screens are still watched.
        store.applyHook(source: CodexAppServer.source, session: session,
                        json: ["url": "ws://127.0.0.1:5555", "token_file": "/nonexistent/token"], sentAt: nil)
        XCTAssertNil(store.codexServers[session.id])
        XCTAssertEqual(session.lastHookAt, .distantPast)
        // Only a loopback websocket is accepted.
        let token = FileManager.default.temporaryDirectory.appendingPathComponent("tako-codex-token-\(UUID().uuidString)")
        try? "abc123".write(to: token, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: token) }
        store.applyHook(source: CodexAppServer.source, session: session, json: ["url": "ws://example.com:5555", "token_file": token.path], sentAt: nil)
        XCTAssertNil(store.codexServers[session.id])
    }

    func testWrapperRunsCodexBehindItsAppServerWithTheOldPathAsFallback() {
        let wrapper = CodexAdapter.wrapperScript(ht: "/Users/me/.tako/bin/ht")
        XCTAssertTrue(wrapper.contains("exec codex app-server --listen ws://127.0.0.1:0 \\\n    --ws-auth capability-token --ws-token-file \"$RUN/token\" \\\n  -c 'hooks.SessionStart="), wrapper)
        XCTAssertTrue(wrapper.contains("codex --remote \"$URL\" --remote-auth-token-env TAKO_CODEX_TOKEN \\\n  -c 'tui.notification_method=\"osc9\"'"), wrapper)
        XCTAssertTrue(wrapper.contains("\"$HT_DIR/bin/ht\" hook codex-app-server"), wrapper)
        XCTAssertTrue(wrapper.contains("exec codex --no-daemon \\\n  -c 'hooks.SessionStart="), wrapper)
        // Hooks, notify and MCP servers go to the process running the agent, both ways.
        XCTAssertEqual(wrapper.components(separatedBy: "hooks.PermissionRequest=").count - 1, 2)
        XCTAssertEqual(wrapper.components(separatedBy: "mcp_servers.tako.command=").count - 1, 2)
        XCTAssertEqual(wrapper.components(separatedBy: "tui.notification_method").count - 1, 2)
    }
}
