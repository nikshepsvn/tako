import XCTest
@testable import Hyperterm

/// Sumi's finished events carry the agent's whole closing message, bounded and on one line.
@MainActor
final class FinalReplyTests: XCTestCase {
    func testShortRepliesArriveWholeOnOneLine() {
        let reply = "## Done\n\nAdded **/orders**.\n- Tests pass\n```swift\nlet x = 1\n```\nNext: wire the UI."
        XCTAssertEqual(FinalReply.excerpt(reply), "Done / Added /orders. / - Tests pass / [code] / Next: wire the UI.")
        XCTAssertNil(FinalReply.excerpt("\n  \n"))
    }

    func testLongRepliesKeepTheOpeningAndTheConclusion() throws {
        let middle = Array(repeating: "filler words here", count: 200).joined(separator: " ")
        let reply = "Summary: migrated the database. " + middle + " Verdict: ship it, all 431 tests pass."
        let excerpt = try XCTUnwrap(FinalReply.excerpt(reply))
        XCTAssertLessThanOrEqual(excerpt.count, FinalReply.limit)
        XCTAssertGreaterThan(excerpt.count, FinalReply.limit - 40)
        XCTAssertTrue(excerpt.hasPrefix("Summary: migrated the database."))
        XCTAssertTrue(excerpt.hasSuffix("Verdict: ship it, all 431 tests pass."), excerpt)
        XCTAssertTrue(excerpt.contains(" … "))
        XCTAssertFalse(excerpt.contains("filler words he …"), "cuts fall on word boundaries")
    }

    func testTheFinishedEventCarriesTheWholeReplyNotItsFirstLine() {
        let api = agent("api", state: .idle), sumi = agent("sumi", sumi: true, state: .needsInput("busy"))
        let store = SessionStore(previewSessions: [api, sumi], previewLayout: .grid)
        let reply = "Added the /orders endpoint with pagination and validation, covering every edge case the spec lists.\n\nTwo things for you: the rate limiter needs a Redis URL, and @web should switch to the new response shape."
        store.applyHook(source: "claude", session: api, json: ["hook_event_name": "Stop", "last_assistant_message": reply], sentAt: nil)
        store.sumiWatches[api.id] = ""

        store.reportToSumi(api, from: .working)
        store.flushSumiDigest(now: Date().addingTimeInterval(SumiDigest.window))

        let report = sumi.pendingMessages.first ?? ""
        XCTAssertTrue(report.contains("@web should switch to the new response shape."), report)
        XCTAssertFalse(report.contains("\n"))
    }

    func testManyFinishesShareTheDigestBudget() {
        let long = String(repeating: "word ", count: 600)
        let events = (0..<10).map { SumiEvent(label: "a\($0)", kind: .finished(long)) }
        let message = SumiDigest.message(events)
        XCTAssertLessThan(message.count, FinalReply.digestBudget + 10 * 60)
        XCTAssertEqual(FinalReply.share(of: 2), FinalReply.limit)
        XCTAssertEqual(FinalReply.share(of: 30), FinalReply.floor)
    }

    private func agent(_ label: String, sumi: Bool = false, state: AgentState) -> TerminalSession {
        var spec = LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas")
        if sumi { spec.sumi = true }
        let session = TerminalSession(spec: spec, resume: false)
        session.apply(.processStarted, source: "test", force: state)
        return session
    }
}
