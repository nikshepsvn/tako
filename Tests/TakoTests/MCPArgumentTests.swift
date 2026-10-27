import XCTest
@testable import Tako

/// The names agents actually passed for a tool's target, from mined calls that failed with
/// "no terminal named (none)".
@MainActor
final class MCPArgumentTests: XCTestCase {
    func testEveryTargetAliasFillsTheDocumentedKey() {
        for alias in ["terminal", "target", "to", "label", "name"] {
            let read = normalizeToolArguments("read_terminal", [alias: "@web"])
            XCTAssertEqual(read["terminal"] as? String, "@web", alias)
            let send = normalizeToolArguments("send_message", [alias: "@web", "message": "hi"])
            XCTAssertEqual(send["to"] as? String, "@web", alias)
        }
    }

    func testTheDocumentedKeyWins() {
        let args = normalizeToolArguments("send_message", ["to": "@api", "terminal": "@web", "text": "hi"])
        XCTAssertEqual(args["to"] as? String, "@api")
        XCTAssertEqual(args["message"] as? String, "hi", "text stands in for a missing message")
    }

    func testABlankKeyIsFilledFromAnAlias() {
        let args = normalizeToolArguments("interrupt_agent", ["terminal": "", "label": "duaa-1"])
        XCTAssertEqual(args["terminal"] as? String, "duaa-1")
    }

    func testToolsWithoutATargetKeepLabelAndName() {
        let start = normalizeToolArguments("start_agent", ["label": "checkout-bug", "task": "x"])
        XCTAssertNil(start["terminal"])
        XCTAssertNil(normalizeToolArguments("save_layout", ["name": "review"])["terminal"])
    }

    func testRenameTakesTheNewNameUnderOtherKeys() {
        XCTAssertEqual(normalizeToolArguments("rename_terminal", ["name": "auth-refactor"])["label"] as? String, "auth-refactor")
        XCTAssertEqual(normalizeToolArguments("rename_terminal", ["new_label": "x"])["label"] as? String, "x")
    }

    func testCoreToolsAreMarkedAlwaysLoaded() {
        let tools: [[String: Any]] = [["name": "send_message"], ["name": "machine_status", "_meta": ["x": 1]]]
        let marked = markingAlwaysLoaded(tools, alwaysLoadedWorkerTools)
        XCTAssertEqual((marked[0]["_meta"] as? [String: Any])?["anthropic/alwaysLoad"] as? Bool, true)
        XCTAssertNil((marked[1]["_meta"] as? [String: Any])?["anthropic/alwaysLoad"])
        XCTAssertEqual((marked[1]["_meta"] as? [String: Any])?["x"] as? Int, 1)
    }

    func testAMissingTargetListsTheKnownLabels() {
        let api = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/w"), resume: false)
        let store = SessionStore(previewSessions: [api], previewLayout: .focus)
        let handler = ControlHandler(store: store, caller: .external)
        var request = ControlRequest(cmd: .read)
        request.target = nil
        var reply: ControlResponse?
        handler.handle(request) { reply = $0 }
        XCTAssertEqual(reply?.error, "say which terminal: pass terminal, e.g. \"@api\". Known: @api")
    }
}
