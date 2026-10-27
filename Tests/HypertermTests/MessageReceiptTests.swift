import XCTest
@testable import Hyperterm

/// A queued message says plainly that it isn't delivered, and its sender hears how it ended.
@MainActor
final class MessageReceiptTests: XCTestCase {
    private func agent(_ label: String, sumi: Bool = false, state: AgentState) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if sumi { spec.sumi = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }

    func testAQueuedMessageSaysItIsNotDeliveredAndCarriesAnID() {
        let api = agent("api", state: .needsInput("Allow Bash?"))
        let store = SessionStore(previewSessions: [api], previewLayout: .focus)
        let reply = api.deliver("Message from @web: rebase please", from: "web")
        XCTAssertTrue(reply.hasPrefix("Queued (message m"), reply)
        XCTAssertTrue(reply.contains("NOT delivered yet; @api is busy at a prompt"), reply)
        XCTAssertTrue(reply.contains("You'll be told when it lands"), reply)
        XCTAssertEqual(api.queue.first?.sender, "web")
        XCTAssertTrue(reply.contains(api.queue.first?.id ?? "?"))
        // The user's own sends keep their short form.
        XCTAssertTrue(api.deliver("hi", from: nil).hasPrefix("queued: @api"))
        _ = store
    }

    func testSumiHearsWhenItsQueuedMessageLandsOrIsDropped() {
        let api = agent("api", state: .needsInput("Allow Bash?")), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        api.store = store
        _ = api.deliver("Message from @sumi: run the tests", from: "sumi")
        _ = api.deliver("Message from @sumi: then push", from: "sumi")
        let ids = api.queue.map(\.id)

        api.apply(.processStarted, source: "test", force: .idle)
        api.sendQueuedNow(at: 0)
        api.removeQueued(at: 0)
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))

        let report = sumi.pendingMessages.joined(separator: "\n")
        XCTAssertTrue(report.contains("your message \(ids[0]) reached @api"), report)
        XCTAssertTrue(report.contains("your message \(ids[1]) to @api was NOT delivered (the user removed it from the queue)"), report)
        XCTAssertTrue(api.queue.isEmpty)
    }

    func testOtherSendersGetOneDebouncedReceiptWhenTheTargetCloses() {
        let api = agent("api", state: .needsInput("Allow Bash?")), web = agent("web", state: .needsInput("Allow Edit?"))
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        api.store = store
        _ = api.deliver("Message from @web: one", from: "web")
        _ = api.deliver("Message from @web: two", from: "web")

        store.messagesDropped(from: api, reason: "@api was closed")
        XCTAssertEqual(store.messageReceipts.pending["web"]?.count, 2)
        store.sendReceipts(to: "web")

        XCTAssertEqual(web.pendingMessages.count, 1, "one receipt for the burst")
        let receipt = web.pendingMessages.first ?? ""
        XCTAssertTrue(receipt.hasPrefix("Tako: your message m"), receipt)
        XCTAssertEqual(receipt.components(separatedBy: "was NOT delivered (@api was closed)").count, 3, receipt)
    }

    func testMessagesStillQueuedAfterAnHourExpire() {
        let api = agent("api", state: .needsInput("Allow Bash?")), web = agent("web", state: .needsInput("Allow Edit?"))
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        api.store = store
        _ = api.deliver("Message from @web: one", from: "web")
        XCTAssertEqual(api.queue.count, 1)
        api.expireQueued(now: Date().addingTimeInterval(TerminalSession.queuedMessageExpiry - 60))
        XCTAssertEqual(api.queue.count, 1)
        api.expireQueued(now: Date().addingTimeInterval(TerminalSession.queuedMessageExpiry + 1))
        XCTAssertTrue(api.queue.isEmpty)
        XCTAssertTrue(store.messageReceipts.pending["web"]?.first?.contains("still queued after 60 min") == true)
    }
}
