import AppKit
import XCTest
@testable import Tako

/// Detached windows snap to halves, quarters or the whole visible frame.
final class WindowSnapTests: XCTestCase {
    /// A visible frame below a menu bar and beside a left Dock, with an odd width.
    private let visible = NSRect(x: 64, y: 0, width: 1377, height: 875)

    func testHalvesAndQuartersTileTheVisibleFrameExactly() {
        for group in [[WindowSnap.leftHalf, .rightHalf], [.topHalf, .bottomHalf], [.topLeft, .topRight, .bottomLeft, .bottomRight]] {
            let frames = group.map { $0.frame(in: visible) }
            XCTAssertEqual(frames.map { $0.width * $0.height }.reduce(0, +), visible.width * visible.height, accuracy: 0.5)
            for (i, a) in frames.enumerated() {
                XCTAssertTrue(visible.contains(a), "stays clear of the menu bar and Dock")
                XCTAssertEqual(a, a.integral, "whole points")
                for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b)) }
            }
        }
    }

    func testRegionsLandWhereTheyAreNamed() {
        XCTAssertEqual(WindowSnap.leftHalf.frame(in: visible).minX, visible.minX)
        XCTAssertEqual(WindowSnap.rightHalf.frame(in: visible).maxX, visible.maxX)
        XCTAssertEqual(WindowSnap.topHalf.frame(in: visible).maxY, visible.maxY, "y grows upward")
        XCTAssertEqual(WindowSnap.bottomRight.frame(in: visible).minY, visible.minY)
        XCTAssertEqual(WindowSnap.bottomRight.frame(in: visible).maxX, visible.maxX)
        XCTAssertEqual(WindowSnap.topLeft.frame(in: visible).maxY, visible.maxY)
        XCTAssertEqual(WindowSnap.maximize.frame(in: visible), visible)
        XCTAssertEqual(Set(WindowSnap.groups.flatMap { $0 }), Set(WindowSnap.allCases), "every region is in the menu")
    }
}
