import Foundation
import XCTest
@testable import Tako

final class LayoutTreeTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    private func assertTiles(_ frames: [UUID: CGRect], in bounds: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        let rects = Array(frames.values)
        for (i, a) in rects.enumerated() {
            XCTAssertTrue(bounds.contains(a), "tile escapes bounds", file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.height, 0, file: file, line: line)
            for b in rects[(i + 1)...] {
                XCTAssertFalse(a.intersects(b), "tiles overlap", file: file, line: line)
            }
        }
    }

    func testBalancedGridCoversEveryTileWithoutOverlap() {
        for count in 1...9 {
            var tree = LayoutTree()
            let order = ids(count)
            tree.reconcile(visible: order, in: bounds)
            XCTAssertEqual(tree.leaves, order, "keeps reading order for \(count)")
            let frames = tree.frames(in: bounds)
            XCTAssertEqual(frames.count, count)
            assertTiles(frames, in: bounds)
        }
    }

    func testTwoTilesSitSideBySideAndEven() {
        var tree = LayoutTree()
        let order = ids(2)
        tree.reconcile(visible: order, in: bounds)
        let frames = tree.frames(in: bounds)
        let a = frames[order[0]]!, b = frames[order[1]]!
        XCTAssertEqual(a.minY, b.minY)
        XCTAssertLessThan(a.maxX, b.minX)
        XCTAssertEqual(a.width, b.width, accuracy: 1)
    }

    func testThreeColumnsAreEqualWidth() {
        let order = ids(3)
        let root = LayoutTree.balanced(order, aspect: 3)!
        let tree = LayoutTree(root: root)
        let widths = order.map { tree.frames(in: CGRect(x: 0, y: 0, width: 1500, height: 500))[$0]!.width }
        XCTAssertEqual(widths.max()! - widths.min()!, 0, accuracy: 0.5)
    }

    func testUncustomizedTreeRebalancesWhenTilesChange() {
        var tree = LayoutTree()
        let order = ids(3)
        tree.reconcile(visible: order, in: bounds)
        tree.reconcile(visible: Array(order.prefix(2)), in: bounds)
        XCTAssertEqual(tree.root, LayoutTree.balanced(Array(order.prefix(2)), aspect: 1.5))
    }

    func testDraggingADividerResizesAndSticks() throws {
        var tree = LayoutTree()
        let order = ids(2)
        tree.reconcile(visible: order, in: bounds)
        let divider = try XCTUnwrap(tree.dividers(in: bounds).first)
        XCTAssertEqual(divider.axis, .horizontal)
        tree.move(divider, to: 0.7)
        XCTAssertTrue(tree.customized)
        let wide = tree.frames(in: bounds)[order[0]]!.width
        XCTAssertGreaterThan(wide, bounds.width * 0.65)

        // A new tile doesn't undo the user's sizing; it splits the biggest tile.
        let third = UUID()
        tree.reconcile(visible: order + [third], in: bounds)
        let frames = tree.frames(in: bounds)
        XCTAssertEqual(frames.count, 3)
        assertTiles(frames, in: bounds)
        XCTAssertEqual(frames[order[1]]!.width, bounds.width - wide - LayoutTree.gap, accuracy: 1)
    }

    func testClosingATileGivesItsSpaceToItsSibling() {
        var tree = LayoutTree()
        let order = ids(3)
        tree.reconcile(visible: order, in: bounds)
        tree.customized = true
        tree.reconcile(visible: [order[0], order[2]], in: bounds)
        XCTAssertEqual(Set(tree.leaves), [order[0], order[2]])
        assertTiles(tree.frames(in: bounds), in: bounds)
        tree.reconcile(visible: [], in: bounds)
        XCTAssertNil(tree.root)
        XCTAssertFalse(tree.customized)
    }

    func testRatioIsClampedToTheMinimumTile() throws {
        var tree = LayoutTree()
        let order = ids(2)
        tree.reconcile(visible: order, in: bounds)
        let divider = try XCTUnwrap(tree.dividers(in: bounds).first)
        tree.move(divider, to: 0.01)
        XCTAssertGreaterThanOrEqual(tree.frames(in: bounds)[order[0]]!.width, LayoutTree.minTile.width - 1)
        tree.move(divider, to: 0.99)
        XCTAssertGreaterThanOrEqual(tree.frames(in: bounds)[order[1]]!.width, LayoutTree.minTile.width - 1)
    }

    func testSwapTradesPlacesAndKeepsSizes() throws {
        var tree = LayoutTree()
        let order = ids(2)
        tree.reconcile(visible: order, in: bounds)
        let divider = try XCTUnwrap(tree.dividers(in: bounds).first)
        tree.move(divider, to: 0.3)
        let before = tree.frames(in: bounds)
        tree.swap(order[0], order[1])
        let after = tree.frames(in: bounds)
        XCTAssertEqual(after[order[1]], before[order[0]])
        XCTAssertEqual(after[order[0]], before[order[1]])
    }

    func testEvenOutRestoresEqualColumns() throws {
        var tree = LayoutTree()
        let order = ids(3)
        let wide = CGRect(x: 0, y: 0, width: 1800, height: 500)
        tree.reconcile(visible: order, in: wide)
        let divider = try XCTUnwrap(tree.dividers(in: wide).first)
        tree.move(divider, to: 0.6)
        tree.evenOut(divider)
        let widths = order.map { tree.frames(in: wide)[$0]!.width }
        XCTAssertEqual(widths[0], widths[1], accuracy: 0.5)
        XCTAssertEqual(widths[1], widths[2], accuracy: 0.5)
    }

    func testMovingADividerOnlyResizesItsNeighbors() throws {
        var tree = LayoutTree()
        let order = ids(3)
        let wide = CGRect(x: 0, y: 0, width: 1800, height: 500)
        tree.reconcile(visible: order, in: wide)
        let before = tree.frames(in: wide)[order[2]]!
        let divider = try XCTUnwrap(tree.dividers(in: wide).first { $0.index == 0 })
        tree.move(divider, to: 0.25)
        XCTAssertEqual(tree.frames(in: wide)[order[2]]!, before)
        XCTAssertLessThan(tree.frames(in: wide)[order[0]]!.width, tree.frames(in: wide)[order[1]]!.width)
    }

    func testPointerMapsBackToTheSameRatio() throws {
        var tree = LayoutTree()
        let order = ids(4)
        tree.reconcile(visible: order, in: bounds)
        for divider in tree.dividers(in: bounds) {
            let point = CGPoint(x: divider.frame.midX, y: divider.frame.midY)
            let ratio = LayoutTree.fraction(for: point, divider: divider)
            XCTAssertGreaterThan(ratio, 0.2)
            XCTAssertLessThan(ratio, 0.8)
        }
    }

    func testSnapsNearHalf() {
        let container = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let divider = LayoutDivider(path: [], index: 0, axis: .horizontal, frame: .zero, span: container)
        XCTAssertEqual(LayoutTree.snapped(0.505, divider: divider), 0.5)
        XCTAssertEqual(LayoutTree.snapped(0.42, divider: divider), 0.42)
    }

    func testTinyBoundsNeverProduceNegativeFrames() {
        for size in [CGSize.zero, CGSize(width: 8, height: 6), CGSize(width: 100, height: 24)] {
            var tree = LayoutTree()
            let rect = CGRect(origin: .zero, size: size)
            tree.reconcile(visible: ids(5), in: rect)
            for frame in tree.frames(in: rect).values {
                XCTAssertGreaterThanOrEqual(frame.width, 0)
                XCTAssertGreaterThanOrEqual(frame.height, 0)
            }
        }
    }

    func testRoundTripsThroughJSON() throws {
        var tree = LayoutTree()
        tree.reconcile(visible: ids(4), in: bounds)
        tree.customized = true
        let data = try JSONEncoder().encode(tree)
        XCTAssertEqual(try JSONDecoder().decode(LayoutTree.self, from: data), tree)
    }
}
