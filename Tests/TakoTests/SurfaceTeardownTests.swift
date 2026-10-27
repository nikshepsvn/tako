import AppKit
import os
import XCTest
@testable import Tako

/// Closing a terminal must never block the main thread on its child's exit. `ghostty_surface_free`
/// joins the IO thread, which waits for the child `login` to exit; a `login` on its way out waits
/// for the terminal's output to drain, and a program flooding it with queries fills the mailbox
/// the reader needs, so the free used to hang the app for good.
final class SurfaceTeardownTests: XCTestCase {
    // MARK: - With a real terminal

    @MainActor
    func testClosingAStubbornFloodingTerminalKeepsTheMainThreadAndKillsTheChild() throws {
        let startedHere = GhosttyRuntime.shared.app == nil
        if startedHere { try XCTSkipUnless(GhosttyRuntime.shared.start(), "libghostty didn't start") }
        defer { if startedHere { GhosttyRuntime.shared.stop() } }

        // Device-status and title queries: each answer or title is a message the reader hands to
        // a mailbox, which fills once the IO thread and main thread stop draining.
        let flood = FileManager.default.temporaryDirectory.appendingPathComponent("tako-flood-\(UUID().uuidString)")
        let chunk = String(repeating: "\u{1b}[6n\u{1b}]2;flood\u{07}", count: 300) + String(repeating: "noise noise noise\n", count: 2000)
        try chunk.write(to: flood, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: flood) }
        let command = "/bin/sh -c \"trap '' HUP TERM; while :; do /bin/cat '\(flood.path)'; done\""
        let view = TerminalSurfaceView(launch: SurfaceLaunch(workingDirectory: "/tmp", command: command, environment: [:]))
        XCTAssertNotNil(view.surface)

        let pty = try XCTUnwrap(SurfacePtys.pty(for: view), "the surface's pty is known")
        var terminal = SessionReaper.Terminal()
        let up = Date().addingTimeInterval(10)
        while Date() < up {
            terminal = SessionReaper.terminal(onTTY: pty.tty)
            if terminal.root != nil, terminal.others.count >= 2 { break }
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let root = try XCTUnwrap(terminal.root, "login runs on the terminal")
        XCTAssertGreaterThanOrEqual(terminal.others.count, 2, "the flooding shell and its cat run: \(terminal)")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // A hung main thread can't fail the test; this can.
        let freedFlag = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
            if !freedFlag.withLock({ $0 }) { fatalError("closing a stubborn terminal hung the main thread") }
        }

        var lastBeat = Date()
        var longestGap: TimeInterval = 0
        let heartbeat = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            MainActor.assumeIsolated {
                longestGap = max(longestGap, Date().timeIntervalSince(lastBeat))
                lastBeat = Date()
            }
        }
        defer { heartbeat.invalidate() }
        let freed = expectation(description: "surface freed")
        let closedAt = Date()
        lastBeat = closedAt
        view.destroy {
            freedFlag.withLock { $0 = true }
            freed.fulfill()
        }
        wait(for: [freed], timeout: 15)
        let tookToFree = Date().timeIntervalSince(closedAt)

        XCTAssertLessThan(longestGap, 0.5, "the main thread stalled \(longestGap) s while the terminal closed")
        XCTAssertLessThan(tookToFree, 5)
        let everything = [root] + terminal.others
        let gone = Date().addingTimeInterval(5)
        while Date() < gone, everything.contains(where: SessionReaper.isRunning) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(everything.contains(where: SessionReaper.isRunning), "still running: \(everything.filter(SessionReaper.isRunning))")
    }

    // MARK: - Pieces

    func testPtyMastersAreFoundAndOtherDescriptorsAreNot() throws {
        var master: Int32 = -1, slave: Int32 = -1
        XCTAssertEqual(openpty(&master, &slave, nil, nil, nil), 0)
        defer { close(master); close(slave) }
        var slaveInfo = stat()
        XCTAssertEqual(fstat(slave, &slaveInfo), 0)

        let found = PtyMaster.all()
        XCTAssertTrue(found.contains(PtyMaster(fd: master, tty: slaveInfo.st_rdev)), "\(found)")
        XCTAssertFalse(found.contains { $0.fd == slave }, "the slave end is not a master")
        XCTAssertNil(PtyMaster.master(slave))
    }

    func testAZombieIsNotRunning() throws {
        var pid: pid_t = 0
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
        defer { argv.forEach { free($0) } }
        XCTAssertEqual(posix_spawn(&pid, "/usr/bin/true", nil, nil, argv, environ), 0)
        defer { var status: Int32 = 0; waitpid(pid, &status, 0) }
        let process = try XCTUnwrap(SessionReaper.facts(pid).map { TrackedProcess(pid: pid, start: $0.start, session: "s") })
        // Exited but not yet collected: a zombie.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, SessionReaper.isRunning(process) { usleep(10_000) }
        XCTAssertFalse(SessionReaper.isRunning(process))
    }

    func testAFreeThatStallsIsLoggedWhileStuckAndWhenItReturns() {
        let logged = OSAllocatedUnfairLock(uncheckedState: [[String: Any]]())
        FreeWatchdog.guarding(limit: 0.1, log: { _, fields in logged.withLock { $0.append(fields) } }) {
            usleep(400_000)
        }
        let stuckNoted = expectation(description: "noted while stuck")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { stuckNoted.fulfill() }
        wait(for: [stuckNoted], timeout: 2)
        let fields = logged.withLock { $0 }
        XCTAssertEqual(fields.count, 2, "\(fields)")
        XCTAssertTrue(fields.contains { $0["stalled"] as? Bool == true })
        XCTAssertTrue(fields.contains { ($0["stalled_for"] as? Double ?? 0) >= 0.4 })
    }

    func testAQuickFreeIsNotLogged() {
        let logged = OSAllocatedUnfairLock(initialState: 0)
        FreeWatchdog.guarding(limit: 0.2, log: { _, _ in logged.withLock { $0 += 1 } }) {}
        let later = expectation(description: "past the limit")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { later.fulfill() }
        wait(for: [later], timeout: 2)
        XCTAssertEqual(logged.withLock { $0 }, 0)
    }
}
