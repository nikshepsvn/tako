import XCTest
@testable import Tako

final class AgentTranscriptTests: XCTestCase {
    private let claude = #"""
    {"type":"permission-mode","permissionMode":"auto"}
    {"type":"user","message":{"role":"user","content":"fix the login bug"}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"}]}}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"git status\n  --short"}}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"M a.swift"}]}}
    {"type":"user","isMeta":true,"message":{"role":"user","content":"Caveat: injected"}}
    {"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}
    {"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent"}]}}
    not json
    {"type":"system","subtype":"turn_duration"}
    {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Fixed it.\nThe token expired early."}]}}
    {"type":"user","message":{"role":"user","content":[{"type":"text","text":"thanks"}]}}
    """#

    private let codex = #"""
    {"type":"session_meta","payload":{"id":"t-1"}}
    {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>x</environment_context>"}]}}
    {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"add tests"}]}}
    {"type":"event_msg","payload":{"type":"user_message","message":"add tests"}}
    {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"swift test\"]}"}}
    {"type":"response_item","payload":{"type":"function_call_output","output":"ok"}}
    {"type":"event_msg","payload":{"type":"token_count","info":{}}}
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Tests pass."}]}}
    {"type":"event_msg","payload":{"type":"agent_message","message":"Tests pass."}}
    """#

    func testRendersClaudeConversation() {
        XCTAssertEqual(AgentTranscript.renderClaude(claude[...]), [
            "› fix the login bug",
            "[tool] Bash: git status --short",
            "Fixed it.",
            "The token expired early.",
            "› thanks",
        ])
    }

    func testRendersCodexConversationWithoutDuplicates() {
        XCTAssertEqual(AgentTranscript.renderCodex(codex[...]), [
            "› add tests",
            "[tool] shell: bash -lc swift test",
            "Tests pass.",
        ])
    }

    func testOlderCodexLogsFallBackToResponseMessages() {
        let old = codex.split(separator: "\n").filter { !$0.contains("event_msg") }.joined(separator: "\n")
        XCTAssertEqual(AgentTranscript.renderCodex(old[...]), ["› add tests", "[tool] shell: bash -lc swift test", "Tests pass."])
    }

    func testComposeKeepsTheScreenAndStaysWithinTheLimit() {
        let conversation = (1...50).map { "line \($0)" }
        let screen = "status\n> prompt"
        let text = AgentTranscript.compose(conversation: conversation, screen: screen, lines: 6)
        XCTAssertEqual(text, "line 48\nline 49\nline 50\n── screen ──\nstatus\n> prompt")
        // No room for even one conversation line: the screen alone.
        XCTAssertEqual(AgentTranscript.compose(conversation: conversation, screen: screen, lines: 3), screen)
        XCTAssertEqual(AgentTranscript.compose(conversation: [], screen: screen, lines: 60), screen)
    }

    func testLongToolInputIsShortened() {
        let line = AgentTranscript.tool("Grep", ["pattern": String(repeating: "a", count: 300)])
        XCTAssertEqual(line.count, "[tool] Grep: ".count + 120)
        XCTAssertTrue(line.hasSuffix("…"))
    }

    func testFindsClaudeTranscriptsByFolderOrByID() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        XCTAssertEqual(AgentTranscript.projectFolder("/Users/me/my app/.claude/worktrees/x_y"), "-Users-me-my-app--claude-worktrees-x-y")
        let id = "0b7c2a3e-1111-4222-8333-444455556666"
        let folder = root.appendingPathComponent("projects/-elsewhere")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(claude.utf8).write(to: folder.appendingPathComponent("\(id).jsonl"))
        // The computed folder misses; the id is found anyway.
        let lines = AgentTranscript.conversation(kind: .claude, id: id, cwds: ["/repo"], root: root)
        XCTAssertEqual(lines.last, "› thanks")
        XCTAssertEqual(AgentTranscript.conversation(kind: .claude, id: "missing-id", cwds: ["/repo"], root: root), [])
        XCTAssertEqual(AgentTranscript.conversation(kind: .claude, id: "../../etc", cwds: ["/repo"], root: root), [])
    }

    func testFindsCodexRollout() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let day = root.appendingPathComponent("sessions/2025/01/02")
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        try Data(codex.utf8).write(to: day.appendingPathComponent("rollout-2025-01-02T00-00-00-t-123.jsonl"))
        XCTAssertEqual(AgentTranscript.conversation(kind: .codex, id: "t-123", cwds: [], root: root).first, "› add tests")
    }
}
