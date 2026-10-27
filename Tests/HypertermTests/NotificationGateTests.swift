import UserNotifications
import XCTest
@testable import Hyperterm

/// Fewer, better banners: once per turn per kind, none for what the user sees, bursts as one.
@MainActor
final class NotificationGateTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func item(_ id: UUID, _ label: String, _ kind: NotificationGate.Kind) -> NotificationGate.Item {
        NotificationGate.Item(sessionID: id, label: label, kind: kind, title: "@\(label)", body: kind.rawValue)
    }

    func testTheSameKindOncePerTurn() {
        var gate = NotificationGate()
        guard case .deliver = gate.offer(item(a, "api", .finished), now: start) else { return XCTFail() }
        XCTAssertEqual(gate.offer(item(a, "api", .finished), now: start + 60), .drop)
        gate.turnStarted(a)
        guard case .deliver = gate.offer(item(a, "api", .finished), now: start + 120) else { return XCTFail("new turn") }
        // Agents whose turns Tako can't see still get one after a long quiet.
        guard case .deliver = gate.offer(item(a, "api", .finished), now: start + 120 + NotificationGate.repeatInterval) else { return XCTFail() }
    }

    func testNeedsYouStaysTimelyButDoesNotFlap() {
        var gate = NotificationGate()
        guard case .deliver = gate.offer(item(a, "api", .needsYou), now: start) else { return XCTFail() }
        XCTAssertEqual(gate.offer(item(a, "api", .needsYou), now: start + 2), .drop)
        guard case .deliver = gate.offer(item(a, "api", .needsYou), now: start + 30) else { return XCTFail("a new wait in the same turn") }
    }

    func testABurstBecomesOneBanner() {
        var gate = NotificationGate()
        guard case .deliver = gate.offer(item(a, "api", .needsYou), now: start) else { return XCTFail() }
        XCTAssertEqual(gate.offer(item(b, "web", .needsYou), now: start + 1), .hold(until: start + NotificationGate.burstWindow))
        _ = gate.offer(item(c, "docs", .needsYou), now: start + 2)
        let delivery = gate.flush(now: start + 5)
        XCTAssertEqual(delivery?.title, "2 agents need you")
        XCTAssertEqual(delivery?.body, "@web needs you · @docs needs you")
        XCTAssertEqual(delivery?.sessionID, b)
        XCTAssertNil(gate.flush(now: start + 6))

        var mixed = NotificationGate()
        _ = mixed.offer(item(a, "api", .finished), now: start)
        _ = mixed.offer(item(b, "web", .finished), now: start + 1)
        _ = mixed.offer(item(c, "docs", .needsYou), now: start + 1)
        let both = mixed.flush(now: start + 5)
        XCTAssertEqual(both?.title, "2 agents need your attention")
        XCTAssertEqual(both?.sessionID, c, "a click opens the one that's waiting")
    }

    func testOneHeldBannerGoesOutAsItself() {
        var gate = NotificationGate()
        _ = gate.offer(item(a, "api", .finished), now: start)
        _ = gate.offer(item(b, "web", .failed), now: start + 1)
        XCTAssertEqual(gate.flush(now: start + 5), NotificationGate.Delivery(sessionID: b, title: "@web", body: "failed", count: 1))
    }

    func testTheNotifierSkipsSessionsInViewAndNeverReachesNotificationCenterInTests() {
        let notifier = AttentionNotifier()
        XCTAssertTrue(notifier.sink is RecordingNotificationSink, "the test host must not post real banners")
        let sink = RecordingNotificationSink()
        let watched = AttentionNotifier(sink: sink)
        let seen = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/tmp"), resume: false)
        let hidden = TerminalSession(spec: LaunchSpec(label: "web", kind: .claude, cwd: "/tmp"), resume: false)
        watched.isLooking = { $0 === seen }
        watched.post(session: seen, title: "@api finished", body: "done", foreground: true, kind: .finished)
        watched.postApproval(session: seen, request: "rm -rf build", alwaysRule: nil)
        XCTAssertTrue(sink.requests.isEmpty)
        watched.post(session: hidden, title: "@web needs you", body: "question", foreground: true, kind: .needsYou)
        XCTAssertEqual(sink.requests.map(\.content.title), ["@web needs you"])
    }
}
