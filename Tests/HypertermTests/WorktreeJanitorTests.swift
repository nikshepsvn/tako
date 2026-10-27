import Darwin
import XCTest
@testable import Hyperterm

/// What closed agents leave behind: worktrees nobody uses any more are archived conservatively,
/// and stale locks are lifted.
final class WorktreeJanitorTests: XCTestCase {
    private let now = Date()
    private let week: TimeInterval = 7 * 24 * 3600

    // MARK: - Plans

    func testPlanKeepsAnythingInUseLockedDirtyOrDetached() {
        typealias Facts = WorktreeJanitor.Facts
        let clean = WorkAtRisk(uncommitted: 0, unmerged: 0)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(inUse: true, risk: clean)).archive)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(lock: .held(42), risk: clean)).archive)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(lock: .foreign("mine"), risk: clean)).archive)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(lock: .foreign("mine"), risk: clean)).unlock)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(dirty: true, risk: clean)).archive)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(detached: true, risk: clean)).archive)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(risk: nil)).archive)
        // A stale lock is lifted even when the work keeps the worktree.
        let dirtyStale = WorktreeJanitor.plan(Facts(lock: .stale(42), dirty: true, risk: clean))
        XCTAssertTrue(dirtyStale.unlock)
        XCTAssertFalse(dirtyStale.archive)
    }

    func testPlanArchivesCleanWorkAtOnceAndUnmergedWorkAfterAWeek() {
        typealias Facts = WorktreeJanitor.Facts
        let landed = WorkAtRisk(uncommitted: 0, unmerged: 0)
        let unmerged = WorkAtRisk(uncommitted: 0, unmerged: 2)
        XCTAssertTrue(WorktreeJanitor.plan(Facts(risk: landed, idleSince: now), now: now).archive)
        XCTAssertFalse(WorktreeJanitor.plan(Facts(risk: unmerged, idleSince: now.addingTimeInterval(-3600)), now: now).archive)
        XCTAssertTrue(WorktreeJanitor.plan(Facts(risk: unmerged, idleSince: now.addingTimeInterval(-week - 1)), now: now).archive)
        let stale = WorktreeJanitor.plan(Facts(lock: .stale(9), risk: landed), now: now)
        XCTAssertTrue(stale.unlock && stale.archive)
    }

    func testClaudeLockReasons() {
        let reason = "claude session api (pid 4242 start Sat Oct 24 18:54:24 2026)"
        var asked: (pid_t, Date?)?
        XCTAssertEqual(WorktreeJanitor.lockState(reason: reason) { asked = ($0, $1); return true }, .held(4242))
        XCTAssertEqual(asked?.0, 4242)
        XCTAssertNotNil(asked?.1, "the start date is read")
        XCTAssertEqual(WorktreeJanitor.lockState(reason: reason) { _, _ in false }, .stale(4242))
        XCTAssertEqual(WorktreeJanitor.lockState(reason: nil) { _, _ in false }, .unlocked)
        XCTAssertEqual(WorktreeJanitor.lockState(reason: "") { _, _ in false }, .foreign("no reason given"))
        XCTAssertEqual(WorktreeJanitor.lockState(reason: "on a USB disk") { _, _ in false }, .foreign("on a USB disk"))
    }

    func testAReusedPidDoesNotHoldALock() throws {
        let mine = try XCTUnwrap(SessionReaper.facts(getpid()))
        let started = Date(timeIntervalSince1970: Double(mine.start) / 1_000_000)
        XCTAssertTrue(WorktreeJanitor.isRunning(getpid(), started: started))
        XCTAssertTrue(WorktreeJanitor.isRunning(getpid(), started: nil))
        XCTAssertFalse(WorktreeJanitor.isRunning(getpid(), started: started.addingTimeInterval(-3600)))
    }

    func testWorktreeListingParsesLocksAndDetachedHeads() {
        let porcelain = """
        worktree /repo
        HEAD 1
        branch refs/heads/main

        worktree /repo/.claude/worktrees/api
        HEAD 2
        branch refs/heads/worktree-api
        locked claude session api (pid 9 start Sat Oct 24 18:54:24 2026)

        worktree /repo/.claude/worktrees/api-2
        HEAD 3
        detached
        locked

        """
        let listed = WorktreeJanitor.parseWorktrees(porcelain)
        XCTAssertEqual(listed.map(\.path), ["/repo/.claude/worktrees/api", "/repo/.claude/worktrees/api-2"])
        XCTAssertEqual(listed[0].lockReason, "claude session api (pid 9 start Sat Oct 24 18:54:24 2026)")
        XCTAssertFalse(listed[0].detached)
        XCTAssertEqual(listed[1].lockReason, "")
        XCTAssertTrue(listed[1].detached)
    }

    // MARK: - A real repository

    private func makeRepository() throws -> String {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("janitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let root = folder.path
        try git(["init", "-q", "-b", "main"], at: root)
        try "hello\n".write(toFile: root + "/README", atomically: true, encoding: .utf8)
        try git(["add", "-A"], at: root)
        try git(["commit", "-q", "-m", "first"], at: root)
        return root
    }

    @discardableResult
    private func git(_ arguments: [String], at path: String) throws -> String {
        try XCTUnwrap(Git.run(arguments, at: path, environment: Git.identity), "git \(arguments.joined(separator: " ")) failed")
    }

    private func addWorktree(_ name: String, in root: String) throws -> String {
        let path = root + "/.claude/worktrees/" + name
        try git(["worktree", "add", "-q", "-b", "worktree-\(name)", path, "main"], at: root)
        return path
    }

    private func record(_ path: String, root: String?, created: Date) -> WorktreeRecord {
        WorktreeRecord(path: path, session: UUID().uuidString, root: root, base: "main", created: created)
    }

    private func deadPID() throws -> pid_t {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func lockReason(pid: pid_t, started: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return "claude session x (pid \(pid) start \(formatter.string(from: started)))"
    }

    func testCollectArchivesOnlyWhatIsSafeAndKeepsBranches() throws {
        let root = try makeRepository()
        let old = now.addingTimeInterval(-2 * week)
        let landed = try addWorktree("landed", in: root)
        let dirty = try addWorktree("dirty", in: root)
        try "wip\n".write(toFile: dirty + "/notes.txt", atomically: true, encoding: .utf8)
        let staleLock = try addWorktree("stale-lock", in: root)
        try git(["worktree", "lock", "--reason", lockReason(pid: try deadPID(), started: now), staleLock], at: root)
        let held = try addWorktree("held", in: root)
        let mine = try XCTUnwrap(SessionReaper.facts(getpid()))
        try git(["worktree", "lock", "--reason", lockReason(pid: getpid(), started: Date(timeIntervalSince1970: Double(mine.start) / 1_000_000)), held], at: root)
        let open = try addWorktree("open", in: root)
        let recent = try addWorktree("recent", in: root)
        let abandoned = try addWorktree("abandoned", in: root)
        for path in [recent, abandoned] {
            try "work\n".write(toFile: path + "/feature.txt", atomically: true, encoding: .utf8)
            try git(["add", "-A"], at: path)
            try git(["commit", "-q", "-m", "feature"], at: path)
        }
        let detached = root + "/.claude/worktrees/detached"
        try git(["worktree", "add", "-q", "--detach", detached, "main"], at: root)
        // Made by hand, not by Tako: never looked at.
        let unrecorded = try addWorktree("unrecorded", in: root)

        let paths = [landed, dirty, staleLock, held, open, abandoned, detached]
        var records = paths.map { record($0, root: root, created: old) }
        records.append(record(recent, root: root, created: old))
        let known = WorktreeJanitor.Known(live: [open + "/src"], closed: [recent: now.addingTimeInterval(-3600)], sessions: [:], bases: [:])
        var lines: [String] = []
        let kept = WorktreeJanitor.collect(records: records, known: known, now: now) { line, _ in lines.append(line) }

        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        XCTAssertFalse(exists(landed))
        XCTAssertFalse(exists(staleLock), "a dead pid's lock is lifted, then the clean worktree goes")
        XCTAssertFalse(exists(abandoned), "unmerged but closed long ago: archived, its branch keeps the commit")
        XCTAssertTrue(exists(dirty))
        XCTAssertTrue(exists(held))
        XCTAssertTrue(exists(open))
        XCTAssertTrue(exists(recent))
        XCTAssertTrue(exists(detached))
        XCTAssertTrue(exists(unrecorded))
        XCTAssertNotNil(Git.run(["rev-parse", "--verify", "-q", "refs/heads/worktree-abandoned"], at: root))
        XCTAssertNotNil(Git.run(["rev-parse", "--verify", "-q", "refs/heads/worktree-landed"], at: root))
        XCTAssertEqual(Set(kept.map(\.path)), [dirty, held, open, recent, detached])
        XCTAssertTrue(lines.contains { $0.hasPrefix("unlocked") && $0.contains("stale-lock") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("kept") && $0.contains("dirty") && $0.contains("uncommitted") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("kept") && $0.contains("held") && $0.contains("holds its lock") })
        XCTAssertFalse(lines.contains { $0.contains("unrecorded") })
    }

    func testCollectAfterACloseLooksOnlyAtThatWorktree() throws {
        let root = try makeRepository()
        let closed = try addWorktree("closed", in: root)
        let other = try addWorktree("other", in: root)
        let records = [closed, other].map { record($0, root: root, created: now) }
        let known = WorktreeJanitor.Known(live: [], closed: [:], sessions: [:], bases: [:])
        _ = WorktreeJanitor.collect(records: records, known: known, only: [closed], now: now) { _, _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: closed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other))
    }

    func testRecordsOfRemovedWorktreesAreForgotten() throws {
        let root = try makeRepository()
        let gone = record(root + "/.claude/worktrees/long-gone", root: root, created: now)
        let lost = record("/nowhere/.claude/worktrees/x", root: nil, created: now)
        let known = WorktreeJanitor.Known(live: [], closed: [:], sessions: [:], bases: [:])
        XCTAssertEqual(WorktreeJanitor.collect(records: [gone, lost], known: known, now: now) { _, _ in }, [])
        // An agent that just started has no worktree yet: its record stays.
        let starting = WorktreeJanitor.Known(live: [gone.path], closed: [:], sessions: [:], bases: [:])
        XCTAssertEqual(WorktreeJanitor.collect(records: [gone], known: starting, now: now) { _, _ in }, [gone])
    }
}
