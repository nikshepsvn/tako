import XCTest
@testable import Tako

final class AccountTests: XCTestCase {
    func testDefaultAccountNeverOverridesTheCLIRoot() {
        // Setting CLAUDE_CONFIG_DIR=~/.claude would create a second, separate Keychain sign-in.
        XCTAssertEqual(AgentAccount(id: "default", kind: .claude, name: "Default").environment, [:])
        XCTAssertEqual(AgentAccount(id: "default", kind: .codex, name: "Default").environment, [:])
    }

    func testExtraAccountsRunFromTheirOwnRoot() {
        let codex = AgentAccount(id: "work", kind: .codex, name: "Work")
        XCTAssertEqual(codex.environment["CODEX_HOME"], AccountStore.root.appendingPathComponent("codex/work").path)
        let claude = AgentAccount(id: "work", kind: .claude, name: "Work")
        XCTAssertEqual(claude.environment["CLAUDE_CONFIG_DIR"], AccountStore.root.appendingPathComponent("claude/work").path)
    }

    func testConversationCopiesKeepTheirRelativePath() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: base) }
        let source = base.appendingPathComponent("a/projects")
        let destination = base.appendingPathComponent("b/projects")
        let project = source.appendingPathComponent("-Users-me-app")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: project.appendingPathComponent("abc-123.jsonl"))
        try Data("other".utf8).write(to: project.appendingPathComponent("zzz-999.jsonl"))

        XCTAssertTrue(AccountStore.copyConversation("abc-123", from: source, to: destination))
        let copied = destination.appendingPathComponent("-Users-me-app/abc-123.jsonl")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "one")
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("-Users-me-app/zzz-999.jsonl").path))
        XCTAssertFalse(AccountStore.copyConversation("missing", from: source, to: destination))
    }
}
