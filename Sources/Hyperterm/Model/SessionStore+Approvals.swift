import AppKit

/// PermissionRequest hooks held open until the user decides, answered through the CLI's own
/// decision API (no keystrokes). Prompts without a waiting hook fall back to pressing the
/// dialog's numbered option.
extension SessionStore {
    func registerApproval(for session: TerminalSession, source: String, payload: String, reply: @escaping ControlServer.Reply) {
        let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
        let tool = json["tool_name"] as? String ?? "tool"
        if session.isSumi, Self.sumiTools.contains(tool) {
            let approval = PendingApproval(source: source, toolName: tool, summary: tool, suggestions: nil, reply: reply)
            reply(ControlResponse.success(text: decisionJSON(approval, .approve, reason: nil)))
            return
        }
        // Behind its app-server, Codex asks there next about a command, and Tako answers that
        // request in kind. Other tools (MCP calls) still go through the hook.
        if source == "codex", tool == "Bash", approvesOverAppServer(session, thread: json["session_id"] as? String) {
            reply(ControlResponse.success())
            return
        }
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let summary = AgentText.describeTool(name: tool, input: input, cwd: json["cwd"] as? String)
        let approval = PendingApproval(source: source, toolName: tool, summary: summary,
                                       request: RiskyRequest.text(tool: tool, input: input),
                                       suggestions: json["permission_suggestions"], reply: reply)
        if approvesInPhoneMode(session, approval) {
            reply(ControlResponse.success(text: decisionJSON(approval, .approve, reason: nil)))
            session.record(.approval, "Allowed \(summary) (Phone Mode)")
            return
        }
        // One held at a time; a second waits its turn instead of pushing the first out of Tako.
        if approvals[session.id] != nil {
            queuedApprovals[session.id, default: []].append((approval, json))
            session.record(.approval, "Also asked to run \(summary) (next in line)")
            let id = approval.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 540) { [weak self] in
                guard let self, var queue = self.queuedApprovals[session.id],
                      let index = queue.firstIndex(where: { $0.approval.id == id }) else { return }
                queue.remove(at: index).approval.reply(ControlResponse.success())
                self.queuedApprovals[session.id] = queue.isEmpty ? nil : queue
            }
            return
        }
        hold(approval, json: json, for: session)
    }

    private func hold(_ approval: PendingApproval, json: [String: Any], for session: TerminalSession) {
        let tool = approval.toolName
        let summary = approval.summary
        let input = json["tool_input"] as? [String: Any] ?? [:]
        approvals[session.id] = approval
        session.hasHookApproval = true
        session.heldToolCall = HeldToolCall(json: json)
        // Plan mode ends by asking to exit it; the plan is the request.
        session.pendingPlan = tool == "ExitPlanMode" ? (json["tool_input"] as? [String: Any])?["plan"] as? String : nil
        session.pendingRequest = summary
        if tool == "AskUserQuestion" { session.pendingQuestion = PendingQuestion.parse(toolInput: input) }
        session.record(.approval, "Asked to run \(summary)")
        session.apply(.claudeHook(event: "Notification", notificationType: "permission_prompt", message: summary),
                      source: "permission hook", force: .needsInput(summary))
        // Sumi was told instead; the user gets this banner if it doesn't answer.
        if session.delegation?.toldAt == nil {
            notifier.postApproval(session: session, request: summary, alwaysRule: alwaysRuleText(approval))
        }
        // Leave headroom under the hook's 600 s timeout so the CLI's own prompt takes over cleanly.
        // Counted from when the hook started: one that waited in line has less left.
        let id = approval.id
        let left = max(5, 540 - Date().timeIntervalSince(approval.createdAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak self, weak session] in
            guard let self, let session, self.approvals[session.id]?.id == id else { return }
            self.dropApproval(for: session)
        }
    }

    /// Answers whatever `session` is waiting on: a held hook if there is one, else its dialog.
    func answer(_ session: TerminalSession, _ answer: PromptAnswer, reason: String? = nil) -> Result<String, TerminalSession.PromptError> {
        guard let approval = approvals.removeValue(forKey: session.id) else {
            return session.answerPromptByKeys(answer)
        }
        session.hasHookApproval = false
        session.heldToolCall = nil
        session.pendingPlan = nil
        learnAnswer(session, approval: approval, answer: answer)
        approval.reply(ControlResponse.success(text: decisionJSON(approval, answer, reason: reason)))
        session.record(.approval, answer == .deny ? "Denied \(approval.summary)" : answer == .always ? "Always allowed \(approval.summary)" : "Allowed \(approval.summary)")
        session.apply(.userSubmitted, source: "approval", force: .working)
        notifier.clearApproval(session: session)
        return .success(answer == .deny ? "denied" : "approved")
    }

    /// Answers a single-select question by picking its option in the CLI's own list. A held
    /// permission hook is released first so the CLI's list is the thing on screen; the keys follow
    /// once it has drawn.
    func answerQuestion(_ session: TerminalSession, option index: Int, completion: @escaping (Result<String, TerminalSession.PromptError>) -> Void) {
        guard approvals[session.id] != nil else { return completion(session.answerQuestionByKeys(option: index)) }
        dropApproval(for: session)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak session] in
            guard let session else { return }
            completion(session.answerQuestionByKeys(option: index))
        }
    }

    /// Releases a held hook with no decision, so the CLI's own prompt (or its outcome) stands.
    /// The next request in line, if any, is held once the CLI has moved on from this one.
    func dropApproval(for session: TerminalSession) {
        guard let approval = approvals.removeValue(forKey: session.id) else { return }
        session.hasHookApproval = false
        session.heldToolCall = nil
        session.pendingPlan = nil
        approval.reply(ControlResponse.success())
        notifier.clearApproval(session: session)
        holdNextApproval(for: session)
    }

    /// Releases every request held or in line: the agent is restarting or closing.
    func dropAllApprovals(for session: TerminalSession) {
        queuedApprovals.removeValue(forKey: session.id)?.forEach { $0.approval.reply(ControlResponse.success()) }
        dropApproval(for: session)
    }

    /// After a beat, so keys meant for the dialog just released land there first.
    private func holdNextApproval(for session: TerminalSession) {
        guard queuedApprovals[session.id]?.isEmpty == false else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak session] in
            guard let self, let session, self.approvals[session.id] == nil,
                  var queue = self.queuedApprovals[session.id], !queue.isEmpty else { return }
            let next = queue.removeFirst()
            self.queuedApprovals[session.id] = queue.isEmpty ? nil : queue
            self.hold(next.approval, json: next.json, for: session)
        }
    }

    func alwaysRuleText(for session: TerminalSession) -> String? {
        approvals[session.id].flatMap(alwaysRuleText)
    }

    private func alwaysRuleText(_ approval: PendingApproval) -> String? {
        guard let suggestions = approval.suggestions as? [[String: Any]] else { return nil }
        for suggestion in suggestions where suggestion["type"] as? String == "addRules" {
            if let rule = (suggestion["rules"] as? [[String: Any]])?.first, let tool = rule["toolName"] as? String {
                let content = rule["ruleContent"] as? String
                return content.map { "\(tool)(\($0))" } ?? tool
            }
        }
        return nil
    }

    private func decisionJSON(_ approval: PendingApproval, _ answer: PromptAnswer, reason: String?) -> String {
        var decision: [String: Any]
        switch answer {
        case .approve:
            decision = ["behavior": "allow"]
        case .always:
            decision = ["behavior": "allow"]
            // Claude persists the rule it suggested, and Codex's app-server takes the decision it
            // offered for "always"; Codex's hook rejects permission updates.
            if approval.source == "claude" || approval.source == CodexAppServer.source, let suggestions = approval.suggestions as? [[String: Any]], !suggestions.isEmpty {
                decision["updatedPermissions"] = suggestions
            }
        case .deny:
            decision = ["behavior": "deny", "message": reason.map(sanitizeMessage) ?? "The user denied this in Tako."]
        }
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        let data = (try? JSONSerialization.data(withJSONObject: output)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The tool call a held PermissionRequest hook asks about. Claude runs read-only tools alongside
/// the one waiting for approval, so only this call's own PostToolUse means it moved on.
struct HeldToolCall {
    let name: String
    let toolUseID: String?
    let input: NSDictionary
    /// The subagent that asked; nil for the main agent.
    let agentID: String?

    init(json: [String: Any]) {
        name = json["tool_name"] as? String ?? ""
        toolUseID = json["tool_use_id"] as? String
        input = NSDictionary(dictionary: json["tool_input"] as? [String: Any] ?? [:])
        agentID = json["agent_id"] as? String
    }

    /// Whether a tool hook payload reports this call: by tool_use_id when both carry one, else by
    /// tool name and input. The permission flow can add to the input (AskUserQuestion's answers),
    /// so every key held must be there unchanged; extra keys are fine. A payload naming no tool
    /// can't be told apart, so it counts.
    func matches(_ json: [String: Any]) -> Bool {
        if let toolUseID, let other = json["tool_use_id"] as? String { return toolUseID == other }
        guard let tool = json["tool_name"] as? String else { return true }
        let other = NSDictionary(dictionary: json["tool_input"] as? [String: Any] ?? [:])
        return tool == name && input.allSatisfy { key, value in (value as AnyObject).isEqual(other[key]) }
    }

    /// Whether another tool call can run while this one waits: a read-only tool Claude runs in
    /// parallel, or any tool from a different agent. Anything else from the same agent means this
    /// call was settled (allowed, denied or answered) and the agent moved on.
    func runsAlongside(_ json: [String: Any]) -> Bool {
        if json["agent_id"] as? String != agentID { return true }
        guard let tool = json["tool_name"] as? String else { return false }
        return Self.readOnlyTools.contains(tool) || ClaudeAdapter.browserReadOnlyTools.contains { "mcp__browser__" + $0 == tool }
    }

    private static let readOnlyTools: Set = [
        "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch", "NotebookRead", "TodoRead", "TodoWrite", "ToolSearch",
    ]
}
