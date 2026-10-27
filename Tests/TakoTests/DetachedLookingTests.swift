import AppKit
import XCTest
@testable import Tako

/// A detached window the user is looking at counts as seen, so it doesn't mark unread.
@MainActor
final class DetachedLookingTests: XCTestCase {
    func testKeyDetachedWindowCountsAsLooking() {
        let session = TerminalSession(spec: LaunchSpec(label: "det", kind: .shell, cwd: "/tmp"), resume: false)
        defer { session.terminate() }
        let store = SessionStore(previewSessions: [session], previewLayout: .grid)
        session.isDetached = true

        store.sessionWantsAttention(session, title: "t", body: "b")
        XCTAssertTrue(session.unread, "no key window: the user isn't looking")
        session.unread = false

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // ARC owns it; the default double-releases
        defer { window.close() }
        window.contentView?.addSubview(session.surface)
        window.makeKeyAndOrderFront(nil)
        guard window.isKeyWindow else { return }  // headless runners may refuse key status

        XCTAssertTrue(store.userIsLooking(at: session))
        store.sessionWantsAttention(session, title: "t", body: "b")
        XCTAssertFalse(session.unread)
    }
}
