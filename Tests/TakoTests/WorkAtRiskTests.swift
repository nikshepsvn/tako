import XCTest
@testable import Tako

final class WorkAtRiskTests: XCTestCase {
    private var root = ""
    private var tree = ""

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "risk-" + UUID().uuidString
        root = base + "/repo"
        tree = base + "/agent"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        git(root, "init", "-b", "main")
        write(root, "a.txt", "one\n")
        git(root, "add", "-A")
        commit(root, "first")
        git(root, "worktree", "add", "-b", "tako/agent", tree)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    func testFreshWorktreeHasNothingAtRisk() {
        XCTAssertEqual(WorkAtRisk.evaluate(at: tree, base: "main"), WorkAtRisk(uncommitted: 0, unmerged: 0))
    }

    func testUncommittedFilesCount() {
        write(tree, "b.txt", "new\n")
        write(tree, "a.txt", "changed\n")
        XCTAssertEqual(WorkAtRisk.evaluate(at: tree, base: "main"), WorkAtRisk(uncommitted: 2, unmerged: 0))
    }

    func testCommitsNotInBaseCount() {
        write(tree, "b.txt", "new\n")
        git(tree, "add", "-A")
        commit(tree, "work")
        XCTAssertEqual(WorkAtRisk.evaluate(at: tree, base: "main"), WorkAtRisk(uncommitted: 0, unmerged: 1))
    }

    func testMergedWorkIsNotAtRisk() {
        write(tree, "b.txt", "new\n")
        git(tree, "add", "-A")
        commit(tree, "work")
        git(root, "merge", "--no-ff", "-m", "merge", "tako/agent")
        XCTAssertEqual(WorkAtRisk.evaluate(at: tree, base: "main"), WorkAtRisk(uncommitted: 0, unmerged: 0))
    }

    func testSquashMergedWorkIsNotAtRisk() {
        for name in ["b.txt", "c.txt"] {
            write(tree, name, "x\n")
            git(tree, "add", "-A")
            commit(tree, "add \(name)")
        }
        git(root, "merge", "--squash", "tako/agent")
        commit(root, "squashed")
        XCTAssertEqual(WorkAtRisk.evaluate(at: tree, base: "main")?.unmerged, 0)
    }

    func testOnlyWorkAddedAfterASquashMergeIsAtRisk() {
        write(tree, "b.txt", "x\n")
        git(tree, "add", "-A")
        commit(tree, "add b")
        git(root, "merge", "--squash", "tako/agent")
        commit(root, "squashed")
        write(tree, "c.txt", "later\n")
        git(tree, "add", "-A")
        commit(tree, "add c")
        XCTAssertEqual(WorkAtRisk.evaluate(at: tree, base: "main")?.unmerged, 1)
    }

    func testMissingFolderCantBeChecked() {
        XCTAssertNil(WorkAtRisk.evaluate(at: tree + "-gone", base: "main"))
    }

    func testHeadlineNamesWhatIsAtRisk() {
        XCTAssertEqual(WorkAtRisk(uncommitted: 3, unmerged: 0).headline(base: "main"), "3 files aren't committed")
        XCTAssertEqual(WorkAtRisk(uncommitted: 0, unmerged: 1).headline(base: "main"), "1 commit isn't in main yet")
        XCTAssertEqual(WorkAtRisk(uncommitted: 1, unmerged: 2).headline(base: nil),
                       "1 file isn't committed and 2 commits aren't in the base branch yet")
    }

    func testArchiveSavesUncommittedWorkOnTheBranchWithoutForce() {
        // Archive snapshots uncommitted work onto the branch first, so the folder can go without --force.
        write(tree, "b.txt", "keep me\n")
        XCTAssertNoThrow(try Review.archive(worktree: tree, mainRoot: root).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree))
        let kept = runGit(["-C", root, "show", "tako/agent:b.txt"])
        XCTAssertEqual(kept, "keep me")
    }

    // MARK: - helpers

    private func write(_ dir: String, _ name: String, _ text: String) {
        try? text.write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func commit(_ dir: String, _ message: String) {
        git(dir, "-c", "commit.gpgsign=false", "commit", "-m", message)
    }

    @discardableResult
    private func git(_ dir: String, _ args: String...) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir] + args
        process.environment = ProcessInfo.processInfo.environment.merging([
            "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        ]) { _, new in new }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
