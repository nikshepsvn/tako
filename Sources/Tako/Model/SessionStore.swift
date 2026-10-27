import AppKit
import Combine

/// The set of sessions, which one is shown, and the rules that connect signals to sessions.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var launchingCount = 0
    @Published var selectedID: UUID?
    @Published private(set) var layout: LayoutMode = LayoutMode(rawValue: UserDefaults.standard.string(forKey: "layout") ?? "") ?? .focus

    /// Called when a session's surface view is created or replaced, so the window can mount it.
    var onSurfaceChange: ((TerminalSession) -> Void)?
    /// Called whenever the visible set, layout, or focused session changes.
    var onArrangementChange: (() -> Void)?
    /// Sumi set the grid's tiles; the canvas adopts the shape as if the user had.
    var onArrangeTiles: ((LayoutNode) -> Void)?
    /// Sumi is between being asked for and its session existing; one start at a time.
    var sumiStarting = false
    /// Phone Mode was switched on while Sumi was still launching; Remote Control opens once it exists.
    var remoteControlWhenSumiUp = false
    /// When Phone Mode last restarted a Sumi that quit, to stop retrying one that can't start.
    var sumiRestarts: [Date] = []
    /// Something asked for Sumi (e.g. the switcher); the window opens its panel.
    var onShowSumi: (() -> Void)?
    /// A detached session was chosen; the window brings its own window forward.
    var onShowDetached: ((TerminalSession) -> Void)?
    /// Pop a tile out into its own window, or put it back in the canvas (Sumi asks).
    var onDetach: ((TerminalSession) -> Void)?
    var onReattach: ((TerminalSession) -> Void)?
    /// Terminals Sumi waits on, each with the note it left for when that one finishes.
    var sumiWatches: [UUID: String] = [:]
    var sumiDigest = SumiDigest()
    /// Folder trust for Sumi's agents, asked once per folder (SessionStore+Startup).
    let startupGate = StartupGate()
    /// Sumi's plan, memory and learned approvals (SumiBrain), on disk beside the sessions.
    lazy var sumiBrain = SumiBrain(directory: persists ? ControlPaths.supportDirectory : nil)
    var sumiDigestRetryScheduled = false
    /// What Sumi opened in the last few seconds (see showOpenedBySumi).
    var sumiOpened: [(id: UUID, at: Date)] = []
    var overlapWatch = OverlapWatch()
    /// Worker agents' waits, team boards and notification limits (SessionStore+AgentTools).
    var agentTools = AgentToolsState()
    /// Which agents reached their prompt and which keep exiting soon after starting (SessionStore+Health).
    var startupHealth = StartupHealth()
    /// Called when a session's status changes. It can change which tiles show (grid hides exited
    /// sessions) and their chrome, but must not pull keyboard focus away from where the user is.
    var onStatusChange: (() -> Void)?
    var onRemove: ((TerminalSession) -> Void)?
    var onSearchUpdate: ((TerminalSession, Int?, Int?, Bool) -> Void)?
    var onMentionRequest: ((TerminalSession) -> Void)?
    /// The inspector's "Archive Worktree": the window asks about anything at risk, then removes it.
    var onArchiveRequest: ((TerminalSession) -> Void)?

    /// Most recently selected first; split view shows the top two.
    private var recent: [UUID] = []
    /// The user's arrangement of tiles (by dragging); sessions not in it follow in creation order.
    private var tileOrder: [UUID] = (UserDefaults.standard.stringArray(forKey: "tileOrder") ?? []).compactMap(UUID.init)
    @Published var inspectorTab: InspectorTab = .changes
    /// A turn the Changes tab should open on (set from the Activity tab's turn list).
    @Published var reviewTurn: Int?

    /// "2 agents waiting · 3 working" under the window title.
    var windowSubtitle: String {
        var parts: [String] = []
        if attentionCount > 0 { parts.append("\(attentionCount) waiting") }
        let working = sessions.filter { $0.state == .working }.count
        if working > 0 { parts.append("\(working) working") }
        if reviewCount > 0 { parts.append("\(reviewCount) to review") }
        if parts.isEmpty { parts.append(sessions.isEmpty ? "No terminals" : "\(sessions.count) terminal\(sessions.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Shown once by the window, then cleared.
    @Published var lastError: String?
    /// Agents closed recently, newest first, so a closed conversation is one click from coming back.
    @Published var recentlyClosed: [LaunchSpec] = SessionStore.loadRecentlyClosed()
    /// Serializes checkpoint captures within a repository, so turns stay ordered, while separate
    /// repositories snapshot in parallel.
    var checkpointQueues: [String: DispatchQueue] = [:]
    let pruneQueue = DispatchQueue(label: "dev.tako.checkpoints.prune", qos: .utility)
    private var layoutBeforeZoom: LayoutMode?

    /// Account-wide usage windows, from the most recent statusLine report of any Claude session.
    @Published var rateLimits: RateLimits?
    /// The same for Codex, from the session log of the most recent Codex turn.
    @Published var codexRateLimits: RateLimits?
    /// Usage windows per account ("claude/work", "codex/default"), so the Accounts window can
    /// show which account still has room.
    @Published var accountLimits: [String: RateLimits] = [:]
    /// Set while Phone Mode is on (SessionStore+PhoneMode). Never persisted: quitting turns it off.
    @Published var phoneModeSince: Date?
    /// Labels of closed user-named terminals, kept from agents for an hour so messages meant for
    /// them can't be captured by a rename.
    private var reservedLabels: [String: Date] = [:]
    private var launchLabels = SessionLabelReservations()
    var approvals: [UUID: PendingApproval] = [:]
    /// Permission requests that arrived while another was held (parallel tools, subagents): each
    /// is held in turn once the one before it is answered.
    var queuedApprovals: [UUID: [(approval: PendingApproval, json: [String: Any])]] = [:]
    /// Codex sessions' own app-servers, which Tako follows as a second client.
    var codexServers: [UUID: CodexAppServer] = [:]
    /// The app-server request behind each session's held approval, so the terminal answering
    /// it clears Tako's.
    var codexHeldRequests: [UUID: (request: CodexAppServer.RequestID, approval: UUID)] = [:]
    /// Channel delivery (opt-in): each Claude session's MCP server long-polls for messages.
    private var channelWaiters: [UUID: ControlServer.Reply] = [:]
    private var channelInbox: [UUID: [String]] = [:]
    private var channelLastSeen: [UUID: Date] = [:]
    /// Identifies the waiter a timeout belongs to, so an old timer can't end a newer long-poll.
    private var channelWaiterTokens: [UUID: UUID] = [:]

    nonisolated static var channelsEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "channels") }
        set { UserDefaults.standard.set(newValue, forKey: "channels") }
    }

    func subscribeChannel(_ session: TerminalSession, reply: @escaping ControlServer.Reply) {
        channelLastSeen[session.id] = Date()
        if let queued = channelInbox.removeValue(forKey: session.id), !queued.isEmpty {
            var response = ControlResponse.success()
            response.messages = queued
            reply(response)
            return
        }
        channelWaiters.removeValue(forKey: session.id)?(ControlResponse.success())
        channelWaiters[session.id] = reply
        let token = UUID()
        channelWaiterTokens[session.id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            guard let self, self.channelWaiterTokens[session.id] == token,
                  let waiting = self.channelWaiters.removeValue(forKey: session.id) else { return }
            self.channelWaiterTokens[session.id] = nil
            waiting(ControlResponse.success())
        }
    }

    /// Forgets a session's channel: its MCP server is gone (closed or restarted). Returns the
    /// messages it never picked up.
    @discardableResult
    func dropChannel(for session: TerminalSession) -> [String] {
        channelWaiters.removeValue(forKey: session.id)?(ControlResponse.success())
        channelWaiterTokens[session.id] = nil
        channelLastSeen[session.id] = nil
        return channelInbox.removeValue(forKey: session.id) ?? []
    }

    /// Pushes a message as a channel event when the session's channel is live. Returns false when
    /// the session has no channel, so the caller types the message instead.
    func pushViaChannel(_ text: String, to session: TerminalSession) -> Bool {
        // A poller from before a restart, sleep or exit can look fresh for a minute while its
        // socket is already gone: only a running agent's channel counts.
        if case .exited = session.state { return false }
        guard Self.channelsEnabled, session.kind == .claude, !session.isAsleep, session.state != .starting,
              let seen = channelLastSeen[session.id], Date().timeIntervalSince(seen) < 60 else { return false }
        // At rest, a channel event starts a turn of its own with no prompt hook to say whose it is.
        if session.isSumi, session.state != .working { session.turnFromUser = false }
        if let waiter = channelWaiters.removeValue(forKey: session.id) {
            var response = ControlResponse.success()
            response.messages = [text]
            waiter(response)
        } else {
            channelInbox[session.id, default: []].append(text)
            // A poller that died inside the freshness window never drains this: if the message is
            // still waiting, call the channel dead and type it instead.
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak session] in
                guard let self, let session, var inbox = self.channelInbox[session.id],
                      let index = inbox.firstIndex(of: text) else { return }
                inbox.remove(at: index)
                self.channelInbox[session.id] = inbox.isEmpty ? nil : inbox
                self.channelLastSeen[session.id] = nil
                _ = session.deliver(text, from: nil)
            }
        }
        return true
    }
    /// Shows an in-app confirmation; set by the window controller.
    var confirmHandler: ((String, String, @escaping (Bool) -> Void) -> Void)?

    private var childCancellables: [UUID: AnyCancellable] = [:]
    private var childChangeQueued = false
    private var lastOutline: [SessionOutline] = []
    private var persistWork: DispatchWorkItem?
    let notifier = AttentionNotifier()
    /// Receipts for queued messages, gathered per sender.
    var messageReceipts = MessageReceipts()
    /// Previews and tests post no banners.
    private(set) var notifiesUser = true
    /// Previews and tests write nothing to disk: the test host shares the app's support folder.
    private(set) var persists = true

    init() {}

    #if DEBUG
    /// Inert fixtures for native previews and visual QA. No processes, persistence, or hooks.
    init(previewSessions: [TerminalSession], previewLayout: LayoutMode = .grid) {
        sessions = previewSessions
        layout = previewLayout
        notifiesUser = false
        persists = false
        tileOrder = []
        selectedID = previewSessions.first?.id
        recent = previewSessions.map(\.id)
        lastOutline = previewSessions.map(SessionOutline.init)
    }
    #endif

    var selected: TerminalSession? { sessions.first { $0.id == selectedID } }

    /// Sessions on screen for the current layout, in a stable (creation) order so tiles don't
    /// jump around as states change.
    var visibleIDs: [UUID] {
        switch layout {
        case .focus:
            // A detached session shows in its own window; the canvas falls back to one it holds.
            guard let selected, selected.isDetached else { return selectedID.map { [$0] } ?? [] }
            let onCanvas = sessions.filter { !$0.isMinimized && !$0.isSumi && !$0.isDetached }
            let ids = Set(onCanvas.map(\.id))
            return (recent.first { ids.contains($0) } ?? onCanvas.first?.id).map { [$0] } ?? []
        case .split:
            let hidden = Set(sessions.filter { $0.isMinimized || $0.isSumi || $0.isDetached }.map(\.id))
            let pair = Set(recent.filter { !hidden.contains($0) }.prefix(2))
            return arranged(sessions.filter { pair.contains($0.id) }).map(\.id)
        case .grid:
            // Servers live in the strip below the canvas unless pinned or selected; minimized
            // sessions wait on the shelf. Sumi answers in the sidebar's box instead, and
            // detached sessions in their own windows.
            return arranged(sessions.filter { session in
                (session.kind != .server || session.pinnedToGrid || session.id == selectedID)
                    && (!isExited(session) || session.id == selectedID)
                    && !session.isMinimized && !session.isSumi && !session.isDetached
            }).map(\.id)
        }
    }

    /// Tiles in the user's order; anything they never moved keeps creation order after it.
    private func arranged(_ list: [TerminalSession]) -> [TerminalSession] {
        var rank: [UUID: Int] = [:]
        for (index, id) in tileOrder.enumerated() where rank[id] == nil { rank[id] = index }
        return list.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    /// Records a drag: `visible` is the new on-screen order.
    func setTileOrder(_ visible: [UUID]) {
        let placed = Set(visible)
        let alive = Set(sessions.map(\.id))
        tileOrder = (visible + tileOrder.filter { !placed.contains($0) }).filter(alive.contains)
        UserDefaults.standard.set(tileOrder.map(\.uuidString), forKey: "tileOrder")
        onArrangementChange?()
    }

    /// Parks a session on the shelf (or brings it back). Minimizing the focused tile moves focus
    /// to the next one on screen.
    func setMinimized(_ session: TerminalSession, _ minimized: Bool) {
        guard session.isMinimized != minimized else { return }
        session.spec.minimized = minimized ? true : nil
        persist()
        if minimized, selectedID == session.id {
            // Focus shows only the selection, so there may be nothing else on screen: fall back
            // like close does, to a session the canvas holds.
            let next = visibleIDs.first { $0 != session.id }.flatMap { id in sessions.first { $0.id == id } }
                ?? sessions.last { $0.id != session.id && !$0.isSumi && !$0.isMinimized && !$0.isDetached }
            select(next)
        } else {
            onArrangementChange?()
        }
    }

    private func isExited(_ session: TerminalSession) -> Bool {
        if case .exited = session.state { return true }
        return false
    }

    func setLayout(_ mode: LayoutMode) {
        layoutBeforeZoom = nil
        guard layout != mode else { return }
        layout = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "layout")
        onArrangementChange?()
    }

    /// Zoom a tile to fill the window, or return to the layout it came from.
    func toggleZoom(_ id: UUID? = nil) {
        if layout == .focus, let previous = layoutBeforeZoom {
            layoutBeforeZoom = nil
            layout = previous
        } else if layout != .focus {
            layoutBeforeZoom = layout
            layout = .focus
        }
        if let id, let session = sessions.first(where: { $0.id == id }) { select(session) } else { onArrangementChange?() }
    }

    /// Sidebar order: needs-you first, then by creation.
    var grouped: [(title: String, sessions: [TerminalSession])] {
        let sorted = sessions.sorted {
            ($0.state.groupRank, $0.spec.createdAt) < ($1.state.groupRank, $1.spec.createdAt)
        }
        var groups: [(String, [TerminalSession])] = []
        for session in sorted {
            let title = session.state.groupTitle
            if let last = groups.last, last.0 == title {
                groups[groups.count - 1].1.append(session)
            } else {
                groups.append((title, [session]))
            }
        }
        return groups.map { (title: $0.0, sessions: $0.1) }
    }

    var attentionCount: Int { sessions.filter { $0.state.needsAttention }.count }
    var reviewCount: Int { sessions.filter(\.readyForReview).count }

    /// Creation order everywhere: positions never shift when states change, so muscle memory
    /// (⌘1–9, where a card sits) stays valid. Attention is shown, not sorted.
    var orderedSessions: [TerminalSession] { sessions }

    /// Agents grouped by repository (worktrees join their main repo), in creation order.
    var projects: [(name: String, agents: [TerminalSession])] {
        var order: [String] = []
        var groups: [String: [TerminalSession]] = [:]
        for session in sessions where session.kind.isAgent && !session.isSumi {
            let name = session.git?.project ?? "Scratch"
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(session)
        }
        return order.map { (name: $0, agents: groups[$0] ?? []) }
    }

    var utilities: [TerminalSession] { sessions.filter { !$0.kind.isAgent && $0.kind != .browser } }

    /// Browsers an agent owns sit under it in the sidebar; the rest get their own section.
    func browsers(ownedBy agent: TerminalSession) -> [TerminalSession] {
        sessions.filter { $0.kind == .browser && $0.spec.owner == agent.id }
    }

    /// Dev servers Tako started for an agent's workspace (`.tako.json` "dev"). They serve
    /// that worktree only, so they close with the agent.
    func servers(ownedBy agent: TerminalSession) -> [TerminalSession] {
        sessions.filter { $0.kind == .server && $0.spec.owner == agent.id }
    }

    /// Sumi has no sidebar row, so its browsers are loose too.
    var looseBrowsers: [TerminalSession] {
        let agents = Set(sessions.filter { $0.kind.isAgent && !$0.isSumi }.map(\.id))
        return sessions.filter { $0.kind == .browser && !($0.spec.owner.map(agents.contains) ?? false) }
    }

    // MARK: - Child changes

    /// Rows observe their own session, so the store only re-publishes when something its own
    /// views read (grouping, ordering, counts, the attention queue) actually changed. Coalesced:
    /// a poll that touches every session costs one comparison, not one re-render per property.
    private func childWillChange() {
        guard !childChangeQueued else { return }
        childChangeQueued = true
        // objectWillChange fires before the value lands; compare once it has.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.childChangeQueued = false
                let outline = self.sessions.map(SessionOutline.init)
                guard outline != self.lastOutline else { return }
                self.lastOutline = outline
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    func create(_ spec: LaunchSpec, resume: Bool = false, select: Bool = true, worktree: Bool = false, task: String? = nil) -> TerminalSession {
        let spec = labeled(spec)
        let prepared = SessionLaunchPreparation.synchronous(spec, resume: resume, worktree: worktree)
        return finishLaunch(prepared, resume: resume, select: select, task: task)
    }

    /// UI and IPC launches suspend while Git and workspace setup run on one background queue.
    /// Reserve addresses before suspending so a simultaneous launch or rename cannot take them.
    @discardableResult
    func launch(_ spec: LaunchSpec, resume: Bool = false, select: Bool = true, worktree: Bool = false,
                isolateIfPossible: Bool = false, task: String? = nil) async -> TerminalSession {
        var spec = labeled(spec)
        spec.label = launchLabels.reserve(spec.label, for: spec.id, occupied: Set(sessions.map(\.label)))
        launchingCount += 1
        defer {
            launchLabels.release(spec.id)
            launchingCount -= 1
        }
        let prepared = await SessionLaunchPreparation.prepare(spec, resume: resume, worktree: worktree,
                                                             isolateIfPossible: isolateIfPossible)
        return finishLaunch(prepared, resume: resume, select: select, task: task)
    }

    private func labeled(_ original: LaunchSpec) -> LaunchSpec {
        var spec = original
        // Unnamed agents, shells and browsers get a short name (alpha, bravo…) that stays put, so
        // it's quick to refer to; the task shows as the summary instead.
        if spec.label.isEmpty, spec.kind != .server {
            spec.label = nextPhoneticLabel(excluding: spec.id)
            spec.labelSource = .user
            return spec
        }
        spec.label = uniqueLabel(spec.label.isEmpty ? defaultLabel(for: spec) : spec.label, excluding: spec.id)
        return spec
    }

    private func finishLaunch(_ prepared: PreparedSessionLaunch, resume: Bool, select: Bool, task: String?) -> TerminalSession {
        var spec = prepared.spec
        if let error = prepared.error { lastError = error }
        // Port reservation stays on the main actor, beside session insertion: overlapping
        // preparations can never assign the same workspace port.
        // New agents start on the account picked for new agents; resumed ones keep theirs.
        if spec.kind.isAgent, spec.account == nil, !resume {
            let preferred = AccountStore.shared.preferredID(for: spec.kind)
            if preferred != AgentAccount.defaultID { spec.account = preferred }
        }
        if spec.kind.isAgent, spec.worktreeBranch != nil || spec.worktreeName != nil {
            spec.portSlot = PortSlots.assign(current: spec.portSlot, taken: Set(sessions.compactMap(\.spec.portSlot)))
        }
        if spec.kind.isAgent, spec.port == nil, let config = prepared.config {
            // Other agents' port ranges are theirs, so a dev server port never lands in one.
            let ranges = sessions.compactMap(\.spec.portSlot).flatMap(PortSlots.range)
            spec.port = Ports.allocate(config: config, taken: Set(sessions.compactMap(\.spec.port) + ranges))
        }
        // The first task is what the session was for; a resumed one keeps it.
        if let task, !task.isEmpty, spec.memory?.task == nil {
            spec.memory = spec.memory ?? SessionMemory()
            spec.memory?.task = sanitizeMessage(task)
        }
        recordWorktree(spec)
        let session = TerminalSession(spec: spec, resume: resume, task: task.map(sanitizeMessage))
        if let task, !task.isEmpty { session.record(.prompt, task) }
        session.store = self
        sessions.append(session)
        childCancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.childWillChange()
        }
        onSurfaceChange?(session)
        if select { self.select(session) }
        persist()
        if !resume { startDevServerIfConfigured(for: session, config: prepared.config) } else { loadTurns(session) }
        if !resume { recordAgentStart(session, restarted: false) }
        // Claude copies `.worktreeinclude` files into its own worktrees.
        if !resume, spec.kind != .claude, spec.worktreeBranch != nil { warmWorktree(session) }
        // Without a prompt hook (Codex), an agent started with a task never rests before its
        // first turn, so that turn's start is recorded here.
        if spec.kind.adapter?.reportsPrompts == false, !resume, let task, !task.isEmpty {
            checkpoint(session, phase: .start, prompt: task)
            session.turnOpenedByGuess = true
        }
        return session
    }

    /// A project's `.tako.json` "dev" command runs next to each new agent workspace, on the
    /// agent's own port.
    private func startDevServerIfConfigured(for agent: TerminalSession, config: ProjectConfig?) {
        guard agent.kind.isAgent, agent.spec.worktreeBranch != nil || agent.spec.worktreeName != nil,
              let port = agent.spec.port else { return }
        let path = agent.spec.workPath
        Workspaces.whenReady(path) { [weak self] in
            guard let self, self.sessions.contains(where: { $0.id == agent.id }) else { return }
            Task { @MainActor [weak self, weak agent] in
                let config = await SessionLaunchPreparation.configuration(for: path, fallback: config)
                guard let self, let agent, self.sessions.contains(where: { $0.id == agent.id }),
                      let config, let dev = config.dev else { return }
                var command = dev.replacingOccurrences(of: "$PORT", with: String(port))
                if let setup = config.setup { command = "\(setup) && \(command)" }
                var server = LaunchSpec(label: "\(agent.label)-dev", kind: .server, cwd: path, command: command)
                server.labelSource = .auto
                server.port = port
                server.owner = agent.id
                self.create(server, select: false)
            }
        }
    }

    func close(_ session: TerminalSession) {
        // An agent's browsers are its tools: left behind they'd become loose tiles, each holding
        // a Chromium renderer.
        // Its workspace's dev server goes too: restored without it, it would hold the port forever.
        if session.kind.isAgent { (browsers(ownedBy: session) + servers(ownedBy: session)).forEach(close) }
        dropAllApprovals(for: session)
        messagesDropped(from: session, reason: "@\(session.label) was closed")
        rememberClosed(session)
        if session.spec.labelSource == .user || session.spec.labelSource == nil {
            reservedLabels[session.label] = Date()
        }
        // Its events stop with the process, so a watch or handoff ends here, told to Sumi.
        let sumiHears = sumi.map { $0.id != session.id && !$0.isExitedProcess } ?? false
        if sumiWatches.removeValue(forKey: session.id) != nil, sumiHears {
            addToSumiDigest(SumiEvent(label: session.label, kind: .exited))
        }
        if session.delegation != nil {
            session.delegation = nil
            if sumiHears { addToSumiDigest(SumiEvent(label: session.label, kind: .stoppedHandling("it was closed"))) }
        }
        session.terminate()
        collectWorktree(afterClosing: session.spec)
        codexServers.removeValue(forKey: session.id)?.close()
        codexHeldRequests[session.id] = nil
        dropChannel(for: session)
        sessions.removeAll { $0.id == session.id }
        forgetOverlaps(with: session)
        agentToolsSessionClosed(session)
        startupHealth.forget(session.id)
        childCancellables[session.id] = nil
        recent.removeAll { $0 == session.id }
        onRemove?(session)
        // Next in view, so closing a tile never brings back one the shelf or a window holds.
        if selectedID == session.id {
            select(visibleIDs.compactMap { id in sessions.first { $0.id == id } }.last
                ?? sessions.last { !$0.isSumi && !$0.isMinimized && !$0.isDetached })
        } else {
            // The others re-flow into the space it left. A status-style refresh: the selection
            // didn't change, so keyboard focus stays where the user is (Sumi or ht may close it).
            onStatusChange?()
        }
        persist()
        notifier.updateBadge(count: attentionCount)
    }

    func select(_ session: TerminalSession?) {
        // Sumi has no tile; choosing it opens its panel.
        if let session, session.isSumi { onShowSumi?(); return }
        if let previous = selected { previous.lastViewedAt = Date() }
        // Choosing a minimized session is asking for it back.
        if let session, session.isMinimized {
            session.spec.minimized = nil
            persist()
        }
        selectedID = session?.id
        if let session {
            if session.unread { session.unread = false }
            if session.finishedUnseen { session.finishedUnseen = false }
            recent.removeAll { $0 == session.id }
            recent.insert(session.id, at: 0)
        }
        // A detached session is chosen by bringing its window forward. After the selection is
        // set: its window becoming key reports back as a choice of what is already chosen.
        if let session, session.isDetached { onShowDetached?(session) }
        onArrangementChange?()
    }

    @discardableResult
    func rename(_ session: TerminalSession, to raw: String, source: LabelSource = .user) -> String? {
        let base = normalizeLabel(raw)
        guard !base.isEmpty else { return nil }
        let label = uniqueLabel(base, excluding: session.id)
        if label != session.label {
            var previous = session.spec.previousLabels ?? []
            previous.removeAll { $0 == label }
            previous.append(session.label)
            session.spec.previousLabels = Array(previous.suffix(8))
            session.spec.label = label
            session.syncNativeName()
            session.labelChanged()
        }
        session.spec.labelSource = source
        persist()
        onArrangementChange?()
        return label
    }

    func isReserved(_ label: String) -> Bool {
        reservedLabels = reservedLabels.filter { Date().timeIntervalSince($0.value) < 3600 }
        return reservedLabels[label] != nil || launchLabels.contains(label)
    }

    func confirm(_ title: String, _ message: String, completion: @escaping (Bool) -> Void) {
        guard let confirmHandler else { completion(false); return }
        confirmHandler(title, message, completion)
    }

    /// Hands naming back to the agent.
    func releaseLabel(_ session: TerminalSession) {
        session.spec.labelSource = .auto
        persist()
    }

    func sessionSurfaceReplaced(_ session: TerminalSession) {
        onSurfaceChange?(session)
        onArrangementChange?()
    }

    // MARK: - Lookup

    func find(_ target: String) -> TerminalSession? {
        if let uuid = UUID(uuidString: target) { return sessions.first { $0.id == uuid } }
        let label = normalizeLabel(target)
        // A single letter is short for its default name: "b" is @bravo.
        let spelled = label.count == 1 ? phoneticLabels.first { $0.hasPrefix(label) } : nil
        return sessions.first { $0.label == label }
            ?? sessions.first { ($0.spec.previousLabels ?? []).contains(label) }
            ?? spelled.flatMap { name in sessions.first { $0.label == name } }
    }

    func session(forEnvironmentID id: String?) -> TerminalSession? {
        guard let id, let uuid = UUID(uuidString: id) else { return nil }
        return sessions.first { $0.id == uuid }
    }

    // MARK: - Navigation

    func selectNextNeedingAttention() {
        let waiting = sessions
            .filter { $0.state.needsAttention || $0.unread }
            .sorted { $0.stateChangedAt < $1.stateChangedAt }
        if let next = waiting.first(where: { $0.id != selectedID }) ?? waiting.first { select(next) }
    }

    /// Sidebar order: agents by project, then servers and shells.
    var navigationOrder: [TerminalSession] {
        projects.flatMap { $0.agents.flatMap { [$0] + browsers(ownedBy: $0) } } + utilities + looseBrowsers
    }

    func selectRelative(_ offset: Int) {
        let ordered = navigationOrder
        guard !ordered.isEmpty else { return }
        let index = ordered.firstIndex { $0.id == selectedID } ?? 0
        select(ordered[(index + offset + ordered.count) % ordered.count])
    }

    func select(index: Int) {
        let ordered = navigationOrder
        guard ordered.indices.contains(index) else { return }
        select(ordered[index])
    }

    // MARK: - Session callbacks

    func sessionStateChanged(_ session: TerminalSession, from previous: AgentState) {
        notifier.updateBadge(count: attentionCount)
        if previous == .working { markFinished(session) }
        onStatusChange?()
        reportToSumi(session, from: previous)
        healthStateChanged(session, from: previous)
        adoptIntoPhoneMode(session)
        delegationStateChanged(session, from: previous)
        watchOverlaps(session, from: previous)
        agentToolsStateChanged(session)
        let isVisible = userIsLooking(at: session)
        switch session.state {
        case .needsInput(let reason):
            // Handed to Sumi: it hears instead, and the user only if it doesn't answer.
            if sumiTakesWait(session, reason: reason) { break }
            if !isVisible { session.unread = true }
            notifier.post(session: session, title: "@\(session.label) needs you", body: reason, foreground: !isVisible, kind: .needsYou)
        case .idle where previous == .working && session.kind.isAgent && raceFinished(session):
            // Every agent on this task is done: one notification for the race, not one each.
            let all = [session] + raceSiblings(of: session)
            let changed = all.filter { ($0.diffStat?.files ?? 0) > 0 }.count
            notifier.post(session: session, title: "All \(all.count) agents finished",
                          body: "\(changed) changed files. Compare them side by side, then right-click the best → Pick This One.",
                          foreground: !NSApp.isActive, kind: .finished)
        case .idle where previous == .working && session.kind.isAgent:
            if !isVisible {
                session.unread = true
                notifier.post(session: session, title: "@\(session.label) finished", body: session.summary ?? "Turn complete", foreground: false, kind: .finished)
            }
        case .failed(let reason):
            if !isVisible { session.unread = true }
            notifier.post(session: session, title: "@\(session.label) failed", body: reason, foreground: !isVisible, kind: .failed)
        case .exited(let code) where session.kind == .server && code != 0:
            session.unread = true
            notifier.post(session: session, title: "@\(session.label) crashed", body: "exit \(code)", foreground: true, kind: .crashed)
        default:
            break
        }
    }

    /// The last agent of a race just finished.
    private func raceFinished(_ session: TerminalSession) -> Bool {
        let siblings = raceSiblings(of: session)
        return !siblings.isEmpty && siblings.allSatisfy { sibling in
            switch sibling.state {
            case .idle, .failed, .exited: return true
            default: return false
            }
        }
    }

    func sessionWantsAttention(_ session: TerminalSession, title: String, body: String) {
        guard !userIsLooking(at: session) else { return }
        session.unread = true
    }

    /// The user is looking at this session: on the canvas while the app is active, or in a
    /// detached window that is the key window.
    func userIsLooking(at session: TerminalSession) -> Bool {
        (visibleIDs.contains(session.id) && NSApp.isActive)
            || (session.isDetached && session.surface.window?.isKeyWindow == true)
    }

    /// Clicking into a tile's terminal makes it the selected session.
    func sessionFocused(_ session: TerminalSession) {
        if selectedID != session.id { select(session) }
        else if session.finishedUnseen { session.finishedUnseen = false; onStatusChange?() }
    }

    /// How long a finished agent stays marked as done before it reads as plain idle.
    static let finishedMarkDuration: TimeInterval = 180

    /// An agent's work is done: its turn ended and no background subagent is still running. It
    /// stays marked for a few minutes or until the user clicks into it, unless it is the only
    /// terminal on screen and they were already looking at it.
    func markFinished(_ session: TerminalSession) {
        guard session.kind.isAgent, session.state == .idle, session.runningSubagents.isEmpty,
              !(selectedID == session.id && NSApp.isActive && visibleIDs.count <= 1) else { return }
        session.finishedUnseen = true
        let finishedAt = session.stateChangedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finishedMarkDuration) { [weak self, weak session] in
            // A later turn has its own mark and its own timer.
            guard let session, session.finishedUnseen, session.stateChangedAt == finishedAt else { return }
            session.finishedUnseen = false
            self?.onStatusChange?()
        }
    }

    // MARK: - Persistence

    private var stateFile: URL { Self.stateFileURL }
    private static var stateFileURL: URL { ControlPaths.supportDirectory.appendingPathComponent("sessions.json") }

    /// True when an earlier run left session state: an upgrade rather than a fresh install.
    static var hasSavedState: Bool { FileManager.default.fileExists(atPath: stateFileURL.path) }

    /// Writes run one at a time, so a quit's flush can't be overwritten by an older write.
    /// Every file the store writes goes through this one queue, so `flushPersist` waits for all of them.
    static let persistQueue = DispatchQueue(label: "dev.tako.persist", qos: .utility)

    func persist() {
        guard persists else { return }
        persistWork?.cancel()
        let specs = sessions.map(\.spec)
        let url = stateFile
        let work = DispatchWorkItem { Self.write(specs, to: url) }
        persistWork = work
        Self.persistQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Quitting: writes the sessions now instead of after persist's debounce, once any write
    /// already under way has landed.
    func flushPersist() {
        guard persists else { return }
        persistWork?.cancel()
        persistWork = nil
        let specs = sessions.map(\.spec)
        let url = stateFile
        Self.persistQueue.sync { Self.write(specs, to: url) }
    }

    nonisolated private static func write(_ specs: [LaunchSpec], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(specs) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func restore() -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: stateFile),
              let specs = try? decoder.decode([LaunchSpec].self, from: data), !specs.isEmpty else { return false }
        // Drop summaries derived from the old title-only heuristic.
        Self.ownedDevServers(specs).map { spec -> LaunchSpec in
            var spec = spec
            if spec.summary == spec.label { spec.summary = nil }
            // Sumi from before it had its own folder starts fresh there; its notes file
            // carries what it knew.
            if spec.sumi == true, spec.cwd != Self.sumiFolder {
                spec.cwd = Self.sumiFolder
                spec.agentSessionId = nil
            }
            // Sumi resumes its conversation on the model it's set to now, not the one it last ran on.
            if spec.sumi == true { spec.options?.model = Self.sumiModel(for: spec.kind) }
            return spec
        }.forEach { create($0, resume: true, select: false) }
        // Never Sumi: selecting it opens its panel instead.
        select(sessions.first { !$0.isSumi })
        return true
    }

    /// Dev servers saved before they had an owner are given back to the agent whose workspace
    /// they serve; one whose agent is gone isn't restored, so its port is free again.
    static func ownedDevServers(_ specs: [LaunchSpec]) -> [LaunchSpec] {
        let agents = specs.filter(\.kind.isAgent)
        let ids = Set(agents.map(\.id))
        return specs.compactMap { spec in
            guard spec.kind == .server else { return spec }
            if let owner = spec.owner { return ids.contains(owner) ? spec : nil }
            guard spec.labelSource == .auto, spec.label.hasSuffix("-dev"),
                  let agent = agents.first(where: { $0.isWorktree && $0.workPath == expandTilde(spec.cwd) && $0.port == spec.port })
            else { return spec }
            var adopted = spec
            adopted.owner = agent.id
            return adopted
        }
    }

    // MARK: - Labels

    private func defaultLabel(for spec: LaunchSpec) -> String {
        let folder = URL(fileURLWithPath: expandTilde(spec.cwd)).lastPathComponent
        switch spec.kind {
        case .server: return normalizeLabel(folder + "-server")
        case .shell: return normalizeLabel(folder)
        default: return normalizeLabel(folder)
        }
    }

    /// The first free name in alpha…zulu; after all 26, alpha-2 and so on.
    func nextPhoneticLabel(excluding id: UUID? = nil) -> String {
        let taken = Set(sessions.filter { $0.id != id }.map(\.label))
            .union(launchLabels.occupied(excluding: id ?? UUID()))
        if let free = phoneticLabels.first(where: { !taken.contains($0) }) { return free }
        return SessionLabelReservations.available(phoneticLabels[0], taken: taken)
    }

    /// Labels are addresses, so they must be unique: api, api-2, api-3.
    private func uniqueLabel(_ base: String, excluding id: UUID) -> String {
        let taken = Set(sessions.filter { $0.id != id }.map(\.label)).union(launchLabels.occupied(excluding: id))
        return SessionLabelReservations.available(base, taken: taken)
    }
}

/// Pending sessions use the same address space as sessions already on screen.
struct SessionLabelReservations {
    private var labels: [UUID: String] = [:]

    mutating func reserve(_ base: String, for id: UUID, occupied: Set<String>) -> String {
        let label = Self.available(base, taken: occupied.union(self.occupied(excluding: id)))
        labels[id] = label
        return label
    }

    mutating func release(_ id: UUID) { labels[id] = nil }

    func contains(_ label: String) -> Bool { labels.values.contains(label) }

    func occupied(excluding id: UUID) -> Set<String> {
        Set(labels.filter { $0.key != id }.map(\.value))
    }

    static func available(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base)-\(counter)") { counter += 1 }
        return "\(base)-\(counter)"
    }
}

struct PreparedSessionLaunch {
    let spec: LaunchSpec
    let config: ProjectConfig?
    let error: String?
}

/// Git worktree operations must be serialized, and none of this preparation touches UI state.
enum SessionLaunchPreparation {
    private static let queue = DispatchQueue(label: "dev.tako.session.prepare", qos: .userInitiated)

    static func prepare(_ spec: LaunchSpec, resume: Bool = false, worktree: Bool = false,
                        isolateIfPossible: Bool = false) async -> PreparedSessionLaunch {
        guard spec.kind.isAgent else { return PreparedSessionLaunch(spec: spec, config: nil, error: nil) }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: resolve(spec, resume: resume, worktree: worktree,
                                                       isolateIfPossible: isolateIfPossible))
            }
        }
    }

    /// Existing immediate callers (browser/utility creation and restoration) keep their API.
    static func synchronous(_ spec: LaunchSpec, resume: Bool, worktree: Bool) -> PreparedSessionLaunch {
        guard spec.kind.isAgent else { return PreparedSessionLaunch(spec: spec, config: nil, error: nil) }
        return queue.sync { resolve(spec, resume: resume, worktree: worktree, isolateIfPossible: false) }
    }

    static func configuration(for path: String, fallback: ProjectConfig?) async -> ProjectConfig? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: ProjectConfig.load(for: path) ?? fallback) }
        }
    }

    private static func resolve(_ original: LaunchSpec, resume: Bool, worktree: Bool,
                                isolateIfPossible: Bool) -> PreparedSessionLaunch {
        var spec = original
        var errorMessage: String?
        if !resume, worktree || isolateIfPossible {
            switch Workspaces.prepare(spec: spec) {
            case .success(let prepared):
                spec = prepared
            case .failure(let error):
                // Automatic isolation is optional outside repositories. Explicit requests
                // retain the existing fallback explanation, as do actual Git setup failures.
                let optionalNonRepository: Bool
                if case .notARepo = error { optionalNonRepository = isolateIfPossible && !worktree }
                else { optionalNonRepository = false }
                if !optionalNonRepository {
                    errorMessage = "Worktree not created: \(error.description). Started in \(abbreviateHome(spec.cwd)) instead."
                }
            }
        }
        let config = !resume || spec.port == nil ? ProjectConfig.load(for: expandTilde(spec.cwd)) : nil
        return PreparedSessionLaunch(spec: spec, config: config, error: errorMessage)
    }
}

/// The parts of a session that views observing the store (not the session) depend on.
@MainActor
private struct SessionOutline: Equatable {
    let id: UUID
    let label: String
    let state: AgentState
    let stateChangedAt: Date
    let summary: String?
    let cwd: String
    let git: GitInfo?
    let pinnedToGrid: Bool
    let minimized: Bool
    let readyForReview: Bool
    let port: Int?

    init(_ session: TerminalSession) {
        id = session.id
        label = session.label
        state = session.state
        stateChangedAt = session.stateChangedAt
        summary = session.summary
        cwd = session.spec.cwd
        git = session.git
        pinnedToGrid = session.pinnedToGrid
        minimized = session.isMinimized
        readyForReview = session.readyForReview
        port = session.spec.port
    }
}
