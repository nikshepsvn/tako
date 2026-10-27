import AppKit

enum LayoutMode: String, CaseIterable, Codable {
    case focus, split, grid

    var title: String {
        switch self {
        case .focus: return "Focus"
        case .split: return "Split"
        case .grid: return "Grid"
        }
    }

    var symbol: String {
        switch self {
        case .focus: return "square"
        case .split: return "rectangle.split.2x1"
        case .grid: return "square.grid.2x2"
        }
    }
}

/// Arranges session tiles. Every session owns one persistent tile; layouts only change which
/// tiles are visible and where, so switching layouts never restarts a process.
///
/// Split and grid are a `LayoutTree` each: tiles share the canvas by weight, and the gaps between
/// them are dividers the user drags to resize. Dragging a tile by its header trades places with
/// the tile it is dropped on.
@MainActor
final class TerminalAreaView: NSView {
    private var tiles: [UUID: TileView] = [:]
    private var visibleOrder: [UUID] = []
    private var lastFocused: UUID?
    private var mode: LayoutMode = .focus
    private let emptyState = NSHostingViewFactory.emptyState()
    /// One arrangement per multi-tile layout, saved between launches.
    private var trees: [LayoutMode: LayoutTree] = [:]
    private var handles: [DividerHandle] = []

    var onSelectTile: ((UUID) -> Void)?
    var onMinimizeTile: ((UUID) -> Void)?
    var onDetachTile: ((UUID) -> Void)?
    var onCloseTile: ((UUID) -> Void)?
    /// The user dragged tiles into a new order (the on-screen order).
    var onReorder: (([UUID]) -> Void)?
    /// The tile being dragged and where it started.
    private var drag: (id: UUID, origin: NSRect)?
    /// Where the dragged tile lands if released now.
    private var pendingDrop: LayoutDrop?
    /// A drag Escape cancelled; its remaining gesture events are ignored.
    private var cancelledDrag: UUID?
    private var escapeMonitor: Any?
    private let snapPreview = SnapPreviewView()
    /// Where tiles go: the bounds, inset from the edges.
    private var tileArea: NSRect = .zero
    /// The shelf pill (servers and parked tiles) in the bottom-right corner, over the tiles. It takes
    /// no space from them, and shows only while the sidebar, which lists the same things, is hidden.
    var shelfButton: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            guard let shelfButton else { return }
            shelfButton.translatesAutoresizingMaskIntoConstraints = false
            shelfButton.isHidden = !showsShelfButton
            addSubview(shelfButton)
            NSLayoutConstraint.activate([
                shelfButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -LayoutTree.gap * 2),
                shelfButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -LayoutTree.gap * 2),
            ])
        }
    }
    var showsShelfButton = false {
        didSet {
            guard showsShelfButton != oldValue else { return }
            shelfButton?.isHidden = !showsShelfButton
            needsLayout = true
        }
    }
    var onZoomTile: ((UUID) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(emptyState)
        for mode in [LayoutMode.split, .grid] { trees[mode] = LayoutTreeStore.load(mode.rawValue) ?? LayoutTree() }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func mount(_ session: TerminalSession) {
        if let tile = tiles[session.id] {
            tile.attachSurface()
            return
        }
        let id = session.id
        let tile = TileView(session: session, actions: TileActions(
            select: { [weak self] in self?.onSelectTile?(id) },
            zoom: { [weak self] in self?.onZoomTile?(id) },
            minimize: { [weak self] in self?.onMinimizeTile?(id) },
            detach: { [weak self] in self?.onDetachTile?(id) },
            close: { [weak self] in self?.onCloseTile?(id) },
            wake: { [weak session] in if let session { session.store?.wake(session) } },
            drag: { [weak self] translation in self?.dragTile(id, by: translation) },
            dragEnded: { [weak self] in self?.endDrag(id) }))
        tile.isHidden = true
        tiles[id] = tile
        addSubview(tile, positioned: .below, relativeTo: handles.first)
    }

    /// Where a tile is on screen, if it is showing; a detached tile's window opens there.
    func screenFrame(of id: UUID) -> NSRect? {
        guard let tile = tiles[id], !tile.isHidden, let window else { return nil }
        return window.convertToScreen(tile.convert(tile.bounds, to: nil))
    }

    func tile(for id: UUID) -> TileView? { tiles[id] }

    func unmount(_ session: TerminalSession) {
        tiles[session.id]?.removeFromSuperview()
        tiles[session.id] = nil
        visibleOrder.removeAll { $0 == session.id }
        if drag?.id == session.id { clearDragChrome(); drag = nil }
        needsLayout = true
    }

    /// Shows `visible` in `mode`, focusing `focused`. `takeFocus` moves keyboard focus into the
    /// focused terminal; status-driven refreshes pass false so they never steal it from a field.
    func apply(mode: LayoutMode, visible: [UUID], focused: UUID?, takeFocus: Bool = true) {
        // Normalize first: stale IDs and duplicates must not force layout on every status poll.
        let requested = Self.visibleIDs(visible, mounted: Set(tiles.keys))
        // The store receives the new order on drop. Polls during the gesture must retain the
        // order already shown by the moving tiles.
        let preservesDrag = drag != nil && mode == self.mode && Set(requested) == Set(visibleOrder)
        let nextVisible = preservesDrag ? visibleOrder : requested
        if !preservesDrag, let drag {
            tiles[drag.id]?.setLifted(false)
            clearDragChrome()
            self.drag = nil
        }
        let changed = mode != self.mode || nextVisible != visibleOrder
        self.mode = mode
        visibleOrder = nextVisible
        let visibleSet = Set(visibleOrder)
        for (id, tile) in tiles {
            let isVisible = visibleSet.contains(id)
            tile.setVisible(isVisible)
            // One tile gets the whole area without chrome, whatever the layout.
            tile.showsHeader = mode != .focus && visibleSet.count > 1
            tile.isFocusedTile = id == focused
        }
        emptyState.isHidden = !tiles.isEmpty
        updateNothingShown(tilesExist: !tiles.isEmpty, anyVisible: !visibleOrder.isEmpty)
        if changed { needsLayout = true; layoutSubtreeIfNeeded() }
        // A status refresh never takes focus from a field, but it does rehome a keyboard that was
        // left on a tile it just hid (parked, exited off the grid) or on nothing at all.
        let keyboardLost = window.map(MainWindowController.keyboardIsLost) ?? false
        if takeFocus || keyboardLost, let focused, visibleSet.contains(focused), let surface = tiles[focused]?.session.surface,
           window?.firstResponder !== surface {
            window?.makeFirstResponder(surface)
            if focused != lastFocused { tiles[focused]?.showRecapIfNeeded() }
        }
        lastFocused = focused
    }

    /// Sessions exist but none is on the canvas (all parked, exited, or in their own windows):
    /// say so, instead of an empty canvas that looks broken and takes no typing.
    private var nothingShown: NSView?

    private func updateNothingShown(tilesExist: Bool, anyVisible: Bool) {
        let show = tilesExist && !anyVisible
        if show, nothingShown == nil {
            let view = NSHostingViewFactory.nothingOnCanvas()
            view.frame = bounds
            addSubview(view, positioned: .below, relativeTo: tiles.values.first)
            nothingShown = view
        }
        nothingShown?.isHidden = !show
    }

    func showSearch(for id: UUID?) {
        guard let id else { return }
        tiles[id]?.showSearch()
    }

    func searchResults(for id: UUID, total: Int?, selected: Int?) {
        if let total { tiles[id]?.search.total = total }
        if let selected { tiles[id]?.search.selected = selected }
    }

    func refreshAttention() {
        for id in visibleOrder { tiles[id]?.refreshAttention() }
    }

    /// Even out the current layout's tiles (View ▸ Even Out Tiles).
    func evenOutTiles() {
        guard var tree = trees[mode] else { return }
        tree.reset(in: tileArea)
        trees[mode] = tree
        LayoutTreeStore.save(tree, mode.rawValue)
        animateToLayout()
    }

    /// Adopts a tile shape chosen for the user (Sumi), kept like one they dragged.
    /// Frames follow on the next layout pass, once the store has shown exactly these tiles.
    func setTree(_ root: LayoutNode, for mode: LayoutMode) {
        let tree = LayoutTree(root: root, customized: true)
        trees[mode] = tree
        LayoutTreeStore.save(tree, mode.rawValue)
        needsLayout = true
    }

    /// Tiles reach the window's top edge on purpose; the titlebar's safe area must not push
    /// their headers, address bars and find bars down.
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    /// View › Theme changed: every tile restyles in place.
    func applyTheme() { tiles.values.forEach { $0.applyTheme() } }

    private var multiTile: Bool { mode != .focus && visibleOrder.count > 1 }

    override func layout() {
        super.layout()
        emptyState.frame = bounds
        nothingShown?.frame = bounds
        let area = bounds
        // Panes float inset from the window edges, like content panes in Apple's apps.
        let inset = min(LayoutTree.gap, max(0, min(area.width, area.height) / 2))
        tileArea = area.insetBy(dx: inset, dy: inset)
        let frames = currentFrames()
        for (id, frame) in frames where id != drag?.id {
            let aligned = frame.integral
            if tiles[id]?.frame != aligned { tiles[id]?.frame = aligned }
        }
        updateHandles()
        // Tiles mount behind the handles, which can put them over the pill; keep it on top.
        if showsShelfButton, let shelfButton, subviews.last !== shelfButton {
            addSubview(shelfButton, positioned: .above, relativeTo: nil)
        }
    }

    /// Reconciles the current tree with what's visible and returns every tile's frame.
    private func currentFrames() -> [UUID: NSRect] {
        guard multiTile, var tree = trees[mode] else {
            return visibleOrder.first.map { [$0: tileArea] } ?? [:]
        }
        let before = tree
        tree.reconcile(visible: visibleOrder, in: tileArea)
        if tree != before {
            trees[mode] = tree
            LayoutTreeStore.save(tree, mode.rawValue)
        }
        return tree.frames(in: tileArea)
    }

    private func animateToLayout() {
        let frames = currentFrames()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.standard)
            context.timingFunction = Motion.curve
            for (id, frame) in frames where id != drag?.id { tiles[id]?.animator().frame = frame.integral }
        }
        updateHandles()
    }

    // MARK: - Dividers

    private func updateHandles() {
        let dividers = multiTile && drag == nil ? (trees[mode]?.dividers(in: tileArea) ?? []) : []
        while handles.count > dividers.count { handles.removeLast().removeFromSuperview() }
        while handles.count < dividers.count {
            let handle = DividerHandle()
            handle.onDrag = { [weak self, weak handle] point in
                guard let self, let handle, let divider = handle.divider else { return }
                self.moveDivider(divider, to: point)
            }
            handle.onEnd = { [weak self] in self?.saveTree() }
            handle.onReset = { [weak self, weak handle] in
                guard let self, let divider = handle?.divider, var tree = self.trees[self.mode] else { return }
                tree.evenOut(divider)
                self.trees[self.mode] = tree
                self.saveTree()
                self.animateToLayout()
            }
            addSubview(handle, positioned: .above, relativeTo: nil)
            handles.append(handle)
        }
        for (handle, divider) in zip(handles, dividers) {
            handle.divider = divider
            // The grab area is wider than the gap so the edge is easy to catch.
            let grab: CGFloat = 10
            handle.frame = divider.axis == .horizontal
                ? divider.frame.insetBy(dx: -(grab - divider.frame.width) / 2, dy: 0)
                : divider.frame.insetBy(dx: 0, dy: -(grab - divider.frame.height) / 2)
        }
    }

    private func moveDivider(_ divider: LayoutDivider, to point: NSPoint) {
        guard var tree = trees[mode] else { return }
        let fraction = LayoutTree.snapped(LayoutTree.fraction(for: point, divider: divider), divider: divider)
        tree.move(divider, to: fraction)
        trees[mode] = tree
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    private func saveTree() {
        if let tree = trees[mode] { LayoutTreeStore.save(tree, mode.rawValue) }
    }

    // MARK: - Drag to rearrange

    /// The tile follows the pointer while a translucent preview shows where it will land: half
    /// of the tile under the pointer (split it), its center (trade places), or a canvas edge (a
    /// full column or row). Escape puts it back.
    private func dragTile(_ id: UUID, by translation: CGSize) {
        guard cancelledDrag != id, multiTile, let tile = tiles[id] else { return }
        if drag == nil {
            drag = (id, tile.frame)
            tile.setLifted(true)
            onSelectTile?(id)
            updateHandles()
            watchForEscape()
        }
        guard let origin = drag?.origin else { return }
        // SwiftUI's global space grows downward; this view's grows upward.
        tile.frame.origin = CGPoint(x: origin.minX + translation.width, y: origin.minY - translation.height)
        let pointer = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
            ?? CGPoint(x: tile.frame.midX, y: tile.frame.midY)
        showDrop(trees[mode]?.drop(at: pointer, dragging: id, in: tileArea), for: id)
    }

    /// Moves the preview only when the zone changes: one Core Animation frame change, no relayout.
    private func showDrop(_ drop: LayoutDrop?, for id: UUID) {
        let frame = drop.flatMap { trees[mode]?.preview($0, moving: id, in: tileArea) }
        // A refused move (it would squeeze a tile too small) shows nothing and drops nowhere.
        let next = frame == nil ? nil : drop
        guard next != pendingDrop else { return }
        pendingDrop = next
        let target: UUID? = {
            switch next {
            case .swap(let other), .beside(let other, _): return other
            default: return nil
            }
        }()
        for (other, view) in tiles where other != id { view.setDropTarget(other == target) }
        snapPreview.show(frame?.integral, in: self)
        if let next { announce(next) }
    }

    /// VoiceOver hears the zone, since the preview is only visual.
    private func announce(_ drop: LayoutDrop) {
        let label = { (id: UUID) in self.tiles[id].map { "@" + $0.session.label } ?? "tile" }
        let text: String
        switch drop {
        case .swap(let other): text = "Swap with \(label(other))"
        case .beside(let other, let edge): text = "\(edge.rawValue.capitalized) of \(label(other))"
        case .canvas(let edge): text = "\(edge.rawValue.capitalized) edge of the canvas"
        }
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func endDrag(_ id: UUID) {
        if cancelledDrag == id { cancelledDrag = nil; return }
        guard drag?.id == id, let tile = tiles[id] else { return }
        let drop = pendingDrop
        clearDragChrome()
        var moved = false
        if let drop, var tree = trees[mode], tree.apply(drop, moving: id, in: tileArea) {
            trees[mode] = tree
            saveTree()
            // Before reconciling: an untouched tree is rebuilt from the visible order, which
            // would put the tiles straight back.
            visibleOrder = tree.leaves
            moved = true
        }
        drag = nil
        settle(tile)
        if moved { onReorder?(visibleOrder) }
    }

    /// Escape mid-drag: the tile flies home and the rest of the gesture is ignored.
    private func cancelDrag() {
        guard let id = drag?.id, let tile = tiles[id] else { return }
        cancelledDrag = id
        clearDragChrome()
        drag = nil
        settle(tile)
    }

    /// Every tile to its frame in the current tree, then the lifted one sets down.
    private func settle(_ tile: TileView) {
        let frames = currentFrames()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.standard)
            context.timingFunction = Motion.curve
            for (other, frame) in frames { tiles[other]?.animator().frame = frame.integral }
        } completionHandler: {
            MainActor.assumeIsolated { tile.setLifted(false) }
        }
        updateHandles()
    }

    private func clearDragChrome() {
        pendingDrop = nil
        tiles.values.forEach { $0.setDropTarget(false) }
        snapPreview.show(nil, in: self)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Only while a drag is live, so no key ever pays for it otherwise.
    private func watchForEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, self.drag != nil else { return event }
            self.cancelDrag()
            return nil
        }
    }

    // MARK: - Keyboard moves

    /// View › Move Tile (⌃⌥ + arrow): the focused tile becomes a full column or row on that side.
    /// Beeps when there is nothing to move or the move would squeeze a tile too small.
    func moveFocusedTile(to edge: LayoutEdge) {
        guard multiTile, drag == nil, let id = lastFocused, visibleOrder.contains(id), var tree = trees[mode] else {
            NSSound.beep(); return
        }
        tree.reconcile(visible: visibleOrder, in: tileArea)
        guard tree.move(id, toCanvas: edge, in: tileArea) else { NSSound.beep(); return }
        trees[mode] = tree
        saveTree()
        visibleOrder = tree.leaves
        animateToLayout()
        onReorder?(visibleOrder)
    }

    // MARK: - Geometry

    /// Preserves the user's order while ignoring IDs whose surfaces have gone away.
    nonisolated static func visibleIDs(_ requested: [UUID], mounted: Set<UUID>) -> [UUID] {
        var seen = Set<UUID>()
        return requested.filter { mounted.contains($0) && seen.insert($0).inserted }
    }
}

/// Where a dragged tile will land: a translucent pane drawn above every tile, the dragged one
/// included. Pure Core Animation; it never takes a click.
@MainActor
final class SnapPreviewView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Ink.text.withAlphaComponent(0.08).cgColor
        layer?.borderColor = Ink.focus.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = Radius.pane
        layer?.cornerCurve = .continuous
        layer?.zPosition = 200
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows at `frame` (nil hides). Glides between zones unless Reduce Motion is on.
    func show(_ frame: NSRect?, in host: NSView) {
        guard let frame else { isHidden = true; return }
        if superview !== host || host.subviews.last !== self { host.addSubview(self, positioned: .above, relativeTo: nil) }
        if isHidden {
            self.frame = frame
            isHidden = false
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.duration(Motion.quick)
            context.timingFunction = Motion.curve
            animator().frame = frame
        }
    }
}

/// The grab area over a gap between tiles. Shows a resize cursor, a hairline while hovered or
/// dragged, and evens out its split on double-click.
@MainActor
final class DividerHandle: NSView {
    var divider: LayoutDivider? {
        didSet { if divider?.axis != oldValue?.axis { window?.invalidateCursorRects(for: self) } }
    }
    var onDrag: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private let line = CALayer()
    private var hovering = false { didSet { updateLine() } }
    private var dragging = false { didSet { updateLine() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        line.backgroundColor = Ink.focus.cgColor
        line.cornerRadius = 1
        line.opacity = 0
        layer?.addSublayer(line)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Tile divider")
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: divider?.axis == .vertical ? .resizeUpDown : .resizeLeftRight)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.frame = divider?.axis == .vertical
            ? NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2)
            : NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        CATransaction.commit()
    }

    private func updateLine() {
        line.opacity = dragging ? 0.9 : hovering ? 0.45 : 0
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging { onEnd?() }
        dragging = false
    }
}
