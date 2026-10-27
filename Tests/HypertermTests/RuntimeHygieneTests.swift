import AppKit
import XCTest
@testable import Hyperterm

/// Runtime efficiency and data hygiene: fixes driven by Tako's own logs.
final class RuntimeHygieneTests: XCTestCase {
    // MARK: - Foreground command label

    func testCommandLabelSkipsURLsAndShortensPaths() {
        XCTAssertEqual(ProcessInspector.commandLabel(argv: ["/usr/local/bin/npx", "-y", "mcp-remote", "https://mcp.example.com/sse"]),
                       "npx -y mcp-remote")
        XCTAssertEqual(ProcessInspector.commandLabel(argv: ["/opt/homebrew/bin/node", "/Users/me/app/server.js", "--port", "3000", "extra"]),
                       "node server.js --port 3000")
        XCTAssertEqual(ProcessInspector.commandLabel(argv: ["python3"]), "python3")
        XCTAssertEqual(ProcessInspector.commandLabel(argv: []), "")
    }

    // MARK: - Statusline

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rt-statusline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func statusInput(cost: Double, durationMs: Int, context: Double = 12) -> Data {
        Data("""
        {"session_id":"s1","model":{"display_name":"Opus"},"context_window":{"used_percentage":\(context)},
         "cost":{"total_cost_usd":\(cost),"total_duration_ms":\(durationMs),"total_api_duration_ms":\(durationMs / 2)}}
        """.utf8)
    }

    func testPlainCommandsSkipTheShell() {
        XCTAssertEqual(StatusLineRunner.plainArgv("python3 /Users/me/scrim.py statusline"), ["python3", "/Users/me/scrim.py", "statusline"])
        XCTAssertNil(StatusLineRunner.plainArgv("cat | jq -r .model"))
        XCTAssertNil(StatusLineRunner.plainArgv("echo $HOME"))
        XCTAssertNil(StatusLineRunner.plainArgv("~/bin/line"))
        XCTAssertNil(StatusLineRunner.plainArgv("FOO=1 line"))
        XCTAssertNil(StatusLineRunner.plainArgv("echo 'a b'"))

        let plan = StatusLineRunner.launchPlan(command: "sh -x", environment: ["PATH": "/nonexistent:/bin"])
        XCTAssertEqual(plan.executable, "/bin/sh")
        XCTAssertEqual(plan.arguments, ["-x"])
        let shell = StatusLineRunner.launchPlan(command: "echo hi | cat", environment: ["PATH": "/bin"])
        XCTAssertEqual(shell.executable, "/bin/sh")
        XCTAssertEqual(shell.arguments, ["-c", "echo hi | cat"])
        // Not on PATH: the shell reports it, as before.
        XCTAssertEqual(StatusLineRunner.launchPlan(command: "no-such-tool-xyz", environment: ["PATH": "/bin"]).executable, "/bin/sh")
    }

    func testUserCommandFollowsClaudeConfigDir() throws {
        let home = try tempDir(), account = try tempDir()
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try Data(#"{"statusLine":{"type":"command","command":"default-line"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude/settings.json"))
        try Data(#"{"statusLine":{"type":"command","command":"work-line"}}"#.utf8)
            .write(to: account.appendingPathComponent("settings.json"))
        XCTAssertEqual(StatusLineRunner.userCommand(environment: [:], home: home), "default-line")
        XCTAssertEqual(StatusLineRunner.userCommand(environment: ["CLAUDE_CONFIG_DIR": account.path], home: home), "work-line")
        try Data(#"{"statusLine":{"command":"/x/ht statusline"}}"#.utf8).write(to: account.appendingPathComponent("settings.json"))
        XCTAssertNil(StatusLineRunner.userCommand(environment: ["CLAUDE_CONFIG_DIR": account.path], home: home))
    }

    func testOutputKeyIgnoresElapsedTime() {
        XCTAssertEqual(StatusLineRunner.outputKey(command: "c", input: statusInput(cost: 1, durationMs: 1000)),
                       StatusLineRunner.outputKey(command: "c", input: statusInput(cost: 1, durationMs: 9000)))
        XCTAssertNotEqual(StatusLineRunner.outputKey(command: "c", input: statusInput(cost: 1, durationMs: 1000)),
                          StatusLineRunner.outputKey(command: "c", input: statusInput(cost: 2, durationMs: 1000)))
        XCTAssertNotEqual(StatusLineRunner.outputKey(command: "c", input: statusInput(cost: 1, durationMs: 1000)),
                          StatusLineRunner.outputKey(command: "d", input: statusInput(cost: 1, durationMs: 1000)))
    }

    func testRenderReusesOutputForIdenticalRefreshesWithinTTL() throws {
        let dir = try tempDir(), account = try tempDir()
        try Data(#"{"statusLine":{"command":"python3 line.py"}}"#.utf8).write(to: account.appendingPathComponent("settings.json"))
        let env = ["CLAUDE_CONFIG_DIR": account.path, "HT_SESSION_ID": "abc-1", "PATH": "/usr/bin:/bin"]
        var runs = 0
        let run: (String, [String], Data) -> Data = { _, _, _ in runs += 1; return Data("line \(runs)".utf8) }
        let start = Date()
        func render(_ input: Data, at offset: TimeInterval) -> String {
            String(decoding: StatusLineRunner.render(input: input, environment: env, directory: dir, now: start.addingTimeInterval(offset), run: run), as: UTF8.self)
        }
        XCTAssertEqual(render(statusInput(cost: 1, durationMs: 100), at: 0), "line 1")
        XCTAssertEqual(render(statusInput(cost: 1, durationMs: 400), at: 0.5), "line 1", "same input, within TTL: no new process")
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(render(statusInput(cost: 2, durationMs: 700), at: 0.8), "line 2", "changed input runs again")
        XCTAssertEqual(render(statusInput(cost: 2, durationMs: 900), at: 30), "line 3", "stale output runs again")
        XCTAssertEqual(runs, 3)
    }

    func testReportOnlyWhenTelemetryChanges() throws {
        let dir = try tempDir()
        let start = Date()
        XCTAssertTrue(StatusLineRunner.reportDue(session: "s", input: statusInput(cost: 1, durationMs: 1), directory: dir, now: start))
        XCTAssertFalse(StatusLineRunner.reportDue(session: "s", input: statusInput(cost: 1, durationMs: 5000), directory: dir, now: start.addingTimeInterval(1)))
        XCTAssertTrue(StatusLineRunner.reportDue(session: "s", input: statusInput(cost: 1, durationMs: 1, context: 40), directory: dir, now: start.addingTimeInterval(1)))
        XCTAssertTrue(StatusLineRunner.reportDue(session: "other", input: statusInput(cost: 1, durationMs: 1, context: 40), directory: dir, now: start))
    }

    // MARK: - Browser janitor

    private func page(_ id: String, _ url: String) -> BrowserJanitor.Target {
        BrowserJanitor.Target(id: id, type: "page", url: url, webSocketDebuggerUrl: "ws://127.0.0.1:1/devtools/page/\(id)")
    }

    @MainActor
    func testJanitorAsksEachOwnedPageOnce() {
        var ledger = BrowserJanitor.Ledger()
        let owned = page("A", "http://localhost:3000/redirected")
        let labels: Set<String> = ["charlie"]
        XCTAssertTrue(ledger.needsTag(owned, labels: labels, addresses: []))
        ledger.record(tag: "charlie", for: "A")
        for _ in 0..<5 {
            XCTAssertFalse(ledger.needsTag(owned, labels: labels, addresses: []), "a known owner is not asked again")
            XCTAssertEqual(ledger.conclude([owned], labels: labels, addresses: []), .init())
        }
        // Renamed: the remembered tag is no longer live, so it is asked again rather than closed.
        XCTAssertTrue(ledger.needsTag(owned, labels: ["delta"], addresses: []))
    }

    @MainActor
    func testJanitorMatchesAddressesWithoutTrailingSlash() {
        let ledger = BrowserJanitor.Ledger()
        let addresses = Set(["http://localhost:3000"].map { BrowserJanitor.Ledger.normalized($0) })
        XCTAssertFalse(ledger.needsTag(page("A", "http://localhost:3000/"), labels: [], addresses: addresses))
        XCTAssertEqual(BrowserJanitor.Ledger.normalized("about:blank"), "about:blank")
        XCTAssertEqual(BrowserJanitor.Ledger.normalized("file:///"), "file://")
    }

    @MainActor
    func testJanitorClosesOrphanThenStopsAHalfClosedOne() {
        var ledger = BrowserJanitor.Ledger()
        let orphan = page("B", "about:blank")
        ledger.record(tag: "alpha", for: "B") // a label no live browser has
        XCTAssertEqual(ledger.conclude([orphan], labels: ["charlie"], addresses: []).close, [], "first sweep only suspects")
        XCTAssertEqual(ledger.conclude([orphan], labels: ["charlie"], addresses: []).close, ["B"])
        // Still listed after the close: its renderer is stopped, then it is left alone for good.
        XCTAssertTrue(ledger.needsTag(orphan, labels: ["charlie"], addresses: []))
        XCTAssertEqual(ledger.conclude([orphan], labels: ["charlie"], addresses: []).stopRenderer, ["B"])
        XCTAssertFalse(ledger.needsTag(orphan, labels: ["charlie"], addresses: []))
        XCTAssertEqual(ledger.conclude([orphan], labels: ["charlie"], addresses: []), .init())
        // Gone pages are forgotten.
        _ = ledger.conclude([], labels: [], addresses: [])
        XCTAssertTrue(ledger.pages.isEmpty)
    }

    // MARK: - Chromium profile

    @MainActor
    func testChromiumCapsDiskCacheAndSkipsComponentUpdates() throws {
        let switches = AgentBrowser.chromiumSwitches
        let cache = try XCTUnwrap(switches["disk-cache-size"] ?? nil).flatMap(Int.init)
        XCTAssertEqual(cache, 96 * 1024 * 1024)
        XCTAssertTrue(switches.keys.contains("disable-component-update"))
        XCTAssertEqual(switches["renderer-process-limit"], "6")
    }

    @MainActor
    func testComponentPruneKeepsLoginsAndCookies() throws {
        let profile = try tempDir()
        let fm = FileManager.default
        for dir in ["component_crx_cache/abc", "Default/Network", "Default/Local Storage"] {
            try fm.createDirectory(at: profile.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("c".utf8).write(to: profile.appendingPathComponent("Default/Network/Cookies"))
        try Data("l".utf8).write(to: profile.appendingPathComponent("Default/Login Data"))
        AgentBrowser.pruneComponentDownloads(in: profile)
        XCTAssertFalse(fm.fileExists(atPath: profile.appendingPathComponent("component_crx_cache").path))
        XCTAssertTrue(fm.fileExists(atPath: profile.appendingPathComponent("Default/Network/Cookies").path))
        XCTAssertTrue(fm.fileExists(atPath: profile.appendingPathComponent("Default/Login Data").path))
        XCTAssertTrue(fm.fileExists(atPath: profile.appendingPathComponent("Default/Local Storage").path))
    }

    // MARK: - Closed sessions

    func testClosedEventsDropStartupNoiseAndMarkup() {
        XCTAssertTrue(SessionStore.isClosedEventNoise("Accepted Claude's development channel warning"))
        XCTAssertTrue(SessionStore.isClosedEventNoise("Kept bypass permissions (declined Claude's auto mode offer)"))
        XCTAssertTrue(SessionStore.isClosedEventNoise("› <channel source=\"hyperterm\" source=\"hyperterm\""))
        XCTAssertTrue(SessionStore.isClosedEventNoise("<task-notification"))
        XCTAssertFalse(SessionStore.isClosedEventNoise("Tests passed: 211 tests"))
        XCTAssertFalse(SessionStore.isClosedEventNoise("Bash: cd /repo && make"))
    }

    func testReopenPlaceForMissingFolders() {
        let root = "/repo"
        var claude = LaunchSpec(label: "api", kind: .claude, cwd: root)
        claude.worktreeName = "api"
        claude.worktreeBranch = "worktree-api"
        let present: Set<String> = [root]
        func place(_ spec: LaunchSpec, branches: Set<String>, exists: Set<String> = present) -> SessionStore.ReopenPlace {
            SessionStore.reopenPlace(for: spec, exists: { exists.contains($0) }, branchExists: { _, branch in branches.contains(branch) })
        }
        XCTAssertEqual(place(claude, branches: [], exists: [root, "/repo/.claude/worktrees/api"]), .asIs)
        XCTAssertEqual(place(claude, branches: ["worktree-api"]),
                       .recreate(root: root, path: "/repo/.claude/worktrees/api", branch: "worktree-api"))

        // Started inside a Claude worktree (no name recorded): the branch is guessed from the folder.
        let inside = LaunchSpec(label: "x", kind: .claude, cwd: "/repo/.claude/worktrees/characters")
        XCTAssertEqual(place(inside, branches: ["worktree-characters"]),
                       .recreate(root: root, path: "/repo/.claude/worktrees/characters", branch: "worktree-characters"))
        guard case .repoRoot(let fallback, let note) = place(inside, branches: []) else { return XCTFail("expected repo root") }
        XCTAssertEqual(fallback, root)
        XCTAssertTrue(note.contains("fresh conversation"))

        // Gone repository, or a Tako worktree outside the repo: nothing to fall back to.
        guard case .unavailable = place(inside, branches: [], exists: []) else { return XCTFail("expected unavailable") }
        var codex = LaunchSpec(label: "c", kind: .codex, cwd: "/Users/me/.hyperterm/worktrees/repo/c")
        codex.worktreeBranch = "ht/c"
        guard case .unavailable(let reason) = place(codex, branches: ["ht/c"]) else { return XCTFail("expected unavailable") }
        XCTAssertTrue(reason.contains("ht/c"))
    }

    @MainActor
    func testHistoryMarksMissingFolders() {
        let spec = LaunchSpec(label: "gone", kind: .claude, cwd: "/repo/.claude/worktrees/gone")
        let text = SessionStore.describeHistory([spec], folderExists: { _ in false })
        XCTAssertTrue(text.contains("folder missing"), text)
    }

    // MARK: - Terminal surface teardown

    @MainActor
    func testSurfaceIsFreedAfterTheCallThatClosedIt() {
        var freed: [Int] = []
        let view = NSView()
        TerminalSurfaceView.releaseLater(7, keeping: view) { freed.append($0) }
        XCTAssertEqual(freed, [], "never inside the libghostty call that asked to close")
        let done = expectation(description: "freed on the next main-queue turn")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(freed, [7])
    }
}
