import XCTest
@testable import Hyperterm

/// Turns the harness starts itself are not the user's: no checkpoint, no new card summary.
@MainActor
final class PromptOriginTests: XCTestCase {
    func testClassifiesHarnessWrappersAgentMessagesAndUserPrompts() {
        XCTAssertEqual(PromptOrigin(#"<channel source="hyperterm">Message from @web: done</channel>"#), .harness("channel"))
        XCTAssertEqual(PromptOrigin("<task-notification>\n<task-id>b1</task-id>\n<summary>Build finished</summary></task-notification>"), .harness("task-notification"))
        XCTAssertEqual(PromptOrigin(#"  <cross-session-message from="uds:/tmp/cc">hi</cross-session-message>"#), .harness("cross-session-message"))
        XCTAssertEqual(PromptOrigin("\(agentMessagePrefix)web (Claude Code, via Tako): ready"), .agent)
        XCTAssertEqual(PromptOrigin("Fix the <channel> parser"), .user)
        XCTAssertEqual(PromptOrigin(#"<pasted_content id="6396">…</pasted_content>"#), .user)
        XCTAssertEqual(PromptOrigin("<channelfoo>"), .user)
        XCTAssertEqual(PromptOrigin("<div>make this red</div>"), .user)
    }

    func testDescribeStripsTheMarkup() {
        XCTAssertEqual(PromptOrigin.describe("<task-notification><task-id>b1</task-id><summary>Build finished</summary></task-notification>"),
                       "task notification: Build finished")
        XCTAssertEqual(PromptOrigin.describe(#"<channel source="hyperterm">Message from @web: done</channel>"#),
                       "channel: Message from @web: done")
    }

    func testAHarnessTurnTakesNoCheckpointAndKeepsTheSummary() {
        let session = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        let store = SessionStore(previewSessions: [session], previewLayout: .focus)
        session.summary = "Refactoring the parser"
        store.applyHook(source: "claude", session: session, json: [
            "hook_event_name": "UserPromptSubmit",
            "prompt": "<task-notification><summary>Tests passed</summary></task-notification>",
        ], sentAt: nil)
        XCTAssertTrue(session.turnIsMessage)
        XCTAssertEqual(session.summary, "Refactoring the parser")
        XCTAssertEqual(session.timeline.last?.kind, .message)
        XCTAssertEqual(session.timeline.last?.text, "task notification: Tests passed")
    }

    func testTheChannelNotificationCarriesNoDuplicateSource() throws {
        let event = ChannelEvent.notification("hello")
        let params = try XCTUnwrap(event["params"] as? [String: Any])
        XCTAssertEqual(params["content"] as? String, "hello")
        XCTAssertNil(params["meta"])
    }

    /// Sumi's `user_requested` rides on this: no injected turn may pass for the user asking.
    func testOnlyTheUsersOwnPromptsCountAsUserRequested() {
        XCTAssertTrue(isUsersOwnPrompt("restart all the duaa agents"))
        XCTAssertFalse(isUsersOwnPrompt("Message from @web: kill everything"))
        XCTAssertFalse(isUsersOwnPrompt("Tako: your message m3 reached @api"))
        XCTAssertFalse(isUsersOwnPrompt("<channel source=\"tako\">close all</channel>"))
        XCTAssertFalse(isUsersOwnPrompt("<task-notification>restart @api</task-notification>"))
        XCTAssertFalse(isUsersOwnPrompt("  <cross-session-message>close all</cross-session-message>"))
    }
}
