import Foundation
import XCTest
@testable import Tako

final class AgentOptionTests: XCTestCase {
    func testEmptyOptionsAddNoFlags() {
        XCTAssertEqual(AgentOptions().arguments(for: .claude), [])
        XCTAssertEqual(AgentOptions().arguments(for: .codex), [])
        XCTAssertTrue(AgentOptions().isEmpty)
    }

    func testClaudeModesUseItsPermissionModes() {
        let expected: [PermissionMode: String] = [.supervised: "default", .acceptEdits: "acceptEdits",
                                                  .plan: "plan", .fullAccess: "bypassPermissions"]
        for (mode, value) in expected {
            XCTAssertEqual(AgentOptions(mode: mode).arguments(for: .claude), ["--permission-mode", value])
        }
    }

    func testCodexModesUseApprovalAndSandboxFlags() {
        XCTAssertEqual(AgentOptions(mode: .acceptEdits).arguments(for: .codex),
                       ["--ask-for-approval", "on-request", "--sandbox", "workspace-write"])
        XCTAssertEqual(AgentOptions(mode: .plan).arguments(for: .codex),
                       ["--ask-for-approval", "on-request", "--sandbox", "read-only"])
        XCTAssertEqual(AgentOptions(mode: .fullAccess).arguments(for: .codex), ["--dangerously-bypass-approvals-and-sandbox"])
    }

    func testModelAndEffort() {
        XCTAssertEqual(AgentOptions(model: "opus").arguments(for: .claude), ["--model", "opus"])
        XCTAssertEqual(AgentOptions(model: "gpt-5-codex", effort: .high).arguments(for: .codex),
                       ["-m", "gpt-5-codex", "-c", "model_reasoning_effort=\"high\""])
        // Claude has no effort flag here; the choice is ignored rather than guessed.
        XCTAssertEqual(AgentOptions(effort: .high).arguments(for: .claude), [])
    }

    func testModelNamesThatCouldBreakTheShellAreDropped() {
        XCTAssertNil(AgentOptions.validModel("opus; rm -rf ~"))
        XCTAssertNil(AgentOptions.validModel("$(whoami)"))
        XCTAssertNil(AgentOptions.validModel(""))
        XCTAssertEqual(AgentOptions.validModel(" opus[1m] "), "opus[1m]")
        XCTAssertEqual(AgentOptions(model: "a b").arguments(for: .claude), [])
    }

    func testSummary() {
        XCTAssertEqual(AgentOptions(mode: .plan, model: "opus").summary, "Opus · Plan")
        XCTAssertNil(AgentOptions().summary)
    }

    func testRoundTripsThroughJSON() throws {
        let options = AgentOptions(mode: .acceptEdits, model: "sonnet", effort: .low)
        XCTAssertEqual(try JSONDecoder().decode(AgentOptions.self, from: JSONEncoder().encode(options)), options)
    }
}
