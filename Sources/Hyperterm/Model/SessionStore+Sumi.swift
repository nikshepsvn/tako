import Foundation

/// Sumi: one agent (Claude or Codex) behind the round button in the window's corner that
/// runs the user's other sessions. It starts agents in any project, arranges the tiles, and closes
/// what's done. It takes no tile and no card; its terminal opens in a floating panel.
extension SessionStore {
    var sumi: TerminalSession? { sessions.first(where: \.isSumi) }

    /// Its own Tako tools run without a permission prompt; the app still checks each call,
    /// and closing a terminal still asks.
    static let sumiTools = ["list_terminals", "read_terminal", "send_message", "start_agent", "arrange_view",
                                 "close_terminal", "save_layout", "restore_layout", "watch_terminal",
                                 "session_history", "reopen_session", "machine_status", "set_policy", "detach_terminals",
                                 "handle_waiting", "stop_handling", "answer_prompt", "phone_mode",
                                 "choose_option", "trust_folder", "sign_in", "interrupt_agent"]
        .map { "mcp__hyperterm__" + $0 }

    /// Where Sumi runs. Its own folder, trusted once: Claude Code asks to trust the home
    /// folder again on every launch, and Sumi reaches every project with absolute paths.
    static var sumiFolder: String {
        let folder = ControlPaths.supportDirectory.appendingPathComponent("organizer")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.path
    }

    static let sumiKindKey = "organizerKind"
    /// Where the choice is kept. A variable so tests can use their own suite.
    static var sumiDefaults = UserDefaults.standard

    /// The CLIs that can run Sumi: every agent kind.
    static var sumiChoices: [SessionKind] { SessionKind.allCases.filter(\.isAgent) }

    /// The CLI the user picked to run Sumi; nil until they first do.
    static var chosenSumiKind: SessionKind? {
        sumiDefaults.string(forKey: sumiKindKey).flatMap(SessionKind.init(rawValue:)).flatMap { $0.isAgent ? $0 : nil }
    }

    /// Which CLI runs Sumi: Claude unless the user switched it in its header, or only Codex is
    /// installed. Phone Mode rides on Claude's Remote Control, so Claude is the default.
    static var sumiKind: SessionKind {
        get { chosenSumiKind ?? (InstalledAgents.shared.isInstalled(.claude) ? .claude : .codex) }
        set { sumiDefaults.set(newValue.rawValue, forKey: sumiKindKey) }
    }

    /// Sumi starts at once: it runs on its CLI's own default model unless the user picked another.
    var sumiNeedsChoice: Bool { false }

    // MARK: - Its model

    /// A model Sumi can run on. It is the brain the user talks to from their phone, so it runs on
    /// the CLI's own (strongest) default unless the user picks a smaller one.
    struct SumiModel: Equatable, Identifiable {
        /// Passed to the CLI as its model; nil leaves the CLI's own default.
        var name: String?
        var title: String
        var detail: String

        var id: String { name ?? "" }
    }

    /// The CLI's default first. Codex's names come from its model catalog (`codex debug models`).
    static func sumiModels(for kind: SessionKind) -> [SumiModel] {
        switch kind {
        case .claude: return [
            SumiModel(name: nil, title: "Claude Code's default", detail: "Usually Opus: the strongest at running many agents."),
            SumiModel(name: "sonnet", title: "Sonnet", detail: "Mid-size and quicker."),
            SumiModel(name: "haiku", title: "Haiku", detail: "Smallest and fastest; misses more."),
        ]
        case .codex: return [
            SumiModel(name: nil, title: "Codex's default", detail: "Its strongest model."),
            SumiModel(name: "gpt-6-luna", title: "GPT-6-Luna", detail: "Fast and affordable; misses more."),
        ]
        default: return []
        }
    }

    private static func sumiModelKey(_ kind: SessionKind) -> String { "organizerModel." + kind.rawValue }

    /// Whether `name` is one of `kind`'s own models: a model from another CLI (Codex's `gpt-6-luna` on
    /// Claude) is never launched, and "" is the CLI's own default.
    static func isSumiModel(_ name: String, of kind: SessionKind) -> Bool {
        name.isEmpty || sumiModels(for: kind).contains { $0.name == name }
    }

    /// The model picked for `kind`: nil until picked, "" for the CLI's own default. One saved for
    /// another CLI is dropped, so Sumi falls back to the default instead of launching a CLI with it.
    static func chosenSumiModel(for kind: SessionKind) -> String? {
        guard let name = sumiDefaults.string(forKey: sumiModelKey(kind)) else { return nil }
        guard isSumiModel(name, of: kind) else {
            sumiDefaults.removeObject(forKey: sumiModelKey(kind))
            return nil
        }
        return name
    }

    static func setSumiModel(_ name: String?, for kind: SessionKind) {
        resetModelsPickedByTheOldChooserOnce()
        sumiDefaults.set(name ?? "", forKey: sumiModelKey(kind))
    }

    /// A model that didn't start: forgotten, so Sumi goes back to the CLI's default.
    static func forgetSumiModel(for kind: SessionKind) {
        sumiDefaults.removeObject(forKey: sumiModelKey(kind))
    }

    /// What Sumi is launched with: nil for the CLI's default.
    static func sumiModel(for kind: SessionKind) -> String? {
        resetModelsPickedByTheOldChooserOnce()
        return chosenSumiModel(for: kind).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let modelsResetKey = "organizerModelsResetToDefault"

    /// The first-run chooser used to pre-select the smallest model, so models saved before it
    /// went are reset once to the CLI's default. A model picked after this sticks.
    static func resetModelsPickedByTheOldChooserOnce() {
        guard !sumiDefaults.bool(forKey: modelsResetKey) else { return }
        sumiDefaults.set(true, forKey: modelsResetKey)
        for kind in sumiChoices { sumiDefaults.removeObject(forKey: sumiModelKey(kind)) }
    }

    /// The model step's choice for `kind`, the CLI whose models were shown: remembered, then the
    /// sumi starts on that CLI and model, replacing one running.
    func chooseSumiModel(_ name: String?, for kind: SessionKind) {
        guard Self.isSumiModel(name ?? "", of: kind) else { return }
        Self.sumiKind = kind
        Self.setSumiModel(name, for: kind)
        if let sumi, !sumi.isExitedProcess { close(sumi) }
        startSumi()
    }

    /// A running sumi that isn't on the CLI chosen (a choice made while another was starting,
    /// or one left from an earlier run) moves to the chosen CLI.
    func reconcileSumiKind() {
        guard !sumiStarting, let sumi, sumi.kind != Self.sumiKind else { return }
        switchSumi(to: Self.sumiKind)
    }

    /// Starts Sumi in `cwd`, replacing one that has exited. It runs with full access:
    /// its work spans every project, so it never stops to ask before reading or running something.
    func startSumi(task: String? = nil) {
        guard !sumiStarting else { return }
        if let sumi {
            guard sumi.isExitedProcess else { return }
            close(sumi)
        }
        var spec = LaunchSpec(label: "sumi", kind: Self.sumiKind, cwd: Self.sumiFolder)
        spec.sumi = true
        spec.options = AgentOptions(mode: .fullAccess, model: Self.sumiModel(for: Self.sumiKind))
        sumiStarting = true
        Task { @MainActor [spec] in
            await self.launch(spec, select: false, task: task)
            self.sumiStarting = false
            self.syncSumiFocusForPhone()
            if self.remoteControlWhenSumiUp, let sumi = self.sumi {
                self.remoteControlWhenSumiUp = false
                if self.isPhoneModeOn { sumi.openRemoteControl() }
            }
            // The CLI was switched while this one was starting.
            if let sumi = self.sumi, sumi.kind != Self.sumiKind { self.switchSumi(to: Self.sumiKind) }
        }
    }

    /// Runs Sumi on another CLI: the current one closes and a new one starts where it was.
    func switchSumi(to kind: SessionKind) {
        guard kind != sumi?.kind || sumi == nil else { Self.sumiKind = kind; return }
        Self.sumiKind = kind
        if kind != .claude { setPhoneMode(false) }
        guard let sumi else { return }
        close(sumi)
        startSumi()
    }

    // MARK: - Arranging

    /// Sessions Sumi just started, reopened or resumed. Opening several takes several
    /// calls, so whatever it opened in the last 20 s shows together: one fills the view, two or
    /// three sit side by side, more go in rows of three.
    func showOpenedBySumi(_ opened: [TerminalSession]) {
        let now = Date()
        sumiOpened.removeAll { entry in now.timeIntervalSince(entry.at) > 20 || !sessions.contains { $0.id == entry.id } }
        sumiOpened += opened.map { (id: $0.id, at: now) }
        let group = sumiOpened.compactMap { entry in sessions.first { $0.id == entry.id } }
        guard group.count > 1 else {
            if let only = group.first { select(only) }
            return
        }
        let rows = stride(from: 0, to: group.count, by: 3).map { start -> LayoutNode in
            let row = group[start..<min(start + 3, group.count)].map { LayoutNode.leaf($0.id) }
            return row.count == 1 ? row[0] : .split(axis: .horizontal, weights: row.map { _ in 1 }, children: row)
        }
        let tiles = rows.count == 1 ? rows[0] : LayoutNode.split(axis: .vertical, weights: rows.map { _ in 1 }, children: rows)
        arrange(layout: .grid, focus: opened.last, tiles: tiles)
    }

    /// Sumi's view request. `tiles` sets the grid exactly: the sessions it names show in
    /// that shape, servers it leaves out go to the strip, and everything else to the shelf.
    func arrange(layout: LayoutMode?, focus: TerminalSession?, tiles: LayoutNode?) {
        if let tiles {
            let shown = Set(tiles.leaves)
            for session in sessions where !session.isSumi {
                if session.kind == .server {
                    session.pinnedToGrid = shown.contains(session.id)
                    if shown.contains(session.id) { session.spec.minimized = nil }
                } else {
                    session.spec.minimized = shown.contains(session.id) ? nil : true
                }
            }
            persist()
            onArrangeTiles?(tiles)
        }
        // Focus first: a selected session outside the tiles would otherwise show and take space.
        let target = focus ?? tiles.flatMap { root in sessions.first { $0.id == root.leaves.first } }
        if let target { select(target) }
        if let tiles { setTileOrder(tiles.leaves) }
        if let layout { setLayout(layout) }
    }

    // MARK: - Named layouts

    struct SavedLayout: Codable {
        var layout: LayoutMode
        var focus: String?
        /// The grid's shape by label, so it survives restarts and renames back.
        var tiles: TileSpec?
    }

    private static let layoutsKey = "organizerLayouts"

    var savedLayouts: [String: SavedLayout] {
        guard let data = UserDefaults.standard.data(forKey: Self.layoutsKey) else { return [:] }
        return (try? JSONDecoder().decode([String: SavedLayout].self, from: data)) ?? [:]
    }

    /// Remembers the window as it is now under `name`.
    func saveLayout(_ name: String) {
        var tiles: TileSpec?
        if layout == .grid, let root = LayoutTreeStore.load(LayoutMode.grid.rawValue)?.root {
            tiles = tileSpec(root)
        }
        var all = savedLayouts
        all[name] = SavedLayout(layout: layout, focus: selected?.label, tiles: tiles)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.layoutsKey) }
    }

    /// Puts a saved layout back. Terminals closed since then are skipped; nil when none is left.
    func restoreLayout(_ name: String) -> [String]? {
        guard let saved = savedLayouts[name] else { return nil }
        let tiles = saved.tiles.flatMap(layoutNode)
        var focus = saved.focus.flatMap(find)
        if let shown = focus, shown.isSumi || tiles.map({ !$0.contains(shown.id) }) == true { focus = nil }
        if saved.tiles != nil && tiles == nil && focus == nil { return nil }
        arrange(layout: saved.layout, focus: focus, tiles: tiles)
        let shown = tiles?.leaves ?? focus.map { [$0.id] } ?? []
        return shown.compactMap { id in sessions.first { $0.id == id }?.label }
    }

    private func tileSpec(_ node: LayoutNode) -> TileSpec? {
        switch node {
        case .leaf(let id):
            return sessions.first { $0.id == id }.map { TileSpec(terminal: $0.label) }
        case .split(let axis, let weights, let children):
            let pairs = zip(weights, children).compactMap { weight, child in tileSpec(child).map { (weight, $0) } }
            guard !pairs.isEmpty else { return nil }
            return TileSpec(split: axis == .horizontal ? "row" : "column", sizes: pairs.map(\.0), children: pairs.map(\.1))
        }
    }

    /// Lenient: labels that no longer exist drop out, and their space goes to their neighbors.
    private func layoutNode(_ spec: TileSpec) -> LayoutNode? {
        var seen = Set<UUID>()
        func build(_ spec: TileSpec) -> LayoutNode? {
            if let label = spec.terminal {
                guard let session = find(label), !session.isSumi, seen.insert(session.id).inserted else { return nil }
                return .leaf(session.id)
            }
            let axis: LayoutAxis = spec.split == "column" ? .vertical : .horizontal
            let children = spec.children ?? []
            let sizes = spec.sizes.flatMap { $0.count == children.count ? $0 : nil } ?? children.map { _ in 1 }
            return LayoutNode.split(axis, zip(sizes, children).compactMap { size, child in build(child).map { (size, $0) } })
        }
        return build(spec)
    }

    // MARK: - History

    /// Closed agents it can reopen, newest first, in `folder` or below. Its own past runs are
    /// left out: reopening one would start a second sumi.
    func closedSessions(in folder: String? = nil) -> [LaunchSpec] {
        let root = folder.map { (expandTilde($0) as NSString).standardizingPath }
        return recentlyClosed.filter { spec in
            guard spec.sumi != true else { return false }
            guard let root else { return true }
            let path = (expandTilde(spec.cwd) as NSString).standardizingPath
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// The closed session `name` means: its label (or an earlier one) or its id. Newest wins.
    func closedSession(named name: String) -> LaunchSpec? {
        let id = UUID(uuidString: name.trimmingCharacters(in: .whitespaces))
        let label = normalizeLabel(name)
        return closedSessions().first { $0.id == id || $0.label == label || $0.previousLabels?.contains(label) == true }
    }

    /// session_history's reply: enough about each closed session to tell them apart and pick.
    static func describeHistory(_ specs: [LaunchSpec], now: Date = Date()) -> String {
        let relative = RelativeDateTimeFormatter()
        relative.locale = Locale(identifier: "en_US_POSIX")
        func ago(_ date: Date) -> String { relative.localizedString(for: date, relativeTo: now) }
        func oneLine(_ text: String, _ limit: Int) -> String {
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        return specs.map { spec in
            let memory = spec.memory
            var head = "@\(spec.label) [\(spec.kind.rawValue)] \(abbreviateHome(expandTilde(spec.cwd)))"
            if let branch = spec.worktreeBranch { head += " (branch \(branch))" }
            head += " · started " + ago(spec.createdAt)
            if let closed = memory?.closedAt { head += ", closed " + ago(closed) }
            head += spec.agentSessionId == nil ? " · starts fresh" : " · resumes its conversation"
            var lines = [head]
            if let state = memory?.finalState { lines.append("    ended: " + oneLine(state, 160)) }
            if let summary = spec.summary { lines.append("    summary: " + oneLine(summary, 200)) }
            if let task = memory?.task { lines.append("    task: " + oneLine(task, 200)) }
            for event in memory?.events ?? [] { lines.append("    - " + oneLine(event, 160)) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }

    // MARK: - Watching

    /// Above this much context in use, Sumi starts a fresh conversation before a digest.
    static let sumiClearPercent: Double = 60

    /// Gathers what Sumi should hear about this change, so one agent's finished work can
    /// start the next. It wakes once for the digest, not once per event.
    func reportToSumi(_ session: TerminalSession, from previous: AgentState) {
        // The plan moves with its owners even while Sumi is away; Sumi hears when it's back.
        planSawStateChange(session, from: previous)
        guard let sumi else { return }
        if sumi.id == session.id {
            // In Phone Mode Sumi is the user's only way in: one that quits comes back, on the phone.
            if case .exited = session.state, isPhoneModeOn { restartSumiForPhone(session) }
            flushSumiDigest()
            return
        }
        // An exited sumi would drop the event; the watch keeps until it can hear.
        guard !sumi.isExitedProcess else { return }
        // An agent launched by an agent can stop at the folder-trust prompt; only the user can
        // answer it, so Sumi is told, to pass that on rather than wait for it.
        if !isPhoneModeOn, session.spec.labelSource == .agent, session.state == .needsInput(TerminalSession.trustReason), previous != session.state {
            addToSumiDigest(SumiEvent(label: session.label, kind: .needsYou(
                "it's asking whether to trust this folder. Only the user can answer: they've been notified and can press Trust Folder on its card. Don't send it input", note: nil)))
        }
        extraSumiEvents(session, from: previous).forEach { addToSumiDigest($0) }
        guard let event = sumiEvent(session, from: previous) else { return }
        addToSumiDigest(event)
    }

    /// The steward saw something it won't act on alone; Sumi checks and tells the user.
    func reportToSumi(_ escalation: Escalation) {
        guard sumi != nil, stewardWarningIsNews(escalation) else { return }
        addToSumiDigest(SumiEvent(label: escalation.label, kind: .steward(escalation.message)))
    }

    /// `urgent` (an agent waiting on the user) goes out almost at once; the rest gather for a
    /// moment so a burst of finishes is one message.
    func addToSumiDigest(_ event: SumiEvent, urgent: Bool = false) {
        let first = sumiDigest.isEmpty
        sumiDigest.add(event, urgent: urgent)
        if first || urgent {
            DispatchQueue.main.asyncAfter(deadline: .now() + (urgent ? SumiDigest.urgentWindow : SumiDigest.window)) { [weak self] in
                self?.flushSumiDigest()
            }
        }
    }

    /// Restarts allowed within `sumiRestartWindow` before Tako stops trying and tells the Mac.
    static let sumiRestartLimit = 3
    static let sumiRestartWindow: TimeInterval = 300

    /// Sumi quit while the user is away: it starts again, reopens Remote Control and is told
    /// Phone Mode is on. A Sumi that keeps failing to start is left for the user.
    private func restartSumiForPhone(_ exited: TerminalSession, now: Date = Date()) {
        sumiRestarts = sumiRestarts.filter { now.timeIntervalSince($0) < Self.sumiRestartWindow }
        guard sumiRestarts.count < Self.sumiRestartLimit else {
            notifier.post(session: exited, title: "Sumi keeps stopping", body: "Phone Mode can't reach your agents until Sumi runs again. Open it on the Mac.", foreground: true, kind: .crashed)
            return
        }
        sumiRestarts.append(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isPhoneModeOn, self.sumi?.isExitedProcess ?? true else { return }
            self.remoteControlWhenSumiUp = true
            self.startSumi()
            self.addToSumiDigest(SumiEvent(label: "tako", kind: .phoneMode(true)))
        }
    }

    /// What this change means for Sumi, if anything. A watched terminal ending its turn
    /// uses up the watch; other kinds of event go here.
    private func sumiEvent(_ session: TerminalSession, from previous: AgentState) -> SumiEvent? {
        // In Phone Mode Sumi hears how every agent ends a turn, so it can tell the user.
        guard let note = sumiWatches[session.id] ?? (isPhoneModeOn && session.kind.isAgent ? "" : nil) else { return nil }
        let kind: SumiEvent.Kind
        switch session.state {
        // Background subagents outlive the turn; their last SubagentStop reports it instead.
        case .idle where previous == .working && session.runningSubagents.isEmpty:
            // The whole closing message (bounded), so Sumi needn't read_terminal for the rest.
            let summary = session.lastReply.flatMap { FinalReply.excerpt($0) } ?? Self.turnSummary(session)
                ?? "turn complete (read_terminal for its reply)"
            kind = .finished(summary + (finishFacts(session).map { " [\($0)]" } ?? ""))
        case .failed(let reason): kind = .failed(reason)
        case .exited: kind = .exited
        default: return nil
        }
        // A repeating watch re-arms until the terminal closes or exits.
        if case .exited = kind { sumiBrain.repeatWatches[session.id] = nil }
        sumiWatches[session.id] = sumiBrain.repeatWatches[session.id]
        return SumiEvent(label: session.label, kind: kind, note: note.isEmpty ? nil : note)
    }

    /// Sends the digest once its window has passed and Sumi isn't mid-turn; the
    /// sumi's own next state change tries again. A mostly full context is cleared first.
    /// Sumi hears even mid-turn: a message typed while it works queues in its CLI for when the
    /// current step ends. `deliver` holds it back only for a dialog or a half-typed draft.
    func flushSumiDigest(now: Date = Date()) {
        guard let sumi, !sumi.isExitedProcess else {
            // One on its way keeps what it should hear first (Phone Mode's briefing).
            if !sumiStarting { sumiDigest = SumiDigest() }
            return
        }
        guard sumiDigest.isDue(at: now), !sumiDigest.clearing else { return }
        guard !sumi.isWaking, sumi.state != .starting, sumi.inputIsEmpty, !sumi.dialogOnScreen else {
            retrySumiDigest()
            return
        }
        if sumi.atRest, sumi.usage.contextPercent ?? 0 >= Self.sumiClearPercent, sumi.startFreshConversation() {
            sumiDigest.clearing = true
            deliverDigestAfterClear(attempts: 10)
            return
        }
        if let message = sumiDigest.take() { _ = sumi.deliver(message, from: nil) }
    }

    /// A digest held back by Sumi's own screen (starting, waking, a dialog, a half-typed draft) is
    /// tried again shortly, not only on Sumi's next state change: one that sits idle behind a dialog
    /// would otherwise keep an agent's wait from it indefinitely.
    private func retrySumiDigest() {
        guard !sumiDigestRetryScheduled else { return }
        sumiDigestRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + SumiDigest.retryInterval) { [weak self] in
            self?.sumiDigestRetryScheduled = false
            self?.flushSumiDigest()
        }
    }

    /// Waits for Sumi to be back at an empty prompt after clearing, then sends the digest.
    private func deliverDigestAfterClear(attempts: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard let sumi = self.sumi else { self.sumiDigest = SumiDigest(); return }
            if attempts > 1, !(sumi.atRest && sumi.inputIsEmpty && !sumi.dialogOnScreen) {
                self.deliverDigestAfterClear(attempts: attempts - 1)
                return
            }
            self.sumiDigest.clearing = false
            if let message = self.sumiDigest.take(cleared: true) { _ = sumi.deliver(message, from: nil) }
        }
    }
}

/// Something Sumi should hear about.
struct SumiEvent: Equatable {
    enum Kind: Equatable {
        case finished(String), failed(String), exited, steward(String)
        /// A session handed to Sumi is waiting, with the user's note for it.
        case needsYou(String, note: String?)
        /// Phone Mode: a wait Sumi was told of is still open after this long.
        case stillWaiting(String, seconds: Int)
        case stoppedHandling(String)
        /// The user turned Phone Mode on or off; not about one terminal.
        case phoneMode(Bool)
        /// The plan moved: tasks done, failed, started.
        case plan(String)
        /// A server exited with an error, with its last output.
        case serverCrashed(code: Int, tail: String)
        /// An agent Sumi follows has waited on the user for minutes.
        case waitingLong(String, minutes: Int)
        /// Tako approved a handled session's request as the user always does in that project.
        case autoApproved(String)
    }

    var label: String
    var kind: Kind
    /// The note watch_terminal left for this terminal.
    var note: String?

    /// The same event with a finished reply cut to `limit` characters.
    func trimmed(to limit: Int) -> SumiEvent {
        guard case .finished(let reply) = kind, reply.count > limit else { return self }
        var copy = self
        copy.kind = .finished(FinalReply.excerpt(reply, limit: limit) ?? reply)
        return copy
    }

    var line: String {
        var line = "@\(label) "
        switch kind {
        case .needsYou(let reason, let note):
            return line + "is waiting: " + reason + (note.map { " (handle per: \($0))" } ?? "")
        case .stillWaiting(let reason, let seconds):
            return line + "is STILL waiting after \(seconds) s: " + reason
                + ". Push the user a notification now naming @\(label) and what it needs, then act on their answer."
        case .stoppedHandling(let why):
            return "stopped handling @\(label): " + why
        case .phoneMode(true):
            return "Phone Mode is on: the user is away and runs everything through you from their phone. Start with "
                + "list_terminals and give them a short roll call: one line per agent, @name, what it's doing. From now "
                + "on Tako tells you the moment any agent waits, finishes, fails or exits. Tako approves ordinary "
                + "permission requests itself; everything else comes to you. Relay each wait to the user at once, naming "
                + "the agent, and act on their answer with your tools (answer_prompt, choose_option, trust_folder, sign_in, "
                + "interrupt_agent, send_message). Approve a risky request only after they say yes to it."
        case .phoneMode(false):
            return "Phone Mode is off: the user is back at the Mac, and agents' waits go to them again."
        case .plan(let news):
            return "plan: " + news
        case .serverCrashed(let code, let tail):
            line += "(server) crashed with exit \(code)" + (tail.isEmpty ? "" : ": " + tail)
                + ". Tell its agent or restart_server it if the cause is clear"
        case .waitingLong(let reason, let minutes):
            line += "has waited \(minutes) min on the user: " + reason
                + ". They were notified; remind them, or unblock what depends on it"
        case .autoApproved(let key):
            line += "asked for \(key): approved, as the user always does in this project"
        case .finished(let summary): line += "finished: " + summary
        case .failed(let reason): line += "failed: " + reason
        case .exited: line += "exited"
        case .steward(let warning): line += "steward warning: " + warning
        }
        if let note { line += " (your note: \(note))" }
        return line
    }
}

/// Events gathered for a few seconds, and while Sumi is mid-turn, so it wakes once for
/// all of them. The message stays on one line: a typed newline would submit it early.
struct SumiDigest {
    static let window: TimeInterval = 1
    /// An agent waiting on the user: barely gathered at all.
    static let urgentWindow: TimeInterval = 0.3
    /// How soon a digest Sumi couldn't take yet is tried again.
    static let retryInterval: TimeInterval = 1

    private(set) var events: [SumiEvent] = []
    /// Most events one digest carries: it is typed into Sumi as one message, and gathers for as
    /// long as Sumi is busy.
    static let cap = 50
    private var dropped = 0
    private var since: Date?
    private var urgent = false
    /// Sumi is starting a fresh conversation; the digest waits for it.
    var clearing = false

    var isEmpty: Bool { events.isEmpty }

    mutating func add(_ event: SumiEvent, urgent: Bool = false, at now: Date = Date()) {
        if events.isEmpty { since = now }
        if urgent { self.urgent = true }
        // The same news about the same agent twice says nothing new: keep the latest.
        events.removeAll { $0.label == event.label && $0.line == event.line }
        events.append(event)
        if events.count > Self.cap {
            dropped += events.count - Self.cap
            events.removeFirst(events.count - Self.cap)
        }
    }

    func isDue(at now: Date) -> Bool {
        guard let since else { return false }
        return now.timeIntervalSince(since) >= (urgent ? Self.urgentWindow : Self.window)
    }

    /// The message for everything gathered so far; the digest starts over empty.
    mutating func take(cleared: Bool = false) -> String? {
        guard !events.isEmpty else { return nil }
        defer { events = []; since = nil; urgent = false; dropped = 0 }
        let older = dropped > 0 ? " (\(dropped) older updates left out; list_terminals for the current state)" : ""
        return Self.message(events, cleared: cleared) + older
    }

    static func message(_ events: [SumiEvent], cleared: Bool = false) -> String {
        var text = "Tako: "
        if cleared { text += "Context was cleared: call standup, plan and recall to pick up; open threads are in \(ControlPaths.sumiNotes). " }
        if events.count == 1 {
            text += events[0].line
        } else {
            // Many finishes in one digest share a budget, so the typed message stays bounded.
            let share = FinalReply.share(of: events.filter { if case .finished = $0.kind { return true } else { return false } }.count)
            text += "\(events.count) updates: " + events.enumerated().map { "[\($0 + 1)] \($1.trimmed(to: share).line)" }.joined(separator: " ")
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
