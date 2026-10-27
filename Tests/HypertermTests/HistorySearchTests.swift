import XCTest
@testable import Hyperterm

/// session_history's query, for "find the session that was looking at the SSD".
final class HistorySearchTests: XCTestCase {
    private var root = URL(fileURLWithPath: "/")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testTakosOwnNotesMatchFirst() {
        var spec = LaunchSpec(label: "disk-check", kind: .claude, cwd: "/Users/me/Code/ops")
        spec.summary = "Checked the external SSD's SMART health; all good"
        var budget = 1000
        let found = HistorySearch.search([candidate(spec, transcript: nil)], query: "ssd health", limit: 5, budget: &budget)
        XCTAssertEqual(found.map(\.field), ["summary"])
        XCTAssertTrue(found[0].snippet.contains("SSD"))
        XCTAssertEqual(budget, 1000, "no transcript read when the notes already match")
    }

    func testTranscriptsAreSearchedWhenTheNotesDontMatch() throws {
        let file = try transcript("a1", cwd: "/Users/me/Code/ops", prompt: "why is /Volumes/SSD mounting read-only?",
                                  reply: "The SSD's volume is APFS-encrypted and locked.")
        let spec = LaunchSpec(label: "alpha", kind: .claude, cwd: "/Users/me/Code/ops")
        let other = LaunchSpec(label: "bravo", kind: .claude, cwd: "/Users/me/Code/web")
        var budget = 10_000_000
        let found = HistorySearch.search([candidate(other, transcript: nil), candidate(spec, transcript: file)],
                                         query: "SSD read-only", limit: 5, budget: &budget)
        XCTAssertEqual(found.map(\.spec.label), ["alpha"])
        XCTAssertEqual(found.first?.field, "transcript")
        XCTAssertTrue(found.first?.snippet.contains("/Volumes/SSD mounting read-only") == true)
    }

    func testTheReadBudgetBoundsTheScan() throws {
        let file = try transcript("a1", cwd: "/w", prompt: "look at the ssd", reply: "ok")
        var budget = 0
        let found = HistorySearch.search([candidate(LaunchSpec(label: "a", kind: .claude, cwd: "/w"), transcript: file)],
                                         query: "ssd", limit: 5, budget: &budget)
        XCTAssertTrue(found.isEmpty)
    }

    func testConversationsTakoNeverRanAreFoundWithTheirFolder() throws {
        _ = try transcript("old-1", cwd: "/Users/me/Volumes", prompt: "list what's on the SSD", reply: "Here")
        _ = try transcript("known-2", cwd: "/Users/me/Code/ops", prompt: "the SSD again", reply: "Yes")
        _ = try transcript("other-3", cwd: "/Users/me/Code/web", prompt: "fix the navbar", reply: "Done")
        var budget = 10_000_000
        let found = HistorySearch.searchLoose(projects: root.appendingPathComponent("projects"), query: "ssd",
                                              skip: ["known-2"], limit: 5, budget: &budget)
        XCTAssertEqual(found.map(\.conversation), ["old-1"])
        XCTAssertEqual(found.first?.folder, "/Users/me/Volumes")
    }

    func testTheReplySaysHowToReopenEach() {
        var spec = LaunchSpec(label: "disk-check", kind: .claude, cwd: "/Users/me/Code/ops")
        spec.summary = "SSD"
        let now = Date()
        let text = ControlHandler.describeSearch(
            query: "ssd",
            matches: [HistorySearch.Match(spec: spec, field: "summary", snippet: "SSD")],
            loose: [HistorySearch.LooseMatch(conversation: "old-1", folder: "/tmp/x", modified: now, snippet: "the SSD")],
            now: now)
        XCTAssertTrue(text.hasPrefix("Closed sessions matching \"ssd\""))
        XCTAssertTrue(text.contains("@disk-check [claude] "))
        XCTAssertTrue(text.contains("reopen_session with conversation and folder"))
        XCTAssertTrue(text.contains("old-1 · /tmp/x"))
        XCTAssertEqual(ControlHandler.describeSearch(query: "zzz", matches: [], loose: []), "No past session mentions \"zzz\".")
    }

    func testSnippetCentersOnTheWord() {
        let text = String(repeating: "a", count: 300) + " SSD " + String(repeating: "b", count: 300)
        let snippet = HistorySearch.snippet(text, around: "ssd")
        XCTAssertTrue(snippet.hasPrefix("…") && snippet.hasSuffix("…") && snippet.contains("SSD"))
    }

    // MARK: - Helpers

    private func candidate(_ spec: LaunchSpec, transcript: URL?) -> HistorySearch.Candidate {
        HistorySearch.Candidate(spec: spec, kind: .claude) { transcript }
    }

    /// A Claude transcript with one prompt and one reply, as Claude writes them.
    private func transcript(_ id: String, cwd: String, prompt: String, reply: String) throws -> URL {
        let folder = root.appendingPathComponent("projects").appendingPathComponent(AgentTranscript.projectFolder(cwd))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            ["type": "user", "cwd": cwd, "message": ["role": "user", "content": prompt]],
            ["type": "assistant", "cwd": cwd, "message": ["role": "assistant", "content": [["type": "text", "text": reply]]]],
        ]
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let file = folder.appendingPathComponent("\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
