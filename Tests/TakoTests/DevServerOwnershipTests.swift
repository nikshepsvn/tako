import XCTest
@testable import Tako

/// An agent's workspace dev server belongs to it and closes with it.
@MainActor
final class DevServerOwnershipTests: XCTestCase {
    func testClosingAnAgentClosesItsDevServerOnly() {
        let agent = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/tmp"), resume: false)
        var devSpec = LaunchSpec(label: "api-dev", kind: .server, cwd: "/tmp", command: "true")
        devSpec.owner = agent.spec.id
        let dev = TerminalSession(spec: devSpec, resume: false)
        let other = TerminalSession(spec: LaunchSpec(label: "db", kind: .server, cwd: "/tmp", command: "true"), resume: false)
        let store = SessionStore(previewSessions: [agent, dev, other], previewLayout: .grid)
        XCTAssertEqual(store.servers(ownedBy: agent).map(\.id), [dev.id])

        store.close(agent)

        XCTAssertEqual(store.sessions.map(\.id), [other.id])
    }

    func testRestoreGivesOldDevServersBackToTheirAgentAndDropsOrphans() {
        var agent = LaunchSpec(label: "api", kind: .claude, cwd: "/repo")
        agent.worktreeName = "api"
        agent.port = 4100
        var legacy = LaunchSpec(label: "api-dev", kind: .server, cwd: "/repo/.claude/worktrees/api", command: "pnpm dev")
        legacy.labelSource = .auto
        legacy.port = 4100
        var orphan = LaunchSpec(label: "gone-dev", kind: .server, cwd: "/repo/.claude/worktrees/gone", command: "pnpm dev")
        orphan.owner = UUID()
        let mine = LaunchSpec(label: "db", kind: .server, cwd: "/repo/.claude/worktrees/api", command: "postgres")

        let restored = SessionStore.ownedDevServers([agent, legacy, orphan, mine])

        XCTAssertEqual(restored.map(\.label), ["api", "api-dev", "db"])
        XCTAssertEqual(restored[1].owner, agent.id)
        XCTAssertNil(restored[2].owner, "a server the user named stays theirs")
    }
}
