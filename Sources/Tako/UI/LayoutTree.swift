import Foundation

/// How tiles share the canvas: a binary tree of splits whose leaves are sessions. Pure geometry
/// with no AppKit, so it is unit-tested on its own.
///
/// While the user hasn't touched a divider, the tree is rebuilt as an even grid whenever the
/// visible set changes. Once they drag a divider it becomes theirs: new tiles split the largest
/// tile, closed tiles hand their space to their sibling, and nothing re-evens behind their back.
indirect enum LayoutNode: Equatable, Codable {
    case leaf(UUID)
    /// Children laid out along `axis`, each taking its weight's share of the space left after gaps.
    case split(axis: LayoutAxis, weights: [Double], children: [LayoutNode])

    var leaves: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let children): return children.flatMap(\.leaves)
        }
    }

    func contains(_ id: UUID) -> Bool { leaves.contains(id) }

    /// One child is just that child; a nested split along the same axis joins its parent.
    static func split(_ axis: LayoutAxis, _ pairs: [(weight: Double, node: LayoutNode)]) -> LayoutNode? {
        var flat: [(Double, LayoutNode)] = []
        for (weight, node) in pairs where weight > 0 {
            if case .split(let inner, let weights, let children) = node, inner == axis {
                let total = weights.reduce(0, +)
                for (w, child) in zip(weights, children) { flat.append((weight * w / max(total, .ulpOfOne), child)) }
            } else {
                flat.append((weight, node))
            }
        }
        if flat.isEmpty { return nil }
        if flat.count == 1 { return flat[0].1 }
        return .split(axis: axis, weights: flat.map(\.0), children: flat.map(\.1))
    }
}

/// `horizontal`: children side by side, dividers vertical. `vertical`: stacked, dividers horizontal.
enum LayoutAxis: String, Codable {
    case horizontal, vertical
}

/// A draggable gap between two neighboring children of a split.
struct LayoutDivider: Equatable {
    /// Child indexes from the root to the split it resizes.
    let path: [Int]
    /// The divider sits after child `index` and before `index + 1`.
    let index: Int
    let axis: LayoutAxis
    /// The gap itself, in the canvas's coordinates.
    let frame: CGRect
    /// The two neighbors together, gap included: the span the divider can travel.
    let span: CGRect
}

struct LayoutTree: Equatable, Codable {
    var root: LayoutNode?
    /// True once the user resized something; the tree then stops re-evening itself.
    var customized = false

    static let gap: CGFloat = 8
    /// Smallest tile the user can drag down to. Terminals stay usable at this size.
    static let minTile = CGSize(width: 180, height: 110)

    var leaves: [UUID] { root?.leaves ?? [] }

    // MARK: - Building

    /// An even grid in `order`, shaped for the canvas's aspect ratio.
    static func balanced(_ order: [UUID], aspect: CGFloat) -> LayoutNode? {
        guard !order.isEmpty else { return nil }
        let shape = gridShape(count: order.count, aspect: aspect)
        var rows: [(weight: Double, node: LayoutNode)] = []
        var index = 0
        for _ in 0..<shape.rows where index < order.count {
            let count = min(shape.columns, order.count - index)
            let cells = order[index..<(index + count)].map { (weight: 1.0, node: LayoutNode.leaf($0)) }
            if let row = LayoutNode.split(.horizontal, cells) { rows.append((1, row)) }
            index += count
        }
        return LayoutNode.split(.vertical, rows)
    }

    /// Picks the column count whose cells are closest to a comfortable terminal shape. Slightly
    /// wide of square: agent TUIs want height, and side-by-side reads better than stacked.
    static func gridShape(count: Int, aspect: CGFloat) -> (columns: Int, rows: Int) {
        guard count > 0 else { return (0, 0) }
        let aspect = max(aspect.isFinite ? aspect : 1, 0.001)
        let target: CGFloat = 1.1
        var best = (columns: 1, rows: count)
        var bestScore = CGFloat.greatestFiniteMagnitude
        for columns in 1...count {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cellAspect = aspect * CGFloat(rows) / CGFloat(columns)
            let empty = CGFloat(columns * rows - count) * 0.35
            let score = abs(log(cellAspect / target)) + empty
            if score < bestScore {
                bestScore = score
                best = (columns, rows)
            }
        }
        return best
    }

    // MARK: - Reconciling with the visible set

    /// Brings the tree in line with the tiles that should show, in `order` for new ones.
    mutating func reconcile(visible order: [UUID], in bounds: CGRect) {
        let aspect = bounds.width / max(bounds.height, 1)
        guard customized, let current = root else {
            root = Self.balanced(order, aspect: aspect)
            return
        }
        let wanted = Set(order)
        var node: LayoutNode? = current
        for id in current.leaves where !wanted.contains(id) { node = node.flatMap { Self.removing(id, from: $0) } }
        for id in order where !(node?.contains(id) ?? false) {
            node = node.map { Self.inserting(id, into: $0, bounds: bounds) } ?? .leaf(id)
        }
        root = node
        if root == nil { customized = false }
    }

    /// Back to an even grid, keeping the current order.
    mutating func reset(in bounds: CGRect) {
        customized = false
        root = Self.balanced(leaves, aspect: bounds.width / max(bounds.height, 1))
    }

    /// A closed tile's space goes to the neighbor that shared its edge.
    static func removing(_ id: UUID, from node: LayoutNode) -> LayoutNode? {
        switch node {
        case .leaf(let leaf): return leaf == id ? nil : node
        case .split(let axis, var weights, let children):
            var kept: [(weight: Double, node: LayoutNode)] = []
            for (index, child) in children.enumerated() {
                if let next = removing(id, from: child) {
                    kept.append((weights[index], next))
                } else {
                    let neighbor = index > 0 ? index - 1 : index + 1
                    if weights.indices.contains(neighbor) { weights[neighbor] += weights[index] }
                    if neighbor < index, !kept.isEmpty { kept[kept.count - 1].weight = weights[neighbor] }
                }
            }
            return LayoutNode.split(axis, kept)
        }
    }

    /// Splits the largest tile in half along its longer side and puts `id` in the new half.
    static func inserting(_ id: UUID, into node: LayoutNode, bounds: CGRect) -> LayoutNode {
        let frames = leafFrames(node, in: bounds, gap: 0)
        guard let target = frames.max(by: { $0.value.width * $0.value.height < $1.value.width * $1.value.height }) else {
            return LayoutNode.split(.horizontal, [(1, node), (1, .leaf(id))]) ?? node
        }
        let axis: LayoutAxis = target.value.width >= target.value.height * 1.2 ? .horizontal : .vertical
        return replacing(target.key, in: node) { LayoutNode.split(axis, [(1, $0), (1, .leaf(id))]) ?? $0 }
    }

    private static func replacing(_ id: UUID, in node: LayoutNode, with make: (LayoutNode) -> LayoutNode) -> LayoutNode {
        switch node {
        case .leaf(let leaf): return leaf == id ? make(node) : node
        case .split(let axis, let weights, let children):
            let pairs = zip(weights, children).map { (weight: $0, node: replacing(id, in: $1, with: make)) }
            return LayoutNode.split(axis, pairs) ?? node
        }
    }

    // MARK: - Editing

    /// Trades places between two tiles; sizes stay where they are.
    mutating func swap(_ a: UUID, _ b: UUID) {
        guard a != b, let root else { return }
        func walk(_ node: LayoutNode) -> LayoutNode {
            switch node {
            case .leaf(let id): return .leaf(id == a ? b : id == b ? a : id)
            case .split(let axis, let weights, let children):
                return .split(axis: axis, weights: weights, children: children.map(walk))
            }
        }
        self.root = walk(root)
    }

    /// Moves `divider` so the child before it takes `fraction` of the two neighbors' space,
    /// clamped so neither drops below the minimum tile. Other children don't move.
    mutating func move(_ divider: LayoutDivider, to fraction: Double) {
        guard let root else { return }
        let length = Double(divider.axis == .horizontal ? divider.span.width : divider.span.height) - Double(Self.gap)
        let minimum = Double(divider.axis == .horizontal ? Self.minTile.width : Self.minTile.height)
        let low = length > 0 ? min(0.5, minimum / length) : 0.5
        let clamped = min(max(fraction, low), 1 - low)
        self.root = Self.updating(root, path: divider.path[...]) { node in
            guard case .split(let axis, var weights, let children) = node,
                  weights.indices.contains(divider.index + 1) else { return node }
            let pair = weights[divider.index] + weights[divider.index + 1]
            weights[divider.index] = pair * clamped
            weights[divider.index + 1] = pair * (1 - clamped)
            return .split(axis: axis, weights: weights, children: children)
        }
        customized = true
    }

    /// Evens out the split a divider belongs to (double-clicking it).
    mutating func evenOut(_ divider: LayoutDivider) {
        guard let root else { return }
        self.root = Self.updating(root, path: divider.path[...]) { node in
            guard case .split(let axis, let weights, let children) = node else { return node }
            return .split(axis: axis, weights: Array(repeating: 1, count: weights.count), children: children)
        }
    }

    private static func updating(_ node: LayoutNode, path: ArraySlice<Int>, _ change: (LayoutNode) -> LayoutNode) -> LayoutNode {
        guard let step = path.first else { return change(node) }
        guard case .split(let axis, let weights, var children) = node, children.indices.contains(step) else { return node }
        children[step] = updating(children[step], path: path.dropFirst(), change)
        return .split(axis: axis, weights: weights, children: children)
    }

    // MARK: - Geometry

    /// Every tile's frame, never negative.
    func frames(in bounds: CGRect) -> [UUID: CGRect] {
        guard let root else { return [:] }
        return Self.leafFrames(root, in: bounds, gap: Self.gap)
    }

    func dividers(in bounds: CGRect) -> [LayoutDivider] {
        guard let root else { return [] }
        var result: [LayoutDivider] = []
        Self.collectDividers(root, in: bounds, path: [], into: &result)
        return result
    }

    static func leafFrames(_ node: LayoutNode, in rect: CGRect, gap: CGFloat) -> [UUID: CGRect] {
        switch node {
        case .leaf(let id):
            return [id: CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width), height: max(0, rect.height))]
        case .split(let axis, let weights, let children):
            var result: [UUID: CGRect] = [:]
            for (child, cell) in zip(children, cells(rect, axis: axis, weights: weights, gap: gap)) {
                result.merge(leafFrames(child, in: cell, gap: gap)) { x, _ in x }
            }
            return result
        }
    }

    private static func collectDividers(_ node: LayoutNode, in rect: CGRect, path: [Int], into result: inout [LayoutDivider]) {
        guard case .split(let axis, let weights, let children) = node else { return }
        let cells = cells(rect, axis: axis, weights: weights, gap: gap)
        for index in 0..<(cells.count - 1) {
            let a = cells[index], b = cells[index + 1]
            let frame: CGRect, span: CGRect
            switch axis {
            case .horizontal:
                frame = CGRect(x: a.maxX, y: rect.minY, width: max(0, b.minX - a.maxX), height: rect.height)
                span = CGRect(x: a.minX, y: rect.minY, width: b.maxX - a.minX, height: rect.height)
            case .vertical:
                frame = CGRect(x: rect.minX, y: b.maxY, width: rect.width, height: max(0, a.minY - b.maxY))
                span = CGRect(x: rect.minX, y: b.minY, width: rect.width, height: a.maxY - b.minY)
            }
            result.append(LayoutDivider(path: path, index: index, axis: axis, frame: frame, span: span))
        }
        for (index, (child, cell)) in zip(children, cells).enumerated() {
            collectDividers(child, in: cell, path: path + [index], into: &result)
        }
    }

    /// Each child's rect along `axis`. AppKit coordinates: y grows upward, so the first child of
    /// a vertical split is the top one.
    static func cells(_ rect: CGRect, axis: LayoutAxis, weights: [Double], gap: CGFloat) -> [CGRect] {
        let count = weights.count
        guard count > 0 else { return [] }
        let length = axis == .horizontal ? rect.width : rect.height
        let gap = count > 1 ? min(gap, max(0, length) / CGFloat(count - 1)) : 0
        let usable = max(0, length - gap * CGFloat(count - 1))
        let total = max(weights.reduce(0, +), .ulpOfOne)
        var offset: CGFloat = 0
        return weights.map { weight in
            let size = usable * CGFloat(weight / total)
            defer { offset += size + gap }
            switch axis {
            case .horizontal:
                return CGRect(x: rect.minX + offset, y: rect.minY, width: size, height: max(0, rect.height))
            case .vertical:
                return CGRect(x: rect.minX, y: rect.maxY - offset - size, width: max(0, rect.width), height: size)
            }
        }
    }

    /// The share the child before `divider` should take with the pointer at `point`.
    static func fraction(for point: CGPoint, divider: LayoutDivider) -> Double {
        let span = divider.span
        switch divider.axis {
        case .horizontal:
            return Double((point.x - span.minX - gap / 2) / max(1, span.width - gap))
        case .vertical:
            return Double((span.maxY - point.y - gap / 2) / max(1, span.height - gap))
        }
    }

    /// Snaps to halves and thirds of the two neighbors so tiles line up without fiddling.
    static func snapped(_ fraction: Double, divider: LayoutDivider) -> Double {
        let length = Double(divider.axis == .horizontal ? divider.span.width : divider.span.height)
        let tolerance = length > 0 ? 10 / length : 0
        for stop in [1.0 / 3, 0.5, 2.0 / 3] where abs(fraction - stop) < tolerance { return stop }
        return fraction
    }
}

/// Saved per layout mode, so split and grid each keep their own arrangement.
enum LayoutTreeStore {
    static func load(_ key: String) -> LayoutTree? {
        guard let data = UserDefaults.standard.data(forKey: "layoutTree." + key) else { return nil }
        return try? JSONDecoder().decode(LayoutTree.self, from: data)
    }

    static func save(_ tree: LayoutTree, _ key: String) {
        guard let data = try? JSONEncoder().encode(tree) else { return }
        UserDefaults.standard.set(data, forKey: "layoutTree." + key)
    }
}
