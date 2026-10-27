import XCTest
@testable import Tako

final class StatusReducerTests: XCTestCase {
    private func hook(_ name: String, type: String? = nil, message: String? = nil) -> StatusEvent {
        .claudeHook(event: name, notificationType: type, message: message)
    }

    func testClaudeTurnLifecycle() {
        var state = AgentState.starting
        state = reduceState(state, kind: .claude, event: hook("SessionStart"))
        XCTAssertEqual(state, .idle)
        state = reduceState(state, kind: .claude, event: hook("UserPromptSubmit"))
        XCTAssertEqual(state, .working)
        state = reduceState(state, kind: .claude, event: hook("Notification", type: "permission_prompt", message: "Claude needs your permission to use Bash"))
        XCTAssertEqual(state, .needsInput("Claude needs your permission to use Bash"))
        state = reduceState(state, kind: .claude, event: hook("PostToolUse"))
        XCTAssertEqual(state, .working)
        state = reduceState(state, kind: .claude, event: hook("Stop"))
        XCTAssertEqual(state, .idle)
    }

    func testIdleReminderIsNotABlockingPrompt() {
        let state = reduceState(.idle, kind: .claude, event: hook("Notification", type: nil, message: "Claude is waiting for your input"))
        XCTAssertEqual(state, .idle)
        let typed = reduceState(.idle, kind: .claude, event: hook("Notification", type: "idle_prompt", message: "Claude is waiting for your input"))
        XCTAssertEqual(typed, .idle)
    }

    func testIdleReminderDoesNotClearAPendingPrompt() {
        let waiting = AgentState.needsInput("approve?")
        XCTAssertEqual(reduceState(waiting, kind: .claude, event: hook("Notification", type: "idle_prompt")), waiting)
    }

    func testStopFailureAndSessionEnd() {
        XCTAssertEqual(reduceState(.working, kind: .claude, event: hook("StopFailure", message: "overloaded")), .failed("overloaded"))
        // SessionEnd also fires on /clear; only the process poll marks an agent exited.
        XCTAssertEqual(reduceState(.idle, kind: .claude, event: hook("SessionEnd")), .idle)
        XCTAssertEqual(reduceState(.exited(0), kind: .claude, event: .userSubmitted), .exited(0))
    }

    func testCodexApprovalNotificationThenTurnComplete() {
        var state = reduceState(.working, kind: .codex, event: .terminalNotification(title: "Codex", body: "Approval requested: run pnpm install"))
        XCTAssertEqual(state, .needsInput("Approval requested: run pnpm install"))
        state = reduceState(state, kind: .codex, event: .userSubmitted)
        XCTAssertEqual(state, .working)
        state = reduceState(state, kind: .codex, event: .codexTurnComplete)
        XCTAssertEqual(state, .idle)
    }

    func testCodexReplyMentioningPermissionIsNotAPrompt() {
        XCTAssertEqual(reduceState(.working, kind: .codex, event: .terminalNotification(title: "Codex", body: "Fixed the permission bug in auth.ts")), .idle)
    }

    func testClaudeTerminalNotificationsDeferToHooks() {
        XCTAssertEqual(reduceState(.working, kind: .claude, event: .terminalNotification(title: "Claude Code", body: "Task complete")), .working)
    }

    func testRegistryOnlyCorrectsDrift() {
        XCTAssertEqual(reduceState(.starting, kind: .claude, event: .registryStatus("idle")), .idle)
        XCTAssertEqual(reduceState(.idle, kind: .claude, event: .registryStatus("busy")), .working)
        // A registry "idle" must not clear a permission prompt the hooks reported.
        XCTAssertEqual(reduceState(.needsInput("x"), kind: .claude, event: .registryStatus("idle")), .needsInput("x"))
    }

    func testProcessesAndExit() {
        XCTAssertEqual(reduceState(.starting, kind: .server, event: .processStarted), .running)
        XCTAssertEqual(reduceState(.running, kind: .server, event: .childExited(1)), .exited(1))
        XCTAssertEqual(reduceState(.working, kind: .claude, event: .childExited(0)), .exited(0))
    }

    func testSummarizeTakesFirstMeaningfulLine() {
        XCTAssertEqual(summarize("\n## Done\n\nMore detail"), "Done")
        XCTAssertEqual(summarize("   \n "), nil)
        XCTAssertEqual(summarize(String(repeating: "a", count: 300), limit: 10), "aaaaaaaaa…")
    }

    func testCleanTitleDropsSpinnerGlyphs() {
        XCTAssertEqual(cleanTitle("✳ Fix auth bug"), "Fix auth bug")
        XCTAssertEqual(cleanTitle("⠋ Running tests"), "Running tests")
    }
}
