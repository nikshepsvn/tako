import XCTest
@testable import Tako

/// Checkpoint refs of sessions gone for good are pruned; live, reopenable and recent ones stay.
final class CheckpointJanitorTests: XCTestCase {
    private let now = Date()
    private let week: TimeInterval = 7 * 24 * 3600

    private func makeRepository() throws -> String {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("checkpoints-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let root = folder.path
        for arguments in [["init", "-q", "-b", "main"], ["commit", "-q", "--allow-empty", "-m", "first"]] {
            _ = try XCTUnwrap(Git.run(arguments, at: root, environment: Git.identity))
        }
        return root
    }

    func testCheckpointListingAndStaleness() {
        let listing = """
        refs/kuronami/aaa/0001-start\t100
        refs/kuronami/aaa/0001-end\t300
        refs/kuronami/bbb/undo\t200
        refs/heads/main\t999
        """
        let found = CheckpointJanitor.sessions(inListing: listing)
        XCTAssertEqual(found, ["aaa": Date(timeIntervalSince1970: 300), "bbb": Date(timeIntervalSince1970: 200)])
        let later = Date(timeIntervalSince1970: 300 + week)
        XCTAssertEqual(CheckpointJanitor.stale(found, keep: [], now: later), ["aaa", "bbb"])
        XCTAssertEqual(CheckpointJanitor.stale(found, keep: ["aaa"], now: later), ["bbb"])
        XCTAssertEqual(CheckpointJanitor.stale(found, keep: [], now: Date(timeIntervalSince1970: 250 + week)), ["bbb"])
    }

    func testCheckpointCollectionKeepsKnownAndRecentSessions() throws {
        let root = try makeRepository()
        for session in ["gone", "kept", "fresh"] {
            Checkpoints.capture(at: root, session: session, turn: 1, phase: .start, prompt: "task")
        }
        var lines: [String] = []
        CheckpointJanitor.collect(roots: [root], keep: ["kept"], now: now) { line, _ in lines.append(line) }
        XCTAssertEqual(Checkpoints.turns(at: root, session: "gone").count, 1, "younger than a week: another Tako's, maybe")
        XCTAssertTrue(lines.isEmpty)

        CheckpointJanitor.collect(roots: [root], keep: ["kept"], now: now.addingTimeInterval(week + 60)) { line, _ in lines.append(line) }
        XCTAssertTrue(Checkpoints.turns(at: root, session: "gone").isEmpty)
        XCTAssertTrue(Checkpoints.turns(at: root, session: "fresh").isEmpty)
        XCTAssertEqual(Checkpoints.turns(at: root, session: "kept").count, 1)
        XCTAssertEqual(lines.count, 1)
    }
}
