import XCTest
@testable import Tako

/// The hourly footprint line, the one breakdown per run, and the notification counts it carries.
@MainActor
final class FootprintTrendTests: XCTestCase {
    // MARK: - Notifications and footprint

    func testTheNotifierCountsWhatItShowsAndWhatItHoldsBack() {
        let notifier = AttentionNotifier(sink: RecordingNotificationSink())
        let api = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/w"), resume: false)
        let now = Date()
        notifier.post(session: api, title: "@api finished", body: "done", foreground: true, kind: .finished, now: now)
        notifier.post(session: api, title: "@api finished", body: "done", foreground: true, kind: .finished, now: now.addingTimeInterval(1))
        notifier.isLooking = { _ in true }
        notifier.post(session: api, title: "@api failed", body: "x", foreground: true, kind: .failed, now: now.addingTimeInterval(60))
        XCTAssertEqual(notifier.counts.sent, 1)
        XCTAssertEqual(notifier.counts.suppressed, 2)
        XCTAssertEqual(notifier.takeCounts().sent, 1)
        XCTAssertEqual(notifier.counts.sent + notifier.counts.suppressed, 0, "taking the counts starts new ones")
    }

    func testTheFootprintIsLoggedHourlyAndBrokenDownOncePerRun() {
        var trend = FootprintTrend()
        let start = Date()
        XCTAssertEqual(trend.update(600 << 20, now: start), FootprintTrend.Due(log: true, breakdown: false), "the run's baseline")
        XCTAssertEqual(trend.update(600 << 20, now: start.addingTimeInterval(59)), FootprintTrend.Due())
        XCTAssertEqual(trend.update(1600 << 20, now: start.addingTimeInterval(120)), FootprintTrend.Due(log: false, breakdown: true))
        XCTAssertEqual(trend.update(1000 << 20, now: start.addingTimeInterval(180)), FootprintTrend.Due())
        XCTAssertEqual(trend.update(1700 << 20, now: start.addingTimeInterval(3600)), FootprintTrend.Due(log: true, breakdown: false),
                       "crossing again in the same run is not another breakdown")
        let fields = FootprintTrend.fields(footprint: 1, sessions: 4, uptime: 7200.6, notifications: (2, 5))
        XCTAssertEqual(fields["sessions"] as? Int, 4)
        XCTAssertEqual(fields["uptime_s"] as? Int, 7200)
        XCTAssertEqual(fields["suppressed"] as? Int, 5)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(fields))
    }

    func testTheBreakdownIsTakenInProcessAndFitsOnALogLine() throws {
        let started = Date()
        let breakdown = MemoryBreakdown.capture()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "one bounded pass")
        let vm = try XCTUnwrap(breakdown["vm_mb"] as? [String: Int])
        XCTAssertGreaterThan(vm["footprint"] ?? 0, 0)
        let tags = try XCTUnwrap(breakdown["tags_mb"] as? [String: Int])
        XCTAssertFalse(tags.isEmpty)
        XCTAssertLessThanOrEqual(tags.count, 12)
        XCTAssertNotNil(breakdown["zones_mb"] as? [String: Int])
        let line = try XCTUnwrap(EventLog.line(date: Date(), kind: "footprint", session: nil, text: "breakdown",
                                               fields: ["breakdown": breakdown]))
        XCTAssertLessThan(line.utf8.count, 4000, line)
        XCTAssertEqual(MemoryBreakdown.tagName(51), "CoreAnimation")
        XCTAssertEqual(MemoryBreakdown.tagName(999), "tag 999")
    }
}
