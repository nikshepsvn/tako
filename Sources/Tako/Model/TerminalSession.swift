import AppKit
import Combine

/// A running Claude subagent.
struct Helper: Identifiable {
    let id: String
    let type: String
    let startedAt: Date
}

/// One labeled terminal: its launch spec, its live libghostty surface, and what it's doing.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    @Published var spec: LaunchSpec
    @Published private(set) var state: AgentState = .starting
    @Published private(set) var stateSource = "launch"
    @Published private(set) var stateChangedAt = Date()
    @Published var summary: String? {
        didSet {
            guard summary != oldValue else { return }
            spec.summary = summary
            store?.persist()
        }
    }
    /// Not published: agent TUIs animate their title many times a second and no view shows it.
    private(set) var title: String = ""
    @Published var ports: [Int] = []
    @Published var foregroundProcess: String?
    /// Background shells under the agent CLI, from the last process snapshot (see `canSleep`).
    var backgroundShells = 0
    /// Scripts running in a shell or server terminal, from the last process snapshot.
    var nestedShells = 0
    @Published var unread = false
    /// Finished a turn the user hasn't looked at since: its tile is marked until they do.
    @Published var finishedUnseen = false
    /// What the agent is doing this moment ("Bash: pnpm test"), from tool-use hooks.
    @Published var activity: String?
    /// The agent's own one-line status, posted with the set_status tool.
    @Published var agentStatus: String?
    /// The request an agent is blocked on ("Bash: pnpm prisma migrate dev"), when known.
    @Published var pendingRequest: String?
    /// What the agent asked with AskUserQuestion, while it waits for the answer.
    @Published var pendingQuestion: PendingQuestion?
    /// The user handed this session's waits to Sumi (in memory only).
    @Published var delegation: Delegation?
    /// True while a PermissionRequest hook is held open, so approvals go through the CLI's API.
    @Published var hasHookApproval = false
    /// The tool call the held hook asks about, so a parallel tool finishing doesn't release it.
    var heldToolCall: HeldToolCall?
    @Published var git: GitInfo?
    @Published var timeline: [TimelineEvent] = []
    @Published var usage = UsageSnapshot()
    @Published var tasks = TaskProgress()
    /// Claude subagents started and not yet stopped, by agent id. Background ones keep working
    /// after the session's own turn ends, so it isn't done while any remain.
    @Published var runningSubagents: [String: Subagent] = [:]
    @Published var testEvidence: TestEvidence?
    @Published var diffStat: DiffStat?
    /// Worktree agents: what closing would lose (uncommitted files, commits not in the base).
    @Published var atRisk: WorkAtRisk?
    /// The running subagents as sidebar rows, oldest first.
    var helpers: [Helper] {
        runningSubagents.map { Helper(id: $0.key, type: $0.value.type, startedAt: $0.value.startedAt) }
            .sorted { $0.startedAt < $1.startedAt }
    }
    /// Finished a turn with changes that the user hasn't opened in review yet.
    @Published var readyForReview = false
    /// Servers normally sit in the canvas's strip; pinned ones get a grid tile.
    @Published var pinnedToGrid = false
    /// Popped out of the canvas into its own window (in memory only; it rejoins the grid on relaunch).
    @Published var isDetached = false
    /// When the user last looked at this session; the recap covers events after it.
    @Published var lastViewedAt = Date()
    /// Checkpointed turns, oldest first (git workspaces only).
    @Published var turns: [Checkpoints.Turn] = []
    /// The plan an agent in plan mode is waiting to have approved.
    @Published var pendingPlan: String?
    /// Set while a "continue at reset" is scheduled after a rate limit.
    @Published var resumeAt: Date?
    /// Review comments drafted in the Changes tab and not yet sent.
    @Published var reviewComments: [ReviewComment] = []
    /// Files that would conflict with each other live agent's workspace, by session.
    @Published var overlaps: [UUID: [String]] = [:]
    /// The agent CLI quit to free its memory; its screen stays and its conversation resumes on
    /// the next message or keystroke. Status events are ignored meanwhile.
    @Published private(set) var isAsleep = false
    /// Relaunched from sleep and not yet at its prompt; keystrokes wait in `wakeDraft`.
    @Published private(set) var isWaking = false
    /// What the user typed while it slept or woke, put in the agent's prompt once it is ready.
    private var wakeDraft = ""
    /// The screen text when it fell asleep, for readers (the terminal itself now holds a shell).
    private(set) var asleepScreen: String?

    /// Whether the agent CLI process has been seen running in this terminal.
    var agentProcessSeen = false
    private(set) var createdAt = Date()
    /// Hook ordering: events stamped earlier than the newest applied one are stale.
    var lastHookSentAt: UInt64 = 0
    var lastHookAt = Date.distantPast
    /// The current turn was started by another agent's message, not the user.
    var turnIsMessage = false
    /// The agent's whole closing message for its last turn (Stop's last_assistant_message);
    /// `summary` holds only its first line. Cleared when a turn starts.
    var lastReply: String?
    /// The current turn began with the user's own prompt: not another agent's message, not a
    /// Tako event digest, not a channel event. Sumi's `user_requested` counts only in such a turn.
    var turnFromUser = true
    /// Its CLI's prompt and stop hooks report turns (a Codex with hooks on), so turns aren't
    /// guessed from work starting.
    var reportsTurnsByHook = false
    /// This turn was opened before any hook could report it (at launch, or from work starting
    /// before Codex's first hooks), so its prompt hook doesn't open another.
    var turnOpenedByGuess = false

    private(set) var surface: any SessionSurface
    /// Messages for an agent that is blocked on a prompt or mid-turn; delivered when it is free
    /// so typed text can't land in a permission dialog or interrupt the turn. Each carries an id
    /// and its sender, so the sender hears when it lands, or that it never did.
    @Published private(set) var queue: [QueuedMessage] = []
    var pendingMessages: [String] { queue.map(\.text) }
    /// The command to type once the shell shows its first prompt.
    private var pendingInput: String?
    /// The shell reported a prompt (OSC 7) and nothing was typed since, so input lands at it.
    private var shellAtPrompt = false
    private var inputGeneration = 0
    /// A label Claude Code itself should adopt via /rename at its next idle prompt, so its
    /// native SendMessage name matches the Tako label.
    private var pendingNativeRename: String?
    weak var store: SessionStore?

    var label: String { spec.label }
    var kind: SessionKind { spec.kind }
    var isMinimized: Bool { spec.minimized == true }
    var isSumi: Bool { spec.sumi == true }

    init(spec: LaunchSpec, resume: Bool, task: String? = nil) {
        self.id = spec.id
        self.spec = spec
        self.surface = TerminalSessionFactory.makeSurface(spec: spec)
        self.surface.events = self
        self.summary = spec.summary.flatMap { $0.hasPrefix("~") || $0.count < 3 ? nil : $0 }
        if !spec.kind.isAgent { state = .running }
        // A known id makes resume independent of hooks reporting it.
        if spec.kind.adapter?.assignsSessionID == true, spec.agentSessionId == nil, spec.forkOf == nil {
            self.spec.agentSessionId = UUID().uuidString.lowercased()
        }
        if spec.asleep == true, spec.kind.isAgent {
            // Restored asleep: a plain shell until something wakes it.
            isAsleep = true
            state = .idle
        } else {
            scheduleInitialInput(resume: resume, task: task)
        }
        bindBrowser()
    }

    /// A browser's page is its status: the title becomes its summary, the address is persisted
    /// so it reopens there.
    private func bindBrowser() {
        guard let browser = surface as? BrowserSurfaceView else { return }
        browser.onNavigate = { [weak self] url, title in
            guard let self else { return }
            let address = url?.absoluteString == "about:blank" ? nil : url?.absoluteString
            if self.spec.url != address {
                self.spec.url = address
                self.store?.persist()
            }
            let summary = title.isEmpty ? address.map(abbreviateURL) : title
            if self.summary != summary { self.summary = summary }
        }
    }

    /// Keeps a browser's page tag in step with its label.
    func labelChanged() {
        (surface as? BrowserSurfaceView)?.label = label
    }

    /// Typing before the shell is ready makes the tty echo the command above the prompt. Shell
    /// integration reports the first prompt via OSC 7 (pwd); fall back to a timer without it.
    private func scheduleInitialInput(resume: Bool, task: String? = nil) {
        inputGeneration += 1
        let generation = inputGeneration
        pendingInput = AgentIntegration.initialInput(for: spec, resume: resume, task: task)
        guard pendingInput != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.inputGeneration == generation, !self.resumeAwaitsExit else { return }
            self.sendPendingInput()
        }
    }

    private func sendPendingInput() {
        guard let input = pendingInput else { return }
        pendingInput = nil
        shellAtPrompt = false
        surface.sendText(input.trimmingCharacters(in: .newlines))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            self?.surface.sendReturn()
        }
    }

    /// Kills the current process and starts the same spec again. Queued messages survive.
    func restart() {
        store?.dropAllApprovals(for: self)
        // Typed once the relaunched agent is ready, instead of lost with the old channel.
        (store?.dropChannel(for: self) ?? []).forEach { enqueue($0, from: nil) }
        endSleep()
        isWaking = false
        resumeAwaitsExit = false
        wakeDraft = ""
        userDraftInProgress = false
        submitInFlight = false
        flushScheduled = false
        shellAtPrompt = false
        surface.events = nil
        destroySurface()
        surface.removeFromSuperview()
        surface = TerminalSessionFactory.makeSurface(spec: spec)
        surface.events = self
        bindBrowser()
        scheduleInitialInput(resume: true)
        ports = []
        agentProcessSeen = false
        createdAt = Date()
        lastHookSentAt = 0
        apply(.processStarted, source: "restart", force: kind.isAgent ? .starting : .running)
        store?.recordAgentStart(self, restarted: true)
        store?.sessionSurfaceReplaced(self)
    }

    func terminate() {
        inputGeneration += 1
        surface.events = nil
        destroySurface()
        surface.removeFromSuperview()
    }

    // MARK: - Sleep

    /// Quits the agent CLI with its own exit command, holding its last frame on screen. The
    /// store checks it is idle at an empty prompt first.
    func fallAsleep() {
        asleepScreen = surface.readText(lastLines: 2000)
        (surface as? TerminalSurfaceView)?.freezeFrame()
        isAsleep = true
        fellAsleepAt = Date()
        spec.asleep = true
        // The CLI holds the terminal until it quits; the shell's next prompt (OSC 7) says it has.
        shellAtPrompt = false
        sleepExitSeen = false
        record(.note, "Asleep: the agent quit to free memory; its conversation resumes on the next message")
        type(kind.adapter?.exitCommand ?? "/exit", submit: true, countsAsWork: false)
    }

    /// Resumes the conversation in the same shell, which is back at its prompt.
    func wakeUp() {
        // Woken while the CLI is still quitting (a key right after the exit command): the resume
        // waits until it has, so it is never typed into the live CLI.
        let quitting = isAsleep && !sleepExitSeen && !shellAtPrompt
        endSleep()
        isWaking = true
        record(.note, "Woke: resuming the conversation")
        resumeAwaitsExit = quitting
        scheduleInitialInput(resume: true)
        agentProcessSeen = false
        createdAt = Date()
        lastHookSentAt = 0
        apply(.processStarted, source: "wake", force: .starting)
        if shellAtPrompt { sendPendingInput() }
    }

    /// When it was told to quit, to notice a CLI that didn't.
    private(set) var fellAsleepAt: Date?
    /// The CLI quit after its exit command: its shell prompt came back, or the poll found it gone.
    /// True when restored asleep, since no CLI ran then.
    private var sleepExitSeen = true
    /// Woken before the CLI was seen to quit; the resume command is held until it has.
    private(set) var resumeAwaitsExit = false

    /// The poll found no agent CLI process while it slept or was waking.
    func cliExitSeen() {
        if isAsleep { sleepExitSeen = true }
        guard resumeAwaitsExit else { return }
        resumeAwaitsExit = false
        // A moment for the shell to draw its prompt.
        let generation = inputGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, self.inputGeneration == generation else { return }
            self.sendPendingInput()
        }
    }

    /// Woken while quitting, and the CLI never did (it asked something instead): drop the resume,
    /// close what it asked and keep the live CLI, as `abortSleep` does.
    func cliStayedRunning() {
        guard resumeAwaitsExit else { return }
        resumeAwaitsExit = false
        pendingInput = nil
        inputGeneration += 1
        _ = surface.pressKey(named: "esc")
        fellAsleepAt = nil
        record(.note, "Stayed awake: the agent didn't quit when asked")
        agentProcessSeen = true
        apply(.processStarted, source: "process", force: .idle)
    }

    /// The CLI is still running after its exit command (it asked something instead): close
    /// whatever it asked and show the live terminal again, awake.
    func abortSleep() {
        guard isAsleep else { return }
        _ = surface.pressKey(named: "esc")
        endSleep()
        fellAsleepAt = nil
        (surface as? TerminalSurfaceView)?.thawFrame()
        record(.note, "Stayed awake: the agent didn't quit when asked")
        store?.persist()
    }

    private func endSleep() {
        isAsleep = false
        asleepScreen = nil
        spec.asleep = nil
    }

    /// The agent is back at its prompt (or failed to start): the live terminal replaces the held
    /// frame, and what the user typed meanwhile becomes their draft.
    private func finishWaking() {
        isWaking = false
        (surface as? TerminalSurfaceView)?.thawFrame()
        deliverWakeDraft()
    }

    /// Types the draft kept while waking once the agent can take it; held while it asks something
    /// or has failed, and delivered when it next goes idle or works.
    private func deliverWakeDraft() {
        let draft = wakeDraft
        guard !draft.isEmpty, state == .idle || state == .working else { return }
        wakeDraft = ""
        // A draft holds queued messages back, as one the user typed would.
        userDraftInProgress = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.surface.sendText(draft)
        }
    }

    /// Keystrokes while asleep or waking: the first wakes it; printable text is kept as a draft
    /// and Return queues it as a message, so nothing reaches the bare shell.
    private func interceptWhileAsleep(_ event: NSEvent) -> Bool {
        guard isAsleep || isWaking else { return false }
        if isAsleep { store?.wake(self) }
        if !event.modifierFlags.isDisjoint(with: [.command, .control]) { return true }
        let chars = event.characters ?? ""
        switch chars {
        case "\r":
            if !wakeDraft.isEmpty { enqueue(wakeDraft, from: nil) }
            wakeDraft = ""
        case "\u{7f}":
            if !wakeDraft.isEmpty { wakeDraft.removeLast() }
        default:
            // Function and arrow keys arrive as private-use characters.
            if chars.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !(0xF700...0xF8FF).contains($0.value) }) {
                wakeDraft += chars
            }
        }
        return true
    }

    /// Closing the terminal hangs up its shell; this also stops what it started that wouldn't
    /// hang up with it (nohup, setsid, daemons).
    private func destroySurface() {
        if kind != .browser {
            ProcessInspector.shared.takeProcesses(ofSession: id.uuidString) { SessionReaper.stop($0) }
        }
        surface.destroy()
    }

    // MARK: - Status

    func apply(_ event: StatusEvent, source: String, force: AgentState? = nil) {
        // Asleep, the agent's process is gone on purpose; its exit is not news.
        guard !isAsleep else { return }
        let next = force ?? reduceState(state, kind: kind, event: event)
        guard next != state else { return }
        if !next.needsAttention { pendingRequest = nil; pendingQuestion = nil }
        if next == .idle || next == .exited(0) { activity = nil }
        if next != .idle { finishedUnseen = false }
        // A CLI that exited or relaunched took its subagents with it.
        if next == .starting { runningSubagents = [:] }
        if case .exited = next { runningSubagents = [:] }
        let previous = state
        state = next
        stateSource = source
        stateChangedAt = Date()
        if isWaking, next != .starting { finishWaking() } else if !isWaking, !wakeDraft.isEmpty { deliverWakeDraft() }
        // Without a prompt hook a turn starts when work starts from rest. Claude's turns come
        // from its UserPromptSubmit and Stop hooks instead.
        if kind.adapter?.reportsPrompts == false, !reportsTurnsByHook, next == .working, previous == .idle || previous == .starting,
           source != "approval", source != "process" {
            store?.checkpoint(self, phase: .start, prompt: lastPrompt ?? "Turn")
            turnOpenedByGuess = true
        }
        if previous.needsAttention && !next.needsAttention { flushPendingMessages() }
        if next == .idle {
            applyPendingNativeRename()
            if !pendingMessages.isEmpty { flushPendingMessages() }
        }
        store?.sessionStateChanged(self, from: previous)
    }

    /// Resume ids are typed into a shell on restore, so only id-shaped values are accepted.
    func recordAgentSessionId(_ value: String?) {
        guard let value, isSafeIdentifier(value), spec.agentSessionId != value else { return }
        spec.agentSessionId = value
        store?.persist()
    }

    func record(_ kind: TimelineEvent.Kind, _ text: String) {
        timeline.append(TimelineEvent(date: Date(), kind: kind, text: String(text.prefix(300))))
        if timeline.count > 300 { timeline.removeFirst(timeline.count - 300) }
    }

    // MARK: - Screen checks

    /// The agent's input prompt is drawn and nothing is asked over it.
    var showsAgentPrompt: Bool {
        guard let marker = kind.adapter?.promptMarker else { return false }
        let screen = surface.readViewport()
        let prompt = screen.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix(marker) }
        return prompt && PromptScreen.menu(screen).isEmpty && !dialogOnScreen
    }

    /// A selection dialog (permission prompt, question, menu) is on screen.
    var dialogOnScreen: Bool {
        let screen = surface.readViewport()
        // Trust and sign-in screens too: a queued message's Return there would answer them.
        return PromptScreen.hasDialog(screen) || PromptScreen.hasTrustDialog(screen) || PromptScreen.hasSignIn(screen, kind: kind)
            || PromptScreen.autoModeOfferKeys(screen) != nil
    }

    /// Claude Code and Codex ask to trust a new folder, and Codex to sign in, before any hook
    /// fires, so only the screen shows it. Polled; reads the screen only before the first hook
    /// (while starting, or in the first two minutes) and while the prompt is up.
    func checkTrustPrompt() {
        guard kind.isAgent, !isAsleep else { return }
        if kind == .claude, Date().timeIntervalSince(startupScreensSince) < 120, answerStartupScreen() { return }
        let mayShow = lastHookAt == .distantPast && (state == .starting || Date().timeIntervalSince(createdAt) < 120)
        guard showingTrustPrompt || mayShow else { return }
        let screen = surface.readViewport()
        if PromptScreen.hasSignIn(screen, kind: kind) {
            let reason = "Sign in to \(kind.displayName)"
            trustPromptSeen(true, reason: reason)
            // After the state change: `apply` drops the question whenever the wait ends.
            if showingTrustPrompt, state == .needsInput(reason), pendingQuestion == nil {
                pendingQuestion = PendingQuestion.fromScreen(screen, question: reason)
            }
        } else if kind == .claude, !PromptScreen.hasTrustDialog(screen) {
            let stuck = isStuckOnStartupScreen(screen)
            if !stuck, pendingQuestion?.selectsByNumber == true { pendingQuestion = nil }
            trustPromptSeen(stuck, reason: Self.startupScreenReason)
            if stuck, pendingQuestion == nil, !PromptScreen.menu(screen).isEmpty {
                pendingQuestion = PendingQuestion.fromScreen(screen, question: Self.startupScreenReason)
            }
        } else {
            if pendingQuestion?.selectsByNumber == true { pendingQuestion = nil }
            let trust = PromptScreen.hasTrustDialog(screen)
            trustPromptSeen(trust)
            if trust, showingTrustPrompt { store?.trustPromptShown(self) }
        }
    }

    /// Claude reports SessionStart as soon as it's up. Running for a while without it, and not
    /// showing its prompt, it is on a screen Tako doesn't know (first-run theme or login picker,
    /// a new notice): someone has to answer it, and nothing typed may land there meanwhile.
    private func isStuckOnStartupScreen(_ screen: String) -> Bool {
        guard agentProcessSeen, lastHookAt == .distantPast, Date().timeIntervalSince(createdAt) > 20,
              state == .starting || showingTrustPrompt else { return false }
        return !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !PromptScreen.showsClaudePrompt(screen)
    }

    private var startupScreenAnsweredAt = Date.distantPast
    /// When startup screens may still come: launch, or the trust prompt's answer, since Claude
    /// shows the development channel warning only after trust. Left 18 minutes on the trust
    /// prompt, an agent used to be past the window and stuck on the warning instead.
    private var startupScreensSince: Date { max(createdAt, trustAnsweredAt) }
    private var trustAnsweredAt = Date.distantPast

    /// Screens Claude shows at startup because of how Tako launched it, answered the way the
    /// launch already decided; left up, they block sessions started from the phone. They can come
    /// after SessionStart, so this runs for the first two minutes whatever the hooks said. True
    /// while one is on screen.
    private func answerStartupScreen() -> Bool {
        let screen = surface.readViewport()
        let keys: [String]
        let note: String
        if PromptScreen.hasDevChannelWarning(screen) {
            // Tako passed --dangerously-load-development-channels itself (channels on).
            keys = ["enter"]
            note = "Accepted Claude's development channel warning"
        } else if let decline = PromptScreen.autoModeOfferKeys(screen) {
            // Launched skipping permissions, Claude offers to make auto mode the default with
            // "Yes" preselected: a stray Return would change the user's settings. Keep what they chose.
            keys = decline
            note = "Kept bypass permissions (declined Claude's auto mode offer)"
        } else {
            return false
        }
        guard Date().timeIntervalSince(startupScreenAnsweredAt) > 2 else { return true }
        startupScreenAnsweredAt = Date()
        keys.forEach { _ = surface.pressKey(named: $0) }
        record(.note, note)
        return true
    }

    nonisolated static let trustReason = "Trust this folder?"
    nonisolated static let startupScreenReason = "Claude is showing a startup screen"

    /// Waits only the user can answer: trusting a folder, signing in, a screen Tako doesn't know.
    static func isUsersOwn(_ reason: String) -> Bool {
        reason == trustReason || reason.hasPrefix("Sign in to ") || reason == startupScreenReason
    }

    func trustPromptSeen(_ onScreen: Bool, reason: String = TerminalSession.trustReason) {
        if onScreen, state != .needsInput(reason), !state.needsAttention || showingTrustPrompt {
            apply(.processStarted, source: "trust prompt", force: .needsInput(reason))
        } else if !onScreen, showingTrustPrompt {
            trustAnsweredAt = Date()
            // SessionStart may have come while it showed (and kept "needs you"); otherwise the
            // normal start flow takes it from here.
            apply(.processStarted, source: "trust answered", force: lastHookAt == .distantPast ? .starting : .idle)
        }
    }

    private var showingTrustPrompt: Bool {
        guard stateSource == "trust prompt", case .needsInput(let reason) = state else { return false }
        return Self.isUsersOwn(reason)
    }

    /// The user typed into this terminal since their last submit. Screen text can't separate a
    /// draft from Claude's dimmed prompt suggestion, so keystrokes decide.
    private(set) var userDraftInProgress = false

    /// The agent's input box holds nothing the user is in the middle of typing. Deleting a draft
    /// with Backspace leaves the keystroke flag set, so a prompt line drawn blank also counts as empty;
    /// a dimmed suggestion isn't blank, so it still holds messages back.
    var inputIsEmpty: Bool {
        !userDraftInProgress || (kind.isAgent && PromptScreen.promptLineIsBlank(surface.readViewport(), kind: kind))
    }

    /// Called on each poll: delivers queued messages once the agent is free.
    func retryPendingMessages() {
        guard !queue.isEmpty, kind.isAgent else { return }
        noticeStaleQueued()
        if isAsleep { store?.wake(self); return }
        guard atRest, !isWaking else { return }
        flushPendingMessages()
    }

    /// At its prompt between turns. Queued messages wait for this: not mid-turn, not before the
    /// agent CLI is running (they'd run as shell commands), not after it exited. Codex stays
    /// "starting" until its first turn, so a running CLI counts as ready.
    var atRest: Bool {
        if isAsleep { return false }
        switch state {
        case .idle, .failed: return true
        // Claude reports SessionStart once up; before that, a running CLI may still be on a
        // startup screen a typed Return would answer, unless its prompt is what's drawn.
        case .starting:
            return agentProcessSeen && (kind != .claude || lastHookAt != .distantPast
                || PromptScreen.showsClaudePrompt(surface.readViewport()))
        default: return false
        }
    }

    // MARK: - Prompts (keystroke fallback)

    /// Answers a prompt by pressing its numbered option. Used when no PermissionRequest hook is
    /// waiting (Codex, or prompts that aren't permission requests). Re-reads the screen first so
    /// a stale "needs you" can never become stray keystrokes.
    func answerPromptByKeys(_ answer: PromptAnswer) -> Result<String, PromptError> {
        guard kind.isAgent, state.needsAttention else { return .failure(.notWaiting(label)) }
        let screen = surface.readViewport()
        guard let keys = PromptScreen.keys(for: answer, screen: screen, kind: kind) else {
            return .failure(.noPromptOnScreen(label))
        }
        keys.forEach { _ = surface.pressKey(named: $0) }
        record(.approval, answer == .deny ? "Denied in Tako" : "Approved in Tako")
        apply(.userSubmitted, source: "approval", force: answer == .deny ? .idle : .working)
        return .success(answer == .deny ? "denied" : "approved")
    }

    /// Picks option `index` of the single-select question on screen by pressing the arrow keys and
    /// enter (or, for a menu read off the screen, its number). Re-reads the screen first, like
    /// `answerPromptByKeys`, so nothing stray is typed.
    func answerQuestionByKeys(option index: Int) -> Result<String, PromptError> {
        guard kind.isAgent, state.needsAttention else { return .failure(.notWaiting(label)) }
        guard let question = pendingQuestion, question.mode == .options, question.items[0].options.indices.contains(index) else {
            return .failure(.noPromptOnScreen(label))
        }
        let screen = surface.readViewport()
        let first = String(question.items[0].options[0].label.prefix(12))
        guard screen.contains(first) else { return .failure(.noPromptOnScreen(label)) }
        let keys = question.selectsByNumber ? PromptScreen.keys(toOption: index + 1, screen: screen, kind: kind)
            : question.keysToPick(option: index)
        keys.forEach { _ = surface.pressKey(named: $0) }
        record(.approval, "Answered \(question.items[0].options[index].label) in Tako")
        pendingQuestion = nil
        // A screen menu (signing in) comes before the CLI is up: back to starting, where the
        // screen is still watched, rather than working.
        apply(.userSubmitted, source: "approval", force: question.selectsByNumber ? .starting : .working)
        return .success(question.items[0].options[index].label)
    }

    /// Signs a signed-out Codex in with a device code, for someone away from this Mac: picks
    /// "Sign in with Device Code" on its sign-in screen, then waits for the link and one-time code
    /// to show and passes them on.
    func signInWithDeviceCode(completion: @escaping (Result<String, PromptError>) -> Void) {
        guard kind == .codex, !isAsleep else { return completion(.failure(.noPromptOnScreen(label))) }
        let screen = surface.readViewport()
        guard PromptScreen.hasSignIn(screen, kind: kind),
              let option = PromptScreen.options(screen).first(where: { $0.text.lowercased().contains("device code") }) else {
            return completion(.failure(.noPromptOnScreen(label)))
        }
        PromptScreen.keys(toOption: option.number, screen: screen, kind: kind).forEach { _ = surface.pressKey(named: $0) }
        record(.note, "Signing in with a device code from Tako")
        pendingQuestion = nil
        apply(.userSubmitted, source: "approval", force: .starting)
        waitForDeviceCode(attemptsLeft: 30, completion: completion)
    }

    /// Polls the screen every half second, up to 15 seconds, for the device-code link and code.
    private func waitForDeviceCode(attemptsLeft: Int, completion: @escaping (Result<String, PromptError>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self] in
            guard let self else { return completion(.failure(.signIn("the session closed before a code appeared"))) }
            let screen = self.surface.readViewport()
            if let found = PromptScreen.deviceCode(in: screen) {
                return completion(.success("Open \(found.url) and enter code \(found.code)"))
            }
            if let message = PromptScreen.signInFailure(in: screen) { return completion(.failure(.signIn(message))) }
            guard attemptsLeft > 1 else {
                return completion(.failure(.signIn("no device code showed on @\(self.label)'s screen; open it to sign in")))
            }
            self.waitForDeviceCode(attemptsLeft: attemptsLeft - 1, completion: completion)
        }
    }

    enum PromptError: Error, CustomStringConvertible {
        case notWaiting(String), noPromptOnScreen(String), noAlwaysOption, signIn(String)
        var description: String {
            switch self {
            case .notWaiting(let label): return "@\(label) isn't waiting on a prompt"
            case .noPromptOnScreen(let label): return "couldn't find the prompt on @\(label)'s screen; open it to answer"
            case .noAlwaysOption: return "this prompt has no \"don't ask again\" option"
            case .signIn(let message): return "sign-in failed: \(message)"
            }
        }
    }

    // MARK: - Naming

    func syncNativeName() {
        guard kind == .claude else { return }
        pendingNativeRename = label
        if state == .idle { applyPendingNativeRename() }
    }

    /// Typed only at an idle, empty prompt so it never lands in the user's half-written message.
    private func applyPendingNativeRename() {
        guard let name = pendingNativeRename, kind == .claude, state == .idle, !isAsleep else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self, self.state == .idle, self.inputIsEmpty, !self.dialogOnScreen else { return }
            self.pendingNativeRename = nil
            self.type("/rename \(name)", submit: true, countsAsWork: false)
        }
    }

    /// Claude's Remote Control continues this session on the phone or web; typed only at an idle,
    /// empty prompt.
    func openRemoteControl() {
        guard kind == .claude else { return }
        if state == .idle && !isAsleep && inputIsEmpty && !dialogOnScreen {
            type("/remote-control", submit: true, countsAsWork: false)
        } else {
            enqueue("/remote-control", from: nil)
            if isAsleep { store?.wake(self) }
        }
    }

    /// Starts a fresh conversation in the same agent (Claude's /clear, Codex's /new). Typed only
    /// at rest with an empty prompt; false when it couldn't be.
    func startFreshConversation() -> Bool {
        guard kind.isAgent, atRest, inputIsEmpty, !dialogOnScreen else { return false }
        guard let command = kind.adapter?.newConversationCommand else { return false }
        type(command, submit: true, countsAsWork: false)
        usage.contextPercent = nil
        return true
    }

    // MARK: - Messaging

    /// Types `text` into the terminal and submits it. For agents, text never lands in a dialog
    /// or a half-typed prompt: it waits until the agent is at an empty prompt.
    func deliver(_ text: String, submit: Bool = true, from sender: String?) -> String {
        if kind == .browser {
            return "@\(label) is a browser; use the browser tools (pageId for @\(label)) to act on it"
        }
        // The CLI is gone and a shell holds the terminal: typed text would run as a command there.
        if kind.isAgent, case .exited = state {
            return "not delivered: @\(label) has exited; restart it first"
        }
        if kind.isAgent, isAsleep || isWaking {
            let message = enqueue(text, from: sender)
            if isAsleep { store?.wake(self) }
            return queuedReply(message, "was asleep; it wakes with the same conversation and gets the message once ready")
        }
        if submit, store?.pushViaChannel(text, to: self) == true {
            if let sender { record(.message, "Message from @\(sender)") }
            // A confirming poller hasn't said it reached Claude yet; Tako types it if it doesn't.
            return (store?.channelConfirms(self) == true ? "sent to @" : "delivered to @") + "\(label) (channel)"
        }
        if kind.isAgent && (state.needsAttention || dialogOnScreen || !inputIsEmpty) {
            return queuedReply(enqueue(text, from: sender), "is busy at a prompt; it gets the message as soon as that clears")
        }
        // Typed into a CLI that hasn't drawn its prompt yet, a message is lost; typed before the
        // previous one's Return, two messages merge into one.
        if kind.isAgent, submit, state == .starting || submitInFlight {
            let message = enqueue(text, from: sender)
            return queuedReply(message, state == .starting ? "is starting; it gets the message once it's ready"
                : "just got another message; it gets this one after that turn")
        }
        // At rest with messages still queued, this one goes after them, not ahead.
        if kind.isAgent, submit, atRest, !queue.isEmpty {
            let message = enqueue(text, from: sender)
            flushPendingMessages()
            return queuedReply(message, "gets it after the \(queue.count - 1) before it")
        }
        type(text, submit: submit)
        if let sender { record(.message, "Message from @\(sender)") }
        return "delivered to @\(label)"
    }

    /// Sends a follow-up. While the agent is mid-turn it waits in the queue and goes out when the
    /// turn ends; `now` types it straight in (Claude reads it as steering the current turn).
    func send(_ text: String, now: Bool) -> String {
        let text = sanitizeMessage(text)
        guard !text.isEmpty else { return "" }
        if kind.isAgent, !now, state == .working || state == .starting {
            enqueue(text, from: nil)
            return "queued"
        }
        return deliver(text, from: nil)
    }

    /// Types exactly what a person at the keyboard would, straight in: no queueing behind a dialog
    /// or a draft, no "Message from" framing. For Sumi answering a free-text field or a menu.
    func typeAsUser(_ text: String, submit: Bool) {
        type(text, submit: submit, countsAsWork: submit && !dialogOnScreen)
    }

    func removeQueued(at index: Int) {
        guard queue.indices.contains(index) else { return }
        store?.messageOutcome(queue.remove(at: index), to: self, .dropped("the user removed it from the queue"))
    }

    /// Sends a queued message right away instead of waiting for the turn to end.
    func sendQueuedNow(at index: Int) {
        guard queue.indices.contains(index), atRest || state == .working, !submitInFlight, !dialogOnScreen, inputIsEmpty else { return }
        land(queue.remove(at: index))
    }

    /// How long a message may wait before its sender is told it is still queued. The message
    /// itself is kept: the target may be in a long build, and dropping it would lose the work.
    static let staleQueuedMessage: TimeInterval = 60 * 60

    @discardableResult
    private func enqueue(_ text: String, from sender: String?) -> QueuedMessage {
        let message = QueuedMessage(text: text, sender: sender)
        queue.append(message)
        return message
    }

    /// What send_message tells the sender: plainly not delivered yet, and that it will hear.
    private func queuedReply(_ message: QueuedMessage, _ reason: String) -> String {
        guard message.sender != nil else { return "queued: @\(label) " + reason }
        return "Queued (message \(message.id)): NOT delivered yet; @\(label) \(reason). You'll be told when it lands, or if it can't."
    }

    private func land(_ message: QueuedMessage) {
        // Tako's own slash commands start no turn, so they mustn't hold the queue.
        type(message.text, submit: true, countsAsWork: !message.text.hasPrefix("/remote-control"))
        if let sender = message.sender { record(.message, "Message from @\(sender)") }
        store?.messageOutcome(message, to: self, .delivered)
    }

    func noticeStaleQueued(now: Date = Date()) {
        let minutes = Int(Self.staleQueuedMessage / 60)
        for index in queue.indices
        where !queue[index].staleNoticed && now.timeIntervalSince(queue[index].queuedAt) >= Self.staleQueuedMessage {
            queue[index].staleNoticed = true
            store?.messageOutcome(queue[index], to: self, .stale("waiting over \(minutes) min"))
        }
    }

    /// Everything still queued, for when the terminal closes.
    func takeQueue() -> [QueuedMessage] {
        defer { queue = [] }
        return queue
    }

    /// One flush in flight at a time: two landing together (the idle transition and the poll)
    /// would both type before the first one's Return, merging two messages into one.
    private var flushScheduled = false

    private func flushPendingMessages() {
        guard !queue.isEmpty, !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
            self?.flushScheduled = false
            // One message per turn: the rest wait for the agent to finish the one just sent.
            // Not inside another message's paste-to-Return window: the two would merge.
            guard let self, self.atRest, !self.submitInFlight, !self.dialogOnScreen,
                  self.inputIsEmpty, !self.queue.isEmpty else { return }
            self.land(self.queue.removeFirst())
            if !self.queue.isEmpty { self.flushPendingMessages() }
        }
    }

    /// The last prompt Tako typed, used to title Codex checkpoints.
    private var lastPrompt: String?

    /// Between a message's paste and its Return.
    private var submitInFlight = false

    private func type(_ text: String, submit: Bool, countsAsWork: Bool = true) {
        if submit, countsAsWork { lastPrompt = summarize(text) ?? text }
        // A message ending in "@name" leaves Claude Code's mention picker open, and the picker
        // takes the Return; a trailing space closes it.
        let text = submit && kind.isAgent && text.range(of: #"@[^\s@]+$"#, options: .regularExpression) != nil ? text + " " : text
        surface.sendText(text)
        guard submit else { return }
        submitInFlight = true
        // Let the paste land before Return so TUIs don't treat it as part of the paste.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { [weak self] in
            self?.submitInFlight = false
            self?.surface.sendReturn()
            if countsAsWork, self?.kind.isAgent == true { self?.apply(.userSubmitted, source: "message") }
        }
    }

    func info() -> SessionInfo {
        SessionInfo(
            id: id.uuidString, label: label, kind: kind.rawValue, state: isAsleep ? "asleep" : state.key,
            stateDetail: state.detail, summary: agentStatus ?? summary, title: title.isEmpty ? nil : title,
            cwd: abbreviateHome(spec.cwd), command: spec.command, ports: ports, unread: unread,
            agentSessionId: spec.agentSessionId, labelSource: (spec.labelSource ?? .user).rawValue,
            activity: activity, project: git?.project, branch: git?.branch,
            sumi: isSumi ? true : nil, conflicts: conflictsByLabel, asleep: isAsleep ? true : nil,
            delegation: delegation?.shortScope, detached: isDetached ? true : nil,
            subagents: runningSubagents.isEmpty ? nil : runningSubagents.count)
    }
}

// MARK: - Surface events

extension TerminalSession: TerminalSurfaceEvents {
    func surfaceTitleChanged(_ title: String) {
        let cleaned = cleanTitle(title)
        // Titles that are just a path (shells, Claude at rest) or the label say nothing new.
        let meaningless = cleaned.contains("/") || cleaned.hasPrefix("~") || cleaned.lowercased() == label
            || cleaned.lowercased() == kind.rawValue || cleaned.count < 3
        let next = meaningless ? "" : cleaned
        guard next != self.title else { return }
        self.title = next
        if kind.isAgent, summary == nil, !next.isEmpty { summary = next }
    }

    func surfacePwdChanged(_ pwd: String) {
        shellAtPrompt = true
        // The shell's prompt is back, so the CLI told to quit has.
        if isAsleep { sleepExitSeen = true }
        resumeAwaitsExit = false
        if pendingInput != nil { sendPendingInput() }
        guard !pwd.isEmpty, let url = URL(string: pwd), url.isFileURL || pwd.hasPrefix("/") else { return }
        let path = url.isFileURL ? url.path : pwd
        if kind == .shell, spec.cwd != path {
            spec.cwd = path
            store?.persist()
        }
    }

    func surfaceNotification(title: String, body: String) {
        // Codex behind its app-server notifies of the approval Tako is already holding and showing.
        if hasHookApproval { return }
        apply(.terminalNotification(title: title, body: body), source: "osc9")
        if kind == .codex, !body.isEmpty { summary = summarize(body) }
        store?.sessionWantsAttention(self, title: title.isEmpty ? "@\(label)" : title, body: body)
    }

    func surfaceBell() {
        store?.sessionWantsAttention(self, title: "@\(label)", body: "Bell")
    }

    func surfaceChildExited(code: Int) {
        apply(.childExited(code), source: "process")
    }

    /// OSC 9;4 progress isn't shown anywhere yet.
    func surfaceProgress(active: Bool, percent: Int) {}

    /// A server's command returning means the server stopped; non-zero means it crashed.
    func surfaceCommandFinished(exitCode: Int) {
        guard kind == .server, state == .running else { return }
        apply(.childExited(exitCode), source: "shell integration")
    }

    func surfaceRequestedClose() {
        store?.close(self)
    }

    func surfaceProcessClosed(processAlive: Bool) {
        // The shell exited (e.g. the user typed `exit`): the terminal closes, as in Terminal.app.
        apply(.childExited(0), source: "process")
        store?.close(self)
    }

    func surfaceFocused() {
        if unread { unread = false }
        store?.sessionFocused(self)
    }

    func surfaceUserSubmitted() {
        userDraftInProgress = false
        // Typed by the user, so the last prompt Tako sent doesn't describe this turn.
        lastPrompt = nil
        apply(.userSubmitted, source: "keyboard")
    }

    func surfaceUserEdited(clearsDraft: Bool) {
        userDraftInProgress = !clearsDraft
    }

    func surfaceSearch(total: Int?, selected: Int?, start: Bool) {
        store?.onSearchUpdate?(self, total, selected, start)
    }

    func surfaceMentionRequested() {
        store?.onMentionRequest?(self)
    }

    func surfaceInterceptsKey(_ event: NSEvent) -> Bool {
        interceptWhileAsleep(event)
    }
}

@MainActor
enum TerminalSessionFactory {
    /// Set at launch; browsers offer the store's running servers on their start page.
    static weak var store: SessionStore?

    static func makeSurface(spec: LaunchSpec) -> any SessionSurface {
        if spec.kind == .browser, let store {
            // `ht new browser @docs -- <address>` passes the address as the command.
            let url = spec.url.flatMap(URL.init(string:)) ?? spec.command.flatMap(resolveAddress)
            return BrowserSurfaceView(url: url, label: spec.label, store: store)
        }
        return TerminalSurfaceView(launch: AgentIntegration.surfaceLaunch(for: spec))
    }
}

/// "https://github.com/acme/api/pulls" → "github.com/acme/api/pulls".
func abbreviateURL(_ address: String) -> String {
    guard let url = URL(string: address), let host = url.host() else { return address }
    let path = url.path()
    return host + (url.port.map { ":\($0)" } ?? "") + (path == "/" ? "" : path)
}

/// Ids typed into shells: letters, digits, dash, underscore, dot. No spaces or metacharacters.
func isSafeIdentifier(_ value: String) -> Bool {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    return (4...128).contains(value.count) && value.unicodeScalars.allSatisfy { allowed.contains($0) }
}

/// Reading agent TUIs from their screen text.
enum PromptScreen {
    /// Numbered option lines like "❯ 1. Yes" or "  2. Yes, and don't ask again".
    /// The keys that pick option `number`. Claude acts on the digit itself. Codex's menus only
    /// confirm with Enter, so it walks the highlight there with the arrows first: a digit alone
    /// does nothing, and Enter alone would take whatever is highlighted.
    static func keys(toOption number: Int, screen: String, kind: SessionKind) -> [String] {
        guard kind == .codex else { return [String(number)] }
        let current = highlighted(screen) ?? 1
        let step = number > current ? "down" : "up"
        return Array(repeating: step, count: abs(number - current)) + ["enter"]
    }

    /// Claude's folder-trust prompt lists its choices unnumbered ("❯ No, exit" over "Yes, I trust
    /// this folder"), so the cursor is moved to the right line and Enter confirms. Never "always".
    static func trustKeys(for answer: PromptAnswer, screen: String) -> [String]? {
        guard answer != .always else { return nil }
        guard answer == .approve else { return ["esc"] }
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let cursor = lines.firstIndex(where: { $0.hasPrefix("❯") || $0.hasPrefix("›") }) else { return nil }
        var start = cursor, end = cursor
        while start > 0, !lines[start - 1].isEmpty { start -= 1 }
        while end + 1 < lines.count, !lines[end + 1].isEmpty { end += 1 }
        let items = lines[start...end].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "❯› ")).lowercased() }
        guard let yes = items.firstIndex(where: { $0.hasPrefix("yes") || $0.hasPrefix("trust") }) else { return nil }
        let steps = yes - (cursor - start)
        return Array(repeating: steps > 0 ? "down" : "up", count: abs(steps)) + ["enter"]
    }

    /// The number of the menu option the cursor marker ("›", "❯" or ">") is on, if any.
    static func highlighted(_ screen: String) -> Int? {
        for raw in screen.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let marker = ["❯", "›", ">"].first(where: line.hasPrefix) else { continue }
            let rest = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            if let dot = rest.firstIndex(of: "."), let number = Int(rest[..<dot]), (1...9).contains(number) { return number }
        }
        return nil
    }

    static func options(_ screen: String) -> [(number: Int, text: String)] {
        screen.split(separator: "\n").compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for marker in ["❯", "›", ">"] where line.hasPrefix(marker) {
                line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            }
            guard let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), (1...9).contains(number) else { return nil }
            return (number, String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
        }
    }

    /// The numbered menu under the selection cursor: the options counting down to 1 above it and up
    /// from it below, so a numbered list in the agent's own reply above the dialog is never mistaken
    /// for one of its choices.
    static func menu(_ screen: String) -> [(number: Int, text: String)] {
        let parsed = screen.split(separator: "\n", omittingEmptySubsequences: false).map { menuLine(String($0)) }
        guard let cursor = parsed.lastIndex(where: { $0?.selected == true }), let current = parsed[cursor] else { return [] }
        var items = [(number: current.number, text: current.text)]
        var expect = current.number - 1
        var index = cursor - 1
        while expect >= 1, index >= 0 {
            if let line = parsed[index] {
                guard line.number == expect else { break }
                items.insert((line.number, line.text), at: 0)
                expect -= 1
            }
            index -= 1
        }
        guard expect == 0 else { return [] }
        expect = current.number + 1
        index = cursor + 1
        while index < parsed.count {
            if let line = parsed[index] {
                guard line.number == expect else { break }
                items.append((line.number, line.text))
                expect += 1
            }
            index += 1
        }
        return items
    }

    private static func menuLine(_ raw: String) -> (number: Int, text: String, selected: Bool)? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        var selected = false
        if let marker = ["❯", "›"].first(where: line.hasPrefix) {
            line = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            selected = true
        }
        guard let dot = line.firstIndex(of: "."), let number = Int(line[..<dot]), (1...99).contains(number) else { return nil }
        return (number, String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces), selected)
    }

    /// Claude's "Make auto mode your default permission mode?" offer: the next key toward "No, keep
    /// …", one per call so each lands before the next, then Enter once the cursor is on it.
    static func autoModeOfferKeys(_ screen: String) -> [String]? {
        guard screen.lowercased().contains("make auto mode your default permission mode") else { return nil }
        let lines = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func plain(_ line: String) -> String {
            line.trimmingCharacters(in: CharacterSet(charactersIn: "❯› ")).lowercased().replacingOccurrences(of: " ", with: "")
        }
        // The last copy on screen is the live one; Claude may leave an earlier frame above it.
        guard let no = lines.lastIndex(where: { plain($0).hasPrefix("no,keep") }),
              let yes = lines[..<no].lastIndex(where: { plain($0).hasPrefix("yes,setautomode") }) else { return nil }
        if lines[no].hasPrefix("❯") || lines[no].hasPrefix("›") { return ["enter"] }
        return lines[yes].hasPrefix("❯") || lines[yes].hasPrefix("›") ? ["down"] : nil
    }

    /// Claude's permission mode, from the footer under its prompt; nil for a mode Tako has no name
    /// for (auto).
    static func claudeMode(_ screen: String) -> PermissionMode? {
        let lower = screen.lowercased()
        if lower.contains("bypass permissions on") { return .fullAccess }
        if lower.contains("accept edits on") { return .acceptEdits }
        if lower.contains("plan mode on") { return .plan }
        if lower.contains("auto mode on") { return nil }
        return .supervised
    }

    /// Claude's prompt box is drawn (not a dialog, not a startup screen), so Shift-Tab reaches it.
    static func showsClaudePrompt(_ screen: String) -> Bool {
        screen.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯") }
            && menu(screen).isEmpty && !hasTrustDialog(screen)
    }

    /// A live dialog draws its selection cursor on one option; an agent's reply that asks "Would you
    /// like me to…" over a numbered list has none, and must not hold messages back while it's on screen.
    static func hasDialog(_ screen: String) -> Bool {
        let lower = screen.lowercased()
        let asks = lower.contains("do you want") || lower.contains("would you like") || lower.contains("allow command")
            || lower.contains("proceed?") || lower.contains("trust this folder") || lower.contains("enter to confirm")
            || lower.contains("press enter to continue") || lower.contains("update available")
        return asks && options(screen).count >= 2 && hasSelectedOption(screen)
    }

    private static func hasSelectedOption(_ screen: String) -> Bool {
        screen.split(separator: "\n").contains { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let marker = ["❯", "›"].first(where: line.hasPrefix) else { return false }
            let rest = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return rest.first.map { ("1"..."9").contains($0) } == true && rest.dropFirst().hasPrefix(".")
        }
    }

    /// Claude's warning for Tako's own --dangerously-load-development-channels, with its default
    /// option ("I am using this for local development") selected.
    static func hasDevChannelWarning(_ screen: String) -> Bool {
        let lower = screen.lowercased()
        guard lower.contains("loading development channels"), lower.contains("server:tako"),
              let first = options(screen).first,
              first.number == 1, first.text.lowercased().hasPrefix("i am using this for local development") else { return false }
        // Return must land on option 1, never "Exit".
        return screen.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("❯") && trimmed.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("1.")
        }
    }

    /// Any agent CLI's folder-trust prompt.
    static func hasTrustDialog(_ screen: String) -> Bool {
        let lower = screen.lowercased()
        return SessionKind.agentAdapters.contains { $0.trustMarkers.contains(where: lower.contains) }
    }

    /// The CLI's signed-out screen.
    static func hasSignIn(_ screen: String, kind: SessionKind) -> Bool {
        let lower = screen.lowercased()
        return kind.adapter?.signInMarkers.contains(where: lower.contains) ?? false
    }

    /// The verification link and one-time code of a device-code sign-in, once both are on screen.
    /// The code is groups of 4–5 capitals or digits joined by dashes ("ABCD-1234", "ABCD-EFGHI").
    static func deviceCode(in screen: String) -> (url: String, code: String)? {
        let urls = screen.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("https://") }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]}>'\"")) }
        guard let url = urls.first(where: { $0.lowercased().contains("device") }) ?? urls.first else { return nil }
        let text = screen.split(whereSeparator: \.isWhitespace).filter { !$0.contains("://") }.joined(separator: " ")
        guard let range = text.range(of: #"\b[A-Z0-9]{4,5}(-[A-Z0-9]{4,5})+\b"#, options: .regularExpression) else { return nil }
        return (url, String(text[range]))
    }

    /// Why a sign-in can't go on, when the screen says so (device-code login turned off).
    static func signInFailure(in screen: String) -> String? {
        screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.lowercased().contains("not enabled") }
    }

    /// The CLI's prompt line is on screen with nothing after its marker.
    static func promptLineIsBlank(_ screen: String, kind: SessionKind) -> Bool {
        let marker = kind.adapter?.promptMarker ?? "❯"
        let lines = screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let prompt = lines.last(where: { $0.hasPrefix(marker) }) else { return false }
        return prompt.dropFirst(marker.count).trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func inputIsEmpty(_ screen: String, kind: SessionKind) -> Bool {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let marker = kind.adapter?.promptMarker ?? "❯"
        guard let prompt = lines.last(where: { $0.hasPrefix(marker) }) else { return true }
        let rest = prompt.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        // Claude shows a dim placeholder ("Try …") when empty; it can't be told from typed text
        // by characters alone, so treat the common placeholder forms as empty.
        return rest.isEmpty || rest.hasPrefix("Try \"") || rest.hasPrefix("Ask anything") || rest.hasPrefix("Implement {feature}")
    }

    /// Keys that choose `answer` in the dialog on screen, or nil when there is no dialog.
    static func keys(for answer: PromptAnswer, screen: String, kind: SessionKind) -> [String]? {
        // Only the block under the cursor: a "1. …" line in the agent's reply above the dialog must
        // never be what "deny" presses. Codex menus drawn without a cursor fall back to every line.
        let underCursor = menu(screen)
        let options = underCursor.isEmpty && kind.adapter?.optionsAloneMakeDialog == true ? options(screen) : underCursor
        if options.isEmpty, hasTrustDialog(screen) { return trustKeys(for: answer, screen: screen) }
        guard hasDialog(screen) || kind.adapter?.optionsAloneMakeDialog == true, !options.isEmpty else { return nil }
        func pick(_ predicate: (String) -> Bool) -> [String]? {
            options.first { predicate($0.text.lowercased()) }.map { keys(toOption: $0.number, screen: screen, kind: kind) }
        }
        switch answer {
        case .approve:
            // "Yes, proceed" for a command; "Trust and continue" for Codex's folder prompt.
            return pick { ($0.hasPrefix("yes") || $0.hasPrefix("trust")) && !$0.contains("don't ask") && !$0.contains("always") && !$0.contains("auto") }
        case .always:
            return pick { $0.contains("don't ask again") || $0.contains("always") }
        case .deny:
            return pick { $0.hasPrefix("no") } ?? ["esc"]
        }
    }
}
