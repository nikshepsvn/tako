import XCTest
@testable import Tako

/// A new agent's brief carries its project's team board, bounded, and nothing when it's empty.
@MainActor
final class TeamBoardBriefTests: XCTestCase {
    func testAnEmptyBoardAddsNothing() async {
        XCTAssertNil(TeamBoard().briefSection(project: "atlas"))
        let (store, _) = fixture()
        let task = await store.withTeamBoard("Add /orders", folder: "/workspace/atlas")
        XCTAssertEqual(task, "Add /orders", "a brief without a board is exactly as before")
    }

    func testTheSectionHasTheLatestNotesAndLiveClaims() {
        var board = TeamBoard()
        for index in 1...7 { board.add(BoardNote(author: "api", text: "note \(index)\nsecond line", date: Date())) }
        let now = Date()
        _ = board.claim(["src/auth/**"], owner: UUID(), label: "api", until: now.addingTimeInterval(600))
        _ = board.claim(["docs"], owner: UUID(), label: "web", until: now.addingTimeInterval(-1))
        XCTAssertEqual(board.briefSection(project: "atlas", now: now), """
        Team board for atlas (team_board read for all of it):
        - @api: note 3 second line
        - @api: note 4 second line
        - @api: note 5 second line
        - @api: note 6 second line
        - @api: note 7 second line
        Claimed: @api src/auth/**
        """, "the last five notes on one line each; expired claims left out")

        var claimsOnly = TeamBoard()
        _ = claimsOnly.claim(["a.ts"], owner: UUID(), label: "db", until: now.addingTimeInterval(60))
        XCTAssertEqual(claimsOnly.briefSection(project: "atlas", now: now),
                       "Team board for atlas (team_board read for all of it):\nClaimed: @db a.ts")
    }

    func testTheSectionStaysWithinItsCap() throws {
        var board = TeamBoard()
        for _ in 1...5 { board.add(BoardNote(author: "api", text: String(repeating: "x", count: 500), date: Date())) }
        let paths = (1...20).map { "src/module\($0)/**" }
        _ = board.claim(paths, owner: UUID(), label: "web", until: Date().addingTimeInterval(600))
        let section = try XCTUnwrap(board.briefSection(project: "atlas"))
        XCTAssertLessThanOrEqual(section.count, 600)
        XCTAssertTrue(section.contains("- @api: " + String(repeating: "x", count: 100)), "long notes are cut, not dropped whole")
        XCTAssertTrue(section.contains("Claimed: @web src/module1/**"), "claims survive the cap")
    }

    func testStartedAgentsGetTheBoardOfTheirProject() async {
        let (store, me) = fixture()
        var note = ControlRequest(cmd: .board)
        note.text = "note"
        note.label = "POST /orders takes {sku, qty}"
        ControlHandler(store: store, caller: .session(me.id.uuidString)).handle(note) { _ in }
        let task = await store.withTeamBoard("Add /orders", folder: "/workspace/atlas")
        XCTAssertEqual(task, """
        Add /orders

        Team board for atlas (team_board read for all of it):
        - @me: POST /orders takes {sku, qty}
        """)
        let elsewhere = await store.withTeamBoard("Fix docs", folder: "/workspace/other")
        XCTAssertEqual(elsewhere, "Fix docs", "another project's board stays out")
    }

    private func fixture() -> (SessionStore, TerminalSession) {
        let me = TerminalSession(spec: LaunchSpec(label: "me", kind: .claude, cwd: "/workspace/atlas"), resume: false)
        let store = SessionStore(previewSessions: [me], previewLayout: .grid)
        me.store = store
        return (store, me)
    }
}
