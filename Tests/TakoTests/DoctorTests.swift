import XCTest
@testable import Tako

/// `ht doctor` and Sumi's doctor tool: the report, its thresholds and who may ask.
@MainActor
final class DoctorTests: XCTestCase {
    // MARK: - Doctor

    func testDoctorChecksTheChannelsRegistration() {
        let ht = "/Applications/Tako.app/Contents/Resources/bin/ht"
        func config(_ servers: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: ["mcpServers": servers]) }
        XCTAssertEqual(Doctor.channels(enabled: false, claudeConfig: nil, htPath: ht), .off)
        XCTAssertEqual(Doctor.channels(enabled: true, claudeConfig: config(["tako": ["command": ht, "args": ["mcp"]]]), htPath: ht), .registered)
        XCTAssertEqual(Doctor.channels(enabled: true, claudeConfig: nil, htPath: ht), .missing)
        XCTAssertEqual(Doctor.channels(enabled: true, claudeConfig: config([:]), htPath: ht), .missing)
        guard case .wrong(let old) = Doctor.channels(enabled: true, claudeConfig: config(["hyperterm": ["command": ht, "args": ["mcp"]]]), htPath: ht),
              case .wrong(let other) = Doctor.channels(enabled: true, claudeConfig: config(["tako": ["command": "/old/ht", "args": ["mcp"]]]), htPath: ht),
              case .wrong(let notMCP) = Doctor.channels(enabled: true, claudeConfig: config(["tako": ["command": "npx", "args": ["x"]]]), htPath: ht)
        else { return XCTFail("each misregistration is called out") }
        XCTAssertTrue(old.contains("hyperterm"), old)
        XCTAssertTrue(other.contains("/old/ht"), other)
        XCTAssertTrue(notMCP.contains("npx x"), notMCP)
    }

    func testAHealthyDoctorIsAllTicks() {
        var snapshot = Doctor.Snapshot()
        snapshot.uptime = 26 * 3600
        snapshot.footprint = 700 << 20
        snapshot.notifications = (3, 9)
        snapshot.agents = [("api", "claude", false), ("web", "codex", true)]
        snapshot.helpers = ["api": 3, "web": 1]
        snapshot.channels = .registered
        let now = snapshot.now
        let events = [
            LoggedEvent(date: now.addingTimeInterval(-20 * 3600), kind: "launch", session: nil, text: "Tako started", fields: [:]),
            LoggedEvent(date: now.addingTimeInterval(-10 * 3600), kind: "footprint", session: nil, text: "",
                        fields: ["footprint": 600 << 20, "notified": 10, "suppressed": 40]),
            LoggedEvent(date: now.addingTimeInterval(-3600), kind: "gc", session: "api", text: "archived worktree", fields: [:]),
            LoggedEvent(date: now.addingTimeInterval(-60), kind: "message", session: "api", text: "m1 delivered", fields: ["outcome": "delivered"]),
        ]
        let report = Doctor.report(snapshot, events: events)
        let lines = report.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Tako doctor · up 1d"), report)
        XCTAssertFalse(report.contains("\n! "), report)
        XCTAssertTrue(report.contains("✓ notifications: 13 sent, 49 suppressed"), "the hourly lines plus the hour so far: \(report)")
        XCTAssertTrue(report.contains("✓ launches: 1; no leftover processes"), report)
        XCTAssertTrue(report.contains("✓ footprint 700 MB (24 h: 600 MB → 700 MB"), report)
        XCTAssertTrue(report.contains("✓ agents: 2 live (1 claude, 1 codex), 1 asleep"), report)
        XCTAssertTrue(report.contains("✓ MCP helpers: 1–3 per agent, 4 in all"), report)
        XCTAssertTrue(report.contains("✓ browser (CEF): not started"), report)
        XCTAssertTrue(report.contains("✓ channels: on, registered as tako"), report)
        XCTAssertTrue((12...30).contains(lines.count), "\(lines.count) lines")
    }

    func testDoctorFlagsWhatNeedsALook() {
        var snapshot = Doctor.Snapshot()
        snapshot.footprint = 1800 << 20
        snapshot.crashLooping = ["web"]
        snapshot.helpers = ["api": 14, "web": 2]
        snapshot.idleWorktrees = [snapshot.now.addingTimeInterval(-9 * 86_400)]
        snapshot.channels = .missing
        snapshot.browser = (true, 5, 400 << 20)
        let now = snapshot.now
        func event(_ kind: String, _ text: String, _ fields: [String: Any] = [:], hoursAgo: Double) -> LoggedEvent {
            LoggedEvent(date: now.addingTimeInterval(-hoursAgo * 3600), kind: kind, session: "web", text: text, fields: fields)
        }
        let events = [
            event("hook", "answered 408 Request Timeout", hoursAgo: 30),  // outside the day
            event("launch", "Tako started", hoursAgo: 23),
            event("sweep", "stopped leftover node pid 1", hoursAgo: 23),
            event("sweep", "stopped leftover node pid 2", hoursAgo: 23),
            event("footprint", "", ["footprint": 900 << 20], hoursAgo: 22),
            event("hook", "answered 408 Request Timeout", hoursAgo: 5),
            event("hook", "answered 408 Request Timeout", hoursAgo: 4),
            event("hook", "answered 400 Bad Request", hoursAgo: 3),
            event("launch", "Tako started", hoursAgo: 2),
            event("message", "m4 dropped", ["outcome": "dropped"], hoursAgo: 1),
            event("message", "c9 not confirmed", ["outcome": "not confirmed"], hoursAgo: 1),
            event("gc", "skipped worktrees: couldn't list processes' folders", hoursAgo: 1),
            event("footprint", "passed 1536 MB", ["footprint": 1600 << 20, "breakdown": ["tags_mb": ["MALLOC_SMALL": 600]]], hoursAgo: 0.5),
        ]
        let report = Doctor.report(snapshot, events: events)
        XCTAssertTrue(report.contains("! hooks: 3 rejected or timed out (2× 408 Request Timeout, 1× 400 Bad Request)"), report)
        XCTAssertTrue(report.contains("! messages: 0 delivered from a queue or channel, 1 dropped (@web), 1 channel pushes not confirmed"), report)
        XCTAssertTrue(report.contains("! launches: 2; leftovers stopped per launch: 2, 0"), report)
        XCTAssertTrue(report.contains("! gc: 1 action, 1 not done"), report)
        XCTAssertTrue(report.contains("! footprint \(Doctor.size(1800 << 20)) (24 h: 900 MB → "), report)
        XCTAssertTrue(report.contains("), growing; breakdown in events.jsonl"), report)
        XCTAssertTrue(report.contains("! agents: 0 live; CRASH-LOOPING: @web"), report)
        XCTAssertTrue(report.contains("! MCP helpers: @api 14 (over 8; others ≤ 2)"), report)
        XCTAssertTrue(report.contains("✓ browser (CEF): running, 5 processes, 400 MB"), report)
        XCTAssertTrue(report.contains("! worktrees: 1 unused"), report)
        XCTAssertTrue(report.contains("! channels: on, but ~/.claude.json has no \"tako\" server"), report)
    }

    func testHtDoctorAnswersTheUserAndSumiButNotOtherAgents() throws {
        let api = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        api.apply(.processStarted, source: "test", force: .idle)
        var spec = LaunchSpec(label: "sumi", kind: .claude, cwd: "/workspace")
        spec.sumi = true
        let sumi = TerminalSession(spec: spec, resume: false)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        api.store = store
        sumi.store = store

        func ask(_ caller: CallerIdentity) -> ControlResponse? {
            let replied = expectation(description: "reply")
            var response: ControlResponse?
            ControlHandler(store: store, caller: caller).handle(ControlRequest(cmd: .doctor)) { response = $0; replied.fulfill() }
            wait(for: [replied], timeout: 10)
            return response
        }
        let user = try XCTUnwrap(ask(.external))
        XCTAssertTrue(user.ok)
        XCTAssertTrue(user.text?.hasPrefix("Tako doctor") ?? false, user.text ?? "")
        XCTAssertTrue(user.text?.contains("agents: 2 live") ?? false, user.text ?? "")
        XCTAssertTrue(try XCTUnwrap(ask(.session(sumi.id.uuidString))).ok)
        XCTAssertFalse(try XCTUnwrap(ask(.session(api.id.uuidString))).ok, "a worker agent has no need for it")
    }
}
