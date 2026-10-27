import AppKit
import GhosttyKit

/// Tiles popped out of the canvas into ordinary windows the user moves and sizes freely. The
/// session keeps running; only where its surface is shown changes. Closing the window, or its
/// grid button, puts the tile back in the canvas.
@MainActor
final class DetachedTiles: NSObject, NSWindowDelegate {
    private var tiles: [UUID: TileView] = [:]
    /// The user closed a window or pressed its grid button.
    var onReturn: ((TerminalSession) -> Void)?
    /// A detached window came forward; its session becomes the selection.
    var onFocus: ((TerminalSession) -> Void)?
    /// The tile's close button or menu item: the session itself is closing (the caller confirms).
    var onClose: ((TerminalSession) -> Void)?

    private static let defaultSize = NSSize(width: 720, height: 460)

    /// Opens `session` in its own window at `frame` (screen coordinates), or centered.
    func open(_ session: TerminalSession, at frame: NSRect?) {
        guard tiles[session.id] == nil else { show(session); return }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 320, height: 200)
        Self.style(window)
        window.title = "@" + session.label
        window.delegate = self

        let tile = TileView(session: session, actions: TileActions(
            select: { [weak self, weak session] in if let session { self?.onFocus?(session) } },
            // Detached, a tile is its own window: zoom and minimize are the window's, detach
            // puts it back, and close ends the session.
            zoom: { [weak self, weak session] in if let session { self?.tiles[session.id]?.window?.zoom(nil) } },
            minimize: { [weak self, weak session] in if let session { self?.tiles[session.id]?.window?.miniaturize(nil) } },
            detach: { [weak self, weak session] in if let session { self?.onReturn?(session) } },
            close: { [weak self, weak session] in if let session { self?.onClose?(session) } },
            wake: { [weak session] in if let session { session.store?.wake(session) } },
            drag: { _ in }, dragEnded: {}))
        let content = NSView()
        tile.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tile)
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: content.topAnchor),
            tile.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Space.xs),
            tile.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Space.xs),
            tile.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Space.xs),
        ])
        window.contentView = content
        window.addTitlebarAccessoryViewController(titlebarControls(for: window))
        tiles[session.id] = tile
        tile.setVisible(true)

        if let frame {
            window.setFrame(window.frameRect(forContentRect: frame), display: false)
        } else {
            window.center()
        }
        Self.blur(window)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(session.surface)
    }

    private static func style(_ window: NSWindow) {
        if Theme.isTranslucent {
            window.isOpaque = false
            window.backgroundColor = .white.withAlphaComponent(0.001)
        } else {
            window.isOpaque = true
            window.backgroundColor = Ink.floor
        }
    }

    private static func blur(_ window: NSWindow) {
        if Theme.isTranslucent, let app = GhosttyRuntime.shared.app {
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
        }
    }

    /// View › Theme changed: restyle the open windows in place.
    func applyTheme() {
        for tile in tiles.values {
            tile.applyTheme()
            if let window = tile.window { Self.style(window); Self.blur(window) }
        }
    }

    /// Takes the session's window away without returning it anywhere (the caller remounts it,
    /// or the session is gone).
    func close(_ session: TerminalSession) {
        guard let tile = tiles.removeValue(forKey: session.id) else { return }
        tile.setVisible(false)
        if let window = tile.window {
            window.delegate = nil
            window.orderOut(nil)
        }
        tile.removeFromSuperview()
    }

    func show(_ session: TerminalSession) {
        guard let window = tiles[session.id]?.window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        window.makeFirstResponder(session.surface)
    }

    /// After a restart swaps the session's surface.
    func attachSurface(_ session: TerminalSession) {
        tiles[session.id]?.attachSurface()
    }

    func owns(_ window: NSWindow) -> Bool { tiles.values.contains { $0.window === window } }

    func tile(for id: UUID) -> TileView? { tiles[id] }

    /// Keeps window titles in step with renames, and the attention marker with status.
    func refresh() {
        for tile in tiles.values {
            tile.refreshAttention()
            let title = "@" + tile.session.label
            if tile.window?.title != title { tile.window?.title = title }
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let session = session(in: sender) { onReturn?(session) }
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let session = session(in: window) else { return }
        onFocus?(session)
    }

    private func session(in window: NSWindow) -> TerminalSession? {
        tiles.values.first { $0.window === window }?.session
    }

    /// Snap ▾ and a worded Dock Back. Dragging to a screen edge is left to macOS 15's own tiling,
    /// which already previews and snaps halves and quarters; this menu adds the same targets
    /// one click away, on the window itself.
    private func titlebarControls(for window: NSWindow) -> NSTitlebarAccessoryViewController {
        let snap = NSPopUpButton(frame: .zero, pullsDown: true)
        snap.isBordered = false
        snap.addItem(withTitle: "")
        snap.item(at: 0)?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Snap")
        for group in WindowSnap.groups {
            if snap.numberOfItems > 1 { snap.menu?.addItem(.separator()) }
            for region in group {
                let item = NSMenuItem(title: region.title, action: #selector(snap(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = SnapChoice(window: window, region: region)
                item.image = NSImage(systemSymbolName: region.symbol, accessibilityDescription: nil)
                snap.menu?.addItem(item)
            }
        }
        snap.toolTip = "Snap to a half, a quarter or the whole screen"
        snap.setAccessibilityLabel("Snap window")
        snap.contentTintColor = Ink.text.withAlphaComponent(0.6)

        let dock = NSButton(title: "Dock Back", image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!,
                            target: self, action: #selector(returnToGrid(_:)))
        dock.isBordered = false
        dock.imagePosition = .imageLeading
        dock.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        dock.contentTintColor = Ink.text.withAlphaComponent(0.75)
        dock.toolTip = "Put this terminal back in the main window's canvas"
        dock.setAccessibilityLabel("Dock back into the canvas")

        let stack = NSStackView(views: [snap, dock])
        stack.spacing = Space.s
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: Space.s)
        stack.frame = NSRect(x: 0, y: 0, width: stack.fittingSize.width, height: 22)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = stack
        accessory.layoutAttribute = .trailing
        return accessory
    }

    @objc private func snap(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SnapChoice, let window = choice.window else { return }
        snap(window, to: choice.region)
    }

    /// Moves `window` onto `region` of its screen's visible frame: under the menu bar, beside the Dock.
    func snap(_ window: NSWindow, to region: WindowSnap) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.setFrame(region.frame(in: visible), display: true, animate: !Motion.reduced)
    }

    @objc private func returnToGrid(_ sender: NSButton) {
        if let window = sender.window, let session = session(in: window) { onReturn?(session) }
    }
}

/// A Snap menu item's payload; weak, so the menu never keeps a closed window alive.
private final class SnapChoice: NSObject {
    weak var window: NSWindow?
    let region: WindowSnap

    init(window: NSWindow, region: WindowSnap) {
        self.window = window
        self.region = region
    }
}

/// Where a detached window can snap on its screen. Pure geometry, unit-tested.
enum WindowSnap: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize

    static let groups: [[WindowSnap]] = [[.leftHalf, .rightHalf, .topHalf, .bottomHalf],
                                         [.topLeft, .topRight, .bottomLeft, .bottomRight], [.maximize]]

    var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left Quarter"
        case .topRight: return "Top Right Quarter"
        case .bottomLeft: return "Bottom Left Quarter"
        case .bottomRight: return "Bottom Right Quarter"
        case .maximize: return "Fill Screen"
        }
    }

    var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.filled"
        case .rightHalf: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        case .maximize: return "rectangle.inset.filled"
        }
    }

    /// The frame within `visible` (screen coordinates, y up), on whole points.
    func frame(in visible: NSRect) -> NSRect {
        let halfWidth = (visible.width / 2).rounded(.down), halfHeight = (visible.height / 2).rounded(.down)
        let left = NSRect(x: visible.minX, y: visible.minY, width: halfWidth, height: visible.height)
        let right = NSRect(x: visible.minX + halfWidth, y: visible.minY, width: visible.width - halfWidth, height: visible.height)
        let top = NSRect(x: visible.minX, y: visible.minY + halfHeight, width: visible.width, height: visible.height - halfHeight)
        let bottom = NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfHeight)
        switch self {
        case .leftHalf: return left
        case .rightHalf: return right
        case .topHalf: return top
        case .bottomHalf: return bottom
        case .topLeft: return left.intersection(top)
        case .topRight: return right.intersection(top)
        case .bottomLeft: return left.intersection(bottom)
        case .bottomRight: return right.intersection(bottom)
        case .maximize: return visible
        }
    }
}
