import AppKit

/// A session whose waits the user handed to Sumi, for as long as they said: its
/// questions and permission prompts wake Sumi instead of the user. The user still hears
/// about anything Sumi leaves, or doesn't answer within `fallback`.
struct Delegation: Equatable {
    enum Scope: Equatable {
        /// Until the agent finishes its current task: its next working → idle with nothing pending.
        case turn
        /// The next n waits.
        case count(Int)
        case until(Date)
        /// Every agent while the user is away in Phone Mode; ends when they turn it off.
        case phoneMode
    }

    var scope: Scope
    /// The user's instructions, e.g. "prefer pnpm".
    var note: String?
    /// Waits handled so far, answered or left for the user.
    var handled = 0
    /// When Sumi was told of the wait in progress.
    var toldAt: Date?
    /// Phone Mode: how many times Sumi was reminded of the wait in progress.
    var reminders = 0

    /// How long Sumi has before the user is notified anyway.
    static let fallback: TimeInterval = 90
    /// Phone Mode: reminders to Sumi before the wait also goes to the Mac.
    static let phoneReminders = 3

    func isUsedUp(at now: Date) -> Bool {
        switch scope {
        case .turn, .phoneMode: return false
        case .count(let limit): return handled >= limit
        case .until(let end): return now >= end
        }
    }

    func isOverdue(at now: Date) -> Bool {
        toldAt.map { now.timeIntervalSince($0) >= Self.fallback } ?? false
    }

    /// "turn", "2 left", "until 14:05".
    var shortScope: String {
        switch scope {
        case .turn: return "turn"
        case .count(let limit): return "\(max(limit - handled, 0)) left"
        case .until(let end): return "until " + Self.clock(end)
        case .phoneMode: return "phone"
        }
    }

    /// "until it finishes its task", "for its next 3 waits", "until 14:05".
    var scopePhrase: String {
        switch scope {
        case .turn: return "until it finishes its task"
        case .count(let limit): return limit == 1 ? "for its next wait" : "for its next \(limit) waits"
        case .until(let end): return "until " + Self.clock(end)
        case .phoneMode: return "while Phone Mode is on"
        }
    }

    /// Sumi tag's tooltip.
    var help: String {
        "Sumi answers this session's questions \(scopePhrase)." + (note.map { " Your note: \($0)" } ?? "")
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

/// Requests Sumi never approves on the user's behalf. The list lives here, in one
/// place, and the app checks it: Sumi's instructions alone are not the guard.
enum RiskyRequest {
    /// Each pattern (case-insensitive, against the full request) with what it means.
    static let patterns: [(pattern: String, why: String)] = [
        (#"\brm\b[^|;&\n]*\s(-[a-z]*r|--recursive)"#, "a recursive delete"),
        (#"\bsudo\b"#, "sudo"),
        (#"\bgit\b[^|;&\n]*\bpush\b"#, "a git push"),
        (#"\bgit\b[^|;&\n]*\breset\b[^|;&\n]*--hard\b"#, "git reset --hard"),
        (#"\bgit\b[^|;&\n]*\bclean\b"#, "git clean"),
        (#"\bchmod\b[^|;&\n]*\s(-[a-z]*r|--recursive)"#, "a recursive chmod"),
        (#"\b(curl|wget)\b[^;&\n]*\|\s*(sudo\s+)?(ba|z|da|k)?sh\b"#, "piping a download into a shell"),
        (#"\bdeploy"#, "a deploy"),
        (#"\b(npm|pnpm|yarn|cargo)\s+publish\b"#, "publishing a package"),
        (#"\bdrop\s+(table|database|schema)\b"#, "dropping a table or database"),
        (#"(^|[^a-z0-9_])\.env\b|secret|credential|keychain|\.ssh/|\.aws/|\.netrc\b|\bid_(rsa|ed25519)\b"#, "secrets or credentials"),
        (#"\bkill\s+(-9|-kill|-sigkill|-s\s+kill)\b|\bkillall\b|\bpkill\b"#, "force-killing processes"),
    ]

    static let fileWriteTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    private static let compiled: [(NSRegularExpression, String)] = patterns.compactMap { entry in
        (try? NSRegularExpression(pattern: entry.pattern, options: [.caseInsensitive])).map { ($0, entry.why) }
    }

    /// Why Sumi must leave this request for the user, or nil when it may approve it.
    static func reason(tool: String?, request: String, workspace: String?) -> String? {
        let range = NSRange(request.startIndex..., in: request)
        if let hit = compiled.first(where: { $0.0.firstMatch(in: request, range: range) != nil }) { return hit.1 }
        if let tool, fileWriteTools.contains(tool), let workspace, request.hasPrefix("/") {
            let path = (request as NSString).standardizingPath
            let root = (expandTilde(workspace) as NSString).standardizingPath
            if path != root && !path.hasPrefix(root.hasSuffix("/") ? root : root + "/") { return "a write outside its workspace" }
        }
        return nil
    }

    /// The whole request a permission hook asks about, not the one-line summary: the full
    /// command, the absolute path, or the tool's input.
    static func text(tool: String, input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
        if let path = (input["file_path"] ?? input["notebook_path"]) as? String { return path }
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return tool + " " + String(decoding: data, as: UTF8.self)
    }
}

extension SessionStore {
    /// handle_waiting: replaces any earlier handoff. A session already waiting is Sumi's
    /// from now; the reply describes that wait.
    func delegate(_ session: TerminalSession, scope: Delegation.Scope, note: String?, now: Date = Date()) -> String? {
        var delegation = Delegation(scope: scope, note: note)
        session.record(.note, "Sumi handling: " + delegation.scopePhrase + (note.map { " (\($0))" } ?? ""))
        if case .until(let end) = scope { scheduleDelegationSweep(after: end.timeIntervalSince(now)) }
        defer { session.delegation = delegation }
        guard case .needsInput(let reason) = session.state, !TerminalSession.isUsersOwn(reason) else { return nil }
        delegation.toldAt = now
        scheduleDelegationSweep(after: Delegation.fallback)
        return waitDescription(session, reason: reason)
    }

    /// Ends a handoff. A wait Sumi was told of and didn't answer goes to the user.
    func stopDelegating(_ session: TerminalSession, why: String, tellSumi: Bool) {
        guard let delegation = session.delegation else { return }
        session.delegation = nil
        session.record(.note, "Sumi stopped handling: " + why)
        if delegation.toldAt != nil { notifyUserOfWait(session) }
        if tellSumi, sumi != nil {
            addToSumiDigest(SumiEvent(label: session.label, kind: .stoppedHandling(why)))
        }
    }

    /// A delegated session started waiting: Sumi hears instead of the user. False when
    /// the user should be notified as usual. Folder trust and sign-in go to Sumi only in Phone
    /// Mode, where it relays them to the user's phone.
    func sumiTakesWait(_ session: TerminalSession, reason: String, now: Date = Date()) -> Bool {
        guard var delegation = session.delegation, let sumi, !sumi.isExitedProcess else { return false }
        guard isPhoneModeOn || !TerminalSession.isUsersOwn(reason) else {
            session.record(.note, reason == TerminalSession.trustReason ? "Left for you: trusting a folder is your call"
                : reason == TerminalSession.startupScreenReason ? "Left for you: Claude's startup screen" : "Left for you: signing in is your call")
            return false
        }
        // The user always allows this here: answered as they would, a beat later, once the state
        // change that brought it has settled. Sumi only hears it happened.
        if learnedAlways(session) {
            DispatchQueue.main.async { [weak self, weak session] in
                guard let self, let session else { return }
                if let key = self.approveAsUserAlwaysDoes(session) {
                    self.addToSumiDigest(SumiEvent(label: session.label, kind: .autoApproved(key)))
                } else if session.state.needsAttention, session.delegation != nil {
                    self.tellSumiOfWait(session, reason: reason)
                }
            }
            return true
        }
        tellSumiOfWait(session, reason: reason, now: now)
        return true
    }

    private func tellSumiOfWait(_ session: TerminalSession, reason: String, now: Date = Date()) {
        guard var delegation = session.delegation else { return }
        delegation.toldAt = now
        delegation.reminders = 0
        session.delegation = delegation
        addToSumiDigest(SumiEvent(label: session.label,
                                  kind: .needsYou(waitDescription(session, reason: reason), note: delegation.note)),
                        urgent: true)
        scheduleDelegationSweep(after: Delegation.fallback)
    }

    /// Scope accounting on each state change: a wait ending counts as handled; a used-up scope,
    /// a finished task (`.turn`) or an exit ends the handoff.
    func delegationStateChanged(_ session: TerminalSession, from previous: AgentState, now: Date = Date()) {
        guard var delegation = session.delegation else { return }
        if previous.needsAttention, delegation.toldAt != nil {
            delegation.toldAt = nil
            delegation.reminders = 0
            delegation.handled += 1
        }
        session.delegation = delegation
        if case .exited = session.state {
            stopDelegating(session, why: "it exited", tellSumi: !(isPhoneModeOn && delegation.scope == .phoneMode))
        } else if delegation.isUsedUp(at: now) {
            stopDelegating(session, why: "scope used up", tellSumi: true)
        } else if delegation.scope == .turn, session.state == .idle, previous == .working {
            stopDelegating(session, why: "it finished its task", tellSumi: true)
        }
    }

    /// Waits Sumi hasn't answered in time go to the user; expired handoffs end. In Phone Mode the
    /// user is away from the Mac, so Sumi is reminded first, to push their phone.
    func sweepDelegations(now: Date = Date()) {
        for session in sessions {
            guard var delegation = session.delegation else { continue }
            if delegation.isOverdue(at: now), session.state.needsAttention, isPhoneModeOn,
               delegation.reminders < Delegation.phoneReminders, case .needsInput(let reason) = session.state {
                delegation.reminders += 1
                delegation.toldAt = now
                session.delegation = delegation
                let waited = Int(Delegation.fallback) * delegation.reminders
                addToSumiDigest(SumiEvent(label: session.label, kind: .stillWaiting(
                    waitDescription(session, reason: reason), seconds: waited)), urgent: true)
                scheduleDelegationSweep(after: Delegation.fallback)
            } else if delegation.isOverdue(at: now), session.state.needsAttention {
                let waited = Int(Delegation.fallback) * (delegation.reminders + 1)
                escalate(session, why: "Sumi didn't get an answer within \(waited) s", now: now)
            } else if delegation.isUsedUp(at: now) {
                stopDelegating(session, why: "scope used up", tellSumi: true)
            }
        }
    }

    /// Hands the current wait back to the user, notified as a normal needs-you.
    func escalate(_ session: TerminalSession, why: String, now: Date = Date()) {
        guard var delegation = session.delegation else { return }
        if delegation.toldAt != nil {
            delegation.toldAt = nil
            delegation.reminders = 0
            delegation.handled += 1
        }
        session.delegation = delegation
        session.record(.note, "Left for you: " + why)
        notifyUserOfWait(session)
        if delegation.isUsedUp(at: now) { stopDelegating(session, why: "scope used up", tellSumi: true) }
    }

    /// answer_prompt: approve or deny one permission request of a delegated, waiting session.
    /// Never "always"; risky requests and folder trust go to the user instead. In Phone Mode the
    /// user is talking to Sumi from their phone, so a risky request it relayed may be
    /// approved once the user OK'd it there (`userApproved`).
    func answerForSumi(_ session: TerminalSession, _ answer: PromptAnswer, reason: String?,
                            userApproved: Bool = false) -> Result<String, DelegationError> {
        guard answer != .always || (phoneModeSince != nil && userApproved) else {
            return .failure(DelegationError("\"always\" needs the user's yes: in Phone Mode, ask them and pass user_approved true; otherwise approve or deny this one request"))
        }
        guard session.delegation != nil else {
            return .failure(DelegationError("@\(session.label) isn't handed to you; take over a session's waits with handle_waiting only when the user asks"))
        }
        guard case .needsInput(let waiting) = session.state else {
            return .failure(DelegationError("@\(session.label) isn't waiting"))
        }
        guard !TerminalSession.isUsersOwn(waiting) else {
            return .failure(DelegationError(waiting == TerminalSession.trustReason
                ? "trusting a folder is the user's call; they've been notified" : "signing in is the user's call; they've been notified"))
        }
        let approval = approvals[session.id]
        let pending = session.pendingRequest
        guard approval != nil || (pending != nil && pending == waiting) else {
            return .failure(DelegationError(session.pendingQuestion?.mode == .options
                ? "@\(session.label) asked a multiple-choice question: answer it with choose_option"
                : "@\(session.label) asked a question, not for permission: answer it with send_message"))
        }
        let request = approval?.request ?? pending ?? waiting
        let summary = approval?.summary ?? waiting
        if answer != .deny, let why = RiskyRequest.reason(tool: approval?.toolName, request: request, workspace: session.spec.workPath) {
            if phoneModeSince != nil {
                guard userApproved else {
                    return .failure(DelegationError("\(why): ask the user on their phone about exactly this request (\(summary)); "
                        + "if they say yes, call answer_prompt again with user_approved true, otherwise deny"))
                }
                session.record(.note, "Approved from your phone: \(why) (\(summary))")
            } else {
                escalate(session, why: "\(why) (\(summary))")
                return .failure(DelegationError("left for the user: \(why)"))
            }
        }
        let denial = answer == .deny ? (reason ?? "Sumi denied this on the user's behalf.") : nil
        // Sumi's own judgment isn't the user's to learn from; a yes it relays from their phone is.
        sumiBrain.sumiAnswering = !(userApproved && phoneModeSince != nil)
        defer { sumiBrain.sumiAnswering = false }
        switch self.answer(session, answer, reason: denial) {
        case .success(let done):
            session.record(.note, "Sumi answered: " + (answer == .deny ? "denied " : answer == .always ? "always allowed " : "allowed ") + summary)
            return .success("\(done) @\(session.label): \(summary)")
        case .failure(let error):
            return .failure(DelegationError(error.description))
        }
    }

    // MARK: - Sumi's hands

    /// Sumi acts on a session the user handed it, or on any agent while Phone Mode is on: there the
    /// user is talking to Sumi from their phone, so what Sumi relays is the user's word.
    /// `userRequested`: the user directly asked for this, in the turn Sumi is in (see
    /// SessionStore+UserRequested for what Tako checks).
    private func sumiMayAct(on session: TerminalSession, userRequested: Bool = false) -> DelegationError? {
        guard session.kind.isAgent, !session.isSumi else { return DelegationError("@\(session.label) isn't an agent") }
        guard isPhoneModeOn || session.delegation != nil || userRequested else {
            return DelegationError("@\(session.label) isn't handed to you. If the user just asked for this, call again with "
                + "user_requested true; otherwise take over its waits with handle_waiting only when the user asks")
        }
        return userRequestRefusal(userRequested && !isPhoneModeOn && session.delegation == nil)
    }

    /// choose_option: picks option `number` (1-based) of the question the agent is asking. A
    /// question the hook described is answered through it; any other numbered menu on screen
    /// (permission menus, plan approval, /model, forms) gets the keys a person would press.
    /// Several numbers answer a form one question at a time.
    func chooseForSumi(_ session: TerminalSession, options numbers: [Int], userApproved: Bool = false, userRequested: Bool = false,
                       completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session, userRequested: userRequested) { return completion(.failure(refusal)) }
        guard let first = numbers.first else { return completion(.failure(DelegationError("option is required"))) }
        if numbers.count == 1, let question = session.pendingQuestion, question.mode == .options, question.items.count == 1 {
            let options = question.items[0].options
            guard options.indices.contains(first - 1) else {
                return completion(.failure(DelegationError("option must be 1–\(options.count)")))
            }
            let label = options[first - 1].label
            return answerQuestion(session, option: first - 1) { result in
                switch result {
                case .success:
                    session.record(.note, "Sumi answered: \(label)")
                    completion(.success("answered @\(session.label): \(label)"))
                case .failure(let error):
                    completion(.failure(DelegationError(error.description)))
                }
            }
        }
        let screen = session.surface.readViewport()
        let menu = PromptScreen.menu(screen)
        guard !menu.isEmpty else {
            return completion(.failure(DelegationError("@\(session.label) has no numbered menu on screen; read_terminal it, then press_keys or type_text")))
        }
        guard let option = menu.first(where: { $0.number == first }) else {
            return completion(.failure(DelegationError("option must be one of \(menu.map { String($0.number) }.joined(separator: ", "))")))
        }
        if let refusal = riskyOnScreen(session, approving: !option.text.lowercased().hasPrefix("no"), userApproved: userApproved) {
            return completion(.failure(refusal))
        }
        let keys = numbers.flatMap { PromptScreen.keys(toOption: $0, screen: screen, kind: session.kind) }
        pressAsUser(session, keys) { after in
            session.record(.note, "Sumi chose: \(option.text)")
            completion(.success("chose \(option.text) on @\(session.label)\n\(after)"))
        }
    }

    /// trust_folder: only on the user's yes, relayed from their phone.
    func trustForSumi(_ session: TerminalSession, userApproved: Bool) -> Result<String, DelegationError> {
        if let refusal = sumiMayAct(on: session) { return .failure(refusal) }
        guard session.state == .needsInput(TerminalSession.trustReason) else {
            return .failure(DelegationError("@\(session.label) isn't asking to trust its folder"))
        }
        guard userApproved else {
            return .failure(DelegationError("ask the user whether to trust \(abbreviateHome(session.spec.workPath)) for @\(session.label); if they say yes, call trust_folder again with user_approved true"))
        }
        switch answer(session, .approve) {
        case .success:
            session.record(.note, "Folder trusted from your phone")
            return .success("trusted \(abbreviateHome(session.spec.workPath)) for @\(session.label)")
        case .failure(let error):
            return .failure(DelegationError(error.description))
        }
    }

    /// sign_in: starts the CLI's device-code sign-in and returns the link and code for the user's phone.
    func signInForSumi(_ session: TerminalSession, completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session) { return completion(.failure(refusal)) }
        guard case .needsInput(let reason) = session.state, reason.hasPrefix("Sign in to ") else {
            return completion(.failure(DelegationError("@\(session.label) isn't asking to sign in")))
        }
        session.signInWithDeviceCode { result in
            switch result {
            case .success(let instructions): completion(.success(instructions))
            case .failure(let error): completion(.failure(DelegationError(error.description)))
            }
        }
    }

    /// interrupt_agent: Esc, as a person presses to stop a turn or back out of a dialog; `hard` is
    /// Ctrl-C, for a command that ignores Esc. Once only: twice in a row quits Claude.
    func interruptForSumi(_ session: TerminalSession, hard: Bool, userRequested: Bool = false,
                          completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session, userRequested: userRequested) { return completion(.failure(refusal)) }
        guard !session.isAsleep else { return completion(.failure(DelegationError("@\(session.label) is asleep; nothing to stop"))) }
        if case .exited = session.state { return completion(.failure(DelegationError("@\(session.label) has exited; restart_agent it"))) }
        pressAsUser(session, [hard ? "ctrl-c" : "esc"]) { after in
            session.record(.note, hard ? "Stopped by Sumi (Ctrl-C)" : "Interrupted by Sumi")
            completion(.success("interrupted @\(session.label)\n\(after)"))
        }
    }

    // MARK: - Sumi at the keyboard

    /// press_keys: any keys, as the user would press them, then what the screen shows. A risky
    /// permission request on screen still needs the user's yes, as answer_prompt does.
    func pressKeysForSumi(_ session: TerminalSession, keys: [String], userApproved: Bool,
                          completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session) { return completion(.failure(refusal)) }
        guard !keys.isEmpty, keys.count <= 40 else { return completion(.failure(DelegationError("pass 1–40 keys"))) }
        let unknown = keys.filter { NamedKey($0) == nil }
        guard unknown.isEmpty else {
            return completion(.failure(DelegationError("unknown key names: \(unknown.joined(separator: ", ")). Use enter, esc, tab, shift-tab, space, backspace, up, down, left, right, home, end, pageup, pagedown, a letter or digit, or ctrl-/shift-/alt- with one of those")))
        }
        if let refusal = riskyOnScreen(session, approving: true, userApproved: userApproved) { return completion(.failure(refusal)) }
        pressAsUser(session, keys) { after in
            session.record(.note, "Sumi pressed " + keys.joined(separator: " "))
            completion(.success("pressed \(keys.joined(separator: " ")) on @\(session.label)\n\(after)"))
        }
    }

    /// type_text: types into the agent as the user would, without "Message from @sumi": a free-text
    /// answer, a slash command, or a draft left for the user (submit false).
    func typeForSumi(_ session: TerminalSession, text: String, submit: Bool, userApproved: Bool = false,
                     completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session) { return completion(.failure(refusal)) }
        let text = sanitizeMessage(text)
        guard !text.isEmpty else { return completion(.failure(DelegationError("text is empty"))) }
        // Claude runs "!…" as a shell command with no permission check; typed into a dialog, text
        // can answer it. Both get the same yes from the user a risky request does.
        if text.hasPrefix("!"), !userApproved {
            return completion(.failure(DelegationError("\"!\" runs a shell command in @\(session.label) without a permission check: ask the user on their phone; if they say yes, call again with user_approved true")))
        }
        if session.dialogOnScreen, let refusal = riskyOnScreen(session, approving: true, userApproved: userApproved) {
            return completion(.failure(refusal))
        }
        if case .exited = session.state { return completion(.failure(DelegationError("@\(session.label) has exited; restart_agent it"))) }
        if session.isAsleep || session.state == .starting {
            return completion(.success(session.deliver(text, submit: submit, from: nil)))
        }
        session.typeAsUser(text, submit: submit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            session.record(.note, "Sumi typed: " + String(text.prefix(80)))
            completion(.success("typed into @\(session.label)\n\(Self.screenTail(session))"))
        }
    }

    /// restart_agent: quits and relaunches the agent on the same conversation.
    func restartForSumi(_ session: TerminalSession, userRequested: Bool = false) -> Result<String, DelegationError> {
        if let refusal = sumiMayAct(on: session, userRequested: userRequested) { return .failure(refusal) }
        session.restart()
        session.record(.note, "Restarted by Sumi")
        return .success("restarting @\(session.label) on the same conversation")
    }

    /// set_mode: Claude cycles modes with Shift-Tab, so Sumi presses it until the footer shows the
    /// mode, as the user would. A mode the cycle doesn't offer (bypass, when Claude didn't start
    /// with it) and Codex, whose mode is a launch flag, relaunch on the same conversation.
    func setModeForSumi(_ session: TerminalSession, mode: PermissionMode, userApproved: Bool = false,
                        completion: @escaping (Result<String, DelegationError>) -> Void) {
        if let refusal = sumiMayAct(on: session) { return completion(.failure(refusal)) }
        // Full Access stops every permission prompt for the rest of the session: the user's call.
        guard mode != .fullAccess || userApproved else {
            return completion(.failure(DelegationError("Full Access means @\(session.label) never asks again: ask the user; if they say yes, call again with user_approved true")))
        }
        var options = session.spec.options ?? AgentOptions()
        options.mode = mode
        session.spec.options = options
        func relaunch() {
            session.restart()
            session.record(.note, "Sumi switched to \(mode.title) (relaunched)")
            completion(.success("@\(session.label) relaunches in \(mode.title) on the same conversation"))
        }
        guard session.kind == .claude, !session.isAsleep, !session.dialogOnScreen,
              PromptScreen.showsClaudePrompt(session.surface.readViewport()) else { return relaunch() }
        func step(_ left: Int) {
            if PromptScreen.claudeMode(session.surface.readViewport()) == mode {
                session.record(.note, "Sumi switched to \(mode.title)")
                return completion(.success("@\(session.label) is in \(mode.title)"))
            }
            guard left > 0 else { return relaunch() }
            _ = session.surface.pressKey(named: "shift-tab")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { step(left - 1) }
        }
        step(6)
    }

    /// Presses keys a beat apart, as fingers do: TUIs drop or merge keys sent in one burst. A held
    /// permission hook is let go first, so the CLI's own dialog is the one the keys land on.
    private func pressAsUser(_ session: TerminalSession, _ keys: [String], then done: @escaping (String) -> Void) {
        let held = approvals[session.id] != nil
        if held { dropApproval(for: session) }
        func press(_ index: Int) {
            guard index < keys.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done(Self.screenTail(session)) }
                return
            }
            _ = session.surface.pressKey(named: keys[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { press(index + 1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (held ? 0.4 : 0)) { press(0) }
    }

    /// What Sumi sees after acting: the bottom of the screen, so it needn't read_terminal again.
    static func screenTail(_ session: TerminalSession) -> String {
        let lines = session.surface.readViewport().split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let shown = lines.reversed().drop(while: \.isEmpty).reversed().suffix(20)
        return "screen now:\n" + shown.joined(separator: "\n")
    }

    /// The risky-request guard for keys: approving a risky permission request needs the user's yes.
    private func riskyOnScreen(_ session: TerminalSession, approving: Bool, userApproved: Bool) -> DelegationError? {
        guard approving, !userApproved, case .needsInput(let waiting) = session.state else { return nil }
        let approval = approvals[session.id]
        let request = approval?.request ?? session.pendingRequest ?? waiting
        guard let why = RiskyRequest.reason(tool: approval?.toolName, request: request, workspace: session.spec.workPath) else { return nil }
        return DelegationError("@\(session.label) is asking about \(why) (\(approval?.summary ?? waiting)): ask the user on their phone; if they say yes, call again with user_approved true")
    }

    /// The normal needs-you, for a wait Sumi didn't take or left.
    private func notifyUserOfWait(_ session: TerminalSession) {
        guard case .needsInput(let reason) = session.state else { return }
        if !userIsLooking(at: session) { session.unread = true }
        guard notifiesUser else { return }
        notifier.post(session: session, title: "@\(session.label) needs you", body: reason, foreground: true)
        if let approval = approvals[session.id] {
            notifier.postApproval(session: session, request: approval.summary, alwaysRule: alwaysRuleText(for: session))
        }
    }

    /// The reason, plus the pending request when it says more, kept short for the digest.
    func waitDescription(_ session: TerminalSession, reason: String) -> String {
        var text = reason
        if let request = approvals[session.id]?.request ?? session.pendingRequest, !reason.contains(request) {
            text += " · request: " + (request.count > 300 ? String(request.prefix(299)) + "…" : request)
        }
        if let question = session.pendingQuestion, question.mode == .options {
            let item = question.items[0]
            text += " · question: " + item.question + " · options: "
                + item.options.enumerated().map { "\($0 + 1). \($1.label)" }.joined(separator: "; ")
                + " (choose_option)"
        } else if reason == TerminalSession.trustReason {
            text += " · folder: \(abbreviateHome(session.spec.workPath)) (trust_folder once the user says yes)"
        } else if reason == TerminalSession.startupScreenReason {
            text += " (read_terminal it and tell the user what it asks; answer with choose_option or press_keys)"
        } else if reason.hasPrefix("Sign in to ") {
            text += " (sign_in gets a link and code for the user's phone)"
        } else if approvals[session.id] != nil || session.pendingRequest == reason {
            text += " (answer_prompt)"
            if let precedent = approvalPrecedent(session) { text += " · " + precedent }
        }
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func scheduleDelegationSweep(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0) + 0.5) { [weak self] in
            self?.sweepDelegations()
        }
    }
}

struct DelegationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
