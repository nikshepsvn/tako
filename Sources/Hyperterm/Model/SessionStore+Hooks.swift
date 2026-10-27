import AppKit

/// Turning agent hook events and statusLine reports into session state.
extension SessionStore {
    /// Payloads can be large (PostToolUse carries whole tool output), so they're parsed on a
    /// serial background queue and applied on main in arrival order.
    private nonisolated static let parseQueue = DispatchQueue(label: "dev.hyperterm.hook-parse", qos: .userInitiated)

    private func parseOffMain(_ payload: String, then apply: @escaping @MainActor ([String: Any]) -> Void) {
        Self.parseQueue.async {
            nonisolated(unsafe) let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any]
            DispatchQueue.main.async {
                MainActor.assumeIsolated { apply(json ?? [:]) }
            }
        }
    }

    /// A hook event from `ht hook` (traced to its session by the kernel).
    func handleHook(source: String, session: TerminalSession, payload: String, sentAt: UInt64?) {
        let id = session.id.uuidString
        Self.parseQueue.async {
            nonisolated(unsafe) let json = Self.parseHook(source: source, sessionID: id, payload: Data(payload.utf8))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self, weak session] in
                    guard let self, let session, self.sessions.contains(where: { $0 === session }) else { return }
                    self.applyHook(source: source, session: session, json: json, sentAt: sentAt)
                }
            }
        }
    }

    /// A hook event from the HTTP listener (authorized for `sessionID`); only the store update
    /// runs on main.
    nonisolated func receiveHook(source: String, sessionID: String, payload: Data, sentAt: UInt64) {
        Self.parseQueue.async {
            nonisolated(unsafe) let json = Self.parseHook(source: source, sessionID: sessionID, payload: payload)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, let session = self.session(forEnvironmentID: sessionID) else { return }
                    self.applyHook(source: source, session: session, json: json, sentAt: sentAt)
                }
            }
        }
    }

    /// Parses a hook payload, minus tool output Tako doesn't use, and logs one line for it.
    /// Runs on `parseQueue`.
    nonisolated private static func parseHook(source: String, sessionID: String, payload: Data) -> [String: Any] {
        var json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] ?? [:]
        _ = dropUnusedToolOutput(&json)
        HookLog.append(source: source, sessionID: sessionID, json: json, bytes: payload.count)
        return json
    }

    /// PostToolUse carries the tool's whole output; only Bash's is read (test evidence).
    /// Returns whether anything was dropped.
    nonisolated static func dropUnusedToolOutput(_ json: inout [String: Any]) -> Bool {
        guard ["PostToolUse", "PostToolUseFailure"].contains(json["hook_event_name"] as? String ?? ""),
              json["tool_name"] as? String != "Bash", json["tool_response"] != nil else { return false }
        json["tool_response"] = nil
        return true
    }

    func applyHook(source: String, session: TerminalSession, json: [String: Any], sentAt: UInt64?) {
        // The wrapper, not Codex, reports its app-server before Codex is up: no hook has fired
        // yet as far as the trust and sign-in screens are concerned.
        if source == CodexAppServer.source { return attachCodexAppServer(session, json: json) }
        // Hook processes race each other to the socket; an event stamped before the newest one
        // already applied is stale and must not roll state back.
        if let sentAt {
            guard sentAt >= session.lastHookSentAt else { return }
            session.lastHookSentAt = sentAt
        }
        session.lastHookAt = Date()
        switch source {
        case "claude":
            handleAgentHook(session, json, source: "claude hook")
        case "codex":
            session.reportsTurnsByHook = true
            followCodexThread(session, json: json)
            handleAgentHook(session, json, source: "codex hook")
        case "codex-notify":
            session.recordAgentSessionId(json["thread-id"] as? String)
            refreshUsage(session)
            // Its hooks already reported the turn; notify stands in only when hooks are off.
            if session.reportsTurnsByHook { return }
            if let last = json["last-assistant-message"] as? String {
                session.summary = summarize(last)
                session.record(.done, summarize(last) ?? "Turn complete")
            }
            session.apply(.codexTurnComplete, source: "codex notify")
            checkpoint(session, phase: .end, prompt: "")
            refreshReview(session)
        default:
            break
        }
    }

    /// Claude Code's hooks, and Codex's, which share their names and fields.
    private func handleAgentHook(_ session: TerminalSession, _ json: [String: Any], source: String) {
        let event = json["hook_event_name"] as? String ?? ""
        let cwd = json["cwd"] as? String
        var question: PendingQuestion?
        // Only conversations with at least one prompt can be resumed.
        if ["UserPromptSubmit", "Stop", "PostToolUse"].contains(event) {
            session.recordAgentSessionId(json["session_id"] as? String)
        }
        // A tool running alongside the one held for approval (Claude runs read-only tools in
        // parallel, subagents run their own) says nothing about the dialog, which is still up.
        // So does the held call's own PreToolUse, which can arrive after its PermissionRequest.
        let toolEvent = ["PreToolUse", "PostToolUse", "PostToolUseFailure"].contains(event)
        let held = toolEvent && session.hasHookApproval ? session.heldToolCall : nil
        let parallelTool = held.map { $0.matches(json) ? event == "PreToolUse" : $0.runsAlongside(json) } ?? false
        // A tool call moving on means a prompt held open was answered in the terminal itself.
        if !parallelTool, held != nil || ["PostToolUse", "PostToolUseFailure", "Stop", "StopFailure", "UserPromptSubmit"].contains(event) {
            // A turn ending or a new prompt means nothing in line is still waiting either.
            if ["Stop", "StopFailure", "UserPromptSubmit"].contains(event) { dropAllApprovals(for: session) } else { dropApproval(for: session) }
            session.pendingQuestion = nil
        }

        switch event {
        case "UserPromptSubmit":
            let prompt = json["prompt"] as? String
            // Another agent's message, or a wrapper the harness injected (a channel push, a task
            // notification), isn't the user's turn: no checkpoint, and the card keeps its summary.
            session.turnIsMessage = !(prompt.map(PromptOrigin.init) ?? .user).isUser
            // A turn already opened before the hooks could report it isn't opened twice.
            if !session.turnIsMessage && !session.turnOpenedByGuess { checkpoint(session, phase: .start, prompt: prompt ?? "Turn") }
            session.turnOpenedByGuess = false
            if let prompt {
                if session.turnIsMessage {
                    session.record(.message, summarize(PromptOrigin.describe(prompt)) ?? prompt)
                } else {
                    session.summary = summarize(prompt).map { "› " + $0 }
                    session.record(.prompt, summarize(prompt, limit: 200) ?? prompt)
                }
            }
            session.readyForReview = false
            session.agentStatus = nil
        case "PreToolUse":
            if let tool = json["tool_name"] as? String {
                let input = json["tool_input"] as? [String: Any] ?? [:]
                let text = AgentText.describeTool(name: tool, input: input, cwd: cwd)
                session.activity = text
                if !parallelTool {
                    session.pendingRequest = text
                    question = tool == "AskUserQuestion" ? PendingQuestion.parse(toolInput: input) : nil
                    session.pendingQuestion = question
                }
                let isEdit = ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"].contains(tool)
                if tool != "Read" && tool != "Glob" && tool != "Grep" { session.record(isEdit ? .edit : .tool, text) }
            }
        case "PostToolUse", "PostToolUseFailure":
            recordTestEvidence(session, json, failed: event == "PostToolUseFailure")
        case "Stop":
            session.activity = nil
            if !session.turnIsMessage { checkpoint(session, phase: .end, prompt: "") }
            if let last = json["last_assistant_message"] as? String {
                session.summary = summarize(last)
                session.record(.done, summarize(last, limit: 200) ?? "Turn complete")
            }
            refreshReview(session)
        case "StopFailure":
            session.activity = nil
            let reason = failureReason(type: json["error"] as? String, details: json["error_details"] as? String, limits: limits(for: session))
            session.record(.failure, reason)
            session.apply(.claudeHook(event: event, notificationType: nil, message: reason), source: source)
            return
        case "SessionEnd":
            session.activity = nil
            // /clear and resume end one conversation but keep the agent running; the process
            // poll decides when the agent really exited.
            return
        case "TaskCreated":
            if let id = json["task_id"] as? String {
                session.tasks.subjects[id] = json["task_subject"] as? String ?? "Task"
                if !session.tasks.order.contains(id) { session.tasks.order.append(id) }
            }
            return
        case "TaskCompleted":
            if let id = json["task_id"] as? String { session.tasks.completed.insert(id) }
            return
        case "SubagentStart":
            if let id = json["agent_id"] as? String {
                session.runningSubagents[id] = Subagent(type: json["agent_type"] as? String ?? "", startedAt: Date())
            }
            session.record(.note, "Started subagent \(json["agent_type"] as? String ?? "")")
            return
        case "SubagentStop":
            guard let id = json["agent_id"] as? String, session.runningSubagents.removeValue(forKey: id) != nil else { return }
            session.record(.note, "Subagent finished \(json["agent_type"] as? String ?? "")")
            // The last background subagent finishing after the turn ended is when the work is done.
            if session.runningSubagents.isEmpty, session.state == .idle {
                reportToSumi(session, from: .working)
                markFinished(session)
                agentToolsStateChanged(session)
                onStatusChange?()
            }
            return
        case "Notification":
            // With a PermissionRequest hook waiting, its request is the precise one.
            if session.hasHookApproval { return }
        default:
            break
        }

        // The held request keeps the session waiting on the user.
        if parallelTool { return }
        let notificationType = json["notification_type"] as? String
        let message = json["message"] as? String
        let detail = notificationType == "permission_prompt" ? (session.pendingRequest ?? message) : message
        let keepRequest = session.pendingRequest
        session.apply(.claudeHook(event: event, notificationType: notificationType, message: detail), source: source)
        if session.state.needsAttention { session.pendingRequest = keepRequest }
        // A state change away from the wait clears the question; this one is still being asked.
        if let question { session.pendingQuestion = question }
    }

    private func recordTestEvidence(_ session: TerminalSession, _ json: [String: Any], failed: Bool) {
        guard json["tool_name"] as? String == "Bash",
              let command = (json["tool_input"] as? [String: Any])?["command"] as? String,
              TestCommand.matches(command) else { return }
        // Claude reports {stdout, stderr}; Codex the output as one string.
        let response = json["tool_response"] as? [String: Any]
        let output = [response?["stdout"] as? String, response?["stderr"] as? String, json["tool_response"] as? String, json["error"] as? String]
            .compactMap { $0 }.joined(separator: "\n")
        let summary = TestCommand.summary(from: output, passed: !failed)
        session.testEvidence = TestEvidence(passed: !failed, summary: summary, date: Date())
        session.record(.test, (failed ? "Tests failing: " : "Tests passed: ") + summary)
    }

    /// StopFailure's error type, in words, with the reset time when it's a rate limit.
    private func failureReason(type: String?, details: String?, limits: RateLimits?) -> String {
        switch type {
        case "rate_limit":
            if let resets = limits?.fiveHourResets ?? limits?.sevenDayResets {
                return "Rate-limited · resets \(resets.formatted(date: .omitted, time: .shortened))"
            }
            return "Rate-limited"
        case "overloaded": return "API overloaded · try again shortly"
        case "billing_error": return "Billing error · check your plan"
        case "authentication_failed", "oauth_org_not_allowed": return "Authentication failed · run /login"
        case "max_output_tokens": return "Hit the output token limit"
        case "server_error": return "API server error"
        default: return summarize(details ?? type ?? "") ?? "Turn ended with an error"
        }
    }

    /// After a turn: recompute the diff and mark the agent ready for review when it changed files.
    func refreshReview(_ session: TerminalSession) {
        let path = session.spec.workPath
        let base = session.spec.baseBranch
        DispatchQueue.global(qos: .utility).async {
            let stat = Review.diffStat(at: path, base: base)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    session.diffStat = stat
                    if let stat, !stat.isEmpty, session.state == .idle { session.readyForReview = true }
                }
            }
        }
    }

    // MARK: - statusLine

    func handleStatusLine(session: TerminalSession, payload: String) {
        parseOffMain(payload) { [weak self, weak session] json in
            guard let self, let session, !json.isEmpty else { return }
            self.applyStatusLine(session: session, json: json)
        }
    }

    private func applyStatusLine(session: TerminalSession, json: [String: Any]) {
        var usage = session.usage
        usage.costUSD = (json["cost"] as? [String: Any])?["total_cost_usd"] as? Double
        usage.contextPercent = (json["context_window"] as? [String: Any])?["used_percentage"] as? Double
        usage.model = (json["model"] as? [String: Any])?["display_name"] as? String
        if let limits = json["rate_limits"] as? [String: Any] {
            func window(_ key: String) -> (Double?, Date?) {
                let entry = limits[key] as? [String: Any]
                let reset = (entry?["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                return (entry?["used_percentage"] as? Double, reset)
            }
            let five = window("five_hour"), seven = window("seven_day")
            let parsed = RateLimits(fiveHourPercent: five.0, fiveHourResets: five.1, sevenDayPercent: seven.0, sevenDayResets: seven.1)
            usage.limits = parsed
            if rateLimits != parsed { rateLimits = parsed }
            recordLimits(parsed, for: session)
        }
        if session.usage != usage { session.usage = usage }
    }

    private func recordLimits(_ limits: RateLimits, for session: TerminalSession) {
        let key = limitsKey(for: session)
        if accountLimits[key] != limits {
            accountLimits[key] = limits
            saveUsage()
        }
    }

    // MARK: - Usage from the session log

    /// Reads the turn's usage from the CLI's session log (Codex), off the main thread.
    func refreshUsage(_ session: TerminalSession) {
        guard let adapter = session.kind.adapter, let thread = session.spec.agentSessionId else { return }
        let root = (AccountStore.shared.account(session.spec.account, kind: session.kind)
            ?? AgentAccount(id: AgentAccount.defaultID, kind: session.kind, name: "Default")).homeDirectory
        Self.parseQueue.async {
            let reading = adapter.usage(id: thread, root: root)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self, weak session] in
                    guard let self, let session, let reading else { return }
                    self.applyCodexUsage(reading, to: session)
                }
            }
        }
    }

    private func applyCodexUsage(_ reading: CodexUsage.Reading, to session: TerminalSession) {
        var usage = session.usage
        usage.contextPercent = reading.contextPercent ?? usage.contextPercent
        if let limits = reading.limits {
            usage.limits = limits
            if codexRateLimits != limits { codexRateLimits = limits }
            recordLimits(limits, for: session)
            if reading.limitReached {
                let resets = [limits.fiveHourResets, limits.sevenDayResets].compactMap { $0 }.filter { $0 > Date() }.min()
                let text = "Rate-limited" + (resets.map { " · resets \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                    + " · Move to Account to continue"
                session.summary = text
                session.record(.failure, text)
            }
        }
        if session.usage != usage { session.usage = usage }
    }
}
