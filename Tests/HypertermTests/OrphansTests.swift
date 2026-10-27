import XCTest
@testable import Hyperterm

/// Stray processes for Sumi's `orphans`: only what this Tako started, and only what no open
/// terminal owns.
@MainActor
final class OrphansTests: XCTestCase {
    private let mine: pid_t = 500
    private let live = "LIVE-SESSION"
    private let gone = "GONE-SESSION"

    func testWhatAClosedTerminalStartedIsAnOrphan() {
        let found = Orphans.find([
            process(10, ppid: 1, session: gone, command: "node vite --port 5173"),
            process(11, ppid: 1, session: live, command: "node next dev"),
        ], ledger: [], live: [live], mine: mine)
        XCTAssertEqual(found.map(\.pid), [10])
        XCTAssertEqual(found.first?.why, "its terminal closed")
    }

    func testNeverTheUsersOwnOrAnotherTakosProcesses() {
        let found = Orphans.find([
            process(20, ppid: 1, session: gone, command: "node server.js", fromTako: false),
            process(21, ppid: 1, session: nil, command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", fromTako: false),
            process(22, ppid: mine, session: nil, command: "Tako Helper (Renderer)"),
            process(mine, ppid: 1, session: nil, command: "Tako"),
        ], ledger: [], live: [live], mine: mine)
        XCTAssertTrue(found.isEmpty)
    }

    func testStrayBrowsersAndServersLaunchdAdoptedAreOrphans() {
        let found = Orphans.find([
            process(30, ppid: 1, session: nil, command: "/Users/me/.cache/ms-playwright/chromium-1200/chrome-mac/Chromium --headless"),
            process(31, ppid: 1, session: nil, command: "/usr/bin/caffeinate -i"),
            process(32, ppid: 77, session: nil, command: "node build.js"),
        ], ledger: [], live: [live], mine: mine)
        XCTAssertEqual(found.map(\.pid), [30], "not unknown programs, nor processes something else still parents")
    }

    func testTheLedgerNamesProcessesThatHideTheirEnvironment() {
        let sleeper = process(40, ppid: 1, session: nil, command: "sleep 9999")
        let found = Orphans.find([sleeper], ledger: [TrackedProcess(pid: 40, start: sleeper.start, session: gone)],
                                 live: [live], mine: mine)
        XCTAssertEqual(found.map(\.pid), [40])
        let reused = Orphans.find([sleeper], ledger: [TrackedProcess(pid: 40, start: sleeper.start + 1, session: gone)],
                                  live: [live], mine: mine)
        XCTAssertTrue(reused.isEmpty, "a pid reused since isn't the recorded process")
    }

    func testChildrenFoldIntoTheirOrphanedParent() {
        let found = Orphans.find([
            process(50, ppid: 1, session: gone, command: "pnpm dev"),
            process(51, ppid: 50, session: gone, command: "node vite"),
            process(52, ppid: 51, session: gone, command: "esbuild --service"),
        ], ledger: [], live: [live], mine: mine)
        XCTAssertEqual(found.map(\.pid), [50])
        XCTAssertEqual(Set(found.first?.children.map(\.pid) ?? []), [51, 52])
        XCTAssertTrue(Orphans.describe(found).contains("+2 child processes"))
    }

    func testKillNeedsTheUsersOrderAndIdsFromTheLastList() {
        var spec = LaunchSpec(label: "sumi", kind: .claude, cwd: "/w")
        spec.sumi = true
        let sumi = TerminalSession(spec: spec, resume: false)
        let store = SessionStore(previewSessions: [sumi], previewLayout: .focus)
        let handler = ControlHandler(store: store, caller: .session(sumi.id.uuidString))
        OrphanList.listed = [60: OrphanProcess(pid: 60, pgid: 60, start: 1, command: "node", why: "x")]
        defer { OrphanList.listed = [:] }
        var request = ControlRequest(cmd: .orphans)
        request.text = "kill"
        request.targets = ["60"]
        guard case .failure(let notAsked) = handler.orphansToKill(request) else { return XCTFail() }
        XCTAssertTrue(notAsked.description.contains("the user's call"))

        request.userRequested = true
        sumi.turnFromUser = false
        guard case .failure(let agentTurn) = handler.orphansToKill(request) else { return XCTFail() }
        XCTAssertTrue(agentTurn.description.contains("turn the user started"))

        sumi.turnFromUser = true
        request.targets = ["60", "61"]
        guard case .failure(let unlisted) = handler.orphansToKill(request) else { return XCTFail() }
        XCTAssertTrue(unlisted.description.hasPrefix("61 wasn't in the last orphans list"))

        request.targets = ["pid 60"]
        guard case .success(let chosen) = handler.orphansToKill(request) else { return XCTFail() }
        XCTAssertEqual(chosen.map(\.pid), [60])
    }

    func testOnlySumiAsks() {
        let api = TerminalSession(spec: LaunchSpec(label: "api", kind: .claude, cwd: "/w"), resume: false)
        let store = SessionStore(previewSessions: [api], previewLayout: .focus)
        var response: ControlResponse?
        ControlHandler(store: store, caller: .session(api.id.uuidString)).handle(ControlRequest(cmd: .orphans)) { response = $0 }
        XCTAssertEqual(response?.error, "only Sumi stops stray processes")
    }

    func testTheProcessTableReadsWithoutNamingAnythingOfAnotherTako() {
        let table = Orphans.snapshot()
        XCTAssertTrue(table.contains { $0.pid == getpid() }, "the table holds this process")
        XCTAssertFalse(table.contains { $0.pid == 1 && $0.fromTako })
        // Every session is "gone" here; still only this test host's own strays may show.
        let found = Orphans.scan(live: [], ledger: URL(fileURLWithPath: "/nonexistent/processes.json"))
        XCTAssertTrue(found.allSatisfy { orphan in table.first { $0.pid == orphan.pid }?.fromTako == true })
    }

    // MARK: - Helpers

    private func process(_ pid: pid_t, ppid: pid_t, session: String?, command: String, fromTako: Bool = true) -> ProcessRecord {
        let name = String((command.split(separator: " ").first ?? "").split(separator: "/").last ?? "")
        return ProcessRecord(pid: pid, ppid: ppid, pgid: pid, start: UInt64(1_700_000_000_000_000 + Int(pid)), name: name,
                             command: command, session: session, fromTako: fromTako)
    }
}
