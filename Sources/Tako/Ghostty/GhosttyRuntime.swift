import AppKit
import Carbon
import GhosttyKit
import os

/// Owns the libghostty app handle and config, and routes runtime callbacks.
///
/// All `ghostty_*` app-level calls live here. Callbacks are file-level C functions that hop to
/// the main actor: wakeups asynchronously (void, any thread), actions synchronously (they return a
/// Bool and arrive on the main thread during `ghostty_app_tick`).
@MainActor
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    private init() {}

    /// Must run before any surface is created.
    func start() -> Bool {
        configureResourcesDirectory()
        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("tako: ghostty_init failed")
            return false
        }
        guard let config = makeConfig() else { return false }

        var runtime = ghostty_runtime_config_s(
            userdata: nil,
            supports_selection_clipboard: true,
            wakeup_cb: ghosttyWakeup,
            action_cb: ghosttyAction,
            read_clipboard_cb: ghosttyReadClipboard,
            confirm_read_clipboard_cb: ghosttyConfirmReadClipboard,
            write_clipboard_cb: ghosttyWriteClipboard,
            close_surface_cb: ghosttyCloseSurface
        )
        guard let app = ghostty_app_new(&runtime, config) else {
            NSLog("tako: ghostty_app_new failed")
            ghostty_config_free(config)
            return false
        }
        self.app = app
        self.config = config
        ghostty_app_set_focus(app, NSApp.isActive)
        observeAppFocus()
        return true
    }

    func tick() {
        if let app { ghostty_app_tick(app) }
    }

    /// Ghostty's `macos-auto-secure-input` (on by default): password prompts turn on secure input.
    var autoSecureInput: Bool {
        guard let config else { return true }
        var value = true
        let key = "macos-auto-secure-input"
        _ = ghostty_config_get(config, &value, key, UInt(key.utf8.count))
        return value
    }

    // MARK: - Setup

    /// The user's Ghostty config (fonts, theme, keybinds) applies as-is. Load order does the
    /// layering instead of editing their file: our styling goes underneath it, and only the
    /// behavior Tako manages goes on top.
    private func makeConfig() -> ghostty_config_t? {
        guard let config = ghostty_config_new() else { return nil }
        loadBundledConfig(config, named: "tako-style")
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        if let cap = ScrollbackCap.overrideFile() { ghostty_config_load_file(config, cap.path) }
        loadBundledConfig(config, named: "tako-defaults")
        ghostty_config_finalize(config)
        logDiagnostics(config)
        return config
    }

    private func loadBundledConfig(_ config: ghostty_config_t, named name: String) {
        guard let url = Bundle.main.url(forResource: name, withExtension: "conf", subdirectory: "ghostty") else { return }
        ghostty_config_load_file(config, url.path)
    }

    private func logDiagnostics(_ config: ghostty_config_t) {
        let count = ghostty_config_diagnostics_count(config)
        for index in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            if let message = diagnostic.message {
                NSLog("tako: ghostty config: %@", String(cString: message))
            }
        }
    }

    /// Shell integration and terminfo are version-matched to the embedded engine, so always point
    /// at our bundled copy even if a standalone Ghostty set the variable.
    private func configureResourcesDirectory() {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty") else { return }
        if FileManager.default.fileExists(atPath: resources.path) {
            setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        }
        unsetenv("NO_COLOR")
    }

    private func observeAppFocus() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, true) }
                SecureInput.apply(active: true)
            }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let app = GhosttyRuntime.shared.app { ghostty_app_set_focus(app, false) }
                SecureInput.apply(active: false)
            }
        }
    }
}

/// A ceiling on the user's own `scrollback-limit`. A value sized for one standalone Ghostty window
/// (say 100 MB) is held by every terminal Tako runs, and an agent's output fills it within hours:
/// two dozen long-lived agents reached gigabytes. A lower value of theirs still wins.
enum ScrollbackCap {
    /// Ghostty's own default, per terminal.
    static let maxBytes: UInt64 = 10_000_000

    /// The limit to impose over `configText` (the user's files, in load order), or nil when theirs
    /// is within the cap or unset (Tako's own 3 MB then applies).
    static func cappedLimit(configText: String) -> UInt64? {
        let values = configText.split(whereSeparator: \.isNewline).compactMap { line -> UInt64? in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "scrollback-limit" else { return nil }
            return UInt64(parts[1].replacingOccurrences(of: "_", with: ""))
        }
        guard let last = values.last, last > maxBytes else { return nil }
        return maxBytes
    }

    /// The files Ghostty loads by default on macOS, in its order (later ones win).
    static func userConfigFiles(environment: [String: String] = ProcessInfo.processInfo.environment,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config")
        let support = home.appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [xdg.appendingPathComponent("ghostty/config"), xdg.appendingPathComponent("ghostty/config.ghostty"),
                support.appendingPathComponent("config"), support.appendingPathComponent("config.ghostty")]
    }

    /// A one-line config setting the cap, when the user's files go over it.
    static func overrideFile() -> URL? {
        let text = userConfigFiles().compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        guard let limit = cappedLimit(configText: text) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tako-scrollback-cap.conf")
        guard (try? "scrollback-limit = \(limit)\n".write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        NSLog("tako: scrollback-limit capped at %llu bytes per terminal", limit)
        return url
    }
}

/// Secure keyboard input is global to the system, so it is held only while Tako is active and a
/// password prompt (or the app-wide toggle) wants it, and every enable is balanced by a disable.
/// Adapted from Ghostty's macOS SecureInput.swift.
@MainActor
enum SecureInput {
    /// Set by Ghostty's app-wide toggle_secure_input binding.
    static var global = false {
        didSet { apply() }
    }

    /// Surfaces at a password prompt, and whether each currently has focus.
    private static var scoped: [ObjectIdentifier: Bool] = [:]
    private static var enabled = false

    static func setScoped(_ object: ObjectIdentifier, focused: Bool) {
        scoped[object] = focused
        apply()
    }

    static func removeScoped(_ object: ObjectIdentifier) {
        guard scoped.removeValue(forKey: object) != nil else { return }
        apply()
    }

    /// Yields secure input while another app is active; it affects every app on the system.
    static func apply(active: Bool? = nil) {
        let desired = (active ?? NSApp.isActive) && (global || scoped.values.contains(true))
        guard enabled != desired else { return }
        let status = desired ? EnableSecureEventInput() : DisableSecureEventInput()
        if status == noErr { enabled = desired }
    }
}

// MARK: - C callbacks

/// Views whose surfaces are alive. Callbacks queued by libghostty's IO thread can arrive after a
/// surface was freed; resolving userdata only through this set avoids touching a dead view.
@MainActor
enum LiveSurfaces {
    private static var views: [UnsafeMutableRawPointer: Weak] = [:]

    private struct Weak {
        weak var view: TerminalSurfaceView?
    }

    static func register(_ view: TerminalSurfaceView) {
        views[Unmanaged.passUnretained(view).toOpaque()] = Weak(view: view)
    }

    static func unregister(_ view: TerminalSurfaceView) {
        views[Unmanaged.passUnretained(view).toOpaque()] = nil
    }

    static func view(for userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
        guard let userdata else { return nil }
        return views[userdata]?.view
    }
}

@MainActor
private func surfaceView(fromUserdata userdata: UnsafeMutableRawPointer?) -> TerminalSurfaceView? {
    LiveSurfaces.view(for: userdata)
}

@MainActor
private func surfaceView(from surface: ghostty_surface_t?) -> TerminalSurfaceView? {
    guard let surface else { return nil }
    return LiveSurfaces.view(for: ghostty_surface_userdata(surface))
}

/// Set while a tick is queued on main. libghostty's IO threads wake us for every chunk of
/// output; coalescing here means a burst costs one main-queue hop and one tick, not one per wakeup.
private let tickPending = OSAllocatedUnfairLock(initialState: false)

private func ghosttyWakeup(_ userdata: UnsafeMutableRawPointer?) {
    let alreadyPending = tickPending.withLock { pending in
        defer { pending = true }
        return pending
    }
    guard !alreadyPending else { return }
    DispatchQueue.main.async {
        // Clear before ticking so a wakeup raised during the tick queues another one.
        tickPending.withLock { $0 = false }
        MainActor.assumeIsolated { GhosttyRuntime.shared.tick() }
    }
}

private func ghosttyAction(_ app: ghostty_app_t?, _ target: ghostty_target_s, _ action: ghostty_action_s) -> Bool {
    let safeTarget = target
    let safeAction = action
    return MainActor.assumeIsolated {
        GhosttyActionRouter.handle(target: safeTarget, action: safeAction)
    }
}

private func ghosttyReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ state: UnsafeMutableRawPointer?) -> Bool {
    nonisolated(unsafe) let ud = userdata
    nonisolated(unsafe) let st = state
    return MainActor.assumeIsolated {
        guard let view = surfaceView(fromUserdata: ud), let surface = view.surface else { return false }
        let pasteboard = location == GHOSTTY_CLIPBOARD_SELECTION
            ? NSPasteboard(name: NSPasteboard.Name("dev.tako.selection"))
            : NSPasteboard.general
        guard let text = pasteboardText(pasteboard) else { return false }
        text.withCString { ghostty_surface_complete_clipboard_request(surface, $0, st, false) }
        return true
    }
}

private func ghosttyConfirmReadClipboard(_ userdata: UnsafeMutableRawPointer?, _ string: UnsafePointer<CChar>?, _ state: UnsafeMutableRawPointer?, _ request: ghostty_clipboard_request_e) {
    // Agents and programs asking to read the clipboard (OSC 52) is denied unless the user's
    // Ghostty config allows it without confirmation; we have no confirmation UI. A paste held
    // back by paste protection (multi-line text) was started by the user, so it goes through.
    nonisolated(unsafe) let ud = userdata
    nonisolated(unsafe) let st = state
    let pasted = request == GHOSTTY_CLIPBOARD_REQUEST_PASTE ? string.map { String(cString: $0) } : nil
    MainActor.assumeIsolated {
        guard let view = surfaceView(fromUserdata: ud), let surface = view.surface else { return }
        (pasted ?? "").withCString { ghostty_surface_complete_clipboard_request(surface, $0, st, true) }
    }
}

private func ghosttyWriteClipboard(_ userdata: UnsafeMutableRawPointer?, _ location: ghostty_clipboard_e, _ content: UnsafePointer<ghostty_clipboard_content_s>?, _ len: Int, _ confirm: Bool) {
    // `confirm` means the user's config asks before a program writes the clipboard (OSC 52).
    // With no confirmation UI, that write is refused rather than made silently.
    guard !confirm else { return }
    guard let content, len > 0 else { return }
    var text: String?
    for index in 0..<len {
        let item = content[index]
        guard let mime = item.mime, let data = item.data else { continue }
        if String(cString: mime) == "text/plain" { text = String(cString: data) }
    }
    guard let text else { return }
    let isSelection = location == GHOSTTY_CLIPBOARD_SELECTION
    DispatchQueue.main.async {
        let pasteboard = isSelection
            ? NSPasteboard(name: NSPasteboard.Name("dev.tako.selection"))
            : NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

private func ghosttyCloseSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
    nonisolated(unsafe) let ud = userdata
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            surfaceView(fromUserdata: ud)?.handleCloseRequest(processAlive: processAlive)
        }
    }
}

private func pasteboardText(_ pasteboard: NSPasteboard) -> String? {
    if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty,
       urls.allSatisfy(\.isFileURL) {
        return urls.map { shellEscape($0.path) }.joined(separator: " ")
    }
    return pasteboard.string(forType: .string)
}

func shellEscape(_ value: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%+=:,./-_"))
    if value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Action routing

@MainActor
enum GhosttyActionRouter {
    static func handle(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        guard target.tag == GHOSTTY_TARGET_SURFACE else { return handleAppAction(action) }
        guard let view = surfaceView(from: target.target.surface) else { return false }
        return handleSurfaceAction(action, view: view)
    }

    private static func handleAppAction(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
            return true
        case GHOSTTY_ACTION_SECURE_INPUT:
            switch action.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON: SecureInput.global = true
            case GHOSTTY_SECURE_INPUT_OFF: SecureInput.global = false
            case GHOSTTY_SECURE_INPUT_TOGGLE: SecureInput.global.toggle()
            default: break
            }
            return true
        case GHOSTTY_ACTION_RELOAD_CONFIG, GHOSTTY_ACTION_CONFIG_CHANGE, GHOSTTY_ACTION_COLOR_CHANGE,
             GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_QUIT_TIMER:
            return true
        default:
            return false
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func handleSurfaceAction(_ action: ghostty_action_s, view: TerminalSurfaceView) -> Bool {
        let payload = action.action
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            view.events?.surfaceTitleChanged(string(payload.set_title.title))
        case GHOSTTY_ACTION_PWD:
            view.events?.surfacePwdChanged(string(payload.pwd.pwd))
        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = payload.desktop_notification
            view.events?.surfaceNotification(title: sanitized(string(note.title)), body: sanitized(string(note.body)))
        case GHOSTTY_ACTION_RING_BELL:
            view.events?.surfaceBell()
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            view.events?.surfaceChildExited(code: Int(payload.child_exited.exit_code))
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let report = payload.progress_report
            view.events?.surfaceProgress(active: report.state != GHOSTTY_PROGRESS_STATE_REMOVE, percent: Int(report.progress))
        case GHOSTTY_ACTION_COMMAND_FINISHED:
            view.events?.surfaceCommandFinished(exitCode: Int(payload.command_finished.exit_code))
        case GHOSTTY_ACTION_CELL_SIZE:
            view.cellSize = NSSize(width: Double(payload.cell_size.width), height: Double(payload.cell_size.height))
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            view.setCursorShape(payload.mouse_shape)
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            NSCursor.setHiddenUntilMouseMoves(payload.mouse_visibility == GHOSTTY_MOUSE_HIDDEN)
        case GHOSTTY_ACTION_OPEN_URL:
            let url = String(cString: payload.open_url.url)
            if let target = URL(string: url) { NSWorkspace.shared.open(target) }
        case GHOSTTY_ACTION_SCROLLBAR, GHOSTTY_ACTION_RENDERER_HEALTH, GHOSTTY_ACTION_INITIAL_SIZE,
             GHOSTTY_ACTION_SIZE_LIMIT, GHOSTTY_ACTION_MOUSE_OVER_LINK,
             GHOSTTY_ACTION_KEY_SEQUENCE, GHOSTTY_ACTION_KEY_TABLE, GHOSTTY_ACTION_SET_TAB_TITLE,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_CONFIG_CHANGE:
            // Accepted with no host-side behavior yet.
            break
        case GHOSTTY_ACTION_SECURE_INPUT:
            // A password prompt: keystrokes stay out of other apps' event taps while it has focus,
            // unless the user's `macos-auto-secure-input` turned that off.
            guard GhosttyRuntime.shared.autoSecureInput else { break }
            switch payload.secure_input {
            case GHOSTTY_SECURE_INPUT_ON: view.passwordInput = true
            case GHOSTTY_SECURE_INPUT_OFF: view.passwordInput = false
            case GHOSTTY_SECURE_INPUT_TOGGLE: view.passwordInput.toggle()
            default: break
            }
        case GHOSTTY_ACTION_START_SEARCH:
            view.events?.surfaceSearch(total: nil, selected: nil, start: true)
        case GHOSTTY_ACTION_SEARCH_TOTAL:
            view.events?.surfaceSearch(total: Int(payload.search_total.total), selected: nil, start: false)
        case GHOSTTY_ACTION_SEARCH_SELECTED:
            view.events?.surfaceSearch(total: nil, selected: Int(payload.search_selected.selected), start: false)
        case GHOSTTY_ACTION_END_SEARCH:
            break
        case GHOSTTY_ACTION_CLOSE_WINDOW, GHOSTTY_ACTION_CLOSE_TAB:
            view.events?.surfaceRequestedClose()
        default:
            // Unhandled actions return false so performable keybinds fall through to the shell.
            return false
        }
        return true
    }

    private static func string(_ pointer: UnsafePointer<CChar>?) -> String {
        guard let pointer else { return "" }
        return String(validatingCString: pointer) ?? ""
    }

    /// Strips C0/C1 controls and bidi overrides before agent-supplied text reaches the UI.
    private static func sanitized(_ text: String) -> String {
        let banned: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        let scalars = text.unicodeScalars.filter { scalar in
            let value = scalar.value
            if banned.contains(value) { return false }
            if value < 0x20 && value != 0x0A { return false }
            if (0x7F...0x9F).contains(value) { return false }
            return true
        }
        return String(String.UnicodeScalarView(scalars)).prefix(500).description
    }
}
