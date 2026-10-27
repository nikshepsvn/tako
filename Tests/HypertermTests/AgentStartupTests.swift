import XCTest
@testable import Hyperterm

/// Agents Sumi starts: folder trust asked once up front, and start_agent reporting where each
/// agent got to instead of "started" for one that was gone 20 s later.
@MainActor
final class AgentStartupTests: XCTestCase {
    private let home = "/Users/me"

    // MARK: - Folder trust

    func testClaudeTrustComesFromTheFolderOrAParentBelowHome() {
        let config: [String: Any] = ["projects": [
            "/Users/me": ["hasTrustDialogAccepted": true],
            "/Users/me/Code/shop": ["hasTrustDialogAccepted": true],
            "/Users/me/Code/new": ["hasTrustDialogAccepted": false],
        ]]
        XCTAssertTrue(FolderTrust.claudeTrusts("/Users/me/Code/shop", config: config, home: home))
        XCTAssertTrue(FolderTrust.claudeTrusts("/Users/me/Code/shop/packages/api/", config: config, home: home))
        XCTAssertFalse(FolderTrust.claudeTrusts("/Users/me/Code/new", config: config, home: home))
        XCTAssertFalse(FolderTrust.claudeTrusts("/Users/me/Desktop/game", config: config, home: home),
                       "trusting home doesn't trust what's under it: Claude still asks there")
        XCTAssertFalse(FolderTrust.claudeTrusts("/Users/me/Code/shop", config: [:], home: home))
    }

    func testCodexTrustIsReadFromItsProjectsTable() {
        let toml = """
        model = "gpt-5"
        [projects."/Users/me/Code/shop"]
        trust_level = "trusted"

        [projects."/Users/me/Code/other"]
        trust_level = "untrusted"
        """
        XCTAssertTrue(FolderTrust.codexTrusts("/Users/me/Code/shop/web", config: toml, home: home))
        XCTAssertFalse(FolderTrust.codexTrusts("/Users/me/Code/other", config: toml, home: home))
        XCTAssertFalse(FolderTrust.codexTrusts("/Users/me/Code/third", config: toml, home: home))
    }

    func testOneQuestionPerFolderAnswersEveryStartWaitingOnIt() {
        let gate = StartupGate()
        var asked = 0
        var finish: ((Bool) -> Void)?
        var answers: [Bool] = []
        for _ in 0..<4 {
            gate.whenAnswered("/tmp/game", ask: { done in asked += 1; finish = done }) { answers.append($0) }
        }
        XCTAssertEqual(asked, 1)
        finish?(true)
        XCTAssertEqual(answers, [true, true, true, true])
        XCTAssertTrue(gate.isApproved("/tmp/game/"))
    }

    func testTrustPromptIsAnsweredOnlyForApprovedAgentsAndNotTwiceInARow() {
        let gate = StartupGate()
        let mine = UUID(), other = UUID()
        gate.trustOnStart(mine)
        let now = Date()
        XCTAssertTrue(gate.shouldAnswerTrust(mine, now: now))
        XCTAssertFalse(gate.shouldAnswerTrust(mine, now: now.addingTimeInterval(1)))
        XCTAssertTrue(gate.shouldAnswerTrust(mine, now: now.addingTimeInterval(4)))
        XCTAssertFalse(gate.shouldAnswerTrust(other, now: now))
    }

    func testStartInAnUntrustedFolderAsksOnceAndStartsNothingOnNo() {
        let (store, sumi) = fixture()
        let folder = untrustedFolder()
        var asked = 0
        store.confirmHandler = { _, _, done in
            asked += 1
            DispatchQueue.main.async { done(false) }
        }
        let replied = expectation(description: "both replies")
        replied.expectedFulfillmentCount = 2
        var errors: [String] = []
        for _ in 0..<2 {
            ControlHandler(store: store, caller: .session(sumi.id.uuidString)).handle(start(folder)) {
                errors.append($0.error ?? "")
                replied.fulfill()
            }
        }
        wait(for: [replied], timeout: 3)
        XCTAssertEqual(asked, 1, "one question for the folder")
        XCTAssertEqual(errors.count, 2)
        XCTAssertTrue(errors.allSatisfy { $0.hasPrefix("the user didn't trust") })
        XCTAssertEqual(store.sessions.count, 1, "nothing started")
        XCTAssertFalse(store.startupGate.isApproved(folder))
    }

    func testPhoneModeAndAgentTurnsCantApproveTrust() {
        let (store, sumi) = fixture()
        let folder = untrustedFolder()
        store.setPhoneMode(true)
        var response: ControlResponse?
        let handler = ControlHandler(store: store, caller: .session(sumi.id.uuidString))
        handler.handle(start(folder)) { response = $0 }
        XCTAssertTrue(response?.error?.contains("call start_agent again with user_approved true") == true)

        var approved = start(folder)
        approved.userApproved = true
        sumi.turnFromUser = false
        handler.handle(approved) { response = $0 }
        XCTAssertTrue(response?.error?.contains("turn the user started") == true)
        XCTAssertFalse(store.startupGate.isApproved(folder))
        store.setPhoneMode(false)
    }

    // MARK: - Where a started agent got to

    func testStartupOutcomes() {
        let agent = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/w"), resume: false)
        let (store, _) = fixture([agent])
        XCTAssertNil(store.startupOutcome(agent), "still starting")
        agent.apply(.processStarted, source: "test", force: .working)
        XCTAssertEqual(store.startupOutcome(agent), .ready)
        agent.apply(.processStarted, source: "test", force: .needsInput(TerminalSession.startupScreenReason))
        XCTAssertEqual(store.startupOutcome(agent), .waiting(TerminalSession.startupScreenReason))
        agent.apply(.processStarted, source: "test", force: .needsInput(TerminalSession.trustReason))
        XCTAssertEqual(store.startupOutcome(agent), .waiting(TerminalSession.trustReason))
        store.startupGate.trustOnStart(agent.id)
        XCTAssertNil(store.startupOutcome(agent), "Tako is answering that trust prompt")
        agent.apply(.processStarted, source: "test", force: .exited(1))
        XCTAssertEqual(store.startupOutcome(agent), .exited("exit code 1"))
        store.close(agent)
        XCTAssertEqual(store.startupOutcome(agent), .exited("its terminal closed"))
    }

    func testAwaitStartupReportsEachAgentConcurrently() {
        let fast = TerminalSession(spec: LaunchSpec(label: "fast", kind: .claude, cwd: "/w"), resume: false)
        let dead = TerminalSession(spec: LaunchSpec(label: "dead", kind: .claude, cwd: "/w"), resume: false)
        let slow = TerminalSession(spec: LaunchSpec(label: "slow", kind: .claude, cwd: "/w"), resume: false)
        let (store, _) = fixture([fast, dead, slow])
        let done = expectation(description: "reported")
        var lines: [String] = []
        store.awaitStartup([fast, dead, slow], timeout: 0.6, poll: 0.05) {
            lines = $0
            done.fulfill()
        }
        fast.apply(.processStarted, source: "test", force: .idle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { store.close(dead) }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "@fast: ready")
        XCTAssertEqual(lines[1], "@dead: exited: its terminal closed")
        XCTAssertTrue(lines[2].hasPrefix("@slow: still starting after 1 s"))
    }

    func testTheReplyCarriesTheLastLinesOfAnAgentThatExited() {
        let text = SessionStore.describeStartup("help-docs-tool", .exited("exit code 1"),
                                                screen: "\nError: invalid settings\n  at ~/.claude/settings.json\n\n", waited: 25)
        XCTAssertEqual(text, "@help-docs-tool: exited: exit code 1\n    last lines: Error: invalid settings ⏎ at ~/.claude/settings.json")
    }

    // MARK: - Helpers

    private func fixture(_ agents: [TerminalSession] = []) -> (SessionStore, TerminalSession) {
        var spec = LaunchSpec(label: "sumi", kind: .claude, cwd: "/workspace")
        spec.sumi = true
        let sumi = TerminalSession(spec: spec, resume: false)
        sumi.apply(.processStarted, source: "test", force: .working)
        return (SessionStore(previewSessions: agents + [sumi], previewLayout: .focus), sumi)
    }

    /// A real folder no CLI was ever told to trust.
    private func untrustedFolder() -> String {
        let folder = NSTemporaryDirectory() + "untrusted-" + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: folder) }
        return folder
    }

    private func start(_ folder: String) -> ControlRequest {
        var request = ControlRequest(cmd: .new)
        request.kind = "claude"
        request.text = "build the game"
        request.cwd = folder
        return request
    }
}
