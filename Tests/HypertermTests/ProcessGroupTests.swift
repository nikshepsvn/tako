import Darwin
import XCTest
@testable import Hyperterm

/// The MCP proxies stop their server with everything it started, and quit when their agent is gone.
final class ProcessGroupTests: XCTestCase {
    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    private func readPIDs(_ file: URL, count: Int) -> [pid_t] {
        var pids: [pid_t] = []
        _ = waitUntil(5) {
            pids = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(whereSeparator: \.isWhitespace).compactMap { pid_t($0) }
            return pids.count >= count
        }
        return pids
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    // MARK: - ProcessGroup

    func testFoundationGivesEachChildItsOwnGroup() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        XCTAssertEqual(getpgid(child.processIdentifier), child.processIdentifier)
        XCTAssertEqual(ProcessGroup.led(by: child.processIdentifier), child.processIdentifier)
    }

    func testNeverSignalsItsOwnGroup() {
        XCTAssertNil(ProcessGroup.led(by: getpid()))
        XCTAssertNil(ProcessGroup.led(by: getpgrp()))
        XCTAssertNil(ProcessGroup.led(by: 1))
    }

    /// Like `npx` → `npm exec` → node: the server is a grandchild, and one ignores SIGTERM.
    func testTerminateStopsGrandchildrenIncludingOneIgnoringTerm() throws {
        let out = try temporaryFolder().appendingPathComponent("pids")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 300 & a=$!; (trap '' TERM; exec sleep 301) & echo $a $! > \"$0\"; wait", out.path]
        try child.run()
        let grandchildren = readPIDs(out, count: 2)
        XCTAssertEqual(grandchildren.count, 2)
        defer { grandchildren.forEach { kill($0, SIGKILL) } }

        ProcessGroup.terminate(leader: child.processIdentifier, grace: 0.5)
        XCTAssertTrue(waitUntil(3) { grandchildren.allSatisfy { !alive($0) } })
        XCTAssertTrue(ProcessGroup.isEmpty(child.processIdentifier))
    }

    func testTerminateReachesWhatOutlivedTheLeader() throws {
        let out = try temporaryFolder().appendingPathComponent("pids")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The shell exits at once; its sleep stays in the group under launchd.
        child.arguments = ["-c", "sleep 300 & echo $! > \"$0\"", out.path]
        try child.run()
        child.waitUntilExit()
        let orphan = try XCTUnwrap(readPIDs(out, count: 1).first)
        defer { kill(orphan, SIGKILL) }
        XCTAssertTrue(alive(orphan))

        ProcessGroup.terminate(leader: child.processIdentifier, grace: 0.5)
        XCTAssertTrue(waitUntil(3) { !alive(orphan) })
    }

    // MARK: - ParentWatch

    func testOrphanedWhenTheParentChangesOrIsLaunchd() {
        XCTAssertFalse(ParentWatch.isOrphaned(original: 500, current: 500))
        XCTAssertTrue(ParentWatch.isOrphaned(original: 500, current: 1))
        XCTAssertTrue(ParentWatch.isOrphaned(original: 500, current: 600))
        XCTAssertTrue(ParentWatch.isOrphaned(original: 1, current: 1))
    }

    // MARK: - The real proxy

    private static let fakeServer = """
    import json, sys
    for line in sys.stdin:
        m = json.loads(line)
        if "id" not in m: continue
        r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        print(json.dumps({"jsonrpc": "2.0", "id": m["id"], "result": r}), flush=True)
    """

    /// `ht mcp-lazy` whose agent vanished without closing its stdin (the pipe's writer lives on):
    /// the parent watch notices, and the server's own child goes with it.
    func testLazyProxyLeavesWithItsServerTreeWhenOrphaned() throws {
        let htBinary = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("bin/ht").path)
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: htBinary) && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"))
        let dir = try temporaryFolder()
        let server = dir.appendingPathComponent("server.py"), grandchild = dir.appendingPathComponent("grandchild"),
            proxy = dir.appendingPathComponent("proxy")
        try Self.fakeServer.write(to: server, atomically: true, encoding: .utf8)
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#
        // The server forks a sleep (as npm exec forks node), then runs the fake server. The
        // subshell exits at once, so launchd adopts the proxy while `sleep 20` holds its stdin open.
        let serverCommand = "sleep 300 & echo $! > \"$1\"; exec /usr/bin/python3 \"$2\""
        let script = """
        ( (printf '%s\\n' '\(initialize)'; exec sleep 20) | HT_HOME="$1" "$2" mcp-lazy --name fake -- /bin/sh -c '\(serverCommand)' sh "$3" "$4" >/dev/null 2>&1 & echo $! > "$5" )
        """
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-c", script, "sh", dir.path, htBinary, grandchild.path, server.path, proxy.path]
        try launcher.run()
        launcher.waitUntilExit()
        let proxyPID = try XCTUnwrap(readPIDs(proxy, count: 1).first)
        let sleeper = try XCTUnwrap(readPIDs(grandchild, count: 1).first, "the server never started")
        defer { kill(proxyPID, SIGKILL); kill(sleeper, SIGKILL) }

        // Well before the 20 s EOF: the watch checks every 2 s.
        XCTAssertTrue(waitUntil(10) { !alive(proxyPID) }, "the orphaned proxy kept running")
        XCTAssertTrue(waitUntil(5) { !alive(sleeper) }, "the server's child outlived the proxy")
    }
}
