import XCTest
@testable import Tako

/// Tiles popped out into their own windows leave the canvas's layouts.
@MainActor
final class DetachedTileTests: XCTestCase {
    func testDetachedSessionLeavesGridAndSplit() {
        let api = agent("api"), web = agent("web"), db = agent("db")
        let store = SessionStore(previewSessions: [api, web, db], previewLayout: .grid)
        web.isDetached = true

        XCTAssertEqual(Set(store.visibleIDs), [api.id, db.id])
        web.isDetached = false
        XCTAssertTrue(store.visibleIDs.contains(web.id))

        let split = SessionStore(previewSessions: [api, web], previewLayout: .split)
        split.select(api)
        split.select(web)
        web.isDetached = true
        XCTAssertEqual(split.visibleIDs, [api.id])
    }

    func testChoosingADetachedSessionBringsItsWindowForward() {
        let api = agent("api"), web = agent("web")
        let store = SessionStore(previewSessions: [api, web], previewLayout: .grid)
        web.isDetached = true
        var shown: [UUID] = []
        store.onShowDetached = { shown.append($0.id) }

        store.select(api)
        store.select(web)

        XCTAssertEqual(shown, [web.id])
        XCTAssertEqual(store.selectedID, web.id)
    }

    private func agent(_ label: String) -> TerminalSession {
        let session = TerminalSession(spec: LaunchSpec(label: label, kind: .claude, cwd: "/workspace/atlas"), resume: false)
        session.apply(.processStarted, source: "test", force: .idle)
        return session
    }
}
