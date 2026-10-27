import Darwin
import XCTest
@testable import Tako

/// Launch lines, agent browser tabs, and the heavy-job queue: fixes found before release.
final class ReleaseFixesLaunchTests: XCTestCase {
    // MARK: Tasks never become flags

    func testFlagShapedTaskStaysThePromptForClaude() {
        let spec = LaunchSpec(label: "fix", kind: .claude, cwd: "/tmp")
        let input = AgentIntegration.initialInput(for: spec, resume: false, task: "--dangerously-skip-permissions") ?? ""
        XCTAssertTrue(input.hasSuffix(" -- '--dangerously-skip-permissions'\n"), input)
    }

    func testFlagShapedTaskStaysThePromptForCodex() {
        let spec = LaunchSpec(label: "fix", kind: .codex, cwd: "/tmp")
        let input = AgentIntegration.initialInput(for: spec, resume: false, task: "--dangerously-bypass-approvals-and-sandbox") ?? ""
        XCTAssertTrue(input.hasSuffix(" -- '--dangerously-bypass-approvals-and-sandbox'\n"), input)
    }

    func testUserArgumentsComeBeforeTheSeparator() {
        var spec = LaunchSpec(label: "fix", kind: .claude, cwd: "/tmp")
        spec.command = "--verbose"
        let input = AgentIntegration.initialInput(for: spec, resume: false, task: "go") ?? ""
        XCTAssertTrue(input.hasSuffix(" --verbose -- 'go'\n"), input)
    }

    func testNoTaskMeansNoSeparator() {
        for kind in [SessionKind.claude, .codex] {
            let spec = LaunchSpec(label: "fix", kind: kind, cwd: "/tmp")
            let input = AgentIntegration.initialInput(for: spec, resume: false) ?? ""
            XCTAssertFalse(input.contains(" -- "), input)
            XCTAssertFalse((AgentIntegration.initialInput(for: spec, resume: false, task: "") ?? "").contains(" -- "))
        }
    }

    // MARK: Agent tabs open pages only

    func testBrowserAllowListRefusesScripts() {
        for raw in ["javascript:alert(1)", "data:text/html,<script>alert(1)</script>", "chrome://settings"] {
            XCTAssertFalse(BrowserTarget.isAllowed(URL(string: raw)!), raw)
        }
        for raw in ["https://example.com", "http://localhost:3000", "file:///tmp/a.html"] {
            XCTAssertTrue(BrowserTarget.isAllowed(URL(string: raw)!), raw)
        }
    }

    // MARK: Heavy queue

    func testSamePidAcquiringTwiceTakesOneSlot() {
        var queue = HeavyQueue(capacity: 2)
        var granted: [pid_t] = []
        queue.acquire(31) { granted.append(31) }
        queue.acquire(31) { granted.append(31) }
        XCTAssertEqual(granted, [31, 31])
        XCTAssertEqual(queue.holders, [31])
        queue.acquire(32) { granted.append(32) }
        XCTAssertEqual(queue.holders, [31, 32], "the second slot is still free for someone else")
    }

    func testSamePidWaitingTwiceIsOneWait() {
        var queue = HeavyQueue(capacity: 1)
        var granted: [String] = []
        queue.acquire(41) { granted.append("41") }
        queue.acquire(42) { granted.append("42a") }
        queue.acquire(42) { granted.append("42b") }
        XCTAssertEqual(queue.waiting, 1)
        queue.release(41)
        XCTAssertEqual(granted, ["41", "42a", "42b"])
        XCTAssertEqual(queue.holders, [42])
    }

    func testChildOfHolderIsGrantedWithoutASlot() {
        var queue = HeavyQueue(capacity: 1)
        var granted: [pid_t] = []
        queue.acquire(51) { granted.append(51) }
        // `ht heavy make` (51) runs `ht heavy cc` (53, via 52): no deadlock, no second slot.
        queue.acquire(53, ancestors: [52, 51]) { granted.append(53) }
        XCTAssertEqual(granted, [51, 53])
        XCTAssertEqual(queue.holders, [51])
        XCTAssertEqual(queue.waiting, 0)
        // Someone outside the job still waits.
        queue.acquire(54, ancestors: [1]) { granted.append(54) }
        XCTAssertEqual(queue.waiting, 1)
        queue.release(53)   // the child's release frees nothing it didn't take
        XCTAssertEqual(queue.holders, [51])
        queue.release(51)
        XCTAssertEqual(granted, [51, 53, 54])
    }

    func testAncestorsStartWithTheParent() {
        let parent = getppid()
        guard parent > 1 else { return }
        XCTAssertEqual(HeavyQueue.ancestors(of: getpid()).first, parent)
        XCTAssertFalse(HeavyQueue.ancestors(of: getpid()).contains(1))
    }
}
