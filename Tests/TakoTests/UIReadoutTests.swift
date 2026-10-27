import XCTest
@testable import Tako

/// The data behind the standup, receipts, machine and worktree surfaces.
@MainActor
final class UIReadoutTests: XCTestCase {
    private func agent(_ label: String, state: AgentState) -> TerminalSession {
        let session = TerminalSession(spec: LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas"), resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }

    // MARK: - Standup

    func testStandupOrdersNeedsYouFailedWorkingDone() {
        let done = agent("done", state: .idle), working = agent("working", state: .working)
        let failed = agent("failed", state: .failed("hook crashed")), waiting = agent("waiting", state: .needsInput("Allow Bash?"))
        let exited = agent("exited", state: .exited(1))
        waiting.pendingRequest = "pnpm test"
        working.tasks = TaskProgress(subjects: ["a": "A", "b": "B"], completed: ["a"], order: ["a", "b"])
        working.usage = UsageSnapshot(costUSD: 1.5, contextPercent: 10, model: "Opus")
        let store = SessionStore(previewSessions: [done, working, failed, waiting, exited], previewLayout: .grid)

        let rows = store.standupRows()
        XCTAssertEqual(rows.map(\.label), ["waiting", "failed", "exited", "working", "done"])
        XCTAssertEqual(rows[0].blocker, "pnpm test")
        XCTAssertEqual(rows[1].blocker, "hook crashed")
        XCTAssertEqual(rows[2].blocker, "Exited with code 1")
        XCTAssertEqual(rows[3].todosDone, 1)
        XCTAssertEqual(rows[3].todosTotal, 2)
        XCTAssertEqual(rows[3].currentTodo, "B")
        XCTAssertEqual(rows[3].cost, 1.5)
        XCTAssertNil(rows[4].blocker)
    }

    func testCrashLoopingCountsAsFailed() {
        let looping = agent("looping", state: .starting)
        let store = SessionStore(previewSessions: [looping], previewLayout: .focus)
        let now = Date()
        for _ in 0...StartupHealth.loopExits { store.startupHealth.sawExit(looping.id, startedAt: now, at: now) }
        let row = store.standupRows(now: now)[0]
        XCTAssertEqual(row.group, .failed)
        XCTAssertTrue(row.crashLooping)
        XCTAssertTrue(row.blocker?.hasPrefix("Crash-looping") == true)
    }

    func testStandupTextIsUnchangedByTheStructuredRows() {
        let working = agent("working", state: .working)
        let store = SessionStore(previewSessions: [working], previewLayout: .focus)
        let text = store.describeStandup([working], git: [working.id: (DiffStat(added: 3, removed: 1, files: 2), 4)], now: Date())
        XCTAssertTrue(text.contains("@working [claude] working"), text)
        XCTAssertTrue(text.contains("+3 −1 · 2 files · 4 uncommitted"), text)
    }

    // MARK: - Sent messages

    func testSentMessagesFollowTheirOutcomeAndStaySettled() {
        let api = agent("api", state: .needsInput("Allow Bash?")), web = agent("web", state: .working)
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        api.store = store
        let framed = "Message from @web: rebase please"
        let reply = api.deliver(framed, from: "web")
        store.noteSent(reply, text: framed, preview: "rebase please", from: web, to: api)
        let id = api.queue.first?.id
        XCTAssertEqual(store.sentMessages.entries(for: "web").first?.outcome, .queued)
        XCTAssertEqual(store.sentMessages.entries(for: "web").first?.messageID, id)

        api.apply(.processStarted, source: "test", force: .idle)
        api.sendQueuedNow(at: 0)
        XCTAssertEqual(store.sentMessages.entries(for: "web").first?.outcome, .delivered)
        // A late "still waiting" doesn't undo a delivery.
        store.sentMessages.update(id ?? "", .stillWaiting)
        XCTAssertEqual(store.sentMessages.entries(for: "web").first?.outcome, .delivered)
    }

    func testSentMessagesReadEveryReplyShape() {
        let api = agent("api", state: .idle), web = agent("web", state: .working)
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        store.noteSent("delivered to @api", text: "x", preview: "x", from: web, to: api)
        store.noteSent("not delivered: @api has exited; restart it first", text: "y", preview: "y", from: web, to: api)
        store.noteSent("sent to @api (channel)", text: "z", preview: "z", from: web, to: api)
        let outcomes = store.sentMessages.entries(for: "web").map(\.outcome)
        XCTAssertEqual(outcomes, [.delivered, .dropped("@api has exited; restart it first"), .channelUnconfirmed])
    }

    func testSentMessageLogIsBounded() {
        let log = SentMessageLog()
        for index in 0..<(SentMessageLog.perSender + 5) {
            log.record(.init(messageID: "m\(index)", target: "api", preview: "", sentAt: Date(), outcome: .queued, updatedAt: Date()), from: "web")
        }
        XCTAssertEqual(log.entries(for: "web").count, SentMessageLog.perSender)
        XCTAssertEqual(log.entries(for: "web").first?.messageID, "m5")
        // An evicted message's outcome finds nothing to change.
        log.update("m0", .delivered)
        XCTAssertFalse(log.entries(for: "web").contains { $0.messageID == "m0" })
        for sender in 0..<(SentMessageLog.senders + 3) {
            log.record(.init(messageID: nil, target: "api", preview: "", sentAt: Date(), outcome: .delivered, updatedAt: Date()), from: "s\(sender)")
        }
        XCTAssertLessThanOrEqual(log.bySender.count, SentMessageLog.senders)
    }

    // MARK: - Worktree decisions

    func testJanitorDecisionsSayWhatAndWhy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unmerged = WorkAtRisk(uncommitted: 0, unmerged: 2)
        let clean = WorkAtRisk(uncommitted: 0, unmerged: 0)
        XCTAssertEqual(WorktreeJanitor.decision(.init(inUse: true), usedBy: "x", now: now).text, "kept: in use by @x")
        XCTAssertEqual(WorktreeJanitor.decision(.init(dirty: true, risk: unmerged), now: now).text, "kept: uncommitted changes")
        let young = WorktreeJanitor.decision(.init(risk: unmerged, idleSince: now.addingTimeInterval(-86400)), now: now)
        XCTAssertEqual(young.kind, .kept)
        XCTAssertTrue(young.text.hasPrefix("kept: unmerged work (archives after 7 days, on "), young.text)
        XCTAssertEqual(WorktreeJanitor.decision(.init(risk: clean), now: now).text, "archives next pass: nothing left to lose")
        let old = WorktreeJanitor.decision(.init(risk: unmerged, idleSince: now.addingTimeInterval(-8 * 86400)), now: now)
        XCTAssertEqual(old.kind, .archives)
        XCTAssertEqual(WorktreeJanitor.decision(.init(lock: .held(42)), now: now).text, "kept: locked by running pid 42")
        let stale = WorktreeJanitor.decision(.init(lock: .stale(7), dirty: true), now: now)
        XCTAssertEqual(stale.text, "kept: uncommitted changes; stale lock (pid 7 gone) is cleared next pass")
    }

    func testRecentJanitorActionsKeepArchivesAndClearedLocks() {
        let line = { (text: String, ago: TimeInterval) in
            LoggedEvent(date: Date().addingTimeInterval(-ago), kind: "gc", session: nil, text: text, fields: [:])
        }
        let events = [line("kept ~/a: it has uncommitted work", 30), line("archived ~/b (nothing left to lose): done", 20),
                      line("unlocked ~/c: its lock's pid 9 is gone", 10)]
        let recent = WorktreeJanitor.recentActions(since: .distantPast, events: events)
        XCTAssertEqual(recent.map(\.text), ["lock cleared: ~/c: its lock's pid 9 is gone", "archived ~/b (nothing left to lose): done"])
    }

    // MARK: - Machine

    func testFootprintTrendReadsTheHourlyLines() {
        let reading = { (bytes: Double) in
            LoggedEvent(date: Date(), kind: "footprint", session: nil, text: "", fields: ["footprint": NSNumber(value: bytes)])
        }
        let trend = MachineReadout.trend([reading(Double(400 << 20)), reading(Double(900 << 20))], now: 1200 << 20)
        XCTAssertEqual(trend, MachineReadout.Trend(start: 400 << 20, peak: 1200 << 20, growing: true))
        XCTAssertNil(MachineReadout.trend([], now: 1))
    }
}
