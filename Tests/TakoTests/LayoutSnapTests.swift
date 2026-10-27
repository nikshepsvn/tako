import Foundation
import XCTest
@testable import Tako

/// Snap zones: dragging a tile onto half of another splits it, onto its center swaps, onto the
/// canvas's edge makes a full column or row. No move loses a tile or squeezes one below minimum.
final class LayoutSnapTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func tree(_ root: LayoutNode) -> LayoutTree { LayoutTree(root: root) }

    /// A | B | C, side by side.
    private func row(_ ids: [UUID]) -> LayoutNode {
        LayoutNode.split(.horizontal, ids.map { (weight: 1.0, node: LayoutNode.leaf($0)) })!
    }

    func testMovingBesideSplitsTheTargetOnThatSide() {
        let a = UUID(), b = UUID(), c = UUID()
        var layout = tree(row([a, b, c]))
        XCTAssertTrue(layout.move(a, beside: c, edge: .top, in: bounds))
        // A leaves the row (its neighbor B takes its share); C's column is now A over C.
        XCTAssertEqual(layout.root, .split(axis: .horizontal, weights: [2, 1], children: [
            .leaf(b), .split(axis: .vertical, weights: [1, 1], children: [.leaf(a), .leaf(c)]),
        ]))
        XCTAssertTrue(layout.customized)
        let frames = layout.frames(in: bounds)
        XCTAssertGreaterThan(frames[a]!.minY, frames[c]!.minY, "A sits above C (y grows upward)")
        XCTAssertEqual(frames[a]!.minX, frames[c]!.minX)
    }

    func testEveryEdgeLandsOnItsSide() {
        for edge in LayoutEdge.allCases {
            let a = UUID(), b = UUID()
            var layout = tree(.split(axis: .vertical, weights: [1, 1], children: [.leaf(a), .leaf(b)]))
            XCTAssertTrue(layout.move(a, beside: b, edge: edge, in: bounds), "\(edge)")
            let frames = layout.frames(in: bounds)
            let moved = frames[a]!, target = frames[b]!
            switch edge {
            case .left: XCTAssertLessThan(moved.maxX, target.minX)
            case .right: XCTAssertGreaterThan(moved.minX, target.maxX)
            case .top: XCTAssertGreaterThan(moved.minY, target.maxY)
            case .bottom: XCTAssertLessThan(moved.maxY, target.minY)
            }
        }
    }

    func testCanvasEdgeMakesAFullHeightColumnMatchingTheOthers() {
        let ids = (0..<4).map { _ in UUID() }
        var layout = tree(LayoutTree.balanced(ids, aspect: 1.5)!) // 2 x 2
        XCTAssertTrue(layout.move(ids[3], toCanvas: .left, in: bounds))
        let frames = layout.frames(in: bounds)
        XCTAssertEqual(frames[ids[3]]!.height, bounds.height, accuracy: 0.5, "full height")
        XCTAssertEqual(frames[ids[3]]!.minX, bounds.minX)
        XCTAssertEqual(Set(layout.leaves), Set(ids))
    }

    func testCanvasEdgeColumnTakesAnEqualShareOfAnExistingRow() {
        let ids = (0..<3).map { _ in UUID() }
        var layout = tree(row(Array(ids.prefix(2))))
        layout.reconcile(visible: ids, in: bounds) // uncustomized: rebalanced as a row of 3
        var moved = layout
        XCTAssertTrue(moved.move(ids[0], toCanvas: .right, in: bounds))
        let widths = moved.frames(in: bounds).values.map(\.width)
        XCTAssertEqual(widths.max()! - widths.min()!, 0, accuracy: 1, "three equal columns")
        XCTAssertEqual(moved.leaves.last, ids[0])
    }

    func testCanvasBottomMakesAFullWidthRow() {
        let ids = (0..<3).map { _ in UUID() }
        var layout = tree(row(ids))
        XCTAssertTrue(layout.move(ids[1], toCanvas: .bottom, in: bounds))
        let frame = layout.frames(in: bounds)[ids[1]]!
        XCTAssertEqual(frame.width, bounds.width, accuracy: 0.5)
        XCTAssertEqual(frame.minY, bounds.minY)
    }

    func testMoveRefusedWhenItWouldSqueezeATileBelowMinimum() {
        // Three ≈197pt columns. A's share goes to B, so C stays ≈197pt; halving it side by side
        // would leave ≈94pt.
        let narrow = CGRect(x: 0, y: 0, width: 600, height: 800)
        let a = UUID(), b = UUID(), c = UUID()
        var layout = tree(row([a, b, c]))
        let before = layout
        XCTAssertFalse(layout.move(a, beside: c, edge: .left, in: narrow))
        XCTAssertEqual(layout, before, "a refused move changes nothing")
        // Stacking in the same column fits.
        XCTAssertTrue(layout.move(a, beside: c, edge: .top, in: narrow))
        XCTAssertEqual(layout.undersized(in: narrow), 0)
    }

    func testRefusedOrDegenerateMovesChangeNothing() {
        let a = UUID(), b = UUID(), stranger = UUID()
        var layout = tree(row([a, b]))
        let before = layout
        XCTAssertFalse(layout.move(a, beside: a, edge: .left, in: bounds))
        XCTAssertFalse(layout.move(stranger, beside: a, edge: .left, in: bounds))
        XCTAssertFalse(layout.move(a, beside: stranger, edge: .left, in: bounds))
        XCTAssertFalse(layout.move(stranger, toCanvas: .left, in: bounds))
        var single = tree(.leaf(a))
        XCTAssertFalse(single.move(a, toCanvas: .left, in: bounds))
        XCTAssertEqual(layout, before)
    }

    func testNoMoveEverLosesOrDuplicatesATile() {
        let ids = (0..<5).map { _ in UUID() }
        var layout = tree(LayoutTree.balanced(ids, aspect: 1.5)!)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let id = ids.randomElement(using: &generator)!
            let target = ids.randomElement(using: &generator)!
            let edge = LayoutEdge.allCases.randomElement(using: &generator)!
            if Bool.random(using: &generator) {
                layout.move(id, beside: target, edge: edge, in: bounds)
            } else {
                layout.move(id, toCanvas: edge, in: bounds)
            }
            XCTAssertEqual(layout.leaves.count, ids.count)
            XCTAssertEqual(Set(layout.leaves), Set(ids))
            let frames = layout.frames(in: bounds)
            for (i, x) in frames.values.enumerated() {
                XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(x))
                for y in Array(frames.values)[(i + 1)...] { XCTAssertFalse(x.insetBy(dx: 0.5, dy: 0.5).intersects(y), "tiles overlap") }
            }
        }
    }

    func testSwapDropKeepsSizesAndEvenState() {
        let a = UUID(), b = UUID()
        var layout = tree(.split(axis: .horizontal, weights: [3, 1], children: [.leaf(a), .leaf(b)]))
        XCTAssertTrue(layout.apply(.swap(b), moving: a, in: bounds))
        XCTAssertEqual(layout.root, .split(axis: .horizontal, weights: [3, 1], children: [.leaf(b), .leaf(a)]))
        XCTAssertFalse(layout.customized)
    }

    func testDropZonesUnderThePointer() {
        let a = UUID(), b = UUID()
        let layout = tree(row([a, b]))
        let target = layout.frames(in: bounds)[b]!
        XCTAssertEqual(layout.drop(at: CGPoint(x: target.midX, y: target.midY), dragging: a, in: bounds), .swap(b))
        XCTAssertEqual(layout.drop(at: CGPoint(x: target.minX + 40, y: target.midY), dragging: a, in: bounds), .beside(b, .left))
        XCTAssertEqual(layout.drop(at: CGPoint(x: target.maxX - 40, y: target.midY), dragging: a, in: bounds), .beside(b, .right))
        XCTAssertEqual(layout.drop(at: CGPoint(x: target.midX, y: target.maxY - 60), dragging: a, in: bounds), .beside(b, .top))
        XCTAssertEqual(layout.drop(at: CGPoint(x: target.midX, y: target.minY + 60), dragging: a, in: bounds), .beside(b, .bottom))
        XCTAssertEqual(layout.drop(at: CGPoint(x: bounds.maxX - 4, y: bounds.midY), dragging: a, in: bounds), .canvas(.right))
        XCTAssertEqual(layout.drop(at: CGPoint(x: bounds.midX - 300, y: bounds.maxY - 4), dragging: a, in: bounds), .canvas(.top))
        // Over its own spot, or off the canvas: nothing.
        let own = layout.frames(in: bounds)[a]!
        XCTAssertNil(layout.drop(at: CGPoint(x: own.midX, y: own.midY), dragging: a, in: bounds))
        XCTAssertNil(layout.drop(at: CGPoint(x: -10, y: 10), dragging: a, in: bounds))
    }

    func testPreviewMatchesTheCommittedFrame() {
        let ids = (0..<3).map { _ in UUID() }
        let layout = tree(row(ids))
        for drop in [LayoutDrop.swap(ids[2]), .beside(ids[2], .bottom), .canvas(.top)] {
            var committed = layout
            XCTAssertTrue(committed.apply(drop, moving: ids[0], in: bounds))
            XCTAssertEqual(layout.preview(drop, moving: ids[0], in: bounds), committed.frames(in: bounds)[ids[0]])
        }
        XCTAssertNil(layout.preview(.beside(ids[0], .left), moving: ids[0], in: bounds))
    }
}
