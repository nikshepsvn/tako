import XCTest
@testable import Tako

final class CodexUsageTests: XCTestCase {
    private let event = #"""
    {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":25840},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":14.0,"window_minutes":10080,"resets_at":1791634371},"secondary":{"used_percent":42.5,"window_minutes":300,"resets_at":1791600000},"rate_limit_reached_type":null}}}
    """#

    func testReadsContextAndSortsWindowsByLength() throws {
        let log = #"{"type":"session_meta","payload":{}}"# + "\n" + event + "\n" + #"{"type":"response_item","payload":{}}"#
        let reading = try XCTUnwrap(CodexUsage.latest(in: log[...]))
        XCTAssertEqual(reading.contextPercent ?? 0, 10, accuracy: 0.01)
        // The weekly window came as "primary" here; it still lands in the weekly slot.
        XCTAssertEqual(reading.limits?.sevenDayPercent, 14)
        XCTAssertEqual(reading.limits?.fiveHourPercent, 42.5)
        XCTAssertEqual(reading.limits?.sevenDayResets, Date(timeIntervalSince1970: 1791634371))
        XCTAssertFalse(reading.limitReached)
    }

    func testFlagsAReachedLimit() throws {
        let reached = event.replacingOccurrences(of: #""rate_limit_reached_type":null"#, with: #""rate_limit_reached_type":"primary""#)
        XCTAssertTrue(try XCTUnwrap(CodexUsage.latest(in: reached[...])).limitReached)
    }

    func testFindsTheThreadLog() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let old = root.appendingPathComponent("sessions/2025/01/02")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        let file = old.appendingPathComponent("rollout-2025-01-02T00-00-00-abc-123.jsonl")
        try Data(event.utf8).write(to: file)
        // Older than the recent-days window, so this exercises the full walk.
        XCTAssertEqual(CodexUsage.logFile(thread: "abc-123", in: root)?.lastPathComponent, file.lastPathComponent)
        XCTAssertNil(CodexUsage.logFile(thread: "missing", in: root))
        XCTAssertNotNil(CodexUsage.tail(of: file).flatMap { CodexUsage.latest(in: $0) })
    }
}
