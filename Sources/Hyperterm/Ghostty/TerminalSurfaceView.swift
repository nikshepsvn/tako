// Input handling in this file is adapted from Ghostty's macOS SurfaceView_AppKit.swift
// (https://github.com/ghostty-org/ghostty, MIT License, Copyright (c) 2024 Mitchell Hashimoto).

import AppKit
import Carbon
import CoreImage
import GhosttyKit

/// What the host learns from a terminal surface. Implemented by `TerminalSession`.
@MainActor
protocol TerminalSurfaceEvents: AnyObject {
    func surfaceTitleChanged(_ title: String)
    func surfacePwdChanged(_ pwd: String)
    func surfaceNotification(title: String, body: String)
    func surfaceBell()
    func surfaceChildExited(code: Int)
    func surfaceProgress(active: Bool, percent: Int)
    func surfaceCommandFinished(exitCode: Int)
    func surfaceRequestedClose()
    func surfaceProcessClosed(processAlive: Bool)
    func surfaceFocused()
    func surfaceUserSubmitted()
    func surfaceSearch(total: Int?, selected: Int?, start: Bool)
    func surfaceUserEdited(clearsDraft: Bool)
    /// The user typed @@: pick a session to name.
    func surfaceMentionRequested()
    /// True when the host takes this keystroke instead of the program (a sleeping agent).
    func surfaceInterceptsKey(_ event: NSEvent) -> Bool
}

struct SurfaceLaunch {
    var workingDirectory: String
    /// Full command line run via the user's login shell. Nil runs the default shell.
    var command: String?
    var environment: [String: String]
    /// Typed into the PTY once the shell starts.
    var initialInput: String? = nil
}

/// An NSView that hosts one libghostty surface. libghostty renders into it with Metal and owns
/// the PTY of the process it spawns.
@MainActor
final class TerminalSurfaceView: NSView, @preconcurrency NSTextInputClient {
    private(set) var surface: ghostty_surface_t?
    weak var events: TerminalSurfaceEvents?
    var cellSize: NSSize = .zero

    private var markedText = NSMutableAttributedString()
    private var keyTextAccumulator: [String]?
    private var lastPerformKeyEvent: TimeInterval?
    /// The last key typed was a plain @, so another one opens the session picker.
    private var lastKeyWasAt = false
    private var focused = false
    /// What libghostty was last told: first responder in the key window.
    /// libghostty creates every surface focused, so the first sync can turn that off.
    private var surfaceHasFocus = true
    private var windowKeyObservers: [NSObjectProtocol] = []
    /// The program is at a password prompt; secure input holds while this surface has focus.
    var passwordInput = false {
        didSet {
            guard passwordInput != oldValue else { return }
            if passwordInput { SecureInput.setScoped(ObjectIdentifier(self), focused: surfaceHasFocus) }
            else { SecureInput.removeScoped(ObjectIdentifier(self)) }
        }
    }
    private var pointerStyle: NSCursor = .iBeam
    private var trackingArea: NSTrackingArea?
    private var windowOcclusionObserver: NSObjectProtocol?
    private var hostOccluded = true
    private var lastPixelSize: NSSize?
    private var lastContentScale: NSSize?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    /// Tiles reach under the titlebar band; a press there selects text, it doesn't move the window.
    override var mouseDownCanMoveWindow: Bool { false }

    init(launch: SurfaceLaunch) {
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        LiveSurfaces.register(self)
        createSurface(launch)
        updateTrackingAreas()
        registerForDraggedTypes([.fileURL, .string, .URL])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func createSurface(_ launch: SurfaceLaunch) {
        guard let app = GhosttyRuntime.shared.app else { return }
        var config = ghostty_surface_config_new()
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque()))
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
        config.font_size = 0
        config.wait_after_command = false
        config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let keys = Array(launch.environment.keys)
        let cKeys = keys.map { strdup($0) }
        let cValues = keys.map { strdup(launch.environment[$0] ?? "") }
        defer { (cKeys + cValues).forEach { free($0) } }
        var envVars = zip(cKeys, cValues).map { ghostty_env_var_s(key: $0, value: $1) }

        surface = launch.workingDirectory.withCString { cwd in
            config.working_directory = cwd
            return withOptionalCString(launch.command) { command in
                config.command = command
                return withOptionalCString(launch.initialInput) { input in
                    config.initial_input = input
                    return envVars.withUnsafeMutableBufferPointer { buffer in
                        config.env_vars = buffer.baseAddress
                        config.env_var_count = buffer.count
                        return ghostty_surface_new(app, &config)
                    }
                }
            }
        }
        if surface == nil { NSLog("hyperterm: ghostty_surface_new failed") }
    }

    /// Frees the surface, which terminates its process.
    func destroy() {
        LiveSurfaces.unregister(self)
        if let windowOcclusionObserver {
            NotificationCenter.default.removeObserver(windowOcclusionObserver)
            self.windowOcclusionObserver = nil
        }
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowKeyObservers = []
        SecureInput.removeScoped(ObjectIdentifier(self))
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    func handleCloseRequest(processAlive: Bool) {
        events?.surfaceProcessClosed(processAlive: processAlive)
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    // MARK: - Frozen frame

    /// The last frame drawn, held over the terminal while the program behind it is gone (a
    /// sleeping agent), so a full-screen TUI's exit doesn't take its screen with it.
    private var frozenFrame: NSImageView?

    /// Holds the current frame on screen. False when there is no drawn frame to hold.
    @discardableResult
    func freezeFrame() -> Bool {
        guard frozenFrame == nil, let image = currentFrame() else { return frozenFrame != nil }
        let view = PassthroughImageView(image: image)
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignTopLeft
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        frozenFrame = view
        return true
    }

    func thawFrame() {
        frozenFrame?.removeFromSuperview()
        frozenFrame = nil
    }

    /// libghostty presents each frame as an IOSurface in its layer's contents.
    private func currentFrame() -> NSImage? {
        let layers = [layer].compactMap { $0 } + (layer?.sublayers ?? [])
        guard let contents = layers.lazy.compactMap({ $0.contents as CFTypeRef? }).first(where: {
            CFGetTypeID($0) == IOSurfaceGetTypeID()
        }) else { return nil }
        var image = CIImage(ioSurface: unsafeBitCast(contents, to: IOSurfaceRef.self))
        // A sleeping agent's stand-in, kept for as long as it sleeps: stored at 1x (a quarter of a
        // Retina frame's memory), drawn at the tile's size.
        let scale = image.extent.width > 0 ? min(1, bounds.width / image.extent.width) : 1
        if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        guard let cgImage = Self.frameContext.createCGImage(image, from: image.extent.integral) else { return nil }
        return NSImage(cgImage: cgImage, size: bounds.size)
    }

    /// One for every freeze: a CIContext is expensive to create.
    private static let frameContext = CIContext(options: [.cacheIntermediates: false])

    // MARK: - Host-driven input

    /// Inserts text as a paste (bracketed when the program enabled it).
    func sendText(_ text: String) {
        guard let surface else { return }
        let length = text.utf8.count
        text.withCString { ghostty_surface_text(surface, $0, UInt(length)) }
    }

    /// Presses Return, encoded by libghostty for the current terminal mode.
    func sendReturn() {
        guard let surface else { return }
        var event = ghostty_input_key_s()
        event.action = GHOSTTY_ACTION_PRESS
        event.keycode = UInt32(kVK_Return)
        event.mods = GHOSTTY_MODS_NONE
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.unshifted_codepoint = 13
        event.composing = false
        "\r".withCString { ptr in
            event.text = ptr
            _ = ghostty_surface_key(surface, event)
        }
        event.action = GHOSTTY_ACTION_RELEASE
        event.text = nil
        _ = ghostty_surface_key(surface, event)
    }

    /// Presses a named key ("enter", "down", "esc", "y", "ctrl-c"). Returns false for unknown names.
    func pressKey(named raw: String) -> Bool {
        guard let surface, let key = NamedKey(raw) else { return false }
        var event = ghostty_input_key_s()
        event.keycode = UInt32(key.keyCode)
        var mods = GHOSTTY_MODS_NONE.rawValue
        if key.control { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if key.shift { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if key.alt { mods |= GHOSTTY_MODS_ALT.rawValue }
        event.mods = ghostty_input_mods_e(mods)
        event.consumed_mods = GHOSTTY_MODS_NONE
        event.unshifted_codepoint = key.text.unicodeScalars.first?.value ?? 0
        event.composing = false
        event.action = GHOSTTY_ACTION_PRESS
        let printable = !key.control && !key.alt && (key.text.unicodeScalars.first?.value ?? 0) >= 0x20
        if printable {
            key.text.withCString { ptr in
                event.text = ptr
                _ = ghostty_surface_key(surface, event)
            }
        } else {
            event.text = nil
            _ = ghostty_surface_key(surface, event)
        }
        event.action = GHOSTTY_ACTION_RELEASE
        event.text = nil
        _ = ghostty_surface_key(surface, event)
        return true
    }

    /// The visible rows only: cheap enough to poll for previews.
    func readViewport() -> String {
        read(GHOSTTY_POINT_VIEWPORT) ?? ""
    }

    /// Returns the last `lines` lines of the screen including scrollback.
    func readText(lastLines lines: Int) -> String {
        let count = max(1, lines)
        // The active area is the bottom screenful, so most reads never copy the scrollback. Its
        // first line may be the tail of a row wrapped from above, so it answers only when it
        // holds more than `count` lines.
        let active = Self.lines(read(GHOSTTY_POINT_ACTIVE) ?? "")
        if active.count > count { return active.suffix(count).joined(separator: "\n") }
        return Self.lines(read(GHOSTTY_POINT_SCREEN) ?? "").suffix(count).joined(separator: "\n")
    }

    /// Lines without the blank ones at the bottom.
    private static func lines(_ text: String) -> [Substring] {
        Array(text.split(separator: "\n", omittingEmptySubsequences: false)
            .reversed().drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty }).reversed())
    }

    private func read(_ tag: ghostty_point_tag_e) -> String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: tag, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    func performBinding(_ action: String) {
        guard let surface else { return }
        _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    // MARK: - Focus, size, scale

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { setFocused(true) }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { setFocused(false) }
        return result
    }

    private func setFocused(_ value: Bool) {
        guard focused != value, surface != nil else { return }
        focused = value
        syncSurfaceFocus()
        if value { events?.surfaceFocused() }
    }

    /// libghostty draws the cursor and reports focus to programs only while this view is the
    /// first responder of the key window, so another window or app taking key unfocuses it.
    /// Phone Mode: Sumi tells its CLI it isn't focused even while its panel is, so Claude Code
    /// pushes the user's phone instead of assuming they're watching this terminal.
    var reportsUnfocused = false {
        didSet { if reportsUnfocused != oldValue { syncSurfaceFocus() } }
    }

    private func syncSurfaceFocus() {
        let value = focused && window?.isKeyWindow == true && !reportsUnfocused
        guard let surface, value != surfaceHasFocus else { return }
        surfaceHasFocus = value
        ghostty_surface_set_focus(surface, value)
        if passwordInput { SecureInput.setScoped(ObjectIdentifier(self), focused: value) }
    }

    /// Hidden sessions keep running; telling libghostty they're occluded stops wasted rendering.
    /// Arrangement runs on every status change, so only real transitions reach libghostty.
    func setOccluded(_ occluded: Bool) {
        hostOccluded = occluded
        updateOcclusion()
    }

    private var isOccluded: Bool?

    private func updateOcclusion() {
        let occluded = hostOccluded || window == nil || isHiddenOrHasHiddenAncestor
            || window?.occlusionState.contains(.visible) != true
        guard let surface, occluded != isOccluded else { return }
        isOccluded = occluded
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateOcclusion()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateOcclusion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        pushSize(newSize)
    }

    private func pushSize(_ size: NSSize) {
        guard let surface, size.width > 0, size.height > 0 else { return }
        let scaled = convertToBacking(size)
        let pixels = NSSize(width: scaled.width.rounded(), height: scaled.height.rounded())
        guard pixels != lastPixelSize else { return }
        lastPixelSize = pixels
        ghostty_surface_set_size(surface, UInt32(pixels.width), UInt32(pixels.height))
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let window {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.contentsScale = window.backingScaleFactor
            CATransaction.commit()
        }
        guard let surface, frame.width > 0, frame.height > 0 else { return }
        let backing = convertToBacking(frame)
        let scale = NSSize(width: backing.width / frame.width, height: backing.height / frame.height)
        if scale != lastContentScale {
            lastContentScale = scale
            lastPixelSize = nil
            ghostty_surface_set_content_scale(surface, scale.width, scale.height)
        }
        pushSize(frame.size)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowOcclusionObserver { NotificationCenter.default.removeObserver(windowOcclusionObserver) }
        windowOcclusionObserver = nil
        if let window {
            windowOcclusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateOcclusion() }
            }
        }
        windowKeyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowKeyObservers = []
        if let window {
            windowKeyObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncSurfaceFocus() }
                }
            }
        }
        syncSurfaceFocus()
        updateOcclusion()
        guard let surface, let screen = window?.screen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return }
        ghostty_surface_set_display_id(surface, displayID)
        viewDidChangeBackingProperties()
    }

    // MARK: - Cursor

    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        let previous = pointerStyle
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: pointerStyle = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: pointerStyle = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: pointerStyle = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: pointerStyle = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: pointerStyle = .closedHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: pointerStyle = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: pointerStyle = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE: pointerStyle = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: pointerStyle = .resizeUpDown
        default: return
        }
        guard pointerStyle !== previous else { return }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: pointerStyle)
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastKeyWasAt = false
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
        if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
    }

    override func rightMouseDown(with event: NSEvent) {
        lastKeyWasAt = false
        if !sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseDown(with: event) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if !sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event) { super.rightMouseUp(with: event) }
    }

    override func otherMouseDown(with event: NSEvent) {
        lastKeyWasAt = false
        sendMouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, event)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, event)
    }

    @discardableResult
    private func sendMouseButton(_ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent) -> Bool {
        guard let surface else { return false }
        return ghostty_surface_mouse_button(surface, state, button, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, GhosttyInput.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseExited(with event: NSEvent) {
        guard let surface, NSEvent.pressedMouseButtons == 0 else { return }
        ghostty_surface_mouse_pos(surface, -1, -1, GhosttyInput.mods(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var deltaX = event.scrollingDeltaX
        var deltaY = event.scrollingDeltaY
        let precise = event.hasPreciseScrollingDeltas
        if precise {
            deltaX *= 2
            deltaY *= 2
        }
        let mods = GhosttyInput.scrollMods(precise: precise, phase: event.momentumPhase)
        ghostty_surface_mouse_scroll(surface, deltaX, deltaY, mods)
    }

    override func pressureChange(with event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else {
            lastKeyWasAt = false
            interpretKeyEvents([event])
            return
        }
        if events?.surfaceInterceptsKey(event) == true { lastKeyWasAt = false; return }
        // @@ opens the session picker. The first @ already reached the program; erasing it also
        // closes Claude Code's file picker that it opened.
        // Only agent terminals: in a shell or vim, @@ belongs to the program (a macro repeat).
        let typedAt = event.characters == "@" && markedText.length == 0
            && (events as? TerminalSession)?.kind.isAgent == true
            && event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        defer { lastKeyWasAt = typedAt && !lastKeyWasAt }
        // The picker is a child of the main window; with that hidden it would never appear and
        // the erased @ would be lost, so the keys go through as typed.
        let pickerCanShow = NSApp.windows.contains { $0 is KuronamiWindow && $0.isVisible }
        if typedAt && lastKeyWasAt && pickerCanShow {
            _ = pressKey(named: "backspace")
            events?.surfaceMentionRequested()
            return
        }
        let translationEvent = GhosttyInput.translationEvent(for: event, surface: surface)
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        let hadMarkedText = markedText.length > 0
        let layoutBefore = hadMarkedText ? nil : GhosttyInput.keyboardLayoutID()
        lastPerformKeyEvent = nil

        interpretKeyEvents([translationEvent])

        // An input method switched layouts; it consumed the key.
        if !hadMarkedText && layoutBefore != GhosttyInput.keyboardLayoutID() { return }
        syncPreedit(clearIfNeeded: hadMarkedText)

        if let texts = keyTextAccumulator, !texts.isEmpty {
            texts.forEach { _ = keyAction(action, event: event, translationEvent: translationEvent, text: $0) }
        } else {
            _ = keyAction(action, event: event, translationEvent: translationEvent,
                          text: GhosttyInput.characters(translationEvent),
                          composing: markedText.length > 0 || hadMarkedText)
        }

        if event.keyCode == UInt16(kVK_Return), !hadMarkedText,
           event.modifierFlags.isDisjoint(with: [.shift, .option, .control, .command]) {
            events?.surfaceUserSubmitted()
        } else {
            // Track whether the user has a draft in progress, so Tako never types into it.
            let control = event.modifierFlags.contains(.control)
            let chars = event.charactersIgnoringModifiers ?? ""
            let clears = event.keyCode == UInt16(kVK_Escape) || (control && ["c", "u"].contains(chars))
            if clears || (!control && !event.modifierFlags.contains(.command) && !(event.characters ?? "").isEmpty) {
                events?.surfaceUserEdited(clearsDraft: clears)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
    }

    override func flagsChanged(with event: NSEvent) {
        guard let mod = GhosttyInput.modifierBit(forKeyCode: event.keyCode), !hasMarkedText() else { return }
        let mods = GhosttyInput.mods(event.modifierFlags)
        let pressed = mods.rawValue & mod != 0 && GhosttyInput.isSidePressed(event)
        _ = keyAction(pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event)
    }

    /// App menu shortcuts win over terminal keybinds; otherwise Ghostty bindings and a few
    /// control combos are encoded here before AppKit's responder chain can eat them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, focused else { return false }
        if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        if isGhosttyBinding(event) {
            keyDown(with: event)
            return true
        }

        let equivalent: String
        switch event.charactersIgnoringModifiers {
        case "\r":
            guard event.modifierFlags.contains(.control) else { return false }
            equivalent = "\r"
        case "/":
            guard event.modifierFlags.contains(.control),
                  event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) else { return false }
            equivalent = "_"
        default:
            if event.timestamp == 0 { return false }
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.control) {
                lastPerformKeyEvent = nil
                return false
            }
            if let last = lastPerformKeyEvent, last == event.timestamp {
                lastPerformKeyEvent = nil
                equivalent = event.characters ?? ""
            } else {
                lastPerformKeyEvent = event.timestamp
                return false
            }
        }

        guard let synthesized = NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow, modifierFlags: event.modifierFlags,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: equivalent, charactersIgnoringModifiers: equivalent,
            isARepeat: event.isARepeat, keyCode: event.keyCode) else { return false }
        keyDown(with: synthesized)
        return true
    }

    private func isGhosttyBinding(_ event: NSEvent) -> Bool {
        guard let surface else { return false }
        var keyEvent = GhosttyInput.keyEvent(event, action: GHOSTTY_ACTION_PRESS)
        var flags = ghostty_binding_flags_e(0)
        return (event.characters ?? "").withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key_is_binding(surface, keyEvent, &flags)
        }
    }

    private func keyAction(_ action: ghostty_input_action_e, event: NSEvent, translationEvent: NSEvent? = nil,
                           text: String? = nil, composing: Bool = false) -> Bool {
        guard let surface else { return false }
        var keyEvent = GhosttyInput.keyEvent(event, action: action, translationMods: translationEvent?.modifierFlags)
        keyEvent.composing = composing
        // Control characters are encoded by libghostty itself; only pass printable text.
        if let text, let first = text.utf8.first, first >= 0x20 {
            return text.withCString { ptr in
                keyEvent.text = ptr
                return ghostty_surface_key(surface, keyEvent)
            }
        }
        return ghostty_surface_key(surface, keyEvent)
    }

    // MARK: - Menu actions

    @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
    @objc func paste(_ sender: Any?) { lastKeyWasAt = false; performBinding("paste_from_clipboard") }
    @objc override func selectAll(_ sender: Any?) { performBinding("select_all") }
    @objc func clearScreen(_ sender: Any?) { performBinding("clear_screen") }
    @objc func increaseFontSize(_ sender: Any?) { performBinding("increase_font_size:1") }
    @objc func decreaseFontSize(_ sender: Any?) { performBinding("decrease_font_size:1") }
    @objc func resetFontSize(_ sender: Any?) { performBinding("reset_font_size") }

    // MARK: - NSTextInputClient

    func hasMarkedText() -> Bool { markedText.length > 0 }

    func markedRange() -> NSRange {
        markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange()
    }

    func selectedRange() -> NSRange {
        guard let surface else { return NSRange() }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        lastKeyWasAt = false
        switch string {
        case let value as NSAttributedString: markedText = NSMutableAttributedString(attributedString: value)
        case let value as String: markedText = NSMutableAttributedString(string: value)
        default: return
        }
        if keyTextAccumulator == nil { syncPreedit() }
    }

    func unmarkText() {
        guard markedText.length > 0 else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface, range.length > 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSAttributedString(string: String(cString: text.text))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface else { return .zero }
        var x: Double = 0, y: Double = 0
        var width = Double(cellSize.width), height = Double(cellSize.height)
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        if range.length == 0 { width = 0 }
        let viewRect = NSRect(x: x, y: frame.height - y, width: width, height: max(height, Double(cellSize.height)))
        let windowRect = convert(viewRect, to: nil)
        return window?.convertToScreen(windowRect) ?? windowRect
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard NSApp.currentEvent != nil else { return }
        let chars: String
        switch string {
        case let value as NSAttributedString: chars = value.string
        case let value as String: chars = value
        default: return
        }
        unmarkText()
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }
        sendText(chars)
    }

    override func doCommand(by selector: Selector) {
        // A command-key event bounced from performKeyEquivalent goes back through dispatch so
        // keyDown can encode it.
        if let last = lastPerformKeyEvent, let current = NSApp.currentEvent, last == current.timestamp {
            NSApp.sendEvent(current)
            return
        }
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)): performBinding("scroll_to_top")
        case #selector(moveToEndOfDocument(_:)): performBinding("scroll_to_bottom")
        default: break
        }
    }

    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }
        if markedText.length > 0 {
            let value = markedText.string
            value.withCString { ghostty_surface_preedit(surface, $0, UInt(value.utf8.count)) }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    // MARK: - Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            sendText(urls.map { $0.isFileURL ? shellEscape($0.path) : $0.absoluteString }.joined(separator: " "))
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            sendText(text)
            return true
        }
        return false
    }
}

/// Clicks fall through to the terminal, so focusing a frozen tile still works.
private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let value else { return body(nil) }
    return value.withCString { body($0) }
}
