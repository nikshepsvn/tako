import AppKit
import Combine
import XCTest
@testable import Tako

final class LayoutAndLabelTests: XCTestCase {
    func testLabelsNormalize() {
        XCTAssertEqual(normalizeLabel(" @API "), "api")
        XCTAssertEqual(normalizeLabel("web server"), "web-server")
        XCTAssertEqual(normalizeLabel("ui_v2.1"), "ui_v2.1")
    }

    func testGridShapePrefersSideBySideForTwo() {
        let shape = LayoutTree.gridShape(count: 2, aspect: 1.5)
        XCTAssertEqual(shape.columns, 2)
        XCTAssertEqual(shape.rows, 1)
    }

    func testGridShapeForFourIsTwoByTwo() {
        let shape = LayoutTree.gridShape(count: 4, aspect: 1.5)
        XCTAssertEqual(shape.columns, 2)
        XCTAssertEqual(shape.rows, 2)
    }

    func testVisibleOrderDropsRemovedAndDuplicateSessions() {
        let first = UUID(), second = UUID(), removed = UUID()
        XCTAssertEqual(
            TerminalAreaView.visibleIDs([second, removed, first, second], mounted: [first, second]),
            [second, first]
        )
        XCTAssertEqual(TerminalAreaView.visibleIDs([removed], mounted: []), [])
    }

    func testEmptyGridDoesNotCreateSlots() {
        let shape = LayoutTree.gridShape(count: 0, aspect: 1.5)
        XCTAssertEqual(shape.columns, 0)
        XCTAssertEqual(shape.rows, 0)
        var tree = LayoutTree()
        tree.reconcile(visible: [], in: .zero)
        XCTAssertTrue(tree.frames(in: .zero).isEmpty)
    }

    func testTinyLayoutsNeverProduceNegativeTerminalDimensions() {
        for size in [NSSize.zero, NSSize(width: 8, height: 6), NSSize(width: 100, height: 24)] {
            let bounds = NSRect(origin: .zero, size: size)
            for count in 1...9 {
                var tree = LayoutTree()
                tree.reconcile(visible: (0..<count).map { _ in UUID() }, in: bounds)
                for frame in tree.frames(in: bounds).values {
                    XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
                    XCTAssertGreaterThanOrEqual(frame.width, 0)
                    XCTAssertGreaterThanOrEqual(frame.height, 0)
                    XCTAssertGreaterThanOrEqual(frame.minX, bounds.minX - 0.001)
                    XCTAssertGreaterThanOrEqual(frame.minY, bounds.minY - 0.001)
                    XCTAssertLessThanOrEqual(frame.maxX, bounds.maxX + 0.001)
                    XCTAssertLessThanOrEqual(frame.maxY, bounds.maxY + 0.001)
                }
            }
        }
    }

    @MainActor
    func testStatusRefreshPreservesTextFieldFocus() {
        let session = TerminalSession(spec: LaunchSpec(label: "focus-test", kind: .shell, cwd: "/tmp"), resume: false)
        defer { session.terminate() }
        let area = TerminalAreaView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 440))
        let field = NSTextField(frame: NSRect(x: 12, y: 410, width: 180, height: 24))
        container.addSubview(area)
        container.addSubview(field)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        area.mount(session)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editingResponder = window.firstResponder

        area.apply(mode: .focus, visible: [session.id], focused: session.id, takeFocus: false)
        XCTAssertTrue(window.firstResponder === editingResponder)

        area.apply(mode: .focus, visible: [session.id], focused: session.id, takeFocus: true)
        XCTAssertTrue(window.firstResponder === session.surface)
    }

    @MainActor
    func testHeaderCoalescesVisibleChangesAndIgnoresUnrelatedMetrics() async {
        let session = TerminalSession(spec: LaunchSpec(label: "header-test", kind: .shell, cwd: "/tmp"), resume: false)
        defer { session.terminate() }
        let model = TileHeaderModel(session: session)
        model.setVisible(true, session: session)
        var updates = 0
        let subscription = model.$snapshot.dropFirst().sink { _ in updates += 1 }
        defer { subscription.cancel() }

        session.unread = true
        session.readyForReview = true
        await drainMainQueue()
        XCTAssertEqual(updates, 0)

        session.ports = [4100]
        session.ports = [4100, 4200]
        session.foregroundProcess = "node"
        await drainMainQueue()
        XCTAssertEqual(updates, 1)
        XCTAssertEqual(model.snapshot.ports, [4100, 4200])
        XCTAssertEqual(model.snapshot.summary, "node")
    }

    @MainActor
    func testHiddenHeaderDefersUpdatesUntilShown() async {
        let session = TerminalSession(spec: LaunchSpec(label: "hidden-test", kind: .shell, cwd: "/tmp"), resume: false)
        defer { session.terminate() }
        let model = TileHeaderModel(session: session)
        session.ports = [4100]
        await drainMainQueue()
        XCTAssertTrue(model.snapshot.ports.isEmpty)

        model.setVisible(true, session: session)
        XCTAssertEqual(model.snapshot.ports, [4100])
        model.setVisible(false, session: session)
        session.ports = [4200]
        await drainMainQueue()
        XCTAssertEqual(model.snapshot.ports, [4100])

        model.setVisible(true, session: session)
        XCTAssertEqual(model.snapshot.ports, [4200])
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testFuzzyScore() {
        XCTAssertEqual(SwitcherModel.fuzzyScore("ap", "api"), 100)
        XCTAssertGreaterThan(SwitcherModel.fuzzyScore("ai", "api"), 0)
        XCTAssertEqual(SwitcherModel.fuzzyScore("zz", "api"), 0)
    }

    func testShortPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(shortPath(home + "/Code/app"), "~/Code/app")
        XCTAssertEqual(shortPath("/a/b/c/d/e"), "…/d/e")
    }
}
