import AppKit

/// Maps control requests to store operations and enforces who may do what.
///
/// The caller comes from the kernel (`CallerIdentity`), never from the request. Fail closed:
/// - The user is a process outside Tako, or one traced to a shell/server terminal.
/// - Agents (traced to an agent terminal) may message other agents, read agents and servers,
///   restart servers, start servers with the user's OK, and rename only themselves. Waiting on,
///   diffing and reading the logs of a terminal follow read's rules; team-board posts and claims
///   act as the calling agent (ControlHandler+AgentTools).
/// - Anything else from inside Tako (detached, unknown) gets read-only access.
/// Only the user may press keys, answer prompts, close terminals, or type raw text: those would
/// let one agent answer another's permission prompts or run commands outside its own checks.
/// Sumi (the agent behind the sidebar's box) also starts agents in any folder, arranges
/// the view, and closes terminals once the user confirms. It answers permission prompts only
/// for sessions the user handed it, never "always", and never past the risky-request guard.
@MainActor
struct ControlHandler {
    /// Most browsers one agent keeps open, its main one included.
    static let agentTabCap = 4

    let store: SessionStore
    let caller: CallerIdentity

    var callerSession: TerminalSession? {
        guard case .session(let id) = caller else { return nil }
        return store.session(forEnvironmentID: id)
    }

    var callerAgent: TerminalSession? {
        guard let session = callerSession, session.kind.isAgent else { return nil }
        return session
    }

    var callerSumi: TerminalSession? {
        guard let agent = callerAgent, agent.isSumi else { return nil }
        return agent
    }

    var isUser: Bool {
        switch caller {
        case .external: return true
        case .session: return callerSession.map { !$0.kind.isAgent } ?? false
        case .detachedInside, .unknown: return false
        }
    }

    /// An agent's browser tools ask this before acting: Chromium is started, the caller's own
    /// browser exists (created on first use), and every page is tagged with its session label so
    /// the tools can tell browsers apart. Replies with the caller's browser label.
    private func handleBrowser(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard callerSession != nil || isUser else { reply(.failure("not allowed from here")); return }
        guard AgentBrowser.shared.start() else {
            reply(.failure("browser unavailable: \(AgentBrowser.shared.startError ?? "Chromium didn't start")"))
            return
        }
        if let agent = callerAgent, request.text == "new_tab" || request.text == "close_tab" {
            handleBrowserTab(request, agent: agent, reply: reply)
            return
        }
        let target: TerminalSession
        if let agent = callerAgent {
            target = store.browser(for: agent)
        } else if let selected = store.selected, selected.kind == .browser {
            target = selected
        } else {
            target = store.looseBrowsers.first ?? store.openBrowser()
        }
        var page: URL?
        if let raw = request.url {
            guard let url = resolveAddress(raw), BrowserTarget.isAllowed(url) else {
                reply(.failure("can't open \(raw): give an http(s) address or a path to a local file"))
                return
            }
            page = url
            store.select(target)
        }
        if let tool = request.text, tool != "mark", let agent = callerAgent {
            AgentBrowser.shared.noteActivity(agent: agent.label, browser: target.label, tool: tool)
        }
        store.wakeBrowser(target)
        // The tab the agent's tools act on counts as in use too, so it isn't put to sleep under it.
        if let agent = callerAgent, let tab = request.target?.trimmingCharacters(in: CharacterSet(charactersIn: "@")),
           let owned = store.browsers(ownedBy: agent).first(where: { $0.label == tab }) {
            store.wakeBrowser(owned)
        }
        let store = self.store
        // Already up, with nothing to load: each page re-tags itself on every load, so there is
        // nothing to wait for. This is most calls.
        if page == nil, request.text != "mark", store.isBrowserReady(target) {
            var response = ControlResponse.success(text: target.label)
            response.endpoint = AgentBrowser.endpoint
            reply(response)
            return
        }
        AgentBrowser.waitUntilReady({ store.isBrowserReady(target) }) { ready in
            guard ready else { reply(.failure("browser unavailable: Chromium didn't come up")); return }
            if let page, let surface = target.surface as? BrowserSurfaceView { surface.model.load(page) }
            if request.text == "mark" { store.markBrowsers() } else { (target.surface as? BrowserSurfaceView)?.mark() }
            // Tags land asynchronously in each page's renderer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                var response = ControlResponse.success(text: target.label)
                response.endpoint = AgentBrowser.endpoint
                reply(response)
            }
        }
    }

    /// An agent's extra tabs are more browsers it owns (they show under it in the sidebar and tile
    /// like any browser). `new_tab` opens one on `request.command`; `close_tab` closes one of the
    /// agent's own, never its first browser or anyone else's.
    private func handleBrowserTab(_ request: ControlRequest, agent: TerminalSession, reply: @escaping ControlServer.Reply) {
        let primary = store.browser(for: agent)
        if request.text == "close_tab" {
            let owned = store.browsers(ownedBy: agent)
            guard let tab = owned.first(where: { $0.label == request.target?.trimmingCharacters(in: CharacterSet(charactersIn: "@")) }) else {
                reply(.failure("that page isn't a tab you opened"))
                return
            }
            guard tab.id != primary.id else { reply(.failure("@\(tab.label) is your main browser; it stays open")); return }
            store.close(tab)
            reply(.success(text: "closed @\(tab.label)"))
            return
        }
        var spec = LaunchSpec(label: "", kind: .browser, cwd: agent.spec.cwd)
        spec.owner = agent.id
        // The same allow-list as `browser`: no javascript:, data: or custom schemes.
        if let raw = request.command, !raw.isEmpty {
            // A local file (relative to the agent's folder), about:blank, or a web address.
            let address = BrowserTarget.fileURL(raw, cwd: agent.spec.workPath)
                ?? (raw.lowercased().hasPrefix("about:") ? URL(string: raw) : nil)
                ?? resolveAddress(raw)
            guard let url = address, BrowserTarget.isAllowed(url) else {
                reply(.failure("can't open \(raw): give an http(s) address or a path to a local file"))
                return
            }
            spec.url = url.absoluteString
        }
        // Each tab is a Chromium renderer: past the cap, the oldest extra tab the agent opened goes.
        let extras = store.browsers(ownedBy: agent).filter { $0.id != primary.id }
        if extras.count >= Self.agentTabCap - 1, let oldest = extras.min(by: { $0.createdAt < $1.createdAt }) {
            store.close(oldest)
            agent.record(.note, "Closed browser @\(oldest.label) (tab limit \(Self.agentTabCap))")
        }
        let tab = store.create(spec, select: false)
        agent.record(.note, "Opened browser @\(tab.label)")
        store.wakeBrowser(tab)
        let store = self.store
        AgentBrowser.waitUntilReady({ store.isBrowserReady(tab) }) { ready in
            guard ready else { reply(.failure("browser unavailable: Chromium didn't come up")); return }
            (tab.surface as? BrowserSurfaceView)?.mark()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                var response = ControlResponse.success(text: tab.label)
                response.endpoint = AgentBrowser.endpoint
                reply(response)
            }
        }
    }

    func handle(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        switch request.cmd {
        case .permission:
            handlePermission(request, reply: reply)
        case .browser:
            handleBrowser(request, reply: reply)
        case .subscribe:
            guard let agent = callerAgent, agent.kind == .claude else { reply(.success()); return }
            store.subscribeChannel(agent, reply: reply)
        case .new where callerSumi != nil && (request.kind == SessionKind.claude.rawValue || request.kind == SessionKind.codex.rawValue):
            startAgentForSumi(request, reply: reply)
        case .close where callerSumi != nil:
            closeForSumi(request, reply: reply)
        case .new where callerAgent != nil && request.kind == SessionKind.server.rawValue:
            startServerForAgent(request, reply: reply)
        case .new where callerAgent != nil && (request.kind == SessionKind.claude.rawValue || request.kind == SessionKind.codex.rawValue):
            startAgentForAgent(request, reply: reply)
        case .new:
            create(request, reply: reply)
        case .act:
            actForSumi(request, reply: reply)
        case .sumi:
            guard callerSumi != nil else { reply(.failure("only Sumi keeps the board and its memory")); return }
            handleSumi(request, reply: reply)
        case .history where request.text == "list" && request.pattern?.isEmpty == false:
            guard callerSumi != nil else { reply(.failure("only Sumi reopens past sessions")); return }
            searchHistory(request, reply: reply)
        case .orphans:
            orphans(request, reply: reply)
        case .wait:
            waitFor(request, reply: reply)
        case .changes:
            changes(request, reply: reply)
        default:
            reply(handle(request))
        }
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        switch request.cmd {
        case .list:
            var response = ControlResponse.success()
            response.sessions = store.orderedSessions.map(listedInfo)
            return response
        case .hook:
            // Hook events only count when the kernel traces them to the session they describe.
            guard let session = callerSession else { return .success() }
            store.handleHook(source: request.source ?? "", session: session, payload: request.payload ?? "{}", sentAt: request.sentAt)
            return .success()
        case .statusline:
            guard let session = callerSession else { return .success() }
            store.handleStatusLine(session: session, payload: request.payload ?? "{}")
            return .success()
        case .key:
            guard isUser else { return .failure("only the user can press keys in terminals") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            let unknown = (request.keys ?? []).filter { !target.surface.pressKey(named: $0) }
            return unknown.isEmpty ? .success() : .failure("unknown key names: \(unknown.joined(separator: ", "))")
        case .layout:
            guard isUser else { return .failure("only the user can change the layout") }
            guard let mode = LayoutMode(rawValue: request.text ?? "") else { return .failure("layout must be focus, split, or grid") }
            store.setLayout(mode)
            return .success()
        case .new:
            // Answered by `create(_:reply:)` in the asynchronous dispatch above.
            return .failure("new is handled asynchronously")
        case .status:
            let target = callerAgent ?? (isUser ? resolve(request.target) : nil)
            guard let me = target else { return .failure("set_status works from inside an agent terminal") }
            let text = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            me.agentStatus = text.isEmpty ? nil : String(text.prefix(140))
            return .success(text: "status set on @\(me.label)")
        case .approve where callerSumi != nil:
            return answerForSumi(request)
        case .approve:
            guard isUser else { return .failure("only the user can answer prompts") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            guard let answer = PromptAnswer(rawValue: request.text ?? "") else {
                return .failure("answer must be approve, always, or deny")
            }
            switch store.answer(target, answer, reason: request.label) {
            case .success(let text): return .success(text: "\(text) @\(target.label)")
            case .failure(let error): return .failure(error.description)
            }
        case .send:
            return send(request)
        case .read:
            return read(request)
        case .focus:
            guard isUser else { return .failure("only the user can change focus") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            store.select(target)
            NSApp.activate(ignoringOtherApps: true)
            return .success()
        case .close:
            guard isUser else { return .failure("only the user can close terminals") }
            guard let target = resolve(request.target) else { return notFound(request.target) }
            store.close(target)
            return .success()
        case .restart:
            return restart(request)
        case .arrange:
            guard callerSumi != nil else { return .failure("only Sumi arranges the view") }
            return arrange(request)
        case .layouts:
            guard callerSumi != nil else { return .failure("only Sumi keeps layouts") }
            return layouts(request)
        case .watch:
            guard callerSumi != nil else { return .failure("only Sumi watches terminals") }
            return watch(request)
        case .history:
            guard callerSumi != nil else { return .failure("only Sumi reopens past sessions") }
            return history(request)
        case .machine:
            guard callerSumi != nil else { return .failure("only Sumi reads the steward") }
            return machine(request)
        case .detach:
            guard callerSumi != nil || isUser else { return .failure("only Sumi moves tiles into windows") }
            return detach(request)
        case .delegate:
            // Only Sumi takes sessions over (when the user asks it to); the user may also stop or list.
            guard callerSumi != nil || (isUser && request.text != "handle") else {
                return .failure("only Sumi handles waiting sessions, when the user asks")
            }
            return delegate(request)
        case .phoneMode:
            guard callerSumi != nil || isUser else { return .failure("only the user or Sumi turns Phone Mode on or off") }
            return phoneMode(request)
        case .rename:
            return rename(request)
        case .notify where callerAgent != nil:
            return notifyUser(request)
        case .board:
            return board(request)
        case .logs:
            return logs(request)
        case .notify:
            guard let target = callerSession ?? (isUser ? resolve(request.target) : nil) else { return notFound(request.target) }
            store.sessionWantsAttention(target, title: "@\(target.label)", body: sanitizeMessage(request.text ?? ""))
            return .success()
        case .permission, .subscribe, .browser, .heavy, .act, .sumi, .wait, .changes, .orphans:
            return .success()
        }
    }

    func resolve(_ target: String?) -> TerminalSession? {
        guard let target, !target.isEmpty else { return nil }
        return store.find(target)
    }

    func notFound(_ target: String?) -> ControlResponse {
        let known = store.sessions.map { "@" + $0.label }.joined(separator: ", ")
        let listed = "Known: \(known.isEmpty ? "none" : known)"
        guard let target, !target.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure("say which terminal: pass terminal, e.g. \"@api\". \(listed)")
        }
        return .failure("no terminal named \(target). \(listed)")
    }

    // MARK: - Commands

    /// `ht new`. A worktree is made off the main thread (`git worktree add` can take seconds), so
    /// the window stays responsive; everything else starts at once as before.
    private func create(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let kind = SessionKind(rawValue: request.kind ?? "shell") else {
            return reply(.failure("kind must be one of: claude, codex, shell, server"))
        }
        if !isUser {
            guard callerAgent != nil else { return reply(.failure("not allowed from a detached process")) }
            if kind == .shell { return reply(.failure("agents can't open shells; ask the user")) }
            // Raw flags would let an agent start a sibling with weaker permissions.
            if request.command?.isEmpty == false { return reply(.failure("agents can't pass extra arguments to new agents")) }
        }
        let cwd = request.cwd ?? callerSession?.spec.cwd ?? NSHomeDirectory()
        var spec = LaunchSpec(label: request.label ?? "", kind: kind, cwd: cwd, command: request.command)
        if callerAgent != nil && spec.labelSource == .user { spec.labelSource = .agent }
        if let account = request.account {
            guard AccountStore.shared.account(account, kind: kind) != nil else {
                return reply(.failure("no \(kind.displayName) account named \(account); add it in Accounts"))
            }
            if account != AgentAccount.defaultID { spec.account = account }
        } else if let parent = callerAgent, parent.kind == kind {
            // An agent's helpers bill the same subscription it does.
            spec.account = parent.spec.account
        }
        func respond(_ session: TerminalSession) {
            var response = ControlResponse.success(text: "@\(session.label)")
            response.session = session.info()
            reply(response)
        }
        if request.worktree == true, kind.isAgent {
            let (store, select) = (self.store, isUser)
            Task { @MainActor in
                respond(await store.launch(spec, select: select, worktree: true, task: request.text))
            }
            return
        }
        respond(store.create(spec, select: isUser, worktree: request.worktree ?? false, task: request.text))
    }

    /// A command an agent wants run as a server runs outside its own permission checks, so the
    /// user confirms it in the app first.
    private func startServerForAgent(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let agent = callerAgent, let command = request.command, !command.isEmpty else {
            reply(.failure("a server needs a command"))
            return
        }
        // An agent CLI run as a server gets none of Tako's hooks: no state, no messages, no sleep.
        let program = (command.split(separator: " ").first.map(String.init) ?? "") as NSString
        if SessionKind.agentAdapters.contains(where: { $0.command == program.lastPathComponent }) {
            reply(.failure("that's an agent, not a server: resume a conversation with reopen_session (conversation, folder), or start one with start_agent"))
            return
        }
        let label = normalizeLabel(request.label ?? "")
        let cwd = request.cwd ?? agent.spec.cwd
        store.confirmUnlessPhoneMode(
            "@\(agent.label) wants to start a server",
            "\(label.isEmpty ? "" : "@\(label) · ")\(abbreviateHome(cwd))\n\n\(command)"
        ) { approved in
            guard approved else {
                reply(.failure("the user declined to start that server"))
                return
            }
            var spec = LaunchSpec(label: label, kind: .server, cwd: cwd, command: command)
            if spec.labelSource == .user { spec.labelSource = .agent }
            let session = store.create(spec, select: false)
            var response = ControlResponse.success(text: "started @\(session.label)")
            response.session = session.info()
            reply(response)
        }
    }

    /// An agent delegating a subtask. Each new agent costs usage and works outside its parent's
    /// view, so the user confirms it. The child inherits the parent's account and permission
    /// choices (never more), gets its own worktree by default, and is asked to report back.
    private func startAgentForAgent(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let parent = callerAgent, let kind = SessionKind(rawValue: request.kind ?? ""), kind.isAgent else {
            reply(.failure("kind must be claude or codex"))
            return
        }
        if request.command?.isEmpty == false {
            reply(.failure("agents can't pass extra arguments to new agents"))
            return
        }
        let task = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            reply(.failure("a new agent needs a task"))
            return
        }
        let cwd = request.cwd ?? parent.spec.workPath
        let worktree = request.worktree ?? true
        store.confirmUnlessPhoneMode(
            "@\(parent.label) wants to start a \(kind.displayName) agent",
            "\(abbreviateHome(cwd))\(worktree ? " · own worktree" : "")\n\n\(task)"
        ) { [store] approved in
            guard approved else {
                reply(.failure("the user declined to start that agent"))
                return
            }
            var spec = LaunchSpec(label: request.label ?? "", kind: kind, cwd: cwd)
            if spec.labelSource == .user { spec.labelSource = .agent }
            if parent.kind == kind {
                spec.account = parent.spec.account
                spec.options = parent.spec.options
            }
            let brief = task + "\n\n(Delegated by @\(parent.label) through Tako. When you finish, use send_message to tell @\(parent.label) what you did and where.)"
            Task { @MainActor [spec] in
                let child = await store.launch(spec, select: false, worktree: worktree, task: brief)
                child.record(.note, "Started by @\(parent.label)")
                parent.record(.note, "Delegated to @\(child.label)")
                var response = ControlResponse.success(text: "started @\(child.label); it will message you when done")
                response.session = child.info()
                reply(response)
            }
        }
    }

    // MARK: - Sumi

    /// The user asked Sumi for these agents, so they start without a second prompt, in
    /// whatever folder it names, isolated in a worktree where the folder is a repo.
    private func startAgentForSumi(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let kind = SessionKind(rawValue: request.kind ?? ""), kind.isAgent else {
            reply(.failure("kind must be claude or codex"))
            return
        }
        if request.command?.isEmpty == false {
            reply(.failure("agents can't pass extra arguments to new agents"))
            return
        }
        let task = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else {
            reply(.failure("a new agent needs a task"))
            return
        }
        guard let folder = request.cwd, !folder.isEmpty else {
            reply(.failure("say which project folder the agent works in"))
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expandTilde(folder), isDirectory: &isDirectory), isDirectory.boolValue else {
            reply(.failure("no folder at \(folder)"))
            return
        }
        let count = request.count ?? 1
        guard (1...sumiStartCap).contains(count) else {
            reply(.failure("count must be 1–\(sumiStartCap)"))
            return
        }
        let path = expandTilde(folder)
        let launch = { [self] (autoTrust: Bool) in
            launchForSumi(request, kind: kind, task: task, folder: path, count: count, autoTrust: autoTrust, reply: reply)
        }
        // A folder the CLI doesn't trust stops every agent at its trust prompt before any hook
        // runs: ask the user once for the folder, however many start calls name it, then let
        // Tako answer each agent's prompt.
        let trusted = FolderTrust.isTrusted(path, kind: kind, account: AccountStore.shared.preferredID(for: kind)) ?? true
        if trusted { return launch(false) }
        if store.startupGate.isApproved(path) { return launch(true) }
        let place = abbreviateHome(path)
        if request.userApproved == true {
            if let refusal = store.userRequestRefusal(true) { return reply(.failure(refusal.description)) }
            store.startupGate.approve(path)
            return launch(true)
        }
        if store.isPhoneModeOn {
            return reply(.failure("\(kind.displayName) hasn't been told to trust \(place) yet, so the agent would stop at its "
                + "trust prompt. Ask the user whether to trust it; if they say yes, call start_agent again with user_approved true"))
        }
        let store = self.store
        store.startupGate.whenAnswered(path, ask: { done in
            store.confirm("Trust \(place) for Sumi's agents?",
                          "Sumi is starting \(kind.displayName) agents in \(place), a folder \(kind.displayName) hasn't been told to trust. "
                          + "Trusting lets them read, edit and run files there; Tako answers each agent's trust prompt for you.",
                          completion: done)
        }) { approved in
            approved ? launch(true) : reply(.failure("the user didn't trust \(place), so nothing was started"))
        }
    }

    /// Starts the agents, then waits (bounded, `request.wait` seconds) until each reaches its
    /// prompt, stops on a screen, or exits, so Sumi hears "exited" now instead of finding the
    /// terminal gone later.
    private func launchForSumi(_ request: ControlRequest, kind: SessionKind, task: String, folder: String, count: Int,
                               autoTrust: Bool, reply: @escaping ControlServer.Reply) {
        let base = normalizeLabel(request.label ?? "")
        let isolate = request.worktree ?? true
        let store = self.store
        let waitSeconds = min(max(request.wait ?? SessionStore.startWaitDefault, 0), SessionStore.startWaitMax)
        // One queued launch per agent: each takes its own steward reservation, so the cap holds
        // for a batch. When anything is held back Sumi hears so right away.
        let batch = LaunchBatch()
        for index in 1...count {
            Steward.shared.enqueueLaunch { Task { @MainActor in
                var spec = LaunchSpec(label: base.isEmpty || count == 1 ? base : "\(base)-\(index)",
                                      kind: kind, cwd: folder)
                if spec.labelSource == .user { spec.labelSource = .agent }
                spec.options = AppSettings.defaultMode.map { AgentOptions(mode: $0) }
                let child = await store.launch(spec, select: false, isolateIfPossible: isolate, task: task)
                if autoTrust { store.startupGate.trustOnStart(child.id) }
                child.record(.note, "Started by Sumi")
                batch.started[index] = child
                // The user asked for them, so each shows as soon as it's up: one is selected, several
                // starting together land side by side like a project window opened for them.
                store.showOpenedBySumi([child])
                guard batch.started.count == count, !batch.replied else { return }
                batch.replied = true
                let ordered = batch.started.sorted { $0.key < $1.key }.map(\.value)
                let labels = ordered.map { "@" + $0.label }.joined(separator: ", ")
                let head = "started \(labels) in \(abbreviateHome(folder))"
                let brief = store.projectBrief(for: folder)
                @MainActor func send(_ text: String, ok: Bool) {
                    var response = ok ? ControlResponse.success(text: text) : ControlResponse.failure(text)
                    response.session = ordered.first?.info()
                    reply(response)
                }
                guard waitSeconds > 0 else { return send(head + brief, ok: true) }
                store.awaitStartup(ordered, timeout: TimeInterval(waitSeconds)) { lines in
                    let allExited = lines.allSatisfy { $0.contains(": exited: ") }
                    send(head + "\n" + lines.joined(separator: "\n") + brief, ok: !allExited)
                }
            } }
        }
        // The launch tasks run after this returns, so `replied` is set before any can read it.
        if Steward.shared.queuedLaunches > 0 {
            batch.replied = true
            let why = Steward.shared.launchBlocker() ?? "memory is short"
            reply(.success(text: "queued: \(why), so the steward starts \(count == 1 ? "it" : "them") when there's room"))
        }
    }

    /// The agents of one sumi start request; the reply waits for the last to be up.
    @MainActor private final class LaunchBatch {
        var started: [Int: TerminalSession] = [:]
        var replied = false
    }

    /// Closed agents: list them, or reopen some and show them, resuming each conversation.
    private func history(_ request: ControlRequest) -> ControlResponse {
        switch request.text {
        case "list":
            let closed = store.closedSessions(in: request.cwd)
            guard !closed.isEmpty else {
                let place = request.cwd.map { " in " + abbreviateHome(expandTilde($0)) } ?? ""
                return .success(text: "No recently closed sessions\(place).")
            }
            let shown = Array(closed.prefix(max(request.lines ?? 15, 1)))
            return .success(text: "Recently closed, newest first:\n" + SessionStore.describeHistory(shown))
        case "reopen":
            let names = request.targets ?? request.target.map { [$0] } ?? []
            guard !names.isEmpty else { return .failure("say which session to reopen") }
            // An unknown name reopens nothing, so a retry doesn't open the rest twice.
            var specs: [LaunchSpec] = []
            for name in names {
                guard let spec = store.closedSession(named: name) else {
                    let known = store.closedSessions().map { "@" + $0.label }.joined(separator: ", ")
                    return .failure("no closed session named \(name). Closed: \(known.isEmpty ? "none" : known)")
                }
                if !specs.contains(where: { $0.id == spec.id }) { specs.append(spec) }
            }
            var reopened: [TerminalSession] = []
            var lines: [String] = []
            for spec in specs {
                let (opened, note) = store.reopenExplained(spec)
                guard let session = opened else {
                    lines.append(store.lastError ?? "@\(spec.label) couldn't be reopened")
                    continue
                }
                reopened.append(session)
                let renamed = session.label == spec.label ? "" : " (was @\(spec.label))"
                lines.append("@\(session.label)\(renamed) " + (session.spec.agentSessionId == nil ? "started fresh" : "resumed its conversation")
                             + (note.map { ". " + $0 } ?? ""))
            }
            store.showOpenedBySumi(reopened)
            let text = lines.joined(separator: "\n")
            guard !reopened.isEmpty else { return .failure(text) }
            var response = ControlResponse.success(text: text)
            response.session = reopened.first?.info()
            return response
        case "resume":
            return resumeConversation(request)
        default:
            return .failure("history takes list, reopen or resume")
        }
    }

    /// A Claude or Codex conversation Tako never ran (say from the CLI on its own), resumed as
    /// a proper agent: hooks, state, sleep and messages all work, unlike a bare process.
    private func resumeConversation(_ request: ControlRequest) -> ControlResponse {
        guard let kind = SessionKind(rawValue: request.kind ?? "claude"), kind.isAgent else {
            return .failure("kind must be claude or codex")
        }
        guard let id = request.target, isSafeIdentifier(id) else { return .failure("give the conversation id") }
        if let open = store.sessions.first(where: { $0.spec.agentSessionId == id }) {
            store.select(open)
            return .success(text: "@\(open.label) already has that conversation open; it's on screen")
        }
        guard let folder = request.cwd.map(expandTilde), !folder.isEmpty else {
            return .failure("say which folder the conversation ran in")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("no folder at \(folder)")
        }
        var spec = LaunchSpec(label: normalizeLabel(request.label ?? ""), kind: kind, cwd: folder)
        if spec.labelSource == .user { spec.labelSource = .agent }
        spec.agentSessionId = id
        spec.options = AppSettings.defaultMode.map { AgentOptions(mode: $0) }
        let session = store.create(spec, resume: true, select: false)
        session.record(.note, "Resumed by Sumi")
        store.showOpenedBySumi([session])
        var response = ControlResponse.success(text: "resumed @\(session.label) in \(abbreviateHome(folder))")
        response.session = session.info()
        return response
    }

    /// Pops terminals out of the canvas into their own windows, or puts them back.
    private func detach(_ request: ControlRequest) -> ControlResponse {
        let back = request.text == "back"
        let names = request.targets ?? request.target.map { [$0] } ?? []
        guard !names.isEmpty else { return .failure("say which terminals") }
        var moved: [String] = []
        for name in names {
            guard let session = resolve(name) else { return notFound(name) }
            guard !session.isSumi else { return .failure("Sumi has its own panel") }
            if back {
                guard session.isDetached else { continue }
                store.onReattach?(session)
            } else {
                guard !session.isDetached else { continue }
                store.wake(session)
                store.onDetach?(session)
            }
            moved.append("@" + session.label)
        }
        guard !moved.isEmpty else { return .success(text: back ? "already in the canvas" : "already in their own windows") }
        return .success(text: (back ? "put back in the canvas: " : "in their own windows: ") + moved.joined(separator: ", "))
    }

    /// The steward's view of the machine, or a change to its policy.
    private func machine(_ request: ControlRequest) -> ControlResponse {
        let steward = Steward.shared
        if request.text == "policy" {
            var policy = steward.policy
            if let cap = request.count { policy.maxActiveAgents = cap > 0 ? cap : nil }
            if let pinned = request.targets { policy.pinned = Set(pinned.map(normalizeLabel).filter { !$0.isEmpty }) }
            steward.policy = policy
            let cap = policy.maxActiveAgents.map { "at most \($0) agents at once" } ?? "no agent cap"
            let pinned = policy.pinned.isEmpty ? "nothing pinned" : "pinned " + policy.pinned.sorted().map { "@" + $0 }.joined(separator: ", ")
            return .success(text: "Policy: \(cap), \(pinned).")
        }
        return .success(text: Self.describe(steward.status()))
    }

    static func describe(_ status: MachineStatus) -> String {
        func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        let power = status.lowPower ? ", Low Power Mode" : ""
        var lines = ["Memory pressure \(status.pressure.rawValue), heat \(status.thermal.rawValue)\(power); \(gb(status.freeBytes)) free of \(gb(status.totalBytes))."]
        let queued = status.queuedLaunches > 0 ? ", \(status.queuedLaunches) queued" : ""
        let waiting = status.heavyWaiting > 0 ? ", \(status.heavyWaiting) waiting" : ""
        lines.append("New agents \(status.admissionOK ? "can start now" : "wait for memory")\(queued). Heavy jobs: \(status.heavySlotsUsed)/\(status.heavySlotsTotal) slots\(waiting).")
        for session in status.sessions.sorted(by: { $0.footprintBytes > $1.footprintBytes }) {
            var line = "@\(session.label) \(session.band.rawValue) · \(gb(session.footprintBytes))"
            if let cpu = session.cpuPercent { line += String(format: " · %.0f%% CPU", cpu) }
            if session.lowered { line += " · lowered" }
            if let warning = session.escalation { line += " · warning: " + warning.message }
            lines.append(line)
        }
        if status.browserProcesses > 0 {
            lines.append("Browsers (Tako's Chromium, all tiles) · \(gb(status.browserBytes)) in \(status.browserProcesses) processes; hidden idle pages close on their own")
        }
        if status.takoBytes > 0 {
            let high = status.takoBytes >= TakoFootprint.warnBytes ? " · high: restart Tako when nothing is mid-task" : ""
            lines.append("Tako itself · \(gb(status.takoBytes))\(high)")
        }
        return lines.joined(separator: "\n")
    }

    /// Named layouts: save the window as it is, put one back, or list them.
    private func layouts(_ request: ControlRequest) -> ControlResponse {
        let name = (request.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch request.text {
        case "save":
            guard !name.isEmpty else { return .failure("give the layout a name") }
            store.saveLayout(name)
            return .success(text: "saved \"\(name)\"")
        case "restore":
            guard store.savedLayouts[name] != nil else {
                let known = store.savedLayouts.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
                return .failure("no layout named \"\(name)\". Saved: \(known.isEmpty ? "none" : known)")
            }
            guard let shown = store.restoreLayout(name) else { return .failure("every terminal in \"\(name)\" has been closed") }
            return .success(text: "restored \"\(name)\"" + (shown.isEmpty ? "" : ": " + shown.map { "@" + $0 }.joined(separator: ", ")))
        default:
            let all = store.savedLayouts
            guard !all.isEmpty else { return .success(text: "No saved layouts.") }
            return .success(text: all.keys.sorted().map { name in
                let saved = all[name]!
                return "\"\(name)\": \(saved.layout.rawValue)" + (saved.focus.map { ", focus @\($0)" } ?? "")
            }.joined(separator: "\n"))
        }
    }

    /// One report per watch: Sumi hears when the terminal ends its next turn.
    private func watch(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        guard target.kind.isAgent, !target.isSumi else { return .failure("only other agents can be watched") }
        let note = sanitizeMessage(request.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        store.sumiWatches[target.id] = String(note.prefix(1000))
        let repeats = request.label == "repeat"
        store.sumiBrain.repeatWatches[target.id] = repeats ? String(note.prefix(1000)) : nil
        return .success(text: "you'll get a message when @\(target.label) finishes " + (repeats ? "each turn, until it closes" : "its turn"))
    }

    /// The user handed a session's waits to Sumi: take them over, stop, or list.
    private func delegate(_ request: ControlRequest) -> ControlResponse {
        if request.text == "list" {
            let handled = store.sessions.compactMap { session in
                session.delegation.map { "@\(session.label): \($0.scopePhrase)" + ($0.note.map { " (note: \($0))" } ?? "") }
            }
            return .success(text: handled.isEmpty ? "No sessions are handed to Sumi." : handled.joined(separator: "\n"))
        }
        guard let target = resolve(request.target) else { return notFound(request.target) }
        switch request.text {
        case "handle":
            guard target.kind.isAgent, !target.isSumi else { return .failure("only other agents' waits can be handed over") }
            let scope: Delegation.Scope
            switch request.label {
            case "turn":
                scope = .turn
            case "count":
                guard let count = request.count, (1...50).contains(count) else { return .failure("count must be 1–50") }
                scope = .count(count)
            case "minutes":
                guard let minutes = request.count, (1...1440).contains(minutes) else { return .failure("minutes must be 1–1440") }
                scope = .until(Date().addingTimeInterval(TimeInterval(minutes * 60)))
            default:
                return .failure("scope must be turn, count, or minutes")
            }
            let note = String(sanitizeMessage(request.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            let waiting = store.delegate(target, scope: scope, note: note.isEmpty ? nil : note)
            var text = "handling @\(target.label)'s waits \(target.delegation?.scopePhrase ?? ""). Tako messages you when it waits; "
                + "the user is notified if you don't answer within \(Int(Delegation.fallback)) s."
            if let waiting { text += " It is waiting now: \(waiting). read_terminal it, then answer." }
            return .success(text: text)
        case "stop":
            guard target.delegation != nil else { return .failure("@\(target.label) isn't handed to Sumi") }
            store.stopDelegating(target, why: isUser ? "the user stopped it" : "Sumi stopped", tellSumi: isUser)
            return .success(text: "stopped handling @\(target.label)")
        default:
            return .failure("delegate takes handle, stop, or list")
        }
    }

    /// Phone Mode: Sumi turns it on when the user, away from the Mac, asks it to.
    private func phoneMode(_ request: ControlRequest) -> ControlResponse {
        switch request.text {
        case "on":
            store.setPhoneMode(true)
            return .success(text: "Phone Mode on: Tako approves agents' ordinary requests; every agent's questions and risky requests come to you.")
        case "off":
            store.setPhoneMode(false)
            return .success(text: "Phone Mode off: agents' waits go to the user again.")
        case "status":
            return .success(text: store.phoneModeSince.map { "Phone Mode on since \($0.formatted(date: .omitted, time: .shortened))" } ?? "Phone Mode off")
        default:
            return .failure("phone mode takes on, off, or status")
        }
    }

    /// answer_prompt: approve or deny a permission request of a session handed to Sumi.
    private func answerForSumi(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        guard let answer = PromptAnswer(rawValue: request.text ?? "") else {
            return .failure("answer must be approve, always, or deny")
        }
        let reason = request.label.map(sanitizeMessage).flatMap { $0.isEmpty ? nil : $0 }
        switch store.answerForSumi(target, answer, reason: reason, userApproved: request.userApproved == true) {
        case .success(let text): return .success(text: text)
        case .failure(let error): return .failure(error.description)
        }
    }

    /// Sumi's hands on an agent: pick a question's option, trust its folder, sign it in, or stop
    /// its turn. Only Sumi, and only where the store allows (Phone Mode, a handed-over session,
    /// or what the user just asked for). Restart, interrupt and choose also take several
    /// terminals or a pattern (`targets`), each answered on its own line.
    private func actForSumi(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard callerSumi != nil else { reply(.failure("only Sumi acts on agents")); return }
        if request.targets?.isEmpty == false { actOnMany(request, reply: reply); return }
        guard let target = resolve(request.target) else { reply(notFound(request.target)); return }
        actForSumi(on: target, request) { result in
            switch result {
            case .success(let text): reply(.success(text: text))
            case .failure(let error): reply(.failure(error.description))
            }
        }
    }

    func actForSumi(on target: TerminalSession, _ request: ControlRequest,
                    completion send: @escaping (Result<String, DelegationError>) -> Void) {
        let userApproved = request.userApproved == true
        let userRequested = request.userRequested == true
        switch request.text {
        case "choose":
            let options = request.options ?? request.count.map { [$0] } ?? []
            store.chooseForSumi(target, options: options, userApproved: userApproved, userRequested: userRequested, completion: send)
        case "trust":
            send(store.trustForSumi(target, userApproved: userApproved))
        case "signin":
            store.signInForSumi(target, completion: send)
        case "interrupt":
            store.interruptForSumi(target, hard: request.hard == true, userRequested: userRequested, completion: send)
        case "keys":
            store.pressKeysForSumi(target, keys: request.keys ?? [], userApproved: userApproved, completion: send)
        case "type":
            store.typeForSumi(target, text: request.label ?? "", submit: request.submit ?? true, userApproved: userApproved, completion: send)
        case "restart":
            send(store.restartForSumi(target, userRequested: userRequested))
        case "mode":
            guard let mode = request.mode.flatMap(PermissionMode.init(rawValue:)) else {
                send(.failure(DelegationError("mode must be one of: " + PermissionMode.allCases.map(\.rawValue).joined(separator: ", "))))
                return
            }
            store.setModeForSumi(target, mode: mode, userApproved: userApproved, completion: send)
        default:
            send(.failure(DelegationError("act must be choose, trust, signin, interrupt, keys, type, restart or mode")))
        }
    }

    /// Closing ends a process and whatever it hadn't saved. The user confirms each close in Tako,
    /// unless they asked Sumi for it directly (`userRequested`). Either way, work that exists
    /// nowhere else keeps the terminal open, unless the user also said to close it anyway (`force`).
    private func closeForSumi(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        if request.targets?.isEmpty == false { closeMany(request, reply: reply); return }
        guard let target = resolve(request.target) else { reply(notFound(request.target)); return }
        closeForSumi(target, request) { result in
            switch result {
            case .success(let text): reply(.success(text: text))
            case .failure(let error): reply(.failure(error.description))
            }
        }
    }

    func closeForSumi(_ target: TerminalSession, _ request: ControlRequest,
                      completion: @escaping (Result<String, DelegationError>) -> Void) {
        guard !target.isSumi else { return completion(.failure(DelegationError("Sumi can't close itself"))) }
        let userRequested = request.userRequested == true
        if let refusal = store.userRequestRefusal(userRequested) { return completion(.failure(refusal)) }
        let force = userRequested && request.force == true
        let spec = target.spec
        let close = { [self] in
            if userRequested { closeNow(target, completion: completion) } else { confirmClose(target, completion: completion) }
        }
        guard spec.isWorktree else { return close() }
        DispatchQueue.global(qos: .userInitiated).async {
            let risk = WorkAtRisk.evaluate(at: spec.workPath, base: spec.baseBranch)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let risk, !risk.isEmpty, !force else { return close() }
                    completion(.failure(DelegationError("@\(target.label) left open: \(risk.headline(base: spec.baseBranch)). "
                        + "Tell the user; if they say to close it anyway, call again with user_requested and force true")))
                }
            }
        }
    }

    private func closeNow(_ target: TerminalSession, completion: @escaping (Result<String, DelegationError>) -> Void) {
        guard store.sessions.contains(where: { $0.id == target.id }) else {
            return completion(.success("@\(target.label) was already closed"))
        }
        target.record(.note, "Closed by Sumi at the user's request")
        store.close(target)
        completion(.success("closed @\(target.label)"))
    }

    private func confirmClose(_ target: TerminalSession, completion: @escaping (Result<String, DelegationError>) -> Void) {
        store.confirmUnlessPhoneMode("Sumi wants to close @\(target.label)", abbreviateHome(target.spec.workPath)) { [store] approved in
            guard approved else { return completion(.failure(DelegationError("the user kept @\(target.label) open"))) }
            // It may have been closed while the sheet was up.
            guard store.sessions.contains(where: { $0.id == target.id }) else {
                return completion(.success("@\(target.label) was already closed"))
            }
            store.close(target)
            completion(.success("closed @\(target.label)"))
        }
    }

    /// Any of: a layout, a terminal to bring to the front, and the grid's exact tiles.
    private func arrange(_ request: ControlRequest) -> ControlResponse {
        var layout: LayoutMode?
        if let text = request.text, !text.isEmpty {
            guard let mode = LayoutMode(rawValue: text) else { return .failure("layout must be focus, split, or grid") }
            layout = mode
        }
        var focus: TerminalSession?
        if let target = request.target, !target.isEmpty {
            guard let session = resolve(target) else { return notFound(target) }
            guard !session.isSumi else { return .failure("Sumi stays in the sidebar; focus another terminal") }
            focus = session
        }
        var tiles: LayoutNode?
        if let spec = request.tiles {
            if let layout, layout != .grid { return .failure("tiles arrange the grid; leave layout out or pass grid") }
            var seen = Set<UUID>()
            switch tileNode(spec, seen: &seen) {
            case .success(let node): tiles = node
            case .failure(let error): return .failure(error.message)
            }
            if let focus, !seen.contains(focus.id) { return .failure("@\(focus.label) isn't one of the tiles") }
            layout = .grid
        }
        guard layout != nil || focus != nil || tiles != nil else { return .failure("pass a layout, a terminal to focus, or tiles") }
        if let focus { store.wake(focus) }
        store.arrange(layout: layout, focus: focus, tiles: tiles)
        return .success(text: "arranged")
    }

    private struct TileError: Error { let message: String }

    /// Labels resolve to sessions; each may appear once, and Sumi never takes a tile.
    private func tileNode(_ spec: TileSpec, seen: inout Set<UUID>) -> Result<LayoutNode, TileError> {
        if let label = spec.terminal {
            guard let session = resolve(label) else { return .failure(TileError(message: notFound(label).error ?? "unknown terminal")) }
            guard !session.isSumi else { return .failure(TileError(message: "Sumi stays in the sidebar; leave it out of the tiles")) }
            guard !session.isDetached else { return .failure(TileError(message: "@\(session.label) is in its own window; detach_terminals back first")) }
            guard seen.insert(session.id).inserted else { return .failure(TileError(message: "@\(session.label) appears twice")) }
            return .success(.leaf(session.id))
        }
        let axis: LayoutAxis
        switch spec.split {
        case "row": axis = .horizontal
        case "column": axis = .vertical
        default: return .failure(TileError(message: "each tile is a terminal label or a split of \"row\" or \"column\""))
        }
        let children = spec.children ?? []
        let sizes = spec.sizes ?? Array(repeating: 1, count: children.count)
        guard sizes.count == children.count, sizes.allSatisfy({ $0 > 0 }) else {
            return .failure(TileError(message: "sizes needs one positive number per child"))
        }
        var pairs: [(weight: Double, node: LayoutNode)] = []
        for (size, child) in zip(sizes, children) {
            switch tileNode(child, seen: &seen) {
            case .success(let node): pairs.append((size, node))
            case .failure(let error): return .failure(error)
            }
        }
        guard let node = LayoutNode.split(axis, pairs) else { return .failure(TileError(message: "a split needs children")) }
        return .success(node)
    }

    private func send(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        let text = sanitizeMessage(request.text ?? "")
        guard !text.isEmpty else { return .failure("message is empty") }
        if let sender = callerAgent {
            if sender.id == target.id { return .failure("that's this terminal") }
            guard target.kind.isAgent else {
                return .failure("@\(target.label) is a \(target.kind.displayName.lowercased()); agents can read it or restart it, not type into it")
            }
            let framed = agentMessagePrefix + "\(sender.label) (\(sender.kind.displayName), via Tako): \(singleLine(text))"
            let result = target.deliver(framed, from: sender.label)
            // Sumi hears the reply to what it sent, without having to ask for a watch.
            if sender.isSumi, !target.isSumi, store.sumiWatches[target.id] == nil {
                store.sumiWatches[target.id] = ""
            }
            // Queued behind a dialog, the message waits on whoever answers it: say so, with the
            // choices, so Sumi answers the dialog instead of assuming the message went through.
            if sender.isSumi, result.lowercased().hasPrefix("queued"), target.dialogOnScreen {
                let menu = PromptScreen.menu(target.surface.readViewport())
                let choices = menu.isEmpty ? "" : " Its choices: " + menu.map { "\($0.number). \($0.text)" }.joined(separator: "; ") + "."
                return .success(text: result + ". @\(target.label) is showing a dialog, so the message waits until it's answered."
                    + choices + " Answer it with choose_option or press_keys, or read_terminal to see it.")
            }
            return .success(text: result)
        }
        guard isUser else { return .failure("not allowed from a detached process") }
        return .success(text: target.deliver(text, submit: request.submit ?? true, from: nil))
    }

    /// Agents can read agents and servers. Shell scrollback can hold secrets, so only the user
    /// reads shells.
    private func read(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        if !isUser && target.kind == .shell && target.id != callerSession?.id {
            return .failure("@\(target.label) is a shell; agents can't read shells")
        }
        let lines = max(1, min(request.lines ?? 60, 2000))
        // Asleep, the terminal holds a bare shell; the agent's last screen is what was asked for.
        if let kept = target.asleepScreen {
            let screen = kept.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            return .success(text: withConversation(of: target, screen: screen, lines: lines))
        }
        return .success(text: withConversation(of: target, screen: target.surface.readText(lastLines: lines), lines: lines))
    }

    /// Fullscreen agents hold one screenful; a read asking for more gets the conversation's
    /// tail from the transcript above the screen.
    private func withConversation(of target: TerminalSession, screen: String, lines: Int) -> String {
        let shown = screen.split(separator: "\n", omittingEmptySubsequences: false).count
        guard lines > shown + 1, target.kind.adapter != nil,
              let id = target.spec.agentSessionId else { return screen }
        let root = (AccountStore.shared.account(target.spec.account, kind: target.kind)
            ?? AgentAccount(id: AgentAccount.defaultID, kind: target.kind, name: "Default")).homeDirectory
        let conversation = AgentTranscript.conversation(
            kind: target.kind, id: id, cwds: [target.spec.workPath, expandTilde(target.spec.cwd)], root: root)
        return AgentTranscript.compose(conversation: conversation, screen: screen, lines: lines)
    }

    /// Agents rename only themselves, never over a name the user chose, and never onto a label
    /// someone else answers to.
    private func rename(_ request: ControlRequest) -> ControlResponse {
        guard let label = request.label, !normalizeLabel(label).isEmpty else {
            return .failure("pass label: the new short kebab-case name, e.g. \"auth-refactor\"")
        }
        if let me = callerAgent {
            if let target = request.target, !target.isEmpty, resolve(target)?.id != me.id {
                return .failure("agents can only rename their own terminal")
            }
            guard me.spec.agentMayRename else { return .failure("the user named this terminal @\(me.label); keep it") }
            if let holder = store.find(label), holder.id != me.id {
                return .failure("@\(normalizeLabel(label)) is taken by another terminal")
            }
            if store.isReserved(normalizeLabel(label)) { return .failure("@\(normalizeLabel(label)) was recently used by another terminal") }
            let old = me.label
            let new = store.rename(me, to: label, source: .agent) ?? old
            return .success(text: new == old ? "already @\(new)" : "renamed @\(old) → @\(new). Other terminals can still reach you at @\(old).")
        }
        guard isUser else { return .failure("not allowed from a detached process") }
        guard let target = resolve(request.target) else { return notFound(request.target) }
        let new = store.rename(target, to: label, source: .user)
        return .success(text: "@\(new ?? target.label)")
    }

    private func restart(_ request: ControlRequest) -> ControlResponse {
        guard let target = resolve(request.target) else { return notFound(request.target) }
        if !isUser {
            guard callerAgent != nil, target.kind == .server else { return .failure("agents can only restart servers") }
        }
        target.restart()
        return .success(text: "restarted @\(target.label)")
    }

    // MARK: - Approvals

    /// PermissionRequest hook: hold the hook open until the user decides in Tako, the agent
    /// moves on (answered in its own terminal), or the hook times out.
    private func handlePermission(_ request: ControlRequest, reply: @escaping ControlServer.Reply) {
        guard let agent = callerAgent else {
            reply(.success())   // no decision: the CLI's own prompt handles it
            return
        }
        store.registerApproval(for: agent, source: request.source ?? "claude", payload: request.payload ?? "{}", reply: reply)
    }

    /// Newlines would submit early in most TUIs; flatten so one message is one prompt.
    private func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ⏎ ")
    }
}

/// Strips control characters (ESC, bracketed-paste markers, C0/C1) and bidi overrides from text
/// that will be typed into a terminal or shown in the UI. Newlines and tabs survive.
func sanitizeMessage(_ text: String) -> String {
    let bidi: ClosedRange<UInt32> = 0x202A...0x202E
    let isolates: ClosedRange<UInt32> = 0x2066...0x2069
    let scalars = text.unicodeScalars.filter { scalar in
        let value = scalar.value
        if value == 0x0A || value == 0x09 { return true }
        if value < 0x20 || (0x7F...0x9F).contains(value) { return false }
        return !bidi.contains(value) && !isolates.contains(value)
    }
    return String(String.UnicodeScalarView(scalars)).prefix(8000).description
}

/// How Tako starts a message it types into an agent on another agent's behalf.
let agentMessagePrefix = "Message from @"

func isAgentMessage(_ prompt: String) -> Bool {
    prompt.hasPrefix(agentMessagePrefix)
}
