import Foundation
import XCTest
@testable import Tako

/// Diff parsing, review, worktree and checkpoint fixes, checked against real throwaway repositories.
final class ReleaseFixesGitTests: XCTestCase {
    private var base = ""
    private var repo = ""
    private let session = "C0FFEE00-0000-4000-8000-000000000002"

    override func setUpWithError() throws {
        base = NSTemporaryDirectory() + "release-fixes-" + UUID().uuidString
        repo = base + "/repo"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        XCTAssertNotNil(Git.run(["init", "-q", "-b", "main"], at: repo))
        try write(repo, "README.md", "hello\n")
        commitAll(repo, "first")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: base)
    }

    // MARK: - Diff lines that look like headers

    private let trickyPatch = """
    diff --git a/x.yml b/x.yml
    index 1111111..2222222 100644
    --- a/x.yml
    +++ b/x.yml
    @@ -1,4 +1,4 @@
     keep
    ----
    --- comment
    +++i;
    ++++
     tail
    \\ No newline at end of file
    diff --git a/y.txt b/y.txt
    index 3333333..4444444 100644
    --- a/y.txt
    +++ b/y.txt
    @@ -1 +1 @@
    -old
    +new
    """

    func testHunkContentThatLooksLikeHeadersIsKept() {
        let lines = PatchLine.parse(trickyPatch)
        XCTAssertEqual(lines.map(\.kind), [.header, .context, .removed, .removed, .added, .added, .context,
                                           .header, .removed, .added])
        XCTAssertEqual(lines.map(\.text), ["@@ -1,4 +1,4 @@", "keep", "---", "-- comment", "++i;", "+++", "tail",
                                           "@@ -1 +1 @@", "old", "new"])
        XCTAssertEqual(lines.map(\.newNumber), [nil, 1, nil, nil, 2, 3, 4, nil, nil, 1])
        XCTAssertEqual(lines[2].oldNumber, 2)
        XCTAssertEqual(lines[3].oldNumber, 3)
        XCTAssertEqual(lines[6].oldNumber, 4)
    }

    func testTurnCountsKeepHeaderLookingContent() {
        let files = Review.files(fromPatch: trickyPatch)
        XCTAssertEqual(files.map(\.path), ["x.yml", "y.txt"])
        XCTAssertEqual(files.map(\.added), [2, 1])
        XCTAssertEqual(files.map(\.removed), [2, 1])
    }

    func testRealGitDiffOfHeaderLookingLinesAgreesWithNumstat() throws {
        try write(repo, "x.yml", "keep\n---\n-- comment\ntail\n")
        commitAll(repo, "yaml")
        try write(repo, "x.yml", "keep\n++i;\n+++\ntail\n")
        let file = try XCTUnwrap(Review.fileDiffs(at: repo, base: nil, scope: .uncommitted).first { $0.path == "x.yml" })
        XCTAssertEqual(file.added, 2)
        XCTAssertEqual(file.removed, 2)
        let parsed = Review.files(fromPatch: file.patch)
        XCTAssertEqual(parsed.first?.added, 2)
        XCTAssertEqual(parsed.first?.removed, 2)
        let lines = PatchLine.parse(file.patch)
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["++i;", "+++"])
        XCTAssertEqual(lines.filter { $0.kind == .removed }.map(\.text), ["---", "-- comment"])
        XCTAssertEqual(lines.first { $0.text == "tail" }?.newNumber, 4)
    }

    func testBlankContextLinesFromSuppressBlankEmptyStillCount() {
        // With diff.suppressBlankEmpty, git writes a blank context line as "" instead of " ".
        let patch = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
        -one
        +uno

         three
        @@ -10,2 +10,2 @@
        -ten
        +diez
         eleven
        """
        let file = Review.files(fromPatch: patch).first
        XCTAssertEqual(file?.added, 2)
        XCTAssertEqual(file?.removed, 2)
        let lines = PatchLine.parse(patch)
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["uno", "diez"])
        XCTAssertEqual(lines.filter { $0.kind == .removed }.map(\.text), ["one", "ten"])
        // The blank line is shown, so "three" keeps its real line number.
        XCTAssertEqual(lines.first { $0.text == "three" }?.newNumber, 3)
        XCTAssertEqual(lines.filter { $0.kind == .context && $0.text.isEmpty }.map(\.newNumber), [2])
    }

    func testRealGitDiffWithSuppressBlankEmptyAgreesWithNumstat() throws {
        try write(repo, "b.txt", "one\n\nthree\n4\n5\n6\n7\n8\n9\nten\n")
        commitAll(repo, "b")
        XCTAssertNotNil(Git.run(["config", "diff.suppressBlankEmpty", "true"], at: repo))
        try write(repo, "b.txt", "uno\n\nthree\n4\n5\n6\n7\n8\n9\ndiez\n")
        let patch = try XCTUnwrap(Git.run(["diff", "-U1", "--", "b.txt"], at: repo))
        XCTAssertTrue(patch.contains("\n\n"), "expected git to write the blank context line as an empty line")
        let file = Review.files(fromPatch: patch).first
        XCTAssertEqual(file?.added, 2)
        XCTAssertEqual(file?.removed, 2)
    }

    // MARK: - Untracked files

    func testUntrackedFileCountsNoPhantomTrailingLine() throws {
        try write(repo, "new.txt", "a\nb\n")
        try write(repo, "open.txt", "a\nb")
        let diffs = Review.fileDiffs(at: repo, base: nil, scope: .branch)
        XCTAssertEqual(diffs.first { $0.path == "new.txt" }?.added, 2)
        XCTAssertEqual(diffs.first { $0.path == "open.txt" }?.added, 2)
        XCTAssertEqual(Review.diffStat(at: repo, base: nil)?.added, 4)
        let lines = PatchLine.parse(diffs.first { $0.path == "new.txt" }?.patch ?? "")
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.text), ["a", "b"])
        XCTAssertEqual(lines.filter { $0.kind == .added }.map(\.newNumber), [1, 2])
    }

    // MARK: - Test commands

    func testTestCommandMatchesRunners() {
        for command in ["pytest -q", "python -m pytest tests/", "npx jest --watch=false", "pnpm vitest run auth",
                        "go test ./...", "cargo test", "swift test --parallel", "npm test", "npm run test:unit",
                        "pnpm test", "yarn test", "bun test", "make test", "xcodebuild -scheme App test",
                        "cd web && npm test", "CI=1 ./node_modules/.bin/jest", "bundle exec rspec", "bunx vitest"] {
            XCTAssertTrue(TestCommand.matches(command), command)
        }
    }

    func testTestCommandIgnoresTheWordTest() {
        for command in ["ls tests/", "cat latest.log", "git commit -m \"add tests\"", "grep test", "git status",
                        "echo 'run pytest later'", "xcodebuild build", "npm install", "mkdir test"] {
            XCTAssertFalse(TestCommand.matches(command), command)
        }
    }

    func testTestCommandMatchesOtherToolchainsAndWrappers() {
        for command in ["./gradlew test", "gradle test", "mvn test", "./mvnw test", "dotnet test", "deno test", "mix test",
                        "rails test", "bundle exec rake test", "python -m unittest", "python3 -m unittest discover",
                        "python manage.py test", "npx playwright test", "flutter test", "dart test", "bazel test //...",
                        "ctest", "pnpm -r test", "pnpm --filter x test", "make -C dir test", "yarn workspace a test",
                        "timeout 600 npm test", "nohup npm test", "nice npm test", "npx --yes jest",
                        "bash -c \"npm test\"", "sh -c 'cd web && pnpm test'", "uv run pytest"] {
            XCTAssertTrue(TestCommand.matches(command), command)
        }
    }

    func testTestCommandWrappersDontMatchTheWordTest() {
        for command in ["echo test", "cd test", "bash -c \"ls tests/\"", "timeout 5 cat latest.log", "make -C test build",
                        "npx --yes eslint test", "python manage.py migrate", "python test_helpers.py",
                        "yarn workspace test build", "gradle build", "nohup grep test"] {
            XCTAssertFalse(TestCommand.matches(command), command)
        }
    }

    // MARK: - Detached HEAD

    func testDetachedHeadIsNotRecordedAsTheBaseBranch() {
        XCTAssertNotNil(Git.run(["checkout", "-q", "--detach"], at: repo))
        guard case .success(let spec) = Workspaces.prepare(spec: LaunchSpec(label: "detached", kind: .claude, cwd: repo)) else {
            return XCTFail("prepare failed")
        }
        XCTAssertNil(spec.baseBranch)
    }

    func testMergeRefusesHeadAsTarget() {
        XCTAssertNotNil(Git.run(["branch", "work"], at: repo))
        XCTAssertNotNil(Git.run(["checkout", "-q", "--detach"], at: repo))
        let head = Git.run(["rev-parse", "HEAD"], at: repo)
        guard case .failure = Review.merge(branch: "work", into: "HEAD", mainRoot: repo) else {
            return XCTFail("merged into a detached HEAD")
        }
        XCTAssertEqual(Git.run(["rev-parse", "HEAD"], at: repo), head)
    }

    // MARK: - Work at risk without a base

    func testMissingBaseIsNeverReportedAsSafe() throws {
        XCTAssertNotNil(Git.run(["branch", "-m", "main", "trunk"], at: repo))
        let tree = base + "/agent"
        XCTAssertNotNil(Git.run(["worktree", "add", "-q", "-b", "tako/agent", tree], at: repo))
        // A commit only this worktree's branch has.
        try write(tree, "work.txt", "work\n")
        commitAll(tree, "work")
        let risk = WorkAtRisk.evaluate(at: tree, base: "gone")
        XCTAssertEqual(risk?.baseUnknown, true)
        XCTAssertEqual(risk?.unmerged, 0)
        XCTAssertEqual(risk?.isEmpty, false)
        XCTAssertTrue(risk?.headline(base: "gone").contains("couldn't be compared") == true)
        // A base that resolves still compares as before.
        XCTAssertEqual(WorkAtRisk.evaluate(at: tree, base: "trunk"), WorkAtRisk(uncommitted: 0, unmerged: 1))
    }

    func testMissingBaseWithHeadOnAnotherBranchIsNotAtRisk() {
        XCTAssertNotNil(Git.run(["branch", "-m", "main", "develop"], at: repo))
        let tree = base + "/agent"
        XCTAssertNotNil(Git.run(["worktree", "add", "-q", "-b", "tako/agent", tree], at: repo))
        for missing in ["gone", "HEAD", nil] as [String?] {
            let risk = WorkAtRisk.evaluate(at: tree, base: missing)
            XCTAssertEqual(risk, WorkAtRisk(uncommitted: 0, unmerged: 0), String(describing: missing))
            XCTAssertEqual(risk?.isEmpty, true, String(describing: missing))
        }
    }

    // MARK: - Checkpoint pruning

    func testPruneRemovesRefsAndUndoScope() throws {
        Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "x")
        let start = try XCTUnwrap(Checkpoints.turns(at: repo, session: session).first?.start)
        try write(repo, "README.md", "changed\n")
        XCTAssertNoThrow(try Checkpoints.restore(at: repo, to: start, session: session).get())
        XCTAssertNotNil(Checkpoints.undoScope(at: repo, session: session))
        Checkpoints.prune(at: repo, session: session)
        XCTAssertNil(Checkpoints.undoScope(at: repo, session: session))
        XCTAssertNil(Checkpoints.undoPoint(at: repo, session: session))
        XCTAssertTrue(Checkpoints.turns(at: repo, session: session).isEmpty)
    }

    func testArchivedWorktreeCheckpointsPruneFromTheMainCheckout() throws {
        let tree = base + "/agent"
        XCTAssertNotNil(Git.run(["worktree", "add", "-q", "-b", "tako/agent", tree], at: repo))
        Checkpoints.capture(at: tree, session: session, turn: 1, phase: .start, prompt: "x")
        XCTAssertNotNil(Git.run(["worktree", "remove", "--force", tree], at: repo))
        XCTAssertEqual(Checkpoints.turns(at: repo, session: session).count, 1)
        Checkpoints.prune(at: repo, session: session)
        XCTAssertTrue(Checkpoints.turns(at: repo, session: session).isEmpty)
    }

    // MARK: - Archive surfaces a failed snapshot

    func testArchiveKeepsTheWorktreeWhenTheSnapshotFails() throws {
        let tree = base + "/agent"
        XCTAssertNotNil(Git.run(["worktree", "add", "-q", "-b", "tako/agent", tree], at: repo))
        try write(tree, "work.txt", "unsaved\n")
        // A held index lock makes `git add` fail.
        let gitDir = try XCTUnwrap(Git.run(["rev-parse", "--absolute-git-dir"], at: tree))
        let lock = (gitDir as NSString).appendingPathComponent("index.lock")
        XCTAssertTrue(FileManager.default.createFile(atPath: lock, contents: Data()))
        guard case .failure = Review.archive(worktree: tree, mainRoot: repo) else { return XCTFail("archived anyway") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree + "/work.txt"))
        try FileManager.default.removeItem(atPath: lock)
        XCTAssertNoThrow(try Review.archive(worktree: tree, mainRoot: repo).get())
        XCTAssertEqual(Git.run(["show", "tako/agent:work.txt"], at: repo), "unsaved")
    }

    func testReviewCommitCommits() throws {
        try write(repo, "a.txt", "a\n")
        let hash = try Review.commit(at: repo, message: "add a").get()
        XCTAssertFalse(hash.isEmpty)
        XCTAssertEqual(Git.run(["status", "--porcelain"], at: repo), "")
    }

    // MARK: - Checkpoints during a merge conflict

    func testSnapshotWorksWithAConflictedIndex() throws {
        try write(repo, "dist/f", "a\n")
        commitAll(repo, "base")
        XCTAssertNotNil(Git.run(["checkout", "-q", "-b", "other"], at: repo))
        try write(repo, "dist/f", "b\n")
        commitAll(repo, "other")
        XCTAssertNotNil(Git.run(["checkout", "-q", "main"], at: repo))
        try write(repo, "dist/f", "c\n")
        commitAll(repo, "main")
        XCTAssertNil(Git.run(["merge", "other"], at: repo, environment: Git.identity))
        XCTAssertFalse((Git.run(["ls-files", "-u"], at: repo) ?? "").isEmpty)
        let status = Git.run(["status", "--porcelain"], at: repo)
        // Excluding the conflicted folder leaves its unmerged entries for write-tree.
        XCTAssertNotNil(Checkpoints.snapshot(at: repo, message: "x", excluding: Overlaps.generated))
        XCTAssertNotNil(Checkpoints.snapshot(at: repo, message: "x"))
        XCTAssertNotNil(Checkpoints.capture(at: repo, session: session, turn: 1, phase: .start, prompt: "mid-merge"))
        // The user's conflicted index is untouched.
        XCTAssertEqual(Git.run(["status", "--porcelain"], at: repo), status)
    }

    // MARK: - helpers

    private func write(_ dir: String, _ name: String, _ text: String) throws {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func commitAll(_ dir: String, _ message: String) {
        XCTAssertNotNil(Git.run(["add", "-A"], at: dir))
        XCTAssertNotNil(Git.run(["commit", "-q", "-m", message], at: dir, environment: Git.identity))
    }
}
