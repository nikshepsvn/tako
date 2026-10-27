import XCTest
@testable import Hyperterm

/// hooks.log and events.jsonl: rotate rather than wipe, and keep no payloads.
final class RotatingLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rotating-log-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }

    func testRotatesKeepingTwoOlderFilesInsteadOfTruncating() {
        let log = RotatingLog(url: directory.appendingPathComponent("hooks.log"), maxBytes: 100, keep: 2)
        for index in 0..<12 { log.append(String(format: "line %02d %@", index, String(repeating: "x", count: 30))) }
        log.flush()
        let current = read(log.url), first = read(log.rotated(1)), second = read(log.rotated(2))
        XCTAssertTrue(current.contains("line 11"), current)
        XCTAssertFalse(first.isEmpty)
        XCTAssertFalse(second.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.rotated(3).path))
        XCTAssertEqual(log.rotated(1).lastPathComponent, "hooks.1.log")
        // Nothing is ever cut mid-line and the newest stretch is complete.
        for text in [current, first, second] { XCTAssertTrue(text.hasSuffix("\n")) }
        XCTAssertLessThanOrEqual(current.utf8.count, 100)
    }

    func testHookLinesAreCompactAndCarryNoContent() {
        let json: [String: Any] = [
            "hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": "0123456789abcdef",
            "tool_input": ["command": "cat ~/.ssh/id_rsa"], "tool_response": ["stdout": "SECRET"],
        ]
        let line = HookLog.line(date: Date(timeIntervalSince1970: 0), source: "claude", sessionID: "S1", json: json, bytes: 1_500)
        XCTAssertEqual(line, "1970-01-01T00:00:00Z claude S1 PostToolUse tool=Bash agent=01234567 bytes=1500")
        let prompt = HookLog.line(date: Date(timeIntervalSince1970: 0), source: "claude", sessionID: "S1",
                                  json: ["hook_event_name": "UserPromptSubmit", "prompt": "my password is hunter2"], bytes: 80)
        XCTAssertTrue(prompt.hasSuffix("UserPromptSubmit bytes=80 prompt=22c"), prompt)
        XCTAssertTrue(HookLog.line(date: Date(), source: "claude", sessionID: nil, json: [:], bytes: 9).hasSuffix("- unparsed bytes=9"))
    }

    func testEventLinesAreJSON() throws {
        let line = try XCTUnwrap(EventLog.line(date: Date(timeIntervalSince1970: 0), kind: "gc", session: "api",
                                               text: "pruned 3", fields: ["count": 3]))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "gc")
        XCTAssertEqual(object["session"] as? String, "api")
        XCTAssertEqual(object["count"] as? Int, 3)
        XCTAssertEqual(object["t"] as? String, "1970-01-01T00:00:00Z")
    }

    func testTheTestHostWritesNoLogsToTheRealHome() {
        XCTAssertTrue(TestHost.isActive)
        XCTAssertNil(HookLog.log)
        XCTAssertNil(EventLog.log)
    }
}
