import Foundation
import XCTest
@testable import Tako

final class CheckpointTests: XCTestCase {
    private var repo: String!
    private let session = "B9C1A0F2-0000-4000-8000-000000000001"

    override func setUpWithError() throws {
        repo = NSTemporaryDirectory() + "kuronami-checkpoints-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertNotNil(Git.run(["init", "-q", "-b", "main"], at: repo))
        try write("README.md", "hello\n")
        try write(".gitignore", "secret.env\n")
        XCTAssertNotNil(Git.run(["add", "-A"], at: repo))
        XCTAssertNotNil(Git.run(["commit", "-q", "-m", "first"], at: repo, environment: Git.identity))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: repo)
    }

    private func write(_ name: String, _ text: String) throws {
        let url = URL(fileURLWithPath: repo).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOfFile: (repo as NSString).appendingPathComponent(name), encoding: .utf8)
    }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (repo as NSString).appendingPathComponent(name))
    }

    func testSnapshotLeavesIndexAndHeadAlone() throws {
        try write("README.md", "changed\n")
        try write("new.txt", "new\n")
        let head = Git.run(["rev-parse", "HEAD"], at: repo)
        let status = Git.run(["status", "--porcelain"], at: repo)
        XCTAssertNotNil(Checkpoints.snapshot(at: repo, message: "x"))
        XCTAssertEqual(Git.run(["rev-parse", "HEAD"], at: repo), head)
        XCTAssertEqual(Git.run(["status", "--porcelain"], at: repo), status)
        XCTAssertEqual(Git.run(["stash", "list"], at: repo), "")
    }

    func testTurnsRecordStartAndEndInOrder() throws {
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "add a feature")
        try write("feature.swift", "let x = 1\n")
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .end, prompt: "add a feature")
        Checkpoints.capture(at: repo, session: session, turn: 2, phase: .start, prompt: "now test it")
        let turns = Checkpoints.turns(at: repo, session: session)
        XCTAssertEqual(turns.map(\.index), [1, 2])
        XCTAssertEqual(turns[0].prompt, "add a feature")
        XCTAssertNotNil(turns[0].end)
        XCTAssertNil(turns[1].end)
        XCTAssertEqual(Checkpoints.nextTurn(at: repo, session: session), 3)
    }

    func testTurnDiffShowsOnlyThatTurn() throws {
        try write("before.txt", "earlier work\n")
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        try write("feature.swift", "let x = 1\n")
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .end, prompt: "one")
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)
        XCTAssertEqual(Checkpoints.changedFiles(at: repo, from: turn.start, to: turn.end), ["feature.swift"])
        XCTAssertTrue(Checkpoints.diff(at: repo, from: turn.start, to: turn.end).contains("+let x = 1"))
    }

    func testDiffAgainstTheLiveWorkspace() throws {
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        try write("README.md", "hello\nmore\n")
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)
        let objects = (Git.run(["count-objects", "-v"], at: repo) ?? "")
        XCTAssertEqual(Checkpoints.changedFiles(at: repo, from: turn.start, to: nil), ["README.md"])
        XCTAssertTrue(Checkpoints.diff(at: repo, from: turn.start, to: nil).contains("+more"))
        XCTAssertEqual(Git.run(["count-objects", "-v"], at: repo), objects, "comparing writes nothing into the repository")
    }

    func testRestoreRevertsEditsRemovesNewFilesAndKeepsIgnored() throws {
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        try write("README.md", "agent rewrote this\n")
        try write("src/deep/new.swift", "new\n")
        try write("secret.env", "TOKEN=1\n")
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)

        guard case .success(let undo) = Checkpoints.restore(at: repo, to: turn.start, session: session) else {
            return XCTFail("restore failed")
        }
        XCTAssertEqual(read("README.md"), "hello\n")
        XCTAssertFalse(exists("src/deep/new.swift"))
        XCTAssertFalse(exists("src"), "empty folders the agent created go too")
        XCTAssertEqual(read("secret.env"), "TOKEN=1\n", "ignored files are never touched")
        XCTAssertEqual(Checkpoints.undoPoint(at: repo, session: session), undo)

        // The restore itself can be undone.
        _ = Checkpoints.restore(at: repo, to: undo, session: session)
        XCTAssertEqual(read("README.md"), "agent rewrote this\n")
        XCTAssertEqual(read("src/deep/new.swift"), "new\n")
    }

    func testRestoreOnlyRewritesFilesThatDiffer() throws {
        try write("untouched.txt", "same\n")
        XCTAssertNotNil(Git.run(["add", "-A"], at: repo))
        XCTAssertNotNil(Git.run(["commit", "-q", "-m", "second"], at: repo, environment: Git.identity))
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        let untouched = (repo as NSString).appendingPathComponent("untouched.txt")
        let past = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: untouched)
        try write("README.md", "changed\n")
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)
        _ = Checkpoints.restore(at: repo, to: turn.start, session: session)
        XCTAssertEqual(read("README.md"), "hello\n")
        let modified = try FileManager.default.attributesOfItem(atPath: untouched)[.modificationDate] as? Date
        XCTAssertEqual(modified, past, "files that didn't change aren't rewritten")
    }

    func testRestoreWorksFromASubfolder() throws {
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        try write("src/a.swift", "new\n")
        try write("README.md", "changed\n")
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)
        let sub = (repo as NSString).appendingPathComponent("src")
        _ = Checkpoints.restore(at: sub, to: turn.start, session: session)
        XCTAssertEqual(read("README.md"), "hello\n")
        XCTAssertFalse(exists("src/a.swift"))
    }

    func testRestoreHandlesNamesGitWouldQuote() throws {
        try write("café.txt", "before\n")
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        try write("café.txt", "after\n")
        try write("naïve new.txt", "new\n")
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)
        XCTAssertEqual(Set(Checkpoints.changedFiles(at: repo, from: turn.start, to: nil)), ["café.txt", "naïve new.txt"])
        guard case .success = Checkpoints.restore(at: repo, to: turn.start, session: session) else { return XCTFail("restore failed") }
        XCTAssertEqual(read("café.txt"), "before\n")
        XCTAssertFalse(exists("naïve new.txt"))
    }

    func testRevertLeavesOtherAgentsFilesAlone() throws {
        let other = "B9C1A0F2-0000-4000-8000-000000000002"
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "mine")
        try write("mine.swift", "mine\n")
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .end, prompt: "mine")
        // Another agent in the same folder edits meanwhile.
        Checkpoints.capture(at: repo, session: other, turn: 1, phase: .start, prompt: "theirs")
        try write("README.md", "theirs\n")
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)
        let scope = Checkpoints.touched(at: repo, session: session, from: 1)
        XCTAssertEqual(scope, ["mine.swift"])
        _ = Checkpoints.restore(at: repo, to: turn.start, session: session, only: scope)
        XCTAssertFalse(exists("mine.swift"))
        XCTAssertEqual(read("README.md"), "theirs\n", "the other agent's edit survives")

        // Undo touches only what the revert changed.
        try write("README.md", "theirs, later\n")
        let undo = try XCTUnwrap(Checkpoints.undoPoint(at: repo, session: session))
        _ = Checkpoints.restore(at: repo, to: undo, session: session, only: Checkpoints.undoScope(at: repo, session: session))
        XCTAssertEqual(read("mine.swift"), "mine\n")
        XCTAssertEqual(read("README.md"), "theirs, later\n")
    }

    func testRestoreLeavesIndexAlone() throws {
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        try write("README.md", "staged change\n")
        XCTAssertNotNil(Git.run(["add", "README.md"], at: repo))
        let turn = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first)
        _ = Checkpoints.restore(at: repo, to: turn.start, session: session)
        XCTAssertEqual(Git.run(["diff", "--cached", "--name-only"], at: repo), "README.md")
    }

    func testPruneRemovesASessionsRefs() {
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "one")
        Checkpoints.prune(at: repo, session: session)
        XCTAssertTrue(Checkpoints.turns(at: repo, session: session).isEmpty)
    }

    func testOutsideARepositoryNothingHappens() throws {
        let plain = NSTemporaryDirectory() + "kuronami-plain-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: plain) }
        XCTAssertNil(Checkpoints.capture(at: plain, session: session, turn: 1, phase: .start, prompt: "x"))
        XCTAssertEqual(Checkpoints.restore(at: plain, to: "HEAD", session: session).failureValue, .notARepository)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
