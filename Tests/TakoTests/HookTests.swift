import XCTest
@testable import Tako

/// Claude hooks posted to Tako's loopback listener. Nothing here writes to disk.
@MainActor
final class HookTests: XCTestCase {
    private func hooks(port: UInt16?) throws -> [String: [[String: Any]]] {
        let json = try JSONSerialization.jsonObject(with: Data(ClaudeAdapter.settings(hookPort: port).utf8)) as? [String: Any]
        let hooks = try XCTUnwrap(json?["hooks"] as? [String: [[String: Any]]])
        return hooks.mapValues { groups in groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] } }
    }

    func testHooksPostToTheListenerExceptSessionStartAndPermission() throws {
        let hooks = try hooks(port: 54321)
        for event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd", "SubagentStart"] {
            let hook = try XCTUnwrap(hooks[event]?.first, event)
            XCTAssertEqual(hook["type"] as? String, "http", event)
            XCTAssertEqual(hook["url"] as? String, "http://127.0.0.1:54321/hook/claude")
            let headers = hook["headers"] as? [String: String]
            XCTAssertEqual(headers?["X-HT-Session"], "$HT_SESSION_ID")
            XCTAssertEqual(headers?["Authorization"], "Bearer $HT_HOOK_TOKEN")
            XCTAssertEqual(Set(hook["allowedEnvVars"] as? [String] ?? []), ["HT_SESSION_ID", "HT_HOOK_TOKEN"])
        }
        XCTAssertEqual(hooks["SessionStart"]?.first?["type"] as? String, "command")
        let permission = try XCTUnwrap(hooks["PermissionRequest"]?.first)
        XCTAssertEqual(permission["type"] as? String, "command")
        XCTAssertTrue((permission["command"] as? String ?? "").hasSuffix("ht permission claude"))
    }

    func testWithoutAListenerEveryHookIsACommand() throws {
        XCTAssertTrue(try hooks(port: nil).values.allSatisfy { $0.allSatisfy { $0["type"] as? String == "command" } })
    }

    func testToolOutputIsKeptOnlyForBash() {
        var read: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": "Read", "tool_input": ["file_path": "/a"], "tool_response": ["file": "…"]]
        XCTAssertTrue(SessionStore.dropUnusedToolOutput(&read))
        XCTAssertNil(read["tool_response"])
        XCTAssertNotNil(read["tool_input"])

        var failed: [String: Any] = ["hook_event_name": "PostToolUseFailure", "tool_name": "Edit", "tool_response": "x"]
        XCTAssertTrue(SessionStore.dropUnusedToolOutput(&failed))

        var bash: [String: Any] = ["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_response": ["stdout": "ok"]]
        XCTAssertFalse(SessionStore.dropUnusedToolOutput(&bash))
        XCTAssertNotNil(bash["tool_response"])

        var pre: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "Read", "tool_response": "kept"]
        XCTAssertFalse(SessionStore.dropUnusedToolOutput(&pre))
    }

    func testAgentMessageTurnsTakeNoCheckpoint() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        let message = "\(agentMessagePrefix)web (Claude Code, via Tako): the endpoint is ready"
        XCTAssertTrue(isAgentMessage(message))
        XCTAssertFalse(isAgentMessage("Fix the Message from @web bug"))

        store.applyHook(source: "claude", session: session, json: ["hook_event_name": "UserPromptSubmit", "prompt": message], sentAt: nil)

        XCTAssertTrue(session.turnIsMessage)
        XCTAssertEqual(session.timeline.last?.kind, .message)
    }

    // MARK: - HTTP

    private func post(session: String, token: String, body: String = #"{"hook_event_name":"Stop"}"#, path: String = "/hook/claude") -> Data {
        Data("POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nX-HT-Session: \(session)\r\nAuthorization: Bearer \(token)\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
    }

    func testParsesARequestOnceTheBodyHasArrived() throws {
        let id = UUID().uuidString
        let raw = post(session: id, token: "t")
        guard case .incomplete = HookHTTPRequest.parse(raw.prefix(40)) else { return XCTFail("headers not complete") }
        guard case .incomplete = HookHTTPRequest.parse(raw.dropLast(3)) else { return XCTFail("body not complete") }
        guard case .complete(let request) = HookHTTPRequest.parse(raw) else { return XCTFail("complete") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/hook/claude")
        XCTAssertEqual(request.headers["x-ht-session"], id)
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), #"{"hook_event_name":"Stop"}"#)
        guard case .invalid = HookHTTPRequest.parse(Data("garbage\r\n\r\n".utf8)) else { return XCTFail("invalid") }
    }

    func testOnlyASessionsOwnTokenIsAccepted() throws {
        let id = UUID().uuidString, other = UUID().uuidString
        func authorized(_ raw: Data) -> String? {
            guard case .complete(let request) = HookHTTPRequest.parse(raw) else { return nil }
            return HookServer.authorizedSession(request)
        }
        XCTAssertEqual(authorized(post(session: id, token: HookServer.token(for: id))), id)
        XCTAssertNil(authorized(post(session: id, token: HookServer.token(for: other))))
        XCTAssertNil(authorized(post(session: id, token: "")))
        XCTAssertNil(authorized(post(session: id, token: HookServer.token(for: id), path: "/other")))
        XCTAssertNil(authorized(post(session: "not-a-uuid", token: HookServer.token(for: "not-a-uuid"))))
    }

    func testListenerAcknowledgesAndDeliversAuthorizedPosts() async throws {
        let delivered = expectation(description: "delivered")
        nonisolated(unsafe) var received: (String, Data)?
        let server = HookServer { _, session, body, _ in
            received = (session, body)
            delivered.fulfill()
        }
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let id = UUID().uuidString

        func send(token: String) async throws -> Int {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook/claude")!)
            request.httpMethod = "POST"
            request.setValue(id, forHTTPHeaderField: "X-HT-Session")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = Data(#"{"hook_event_name":"Stop"}"#.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        }
        let forged = try await send(token: "forged")
        XCTAssertEqual(forged, 403)
        let ok = try await send(token: HookServer.token(for: id))
        XCTAssertEqual(ok, 200)
        await fulfillment(of: [delivered], timeout: 5)
        XCTAssertEqual(received?.0, id)
        XCTAssertEqual(received.map { String(decoding: $0.1, as: UTF8.self) }, #"{"hook_event_name":"Stop"}"#)
    }
}
