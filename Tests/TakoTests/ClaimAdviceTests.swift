import Darwin
import XCTest
@testable import Tako

/// Advisory file claims at edit time: an edit inside another agent's claim goes ahead with a
/// heads-up in the hook reply, and the holder hears once. Stores are previews.
@MainActor
final class ClaimAdviceTests: XCTestCase {
    func testAnEditInsideAnotherAgentsClaimIsAllowedWithAHeadsUp() throws {
        let (store, me, api) = fixture()
        claim(store, api, ["src/auth/**"])

        let reply = try XCTUnwrap(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Edit", "/workspace/atlas/src/auth/login.ts")))
        let output = try XCTUnwrap(try decode(reply)["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["hookEventName"] as? String, "PreToolUse")
        XCTAssertNil(output["permissionDecision"], "advisory: the CLI's own permission rules decide")
        XCTAssertEqual(output["additionalContext"] as? String,
                       "Tako team board: src/auth/login.ts is in @api's claim src/auth/**. The edit goes ahead and @api was told; coordinate via send_message or team_board.")

        XCTAssertEqual(api.pendingMessages.count, 1, "queued for the end of the holder's turn")
        XCTAssertTrue(api.pendingMessages[0].hasPrefix("Message from @me (via Tako's team board): heads-up, I'm editing src/auth/login.ts (your claim src/auth/**)"),
                      api.pendingMessages[0])

        XCTAssertNil(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Edit", "/workspace/atlas/src/auth/token.ts")),
                     "one heads-up per claim and editor, not one per edit")
        XCTAssertEqual(api.pendingMessages.count, 1, "the holder isn't messaged again")
    }

    func testWritesAndGlobsOverlapLikeClaims() {
        let (store, me, api) = fixture()
        claim(store, api, ["src/*.ts"])
        XCTAssertNil(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Write", "/workspace/atlas/docs/a.md")))
        XCTAssertNotNil(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Write", "/workspace/atlas/src/a/b.ts")),
                        "* crosses folders, as claims do")
        XCTAssertNil(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Write", "/elsewhere/src/a.ts")),
                     "a path outside the editor's workspace is nobody's claim")
    }

    func testOwnClaimsAndOtherToolsSayNothing() {
        let (store, me, _) = fixture()
        claim(store, me, ["src/**"])
        XCTAssertNil(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Edit", "/workspace/atlas/src/a.ts")))
        let (store2, me2, api2) = fixture()
        claim(store2, api2, ["src/**"])
        XCTAssertNil(store2.adviseEditHook(sessionID: me2.id.uuidString, payload: edit("Read", "/workspace/atlas/src/a.ts")))
    }

    func testExpiredAndReleasedClaimsSayNothing() throws {
        let (store, me, api) = fixture()
        claim(store, api, ["src/**"])
        let later = Date().addingTimeInterval(3 * 3600)
        XCTAssertNil(store.claimIndex.advise(editor: me.id, payload: edit("Edit", "/workspace/atlas/src/a.ts"), now: later),
                     "a claim past its minutes no longer counts")

        _ = board(store, api, "release")
        XCTAssertTrue(store.claimIndex.isEmpty, "no claims: the hook path parses nothing")
        XCTAssertNil(store.claimIndex.workspace(of: me.id), "an idle index holds nothing")
        XCTAssertNil(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Edit", "/workspace/atlas/src/a.ts")))
    }

    func testAnExitedHolderNoLongerCounts() {
        let (store, me, api) = fixture()
        claim(store, api, ["src/**"])
        api.apply(.processStarted, source: "test", force: .exited(0))
        XCTAssertTrue(store.claimIndex.isEmpty)
        XCTAssertNil(store.adviseEditHook(sessionID: me.id.uuidString, payload: edit("Edit", "/workspace/atlas/src/a.ts")))
    }

    func testAnAgentStartedAfterTheClaimIsCheckedOnceItHooks() {
        let (store, late, api) = fixture()
        claim(store, api, ["src/**"])
        // As if it started after the claim, or before Git reported its worktree.
        store.claimIndex.register(late.id, nil)
        store.applyHook(source: "codex", session: late, json: ["hook_event_name": "UserPromptSubmit", "prompt": "go"], sentAt: nil)
        XCTAssertNotNil(store.claimIndex.workspace(of: late.id))
        XCTAssertNotNil(store.adviseEditHook(sessionID: late.id.uuidString, payload: edit("Edit", "/workspace/atlas/src/a.ts")))
    }

    /// Codex's hooks go through `ht hook`, which prints the reply's text.
    func testCodexApplyPatchGetsTheHeadsUpThroughTheControlSocket() throws {
        let (store, me, api) = fixture()
        claim(store, api, ["src/auth"])
        let patch = "*** Begin Patch\n*** Update File: src/auth/login.ts\n@@\n-a\n+b\n*** End Patch"
        let json: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": "apply_patch", "cwd": "/workspace/atlas",
                                   "tool_input": ["command": patch]]
        var request = ControlRequest(cmd: .hook)
        request.source = "codex"
        request.payload = String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
        let text = try XCTUnwrap(response(store, me, request).text)
        let output = try decode(Data(text.utf8))["hookSpecificOutput"] as? [String: Any]
        XCTAssertTrue((output?["additionalContext"] as? String)?.contains("src/auth/login.ts is in @api's claim src/auth") == true)

        var other = ControlRequest(cmd: .hook)
        other.source = "codex"
        other.payload = #"{"hook_event_name":"Stop"}"#
        XCTAssertNil(response(store, me, other).text, "other events print nothing, as before")
    }

    func testEditPathsFromEachTool() {
        func paths(_ tool: String, _ input: [String: Any], event: String = "PreToolUse") -> [String] {
            EditHook.paths(["hook_event_name": event, "tool_name": tool, "tool_input": input])
        }
        XCTAssertEqual(paths("MultiEdit", ["file_path": "/a/b.ts"]), ["/a/b.ts"])
        XCTAssertEqual(paths("NotebookEdit", ["notebook_path": "/a/n.ipynb"]), ["/a/n.ipynb"])
        XCTAssertEqual(paths("apply_patch", ["input": "*** Add File: x.ts\n*** Delete File: y.ts\n*** Update File: z.ts\n*** Move to: w.ts"]),
                       ["x.ts", "y.ts", "z.ts", "w.ts"])
        XCTAssertEqual(paths("Read", ["file_path": "/a/b.ts"]), [])
        XCTAssertEqual(paths("Edit", ["file_path": "/a/b.ts"], event: "PostToolUse"), [])
    }

    /// Claude's HTTP hooks: the advisor's JSON is the reply body; without one the reply is empty.
    nonisolated func testTheHookListenerRepliesWithTheAdvisorsBody() throws {
        let body = Data(#"{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"hi"}}"#.utf8)
        let server = HookServer(advisor: { _, payload in
            payload.range(of: Data("Edit".utf8)) == nil ? nil : body
        }) { _, _, _, _ in }
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let edited = try Self.post(#"{"hook_event_name":"PreToolUse","tool_name":"Edit"}"#, port: port)
        XCTAssertTrue(edited.hasPrefix("HTTP/1.1 200 OK"), edited)
        XCTAssertTrue(edited.contains("Content-Type: application/json"), edited)
        XCTAssertTrue(edited.hasSuffix("\r\n\r\n" + String(decoding: body, as: UTF8.self)), edited)
        let plain = try Self.post(#"{"hook_event_name":"Stop"}"#, port: port)
        XCTAssertTrue(plain.hasSuffix("Content-Length: 0\r\nConnection: close\r\n\r\n"), plain)
    }

    // MARK: - Helpers

    private func fixture() -> (SessionStore, TerminalSession, TerminalSession) {
        let me = agent("me"), api = agent("api")
        let store = SessionStore(previewSessions: [me, api], previewLayout: .grid)
        me.store = store
        api.store = store
        return (store, me, api)
    }

    /// Working, so a message to it queues where the test can see it.
    private func agent(_ label: String) -> TerminalSession {
        let session = TerminalSession(spec: LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas"), resume: false)
        session.apply(.processStarted, source: "test", force: .working)
        return session
    }

    private func claim(_ store: SessionStore, _ agent: TerminalSession, _ paths: [String]) {
        XCTAssertTrue(board(store, agent, "claim", paths: paths).text?.hasPrefix("claimed") == true)
    }

    private func board(_ store: SessionStore, _ caller: TerminalSession, _ action: String, paths: [String]? = nil) -> ControlResponse {
        var request = ControlRequest(cmd: .board)
        request.text = action
        request.paths = paths
        return response(store, caller, request)
    }

    private func response(_ store: SessionStore, _ caller: TerminalSession, _ request: ControlRequest) -> ControlResponse {
        let got = Reply()
        ControlHandler(store: store, caller: .session(caller.id.uuidString)).handle(request) { got.value = $0 }
        return got.value ?? .failure("no reply")
    }

    private func edit(_ tool: String, _ path: String) -> Data {
        let json: [String: Any] = ["hook_event_name": "PreToolUse", "tool_name": tool, "cwd": "/workspace/atlas",
                                   "tool_input": ["file_path": path, "content": "x"]]
        return (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// One authorized hook POST; returns the whole reply.
    nonisolated private static func post(_ body: String, port: UInt16) throws -> String {
        let session = UUID().uuidString
        let raw = "POST /hook/claude HTTP/1.1\r\nHost: 127.0.0.1\r\nX-HT-Session: \(session)\r\nAuthorization: Bearer \(HookServer.token(for: session))\r\n"
            + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = raw.withCString { write(fd, $0, strlen($0)) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            reply.append(contentsOf: buffer[0..<n])
        }
        return String(decoding: reply, as: UTF8.self)
    }
}

private final class Reply: @unchecked Sendable {
    var value: ControlResponse?
}
