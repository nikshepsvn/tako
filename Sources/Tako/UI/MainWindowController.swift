import AppKit
import Combine
import GhosttyKit
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SessionStore
    private let terminalArea = TerminalAreaView()
    private var sheetWindow: NSWindow?
    private lazy var sumiDock = SumiDock(store: store)
    private let detachedTiles = DetachedTiles()
    private lazy var projectActionsMenu = ProjectActionsMenu(store: store)

    private var sidebarItem: NSSplitViewItem?
    private var inspectorItem: NSSplitViewItem?
    /// The sidebar's and inspector's backings, which carry the theme's pane fill.
    private var paneBackings: [NSView] = []
    private let canvas = InkCanvas()
    private var terminalTop: NSLayoutConstraint?
    private var canvasBarHeight: NSLayoutConstraint?
    private var canvasSidebarButton: NSView?
    private var canvasBandShown: Bool?
    private var subscriptions: Set<AnyCancellable> = []

    init(store: SessionStore) {
        self.store = store
        let window = KuronamiWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Tako"
        // No toolbar: its actions live in the sidebar footer, the traffic lights in the sidebar's
        // top inset, and the panes run to the window's top edge. Always dark; View › Theme picks
        // the colours and opacity (applyTheme).
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 780, height: 520)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentViewController = makeSplitController()
        Self.adoptLegacyFrame()
        // A restored frame can be stale (screen changes); never come back smaller than usable.
        if !window.setFrameUsingName("TakoMain") || window.frame.height < 500 || window.frame.width < 900 {
            window.setContentSize(NSSize(width: 1360, height: 840))
            window.center()
        }
        window.setFrameAutosaveName("TakoMain")
        window.onFullScreenChange = { [weak self] in self?.updateCanvasBand() }
        updateCanvasBand()
        applyTheme()
        NotificationCenter.default.addObserver(forName: .windowThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        bindStore()
        sumiDock.install(in: window)
        sumiDock.keepsOpenForClicks = { [weak self] clicked in
            guard let self else { return false }
            return clicked === self.switcher || clicked === self.mentionPicker || self.detachedTiles.owns(clicked)
        }
    }

    /// View › Theme's colours and opacity, applied in place: nothing is rebuilt, no session restarts.
    private func applyTheme() {
        guard let window else { return }
        let theme = Theme.window
        window.isOpaque = !theme.isTranslucent
        window.backgroundColor = theme.windowFill
        paneBackings.forEach { $0.layer?.backgroundColor = theme.paneFill.cgColor }
        canvas.applyTheme()
        terminalArea.applyTheme()
        detachedTiles.applyTheme()
        // The user's own Ghostty `background-blur`, if they set one; nothing is added on top.
        if theme.isTranslucent, let app = GhosttyRuntime.shared.app {
            ghostty_set_window_background_blur(app, Unmanaged.passUnretained(window).toOpaque())
        }
    }

    /// The window's frame was saved as "HypertermMain" before the rename; carry it over once so
    /// the first launch after updating opens where the user left it.
    private static func adoptLegacyFrame(defaults: UserDefaults = .standard) {
        let key = "NSWindow Frame TakoMain"
        guard defaults.string(forKey: key) == nil, let old = defaults.string(forKey: "NSWindow Frame HypertermMain") else { return }
        defaults.set(old, forKey: key)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    var actions: SessionActions {
        SessionActions(
            newSession: { [weak self] in self?.presentNewSession() },
            rename: { [weak self] in self?.presentRename($0) },
            releaseLabel: { [weak self] in self?.store.releaseLabel($0) },
            restart: { [weak self] in self?.confirmRestart($0) },
            close: { [weak self] in self?.confirmClose($0) },
            review: { [weak self] in self?.showInspector(for: $0) },
            showPlan: { [weak self] in self?.showInspector(for: $0, tab: .plan) },
            pickWinner: { [weak self] in self?.confirmPickWinner($0) },
            dispatch: { [weak self] task, kinds, cwd, options in self?.store.dispatch(task, kinds: kinds, cwd: cwd, options: options) },
            toggleSidebar: { [weak self] in self?.toggleSidebar() },
            toggleInspector: { [weak self] in self?.toggleInspector() },
            showProjectActions: { [weak self] in self?.projectActionsMenu.popUp() })
    }

    // MARK: - Layout

    /// Native three-pane layout: sidebar, terminals, and an inspector for review, activity, and
    /// session info. All three run to the window's top edge.
    private func makeSplitController() -> NSSplitViewController {
        let split = NSSplitViewController()
        // Hosting controllers must not drive the window size from SwiftUI's ideal size.
        let sidebarHost = NSHostingController(rootView: SidebarView(store: store, actions: actions))
        sidebarHost.sizingOptions = []
        // A plain item, not a sidebar-behavior one: that adds the system's behind-window sidebar
        // material under it, which tints the sidebar apart from the canvas (and costs a live blur).
        // It's toggled by `toggleSidebar()` rather than NSSplitViewController's.
        let sidebarItem = NSSplitViewItem(viewController: backed(sidebarHost))
        sidebarItem.minimumThickness = 280
        sidebarItem.maximumThickness = 460
        sidebarItem.preferredThicknessFraction = 0.24
        sidebarItem.canCollapse = true
        // Like a sidebar: the canvas, not the sidebar, takes up a window resize.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        split.addSplitViewItem(sidebarItem)
        self.sidebarItem = sidebarItem

        let detail = NSViewController()
        let container = canvas
        terminalArea.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminalArea)
        // The canvas's top edge drags the window: a gap-high strip over the space above the tiles,
        // or the whole titlebar band while the sidebar is hidden (updateCanvasBand).
        let bar = WindowDragView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)
        // It sits in the titlebar band, so it ignores the titlebar's safe area.
        let button = NSHostingView(rootView: CanvasBandControls(store: store) { [weak self] in
            self?.toggleSidebar()
        }.ignoresSafeArea())
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isHidden = true
        container.addSubview(button)
        canvasSidebarButton = button
        let top = terminalArea.topAnchor.constraint(equalTo: container.topAnchor)
        let barHeight = bar.heightAnchor.constraint(equalToConstant: LayoutTree.gap)
        terminalTop = top
        canvasBarHeight = barHeight
        NSLayoutConstraint.activate([
            top,
            terminalArea.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalArea.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminalArea.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            barHeight,
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Size.trafficLights),
            button.centerYAnchor.constraint(equalTo: container.topAnchor, constant: Size.titlebar / 2),
            button.heightAnchor.constraint(equalToConstant: Size.iconButton),
        ])
        detail.view = container
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420
        split.addSplitViewItem(detailItem)

        let inspectorHost = NSHostingController(rootView: InspectorView(store: store, actions: actions))
        inspectorHost.sizingOptions = []
        let inspector = NSSplitViewItem(inspectorWithViewController: backed(inspectorHost))
        inspector.minimumThickness = 340
        inspector.maximumThickness = 640
        inspector.canCollapse = true
        inspector.isCollapsed = true
        split.addSplitViewItem(inspector)
        inspectorItem = inspector
        split.splitView.autosaveName = "KuronamiWorkspace.v3"
        // The inspector opens on demand (review chip, ⌥⌘R); don't restore it open and empty.
        DispatchQueue.main.async { inspector.isCollapsed = true }
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split.splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCanvasBand() }
        }
        return split
    }

    /// Wraps a view controller's view in a backing that carries the theme's pane fill.
    private func backed(_ child: NSViewController) -> NSViewController {
        let wrapper = NSViewController()
        let effect = NSView()
        effect.wantsLayer = true
        paneBackings.append(effect)
        wrapper.addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.topAnchor.constraint(equalTo: effect.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            child.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
        ])
        wrapper.view = effect
        return wrapper
    }

    func toggleSidebar() {
        guard let sidebarItem else { return }
        if Motion.reduced { sidebarItem.isCollapsed.toggle() }
        else { sidebarItem.animator().isCollapsed.toggle() }
    }

    /// With the sidebar hidden the traffic lights sit over the canvas, so the tiles start below a
    /// titlebar band that holds them and the sidebar's button and "N needs you" pill. Full screen
    /// keeps the band too (the pill must stay reachable), just without the traffic lights.
    /// Otherwise the tiles reach the top edge.
    private func updateCanvasBand() {
        guard let sidebarItem else { return }
        let band = sidebarItem.isCollapsed
        guard band != canvasBandShown else { return }
        canvasBandShown = band
        terminalTop?.constant = band ? Size.titlebar : 0
        canvasBarHeight?.constant = band ? Size.titlebar : LayoutTree.gap
        canvasSidebarButton?.isHidden = !band
        updateShelfButton()
    }

    /// The shelf pill shows only with the sidebar hidden, and only when there's something to list.
    private func updateShelfButton() {
        let shows = sidebarItem?.isCollapsed == true
            && !(ShelfButton.servers(store).isEmpty && ShelfButton.parked(store).isEmpty)
        if terminalArea.showsShelfButton != shows { terminalArea.showsShelfButton = shows }
    }

    func toggleSumi() { sumiDock.toggle() }

    func toggleInspector() {
        guard let inspectorItem else { return }
        if Motion.reduced { inspectorItem.isCollapsed.toggle() }
        else { inspectorItem.animator().isCollapsed.toggle() }
    }

    func showInspector(for session: TerminalSession, tab: InspectorTab = .changes) {
        store.select(session)
        store.inspectorTab = tab
        if inspectorItem?.isCollapsed == true {
            if Motion.reduced { inspectorItem?.isCollapsed = false }
            else { inspectorItem?.animator().isCollapsed = false }
        }
    }

    func evenOutTiles() { terminalArea.evenOutTiles() }

    private func bindStore() {
        let shelf = NSHostingView(rootView: ShelfButton(store: store))
        shelf.sizingOptions = [.intrinsicContentSize]
        terminalArea.shelfButton = shelf
        store.$lastError
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in MainActor.assumeIsolated { self?.reportLaunchError(error) } }
            .store(in: &subscriptions)
        // Sumi's terminal lives in its floating panel; every other session gets a tile.
        // Detached sessions live in their own windows.
        store.onSurfaceChange = { [weak self] session in
            if session.isSumi { self?.sumiDock.attach(session) }
            else if session.isDetached { self?.detachedTiles.attachSurface(session) }
            else { self?.terminalArea.mount(session) }
        }
        store.onRemove = { [weak self] session in
            if session.isSumi { self?.sumiDock.detach(session) }
            else if session.isDetached { self?.detachedTiles.close(session) }
            else { self?.terminalArea.unmount(session) }
        }
        store.onShowSumi = { [weak self] in self?.sumiDock.open() }
        store.onShowDetached = { [weak self] session in self?.detachedTiles.show(session) }
        store.onDetach = { [weak self] session in self?.detach(session) }
        store.onReattach = { [weak self] session in self?.reattach(session) }
        detachedTiles.onReturn = { [weak self] session in self?.reattach(session) }
        detachedTiles.onClose = { [weak self] session in self?.confirmClose(session) }
        detachedTiles.onFocus = { [weak self] session in
            guard let self, self.store.selectedID != session.id else { return }
            self.store.select(session)
        }
        store.onArrangementChange = { [weak self] in self?.arrange(takeFocus: true) }
        store.onArrangeTiles = { [weak self] root in self?.terminalArea.setTree(root, for: .grid) }
        store.onStatusChange = { [weak self] in self?.arrange(takeFocus: false) }
        store.confirmHandler = { [weak self] title, message, completion in
            guard let window = self?.windowForSheet() else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Don't Allow")
            NSApp.activate(ignoringOtherApps: true)
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        }
        terminalArea.onSelectTile = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.store.select(session)
        }
        terminalArea.onZoomTile = { [weak self] id in self?.store.toggleZoom(id) }
        terminalArea.onMinimizeTile = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.store.setMinimized(session, true)
        }
        terminalArea.onDetachTile = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.detach(session)
        }
        terminalArea.onCloseTile = { [weak self] id in
            guard let self, let session = self.store.sessions.first(where: { $0.id == id }) else { return }
            self.confirmClose(session)
        }
        terminalArea.onReorder = { [weak self] order in self?.store.setTileOrder(order) }
        store.onMentionRequest = { [weak self] session in self?.showMentionPicker(for: session) }
        store.onArchiveRequest = { [weak self] session in self?.requestArchive(session) }
        store.onSearchUpdate = { [weak self] session, total, selected, start in
            guard let self else { return }
            if let tile = self.detachedTiles.tile(for: session.id) {
                if start { tile.showSearch() }
                if let total { tile.search.total = total }
                if let selected { tile.search.selected = selected }
                return
            }
            if start { self.terminalArea.showSearch(for: session.id) }
            self.terminalArea.searchResults(for: session.id, total: total, selected: selected)
        }
    }

    // MARK: - Detached tiles

    /// Pops a tile out of the canvas into its own window, opening where the tile was.
    func detach(_ session: TerminalSession) {
        guard !session.isDetached, !session.isSumi else { return }
        let frame = terminalArea.screenFrame(of: session.id)
        session.isDetached = true
        terminalArea.unmount(session)
        detachedTiles.open(session, at: frame)
        arrange(takeFocus: false)
    }

    /// The main window or a detached tile's: where ⌘W closes a terminal rather than the window.
    func isTerminalWindow(_ candidate: NSWindow) -> Bool {
        candidate === window || detachedTiles.owns(candidate)
    }

    /// Puts a detached tile back in the canvas, focused.
    func reattach(_ session: TerminalSession) {
        guard session.isDetached else { return }
        // Cleared first: closing the tile can make this window key, which must not treat the
        // session as still detached and select another one.
        session.isDetached = false
        detachedTiles.close(session)
        terminalArea.mount(session)
        window?.makeKeyAndOrderFront(nil)
        store.select(session)
    }

    private func arrange(takeFocus: Bool) {
        terminalArea.apply(mode: store.layout, visible: store.visibleIDs, focused: store.selectedID, takeFocus: takeFocus)
        updateShelfButton()
        terminalArea.refreshAttention()
        let title: String, subtitle: String
        if let session = store.selected {
            title = "@" + session.label
            subtitle = [session.git?.project, session.git?.branch].compactMap { $0 }.joined(separator: " · ")
        } else {
            title = "Tako"
            subtitle = store.windowSubtitle
        }
        // Setting these relayouts the titlebar even when unchanged.
        if window?.title != title { window?.title = title }
        if window?.subtitle != subtitle { window?.subtitle = subtitle }
        detachedTiles.refresh()
    }

    func showSearch() {
        if let id = store.selectedID, let tile = detachedTiles.tile(for: id) { tile.showSearch() }
        else { terminalArea.showSearch(for: store.selectedID) }
    }

    func presentWorktreeCleanup() {
        guard sheetWindow == nil, let window = windowForSheet() else { return }
        let roots = store.sessions.compactMap { $0.git.map(GitInfo.mainRoot) }
        let inUse = Set(store.sessions.map(\.spec.workPath))
        // Closed agents' checkpoints live in the shared repo; archiving their worktree prunes them.
        let closedIDs = Dictionary(grouping: store.recentlyClosed, by: \.workPath).mapValues { $0.map(\.id.uuidString) }
        let view = WorktreeCleanupView(repoRoots: roots, inUse: inUse, sessionIDs: closedIDs) { [weak self] in self?.dismissSheet() }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    // MARK: - Quick switcher

    private var switcher: SwitcherPanel?

    func toggleSwitcher() {
        if let switcher, switcher.isVisible { switcher.close(); return }
        guard let window else { return }
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 440),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        let view = QuickSwitcherView(store: store, quickCreate: { [weak self] in self?.quickCreate($0) },
                                     dismiss: { [weak panel] in panel?.close() })
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let frame = window.frame
        panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - host.fittingSize.width / 2, y: frame.maxY - 110))
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        switcher = panel
    }

    // MARK: - Mention picker

    private var mentionPicker: SwitcherPanel?

    /// Opens under the terminal's cursor; the picked session's name is typed where @@ was.
    func showMentionPicker(for session: TerminalSession) {
        mentionPicker?.close()
        guard let window else { return }
        let panel = SwitcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)
        let surface = session.surface
        let close = { [weak panel] in
            panel?.close()
            surface.window?.makeFirstResponder(surface)
        }
        let view = MentionPickerView(store: store, origin: session,
                                     pick: { picked in close(); surface.sendText(picked.label + " ") },
                                     dismiss: close)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let cursor = (surface as? TerminalSurfaceView)?.firstRect(forCharacterRange: NSRange(), actualRange: nil)
        let anchor = cursor.flatMap { $0 == .zero ? nil : NSPoint(x: $0.minX, y: $0.minY - 4) }
            ?? NSPoint(x: window.frame.midX - host.fittingSize.width / 2, y: window.frame.midY)
        panel.setFrameTopLeftPoint(anchor)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        mentionPicker = panel
    }

    // MARK: - Quick Ask

    private var quickAsk: SwitcherPanel?

    /// The floating task field from ⌃⌥Space. It takes keystrokes without bringing the main window
    /// forward, so the app you were in stays where it was.
    func toggleQuickAsk() {
        if let quickAsk, quickAsk.isVisible { quickAsk.close(); return }
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 140),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: QuickAskView(store: store, dismiss: { [weak panel] in panel?.close() }))
        host.frame.size = host.fittingSize
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - host.fittingSize.width / 2, y: visible.maxY - visible.height * 0.22))
        }
        panel.makeKeyAndOrderFront(nil)
        quickAsk = panel
    }

    // MARK: - Sheets

    func presentNewSession(kind: SessionKind? = nil) {
        guard sheetWindow == nil, let window = windowForSheet() else { return }
        var draft = NewSessionDraft()
        if let current = store.selected { draft.cwd = current.spec.cwd }
        if let kind { draft.kind = kind }
        // Default to a worktree when another agent already works in this repo.
        let currentRoot = store.selected?.git.map(GitInfo.mainRoot)
        draft.worktree = currentRoot != nil && store.sessions.contains {
            $0.kind.isAgent && $0.git.map(GitInfo.mainRoot) == currentRoot
        }
        let recents = Array(NSOrderedSet(array: store.sessions.map(\.spec.cwd).reversed()).array as? [String] ?? [])
        let view = NewSessionView(draft: draft, recentDirectories: recents, defaultName: store.nextPhoneticLabel(),
            onCreate: { [weak self] draft in
                self?.dismissSheet()
                self?.createSession(from: draft)
            },
            onCancel: { [weak self] in self?.dismissSheet() })
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: view))
        sheetWindow = sheet
        window.beginSheet(sheet)
    }

    /// The window, brought back if the red button hid it: a sheet on a hidden window never shows,
    /// and one that never shows is never dismissed.
    private func windowForSheet() -> NSWindow? {
        guard let window else { return nil }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !window.isVisible { showWindow(nil) }
        return window
    }

    private func dismissSheet() {
        guard let sheet = sheetWindow else { return }
        window?.endSheet(sheet)
        sheetWindow = nil
    }

    private func createSession(from draft: NewSessionDraft) {
        var spec = LaunchSpec(label: draft.label, kind: draft.kind, cwd: draft.cwd, command: draft.command)
        if draft.kind.isAgent, let account = draft.account { spec.account = account }
        if draft.kind.isAgent, !draft.options.isEmpty { spec.options = draft.options }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.launch(spec, worktree: draft.worktree)
        }
    }

    /// Launch problems (a worktree that couldn't be made) are shown once, from any launch path.
    private func reportLaunchError(_ error: String) {
        store.lastError = nil
        // The first sentence is the headline; the rest explains.
        let alert = NSAlert()
        let parts = error.components(separatedBy: ". ")
        alert.messageText = parts[0].hasSuffix(".") ? parts[0] : parts[0] + "."
        alert.informativeText = parts.dropFirst().joined(separator: ". ")
        if let window = windowForSheet() { alert.beginSheetModal(for: window) }
    }

    /// One-keystroke creation in the current session's folder.
    func quickCreate(_ kind: SessionKind) {
        let cwd = store.selected?.spec.cwd ?? NSHomeDirectory()
        let spec = LaunchSpec(label: "", kind: kind, cwd: cwd)
        Task { @MainActor [weak self] in
            guard let self else { return }
            await store.launch(spec)
        }
    }

    func presentRename(_ session: TerminalSession) {
        let alert = NSAlert()
        alert.messageText = "Rename @\(session.label)"
        alert.informativeText = session.kind.isAgent
            ? "Once you name it, the agent won't rename it. The old name keeps working as an alias."
            : "Agents use this label to address the terminal. The old name keeps working as an alias."
        let field = NSTextField(string: session.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard let window = windowForSheet() else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.rename(session, to: field.stringValue)
        }
    }

    /// Closing something that holds work asks first, on the agent itself; anything else just closes.
    func confirmClose(_ session: TerminalSession) {
        askBeforeRemoving(session, archive: false)
    }

    /// The inspector's Archive: the same question, with "keep it on the branch" as the way out.
    func requestArchive(_ session: TerminalSession) {
        askBeforeRemoving(session, archive: true)
    }

    private func askBeforeRemoving(_ session: TerminalSession, archive: Bool) {
        // A browser has no process to lose; closing it just closes the page.
        guard session.kind != .browser else { store.close(session); return }
        // A shell or server reads as running while it lives, so it holds work only while a program
        // other than its shell is running in it.
        let running = session.state == .working || session.state.needsAttention
            || (session.state == .running && (session.kind.isAgent || session.foregroundProcess != nil || session.nestedShells > 0))
        let spec = session.spec
        guard spec.isWorktree else {
            if running { presentCloseBar(for: session, risk: nil, running: true, archive: archive) } else { store.close(session) }
            return
        }
        Task {
            let risk = await Task.detached { WorkAtRisk.evaluate(at: spec.workPath, base: spec.baseBranch) }.value
            guard store.sessions.contains(where: { $0.id == session.id }) else { return }
            if running || !(risk?.isEmpty ?? true) {
                presentCloseBar(for: session, risk: risk, running: running, archive: archive)
            } else {
                closeAndRemoveFolder(session, saveWork: false, reportFailure: archive)
            }
        }
    }

    private func presentCloseBar(for session: TerminalSession, risk: WorkAtRisk?, running: Bool, archive: Bool, retry: Bool = true) {
        let spec = session.spec
        var parts: [String] = []
        if let risk, !risk.isEmpty { parts.append(risk.headline(base: spec.baseBranch) + ".") }
        if running { parts.append(session.kind.isAgent ? "Still working." : "Still running.") }
        let canMerge = !running && spec.isWorktree && spec.baseBranch != nil && risk?.isEmpty == false && risk?.baseUnknown != true
        let leaveTitle = running ? (archive ? "Stop and archive" : "Stop and close") : archive ? "Archive, keep work on branch" : "Close, leave work in folder"
        let model = CloseBarModel(message: parts.joined(separator: " "),
                                  mergeTitle: canMerge ? (archive ? "Merge, then archive" : "Merge, then close") : nil,
                                  leaveTitle: leaveTitle)
        guard let tile = terminalArea.tile(for: session.id) ?? detachedTiles.tile(for: session.id), !tile.isHidden else {
            // Not on screen (parked, or hidden by the layout): bring it up so the question sits on its own agent.
            guard retry else { return presentCloseAlert(for: session, model: model, archive: archive) }
            store.select(session)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.presentCloseBar(for: session, risk: risk, running: running, archive: archive, retry: false) }
            }
            return
        }
        model.onKeep = { [weak tile] in tile?.hideCloseBar() }
        model.onLeave = { [weak self, weak tile] in
            tile?.hideCloseBar()
            if archive { self?.closeAndRemoveFolder(session, saveWork: true, reportFailure: true) }
            else { self?.store.close(session) }
        }
        model.onMerge = { [weak self, weak tile, weak model] in self?.mergeThenClose(session, model: model, tile: tile) }
        tile.showCloseBar(model)
    }

    /// Fallback when the agent has no tile to carry the bar: the same question as a sheet.
    private func presentCloseAlert(for session: TerminalSession, model: CloseBarModel, archive: Bool) {
        guard let window = windowForSheet() else { return }
        let alert = NSAlert()
        alert.messageText = "Close @\(session.label)?"
        alert.informativeText = model.message
        alert.addButton(withTitle: "Keep Open")
        alert.addButton(withTitle: model.leaveTitle)
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            if archive { self.closeAndRemoveFolder(session, saveWork: true, reportFailure: true) } else { self.store.close(session) }
        }
    }

    /// Commits what's there, merges the branch into its base, then closes and cleans up. A merge
    /// that can't happen (your own checkout is in the way, a conflict) says so on the bar and
    /// leaves the agent open.
    private func mergeThenClose(_ session: TerminalSession, model: CloseBarModel?, tile: TileView?) {
        guard let base = session.spec.baseBranch else { return }
        let path = session.spec.workPath
        let root = session.git.map(GitInfo.mainRoot) ?? path
        let label = session.label
        model?.busy = true
        model?.error = nil
        Task {
            let outcome: Result<String, ReviewError> = await Task.detached {
                guard let branch = Review.currentBranch(at: path), branch != "HEAD" else { return .failure(.git("not on a branch")) }
                if !(runGit(["-C", path, "status", "--porcelain"]) ?? "").isEmpty,
                   case .failure(let error) = Review.commit(at: path, message: "Work from @\(label) (Tako)") {
                    return .failure(error)
                }
                return Review.merge(branch: branch, into: base, mainRoot: root)
            }.value
            model?.busy = false
            switch outcome {
            case .failure(let error): model?.error = error.description
            case .success:
                tile?.hideCloseBar()
                closeAndRemoveFolder(session, saveWork: false, reportFailure: false)
            }
        }
    }

    /// Closes the agent and, once its process is gone, removes its worktree folder; the branch
    /// stays. Without `saveWork` the folder is only removed if it is still empty of risk by then.
    private func closeAndRemoveFolder(_ session: TerminalSession, saveWork: Bool, reportFailure: Bool) {
        let spec = session.spec
        let path = spec.workPath, base = spec.baseBranch, label = session.label
        let root = session.git.map(GitInfo.mainRoot) ?? path
        let id = session.id.uuidString
        let shared = store.sessions.contains { $0.id != session.id && $0.spec.workPath == path }
        store.close(session)
        guard spec.isWorktree, !shared else { return }
        // Closing stops the agent; its worktree lock goes with it once the reaper has stopped
        // its process tree (SIGKILL after the grace period), plus a moment for the kill to land.
        SessionReaper.whenStopped(session: id) { [weak self] in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [weak self] in
                if !saveWork {
                    guard let risk = WorkAtRisk.evaluate(at: path, base: base), risk.isEmpty else { return }
                }
                let outcome = Review.archive(worktree: path, mainRoot: root)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch outcome {
                        case .success: Checkpoints.prune(at: root, session: id)
                        case .failure(let error):
                            guard reportFailure, let window = self?.windowForSheet() else { return }
                            let alert = NSAlert()
                            alert.messageText = "Couldn't archive @\(label)'s worktree"
                            alert.informativeText = error.description
                            alert.beginSheetModal(for: window)
                        }
                    }
                }
            }
        }
    }

    func confirmPickWinner(_ session: TerminalSession) {
        guard let window = windowForSheet() else { return }
        let others = store.raceSiblings(of: session)
        let alert = NSAlert()
        alert.messageText = "Keep \(session.label)'s work?"
        alert.informativeText = "Its changes are committed and merged into \(session.spec.baseBranch ?? "the base branch"). "
            + "\(others.map(\.label).joined(separator: ", ")) will be closed and their worktrees archived. "
            + "Anything they hadn't committed is saved on their branches, which stay."
        alert.addButton(withTitle: "Merge and Close Others")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.store.pickWinner(session) { [weak self] result in
                guard let self, let window = self.windowForSheet() else { return }
                let done = NSAlert()
                switch result {
                case .success(let text): done.messageText = text
                case .failure(let error):
                    done.messageText = "Couldn't merge \(session.label)"
                    done.informativeText = error.description
                }
                done.beginSheetModal(for: window)
            }
        }
    }

    func confirmRestart(_ session: TerminalSession) {
        guard session.state == .working || session.state.needsAttention, let window = windowForSheet() else { session.restart(); return }
        let alert = NSAlert()
        alert.messageText = "Restart @\(session.label)?"
        alert.informativeText = session.kind.isAgent
            ? "The agent is mid-turn. It will be stopped and resumed from its last saved conversation."
            : "The running process will be stopped and started again."
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { session.restart() }
        }
    }

    // MARK: - NSWindowDelegate

    /// The red button hides the window like any Mac app; sessions keep running, the Dock icon
    /// brings it back, and ⌘Q quits.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Sumi's panel is the window's child and would be left open with nothing under it.
        sumiDock.close(restoreFocus: false)
        sender.orderOut(nil)
        return false
    }

    /// Native full screen (Original): the content runs edge to edge and the titlebar only slides
    /// in with the menu bar. AppKit draws that titlebar in its own window with an opaque
    /// background, a gray band over the sidebar and canvas; clear it so the content shows
    /// through, as it does in a normal window.
    func windowDidEnterFullScreen(_ notification: Notification) {
        updateCanvasBand()
        guard let toolbarWindow = window?.standardWindowButton(.closeButton)?.window,
              toolbarWindow !== window, let root = toolbarWindow.contentView?.superview else { return }
        toolbarWindow.isOpaque = false
        toolbarWindow.backgroundColor = .clear
        func clear(_ view: NSView) {
            if view is NSVisualEffectView || String(describing: type(of: view)).contains("TitlebarBackground") {
                view.isHidden = true
            }
            view.subviews.forEach(clear)
        }
        clear(root)
    }

    func windowDidExitFullScreen(_ notification: Notification) { updateCanvasBand() }

    func windowDidResize(_ notification: Notification) { sumiDock.reposition() }

    func windowDidBecomeKey(_ notification: Notification) {
        // Hiding the window drops its child windows; bring Sumi's button back with it.
        if let window { sumiDock.install(in: window) }
        // Coming back from a detached tile's window: the main window takes a session it holds.
        if let session = store.selected, session.isDetached,
           let fallback = store.visibleIDs.first.flatMap({ id in store.sessions.first { $0.id == id } }) {
            store.select(fallback)
        }
        guard let window, Self.keyboardIsLost(in: window) else { return }
        if let session = store.selected, session.surface.window === window { window.makeFirstResponder(session.surface) }
    }

    /// Nothing visible would take a key: no first responder, the window itself, or a view that was
    /// hidden or moved out of this window (a tile parked, detached or closed while it had focus).
    /// Typing then went nowhere until the window was closed and reopened.
    static func keyboardIsLost(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, responder !== window else { return true }
        guard let view = responder as? NSView else { return false }
        return view.window !== window || view.isHiddenOrHasHiddenAncestor
    }
}

/// Night goes full screen in place, like Ghostty's `macos-non-native-fullscreen`: native full
/// screen moves the window to its own Space with a black backdrop, so there'd be nothing to see
/// through to. In place, the window covers the screen with the menu bar and Dock hidden and no
/// traffic lights, so the panes run edge to edge. Original uses native full screen.
final class KuronamiWindow: NSWindow {
    private var restoreFrame: NSRect?
    /// Entered or left full screen in place (native full screen reports through the delegate).
    var onFullScreenChange: (() -> Void)?

    var isFullScreen: Bool { restoreFrame != nil || styleMask.contains(.fullScreen) }

    override func toggleFullScreen(_ sender: Any?) {
        // Leaving goes the way it came in, even if the theme changed meanwhile.
        guard restoreFrame != nil || (Theme.isTranslucent && !styleMask.contains(.fullScreen)) else {
            return super.toggleFullScreen(sender)
        }
        if let restoreFrame {
            self.restoreFrame = nil
            NSApp.presentationOptions = []
            setTrafficLightsHidden(false)
            isMovable = true
            setFrame(restoreFrame, display: true, animate: true)
        } else if let screen {
            restoreFrame = frame
            NSApp.presentationOptions = [.autoHideMenuBar, .autoHideDock]
            setTrafficLightsHidden(true)
            isMovable = false
            setFrame(screen.frame, display: true, animate: true)
        }
        onFullScreenChange?()
    }

    private func setTrafficLightsHidden(_ hidden: Bool) {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(kind)?.isHidden = hidden
        }
    }

    // Titled windows are kept below the menu bar; in-place full screen covers it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        restoreFrame == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
}
