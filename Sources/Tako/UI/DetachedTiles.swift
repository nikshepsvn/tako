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
        window.addTitlebarAccessoryViewController(returnButton())
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

    private func returnButton() -> NSTitlebarAccessoryViewController {
        let button = NSButton(image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Return to Grid")!,
                              target: self, action: #selector(returnToGrid(_:)))
        button.isBordered = false
        button.contentTintColor = Ink.text.withAlphaComponent(0.6)
        button.toolTip = "Return to the grid"
        button.frame = NSRect(x: 0, y: 0, width: 28, height: 22)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = button
        accessory.layoutAttribute = .trailing
        return accessory
    }

    @objc private func returnToGrid(_ sender: NSButton) {
        if let window = sender.window, let session = session(in: window) { onReturn?(session) }
    }
}
