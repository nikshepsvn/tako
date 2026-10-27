import XCTest
@testable import Tako

/// Selection and arrangement when tiles close, minimize, or live in their own windows, and the
/// reaper's wait before a closed agent's worktree is removed. Preview stores write nothing to disk.
@MainActor
final class ReleaseFixesUITests: XCTestCase {
    func testClosingAnUnselectedTileReflowsWithoutTakingFocus() {
        let api = shell("api"), web = shell("web"), db = shell("db")
        let store = SessionStore(previewSessions: [api, web, db], previewLayout: .grid)
        store.select(api)
        var refreshes = 0, arrangements = 0
        store.onStatusChange = { refreshes += 1 }
        store.onArrangementChange = { arrangements += 1 }

        store.close(web)

        XCTAssertEqual(store.selectedID, api.id)
        XCTAssertEqual(Set(store.visibleIDs), [api.id, db.id])
        XCTAssertEqual(refreshes, 1, "the canvas re-flows into the closed tile's space")
        XCTAssertEqual(arrangements, 0, "the selection didn't change, so focus stays put")
    }

    func testClosingTheSelectedTileArrangesOnce() {
        let api = shell("api"), web = shell("web")
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        store.select(web)
        var refreshes = 0, arrangements = 0
        store.onStatusChange = { refreshes += 1 }
        store.onArrangementChange = { arrangements += 1 }

        store.close(web)

        XCTAssertEqual(store.selectedID, api.id)
        XCTAssertEqual(arrangements, 1)
        XCTAssertEqual(refreshes, 0)
    }

    func testMinimizingTheFocusedTileInFocusShowsAnotherOnTheCanvas() {
        let api = shell("api"), web = shell("web"), db = shell("db")
        let store = SessionStore(previewSessions: [api, web, db], previewLayout: .focus)
        db.isDetached = true
        store.select(web)

        store.setMinimized(web, true)

        XCTAssertEqual(store.selectedID, api.id, "skips the detached session, like close does")
        XCTAssertEqual(store.visibleIDs, [api.id])
    }

    func testMinimizingTheFocusedTileInSplitShowsTheOtherHalf() {
        let api = shell("api"), web = shell("web")
        let store = SessionStore(previewSessions: [api, web], previewLayout: .split)
        store.select(api)
        store.select(web)

        store.setMinimized(web, true)

        XCTAssertEqual(store.selectedID, api.id)
        XCTAssertEqual(store.visibleIDs, [api.id])
    }

    func testChoosingADetachedSessionDoesNotReenterSelect() {
        let api = shell("api"), web = shell("web")
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        store.select(api)
        web.isDetached = true
        api.lastViewedAt = .distantPast
        var selectedWhenShown: UUID?
        var nested = 0
        store.onShowDetached = { [unowned store] session in
            selectedWhenShown = store.selectedID
            // What the tile's window delegate does when that window becomes key.
            if store.selectedID != session.id { nested += 1; store.select(session) }
        }

        store.select(web)

        XCTAssertEqual(selectedWhenShown, web.id)
        XCTAssertEqual(nested, 0)
        XCTAssertEqual(store.selectedID, web.id)
        XCTAssertGreaterThan(api.lastViewedAt, .distantPast, "the session left behind is marked as viewed")
    }

    func testWorktreeWaitRunsAfterTheStopUnderWay() {
        // No process has this pid (macOS caps pids below 100000), so nothing is signalled.
        let process = TrackedProcess(pid: 999_999, start: 0, session: "release-fixes-wait")
        let stopped = expectation(description: "stop finished")
        let waited = expectation(description: "waiter ran")
        SessionReaper.stop([process], grace: 0.2) { stopped.fulfill() }
        SessionReaper.whenStopped(session: "release-fixes-wait") { waited.fulfill() }
        wait(for: [stopped, waited], timeout: 3, enforceOrder: true)
    }

    func testWorktreeWaitRunsAtOnceWithNothingToStop() {
        let waited = expectation(description: "waiter ran")
        SessionReaper.whenStopped(session: "release-fixes-none") { waited.fulfill() }
        wait(for: [waited], timeout: 1)
    }

    private func shell(_ label: String) -> TerminalSession {
        TerminalSession(spec: LaunchSpec(label: label, kind: .shell, cwd: "/tmp"), resume: false)
    }
}
