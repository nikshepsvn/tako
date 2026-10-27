import AppKit
import XCTest
@testable import Tako

/// Regressions from the memory soak (scripts/soak.sh): what grew without bound over a long run.
final class MemoryGrowthTests: XCTestCase {
    // MARK: - Scrollback

    func testUserScrollbackAboveCapIsCapped() {
        let config = "font-size = 13\nscrollback-limit = 100000000\n"
        XCTAssertEqual(ScrollbackCap.cappedLimit(configText: config), ScrollbackCap.maxBytes)
    }

    func testLastScrollbackSettingWins() {
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: "scrollback-limit = 100_000_000\nscrollback-limit = 2000000"))
        XCTAssertNotNil(ScrollbackCap.cappedLimit(configText: "scrollback-limit=5000000\nscrollback-limit = 50_000_000"))
    }

    func testSmallOrMissingScrollbackIsLeftAlone() {
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: "scrollback-limit = 1000000"))
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: "# scrollback-limit = 100000000\ntheme = dark"))
        XCTAssertNil(ScrollbackCap.cappedLimit(configText: ""))
    }

    // MARK: - Closed sessions

    @MainActor
    func testClosedSessionIsFreed() {
        weak var closed: TerminalSession?
        weak var closedSurface: NSView?
        let keep = TerminalSession(spec: LaunchSpec(label: "keep", kind: .shell, cwd: "/tmp"), resume: false)
        defer { keep.terminate() }
        let store: SessionStore = autoreleasepool {
            let agent = TerminalSession(spec: LaunchSpec(label: "gone", kind: .claude, cwd: "/tmp"), resume: false)
            let store = SessionStore(previewSessions: [keep, agent], previewLayout: .grid)
            agent.record(.prompt, "a turn")
            store.select(agent)
            store.close(agent)
            closed = agent
            closedSurface = agent.surface
            return store
        }
        // The surface is freed on the next main-queue turn.
        let drained = expectation(description: "main queue turn")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertEqual(store.sessions.map(\.label), ["keep"])
        XCTAssertNil(closed, "a closed session must not outlive its close")
        XCTAssertNil(closedSurface, "nor its terminal view")
    }

    @MainActor
    func testDestroyedSurfaceDropsItsLastFrame() {
        let view = TerminalSurfaceView(launch: SurfaceLaunch(workingDirectory: "/tmp", command: nil, environment: [:]))
        view.layer?.contents = NSImage(size: NSSize(width: 8, height: 8))
        let sub = CALayer()
        sub.contents = NSImage(size: NSSize(width: 8, height: 8))
        view.layer?.addSublayer(sub)

        view.dropLastFrame()

        XCTAssertNil(view.layer?.contents)
        XCTAssertTrue(view.layer?.sublayers?.isEmpty ?? true)
        view.destroy()
    }

    func testConfigFilesFollowXDG() {
        let files = ScrollbackCap.userConfigFiles(environment: ["XDG_CONFIG_HOME": "/x"], home: URL(fileURLWithPath: "/h"))
        XCTAssertEqual(files.first?.path, "/x/ghostty/config")
        XCTAssertEqual(files.last?.path, "/h/Library/Application Support/com.mitchellh.ghostty/config.ghostty")
    }
}
