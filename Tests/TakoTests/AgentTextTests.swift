import XCTest
@testable import Tako

final class AgentTextTests: XCTestCase {
    func testDescribesToolCalls() {
        XCTAssertEqual(AgentText.describeTool(name: "Bash", input: ["command": "pnpm test\n--watch"], cwd: nil), "Bash: pnpm test")
        XCTAssertEqual(AgentText.describeTool(name: "Edit", input: ["file_path": "/repo/src/a.ts"], cwd: "/repo"), "Edit: src/a.ts")
        XCTAssertEqual(AgentText.describeTool(name: "mcp__hyperterm__send_message", input: [:], cwd: nil), "hyperterm: send_message")
        XCTAssertEqual(AgentText.describeTool(name: "TodoWrite", input: [:], cwd: nil), "TodoWrite")
    }

    func testPreviewSkipsClaudeChrome() {
        let screen = """
         ▐▛███▜▌   Claude Code v2.1.287
        ▝▜█████▛▘  Haiku 4.5 · Claude Max

        ● Update(src/components/Hero.tsx) +28 −19
          ⎿ New headline, shorter subhead
        ✻ Checking the mobile breakpoint… (esc to interrupt)
        ──────────────────────────────────────────────── api ─
        ❯ 
        ──────────────────────────────────────────────────────
          ⏵⏵ auto mode on (shift+tab to cycle)
        """
        XCTAssertEqual(AgentText.preview(from: screen), [
            "● Update(src/components/Hero.tsx) +28 −19",
            "⎿ New headline, shorter subhead",
        ])
    }
}
