import XCTest
@testable import Tako

/// The morning briefing (`standup since`), startup health, crash loops, and the events they read.
@MainActor
final class AwarenessTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("aware-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        EventLog.log?.flush()
        EventLog.log = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - since

    func testSinceTakesLastADurationOrAnISOTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let last = now.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(Briefing.start("last", last: last, now: now), last)
        XCTAssertEqual(Briefing.start("last", last: nil, now: now), now.addingTimeInterval(-Briefing.defaultLookback),
                       "no standup on record: the last 8 hours")
        XCTAssertEqual(Briefing.start("8h", last: nil, now: now), now.addingTimeInterval(-8 * 3600))
        XCTAssertEqual(Briefing.start("90m", last: nil, now: now), now.addingTimeInterval(-90 * 60))
        XCTAssertEqual(Briefing.start(" 2d ", last: nil, now: now), now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(Briefing.start("2027-01-15T08:00:00Z", last: nil, now: now), ISO8601DateFormatter().date(from: "2027-01-15T08:00:00Z"))
        XCTAssertNotNil(Briefing.start("2027-01-15T08:00", last: nil, now: now), "local time without a zone")
        XCTAssertNil(Briefing.start("yesterday-ish", last: nil, now: now))
        XCTAssertEqual(Briefing.start("90d", last: nil, now: now), now.addingTimeInterval(-Briefing.maxLookback),
                       "never further back than the log reaches")
    }

    // MARK: - Briefing

    func testBriefingSummarizesTheNightInAFewLines() {
        let now = Date()
        let since = now.addingTimeInterval(-8 * 3600)
        func event(_ kind: String, _ session: String?, _ text: String, _ fields: [String: Any] = [:], minutesAgo: Double = 60) -> LoggedEvent {
            LoggedEvent(date: now.addingTimeInterval(-minutesAgo * 60), kind: kind, session: session, text: text, fields: fields)
        }
        let events = [
            event("agent", "api", "started", ["action": "started"]),
            event("agent", "web", "started", ["action": "started"]),
            event("agent", "web", "restarted", ["action": "restarted"]),
            event("agent", "web", "exited with code 1", ["action": "exited", "code": 1]),
            event("agent", "docs", "exited", ["action": "exited", "code": 0]),
            event("plan", "api", "api done", ["task": "api", "status": "done"]),
            event("plan", "web", "web failed", ["task": "web", "status": "failed"]),
            event("approval", "api", "phone-mode: Bash", ["outcome": "phone-mode"]),
            event("approval", "api", "approved: Bash", ["outcome": "approved", "by": "auto"]),
            event("approval", "web", "approved: Edit", ["outcome": "approved"]),
            event("approval", "web", "released: Bash", ["outcome": "released"]),
            event("message", "api", "m1 delivered", ["outcome": "delivered"]),
            event("message", "docs", "m2 dropped", ["outcome": "dropped"]),
            event("message", "api", "c3 not confirmed", ["outcome": "not confirmed"]),
            event("escalation", "web", "@web uses 5 GB", ["what": "memory"]),
        ]
        var live = Briefing.Live()
        live.finished = [("api", 4, "added pagination to /orders"), ("web", 1, nil)]
        live.waitingOnUser = ["web"]
        live.queued = [("api", 2)]
        let text = Briefing.describe(since: since, now: now, events: events, live: live)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("Since "), text)
        XCTAssertTrue(lines[0].contains("8h ago"), text)
        XCTAssertLessThanOrEqual(lines.count, 25, "bounded for a phone")
        XCTAssertTrue(text.contains("started 2: @api, @web; restarted 1: @web"), text)
        XCTAssertTrue(text.contains("finished 5 turns: @api 4, @web 1"), text)
        XCTAssertTrue(text.contains("added pagination"), text)
        XCTAssertTrue(text.contains("FAILED or exited 1: @web exited with code 1"), "a clean exit isn't a failure: \(text)")
        XCTAssertTrue(text.contains("plan: 1 done (api), 1 failed (web)"), text)
        XCTAssertTrue(text.contains("approvals: 2 auto-answered, 1 answered, 1 left to the CLI's own prompt; WAITING on the user now: @web"), text)
        XCTAssertTrue(text.contains("messages: 1 delivered, 1 NOT delivered (@docs), 1 channel pushes not confirmed"), text)
        XCTAssertTrue(text.contains("2 still queued (@api 2)"), text)
        XCTAssertTrue(text.contains("steward: 1 escalation (@web)"), text)
    }

    func testAQuietNightSaysSo() {
        let now = Date()
        let text = Briefing.describe(since: now.addingTimeInterval(-3600), now: now, events: [], live: Briefing.Live())
        XCTAssertEqual(text.split(separator: "\n").count, 2)
        XCTAssertTrue(text.hasSuffix("- nothing happened"))
    }

    func testStandupSinceLeadsWithTheBriefingAndRemembersWhenItRan() {
        let (store, api, _) = fixture()
        api.record(.done, "fixed the flaky checkout test")
        XCTAssertNil(store.sumiBrain.lastStandup)
        let done = expectation(description: "standup")
        var reply = ""
        store.standup(since: "last") { reply = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(reply.hasPrefix("Since "), reply)
        XCTAssertTrue(reply.contains("finished 1 turn: @api 1"), reply)
        XCTAssertTrue(reply.contains("@api [claude]"), "the usual standup follows: \(reply)")
        XCTAssertNotNil(store.sumiBrain.lastStandup, "the next since:\"last\" starts here")

        let again = expectation(description: "standup again")
        store.standup(since: "whenever") { reply = $0; again.fulfill() }
        wait(for: [again], timeout: 5)
        XCTAssertTrue(reply.hasPrefix("since: couldn't read \"whenever\""), reply)

        let plain = expectation(description: "plain standup")
        store.standup { reply = $0; plain.fulfill() }
        wait(for: [plain], timeout: 5)
        XCTAssertFalse(reply.contains("Since "), "no briefing unless asked: \(reply)")
    }

    func testTheLastStandupSurvivesARestart() {
        let first = SumiBrain(directory: directory)
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        first.lastStandup = at
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("organizer-standup.json").path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(SumiBrain(directory: directory).lastStandup, at)
    }

    // MARK: - Events, end to end

    func testLifecycleAndPlanEventsReachTheLogAndReadBack() {
        EventLog.log = RotatingLog(url: directory.appendingPathComponent("events.jsonl"), maxBytes: 1_000_000)
        let (store, api, _) = fixture()
        let before = Date().addingTimeInterval(-1)
        store.recordAgentStart(api, restarted: false)
        _ = store.planCommand(["action": "add", "tasks": [["id": "api", "title": "Build the API", "owner": "api"]]])
        api.apply(.processStarted, source: "test", force: .working)
        api.apply(.processStarted, source: "test", force: .idle)
        api.apply(.processStarted, source: "test", force: .exited(2))
        let events = EventLog.read(since: before)
        XCTAssertEqual(events.filter { $0.kind == "agent" }.map { $0.string("action") ?? "" }, ["started", "exited"])
        XCTAssertEqual(events.first { $0.kind == "agent" && $0.string("action") == "exited" }?.int("code"), 2)
        XCTAssertEqual(events.filter { $0.kind == "plan" }.map { $0.string("status") ?? "" }, ["done"])
        XCTAssertTrue(EventLog.read(since: Date().addingTimeInterval(60)).isEmpty, "nothing after since")
    }

    func testReadingBackSpansRotatedFilesAndSkipsGarbage() throws {
        let log = RotatingLog(url: directory.appendingPathComponent("events.jsonl"), maxBytes: 400)
        let now = Date()
        for index in 0..<12 {
            log.append(EventLog.line(date: now.addingTimeInterval(Double(index - 12) * 60), kind: "gc", session: nil,
                                     text: "archived worktree \(index)", fields: ["n": index]) ?? "")
        }
        log.append("not json")
        log.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.rotated(1).path), "the test needs a rotation")
        let all = EventLog.read(since: now.addingTimeInterval(-3600), from: log)
        XCTAssertEqual(all.map { $0.int("n") ?? -1 }, Array(all.map { $0.int("n") ?? -1 }).sorted(), "oldest first")
        XCTAssertEqual(all.last?.int("n"), 11)
        let recent = EventLog.read(since: now.addingTimeInterval(-3.5 * 60), from: log)
        XCTAssertEqual(recent.map { $0.int("n") ?? -1 }, [9, 10, 11])
    }

    // MARK: - Startup health

    func testThreeQuickExitsAreACrashLoopButSlowOnesAreNot() {
        var health = StartupHealth()
        let id = UUID()
        let start = Date()
        for minute in [2.0, 9, 15] {
            health.sawExit(id, startedAt: start.addingTimeInterval((minute - 1) * 60), at: start.addingTimeInterval(minute * 60))
        }
        XCTAssertTrue(health.isCrashLooping(id, now: start.addingTimeInterval(16 * 60)))
        XCTAssertFalse(health.isCrashLooping(id, now: start.addingTimeInterval(3 * 3600)), "an old loop is over")

        var slow = StartupHealth()
        for hour in 1...4 { slow.sawExit(id, startedAt: start, at: start.addingTimeInterval(Double(hour) * 3600)) }
        XCTAssertFalse(slow.isCrashLooping(id, now: start.addingTimeInterval(4 * 3600)), "exits long after starting aren't a loop")

        var two = StartupHealth()
        two.sawExit(id, startedAt: start, at: start.addingTimeInterval(60))
        two.sawExit(id, startedAt: start, at: start.addingTimeInterval(120))
        XCTAssertFalse(two.isCrashLooping(id, now: start.addingTimeInterval(180)), "more than two")
    }

    func testStandupFlagsACrashLoopAndAStartThatNeverReachedItsPrompt() {
        let (store, api, _) = fixture(apiState: .starting)
        api.apply(.processStarted, source: "test", force: .exited(1))
        var line = store.describeStandup([api], git: [:], now: Date())
        XCTAssertTrue(line.contains("startup failed: exited with code 1 before reaching its prompt"), line)
        XCTAssertFalse(line.contains("CRASH-LOOPING"), line)
        for _ in 0..<2 {
            api.apply(.processStarted, source: "test", force: .idle)
            api.apply(.processStarted, source: "test", force: .exited(1))
        }
        line = store.describeStandup([api], git: [:], now: Date())
        XCTAssertTrue(line.contains("CRASH-LOOPING: exited 3× within 10 min of starting"), line)
        XCTAssertFalse(line.contains("startup failed"), "it reached its prompt on this start: \(line)")
    }

    func testAHealthyAgentAddsNothingToStandup() {
        let (store, api, _) = fixture()
        api.apply(.processStarted, source: "test", force: .idle)
        let line = store.describeStandup([api], git: [:], now: Date())
        XCTAssertFalse(line.contains("startup"), line)
        XCTAssertFalse(line.contains("CRASH"), line)
    }

    // MARK: - Fixture

    private func fixture(apiState: AgentState = .working) -> (SessionStore, TerminalSession, TerminalSession) {
        let api = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        if apiState != .starting { api.apply(.processStarted, source: "test", force: apiState) }
        var spec = LaunchSpec(label: "sumi", kind: .claude, cwd: "/workspace")
        spec.sumi = true
        let sumi = TerminalSession(spec: spec, resume: false)
        sumi.apply(.processStarted, source: "test", force: .idle)
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        api.store = store
        sumi.store = store
        return (store, api, sumi)
    }
}
