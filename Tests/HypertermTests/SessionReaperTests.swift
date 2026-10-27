import Darwin
import XCTest
@testable import Hyperterm

/// Which processes a closed session stops, and that a reused pid is never one of them.
final class SessionReaperTests: XCTestCase {
    private let mine: pid_t = 100

    private func entry(_ pid: pid_t, parent: pid_t, start: UInt64 = 1) -> ProcessInspector.ProcessEntry {
        .init(pid: pid, ppid: parent, name: "p\(pid)", startSeconds: 0, start: start)
    }

    private func select(_ table: [ProcessInspector.ProcessEntry], seeds: [pid_t], recorded: [TrackedProcess] = []) -> Set<pid_t> {
        let byPID = Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0) })
        let tree = ProcessInspector.selectTree(session: "s", seeds: seeds, recorded: recorded, byPID: byPID,
                                               children: Dictionary(grouping: table, by: \.ppid), mine: mine)
        return Set(tree.map(\.pid))
    }

    func testTreeKeepsRecordedOrphansAndTheirChildren() {
        // 200 is a terminal root (login); 201 the shell; 300 a daemon that left for launchd.
        let table = [entry(mine, parent: 1), entry(200, parent: mine), entry(201, parent: 200),
                     entry(202, parent: 201), entry(300, parent: 1, start: 7), entry(301, parent: 300),
                     entry(400, parent: 1)]
        let recorded = [TrackedProcess(pid: 300, start: 7, session: "s")]
        XCTAssertEqual(select(table, seeds: [201, 202], recorded: recorded), [201, 202, 300, 301])
    }

    func testTreeNeverIncludesKuronamiOrItsChildren() {
        // A Chromium helper (500) and another session's root (200) are Tako's children.
        let table = [entry(mine, parent: 1), entry(200, parent: mine), entry(201, parent: 200),
                     entry(500, parent: mine), entry(501, parent: 500)]
        XCTAssertEqual(select(table, seeds: [mine, 200, 500, 1]), [])
    }

    func testTreeDropsRecordedPidReusedByAnotherProcess() {
        let table = [entry(300, parent: 1, start: 9), entry(301, parent: 300)]
        let recorded = [TrackedProcess(pid: 300, start: 7, session: "s")]
        XCTAssertEqual(select(table, seeds: [], recorded: recorded), [])
    }

    func testSignalGuard() {
        let process = TrackedProcess(pid: 300, start: 7, session: "s")
        let same = ProcessFacts(start: 7, ppid: 1, pgid: 300, name: "node")
        XCTAssertTrue(SessionReaper.maySignal(process, same, mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(process, ProcessFacts(start: 8, ppid: 1, pgid: 300, name: "node"), mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(process, nil, mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(process, ProcessFacts(start: 7, ppid: mine, pgid: 300, name: "Helper"), mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(TrackedProcess(pid: mine, start: 7, session: "s"), same, mine: mine))
        XCTAssertFalse(SessionReaper.maySignal(TrackedProcess(pid: 1, start: 7, session: "s"), same, mine: mine))
    }

    func testSweepTakesOrphansAndTheirRecordedChildrenOnly() {
        let facts: [pid_t: ProcessFacts] = [
            10: ProcessFacts(start: 1, ppid: 1, pgid: 10, name: "node"),     // orphaned leftover
            11: ProcessFacts(start: 1, ppid: 10, pgid: 10, name: "esbuild"), // its child
            20: ProcessFacts(start: 1, ppid: 55, pgid: 20, name: "sleep"),   // parent still alive
            30: ProcessFacts(start: 2, ppid: 1, pgid: 30, name: "other"),    // pid reused
        ]
        let recorded = [10, 11, 20, 30, 40].map { TrackedProcess(pid: $0, start: 1, session: "s") }
        let swept = SessionReaper.leftovers(recorded, facts: { facts[$0] })
        XCTAssertEqual(Set(swept.map(\.pid)), [10, 11])
    }

    // MARK: - Real processes

    /// `sh -c 'sleep & sleep &'` in its own session: the shell exits and both sleeps are left
    /// to launchd, like a nohup'd job after its terminal closed. One also ignores SIGTERM.
    private func spawnOrphans(script: String = "sleep 300 & a=$!; trap '' TERM; sleep 301 & echo $a $! > \"$0\"",
                              count: Int = 2) throws -> [pid_t] {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for fd: Int32 in [0, 1, 2] { posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", O_RDWR, 0) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: out) }
        let argv: [UnsafeMutablePointer<CChar>?] = (["/bin/sh", "-c", script, out] as [String]).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var shell: pid_t = 0
        XCTAssertEqual(posix_spawn(&shell, "/bin/sh", &actions, &attributes, argv, environ), 0)
        var status: Int32 = 0
        waitpid(shell, &status, 0)
        let output = (try? String(contentsOfFile: out, encoding: .utf8)) ?? ""
        let pids = output.split(separator: " ").compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        XCTAssertEqual(pids.count, count)
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !pids.allSatisfy({ SessionReaper.facts($0)?.ppid == 1 }) { usleep(20_000) }
        return pids
    }

    private func waitUntilGone(_ pids: [pid_t], timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ SessionReaper.facts($0) == nil }) { return true }
            usleep(50_000)
        }
        return false
    }

    func testStopsDetachedJobsIncludingOneIgnoringTerm() throws {
        let pids = try spawnOrphans()
        let recorded = pids.compactMap { pid in SessionReaper.facts(pid).map { TrackedProcess(pid: pid, start: $0.start, session: "s") } }
        XCTAssertEqual(Set(SessionReaper.leftovers(recorded, facts: SessionReaper.facts).map(\.pid)), Set(pids))

        let done = expectation(description: "stopped")
        SessionReaper.stop(recorded, grace: 0.5) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(waitUntilGone(pids))
    }

    /// Closing a session while a slow poll holds the inspector's queue returns at once; the
    /// session's processes still arrive once the poll finishes.
    func testTakingProcessesNeverWaitsOnAPollInFlight() throws {
        // /bin/sleep hides its environment like every platform binary, and a re-signed copy of it
        // is arm64e, which macOS 15 won't run outside the platform. A helper built here is plain
        // arm64, signed by the linker, runs everywhere and shows its environment.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("sleeper.c")
        try "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".write(to: source, atomically: true, encoding: .utf8)
        let sleep = folder.appendingPathComponent("sleeper").path
        XCTAssertNotNil(runProcess("/usr/bin/clang", [source.path, "-o", sleep], timeout: 60), "couldn't build the sleeper helper")
        let session = UUID().uuidString
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "\"$0\" 30; :", sleep]
        shell.environment = ["HT_SESSION_ID": session, "PATH": "/bin:/usr/bin"]
        try shell.run()
        defer { shell.terminate() }
        var sleeper: pid_t?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, sleeper == nil {
            sleeper = runProcess("/usr/bin/pgrep", ["-P", "\(shell.processIdentifier)"])
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if sleeper == nil { usleep(20_000) }
        }
        let child = try XCTUnwrap(sleeper)
        defer { kill(child, SIGKILL) }

        let inspector = ProcessInspector()
        let polling = expectation(description: "polling")
        let release = DispatchSemaphore(value: 0)
        inspector.start(interval: 60) { _ in
            polling.fulfill()
            release.wait()
        }
        inspector.setInterval(60)
        wait(for: [polling], timeout: 5)

        let taken = expectation(description: "taken")
        let started = Date()
        inspector.takeProcesses(ofSession: session) { processes in
            XCTAssertEqual(Set(processes.map(\.pid)), [child])
            taken.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        release.signal()
        wait(for: [taken], timeout: 5)
    }

    func testStopLeavesAProcessWhoseStartTimeDiffers() throws {
        let pids = try spawnOrphans()
        defer { pids.forEach { kill($0, SIGKILL) } }
        let stale = pids.compactMap { pid in SessionReaper.facts(pid).map { TrackedProcess(pid: pid, start: $0.start + 1, session: "s") } }
        XCTAssertEqual(stale.count, 2, "\(pids.map { SessionReaper.facts($0) as Any })")

        let done = expectation(description: "stopped")
        SessionReaper.stop(stale, grace: 0.2) { done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(pids.allSatisfy { SessionReaper.facts($0) != nil })
    }

    // MARK: - Waiting for the stop

    private func tracked(_ pids: [pid_t]) -> [TrackedProcess] {
        pids.compactMap { pid in SessionReaper.facts(pid).map { TrackedProcess(pid: pid, start: $0.start, session: "s") } }
    }

    /// One ignores SIGTERM, as an interactive shell does, but not the hangup.
    func testStopAndWaitReturnsAsSoonAsEverythingIsGone() throws {
        let pids = try spawnOrphans(script: "sleep 300 & a=$!; (trap '' TERM; exec sleep 301) & echo $a $! > \"$0\"")
        defer { pids.forEach { kill($0, SIGKILL) } }
        let started = Date()
        SessionReaper.stopAndWait(tracked(pids), grace: 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "returns once they're gone, not after the grace")
        XCTAssertTrue(pids.allSatisfy { SessionReaper.facts($0) == nil })
    }

    func testStopAndWaitKillsWhatIgnoresTermAfterTheGrace() throws {
        let pids = try spawnOrphans()
        defer { pids.forEach { kill($0, SIGKILL) } }
        SessionReaper.stopAndWait(tracked(pids), grace: 0.3)
        XCTAssertTrue(pids.allSatisfy { SessionReaper.facts($0) == nil })
    }

    /// Quitting stops every session's processes before Tako exits.
    func testQuitStopsEverySessionsProcesses() throws {
        let first = try spawnOrphans(), second = try spawnOrphans(script: "sleep 302 & echo $! > \"$0\"", count: 1)
        defer { (first + second).forEach { kill($0, SIGKILL) } }
        let bySession = ["a": tracked(first), "b": tracked(second)]
        SessionReaper.stopAllForQuit(sessions: ["a", "b", "c"], grace: 0.3) { session, completion in
            DispatchQueue.global().async { completion(bySession[session] ?? []) }
        }
        XCTAssertTrue((first + second).allSatisfy { SessionReaper.facts($0) == nil })
    }

    /// Sessions restore only once what the last run left has gone.
    func testSweepCompletesAfterLeftoversAreGone() throws {
        let pids = try spawnOrphans()
        defer { pids.forEach { kill($0, SIGKILL) } }
        let gone = Process()
        gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try gone.run()
        gone.waitUntilExit()
        let ledger = ProcessLedger(ownerPID: gone.processIdentifier, ownerStart: 1, processes: tracked(pids))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        try JSONEncoder().encode(ledger).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var logged: [String] = []
        let done = expectation(description: "restored")
        SessionReaper.sweepLeftovers(ledger: url, grace: 0.3, log: { line, _ in logged.append(line) }) {
            XCTAssertTrue(pids.allSatisfy { SessionReaper.facts($0) == nil }, "a leftover still runs as sessions restore")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(logged.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSweepWithNothingLeftCompletesAtOnce() {
        var completed = false
        SessionReaper.sweepLeftovers(ledger: URL(fileURLWithPath: "/nonexistent/ledger.json"), log: { _, _ in }) { completed = true }
        XCTAssertTrue(completed)
    }
}
