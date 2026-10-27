import Foundation

/// A normalized observation about a session, from any signal source.
enum StatusEvent: Equatable {
    case userSubmitted
    case claudeHook(event: String, notificationType: String?, message: String?)
    case codexTurnComplete
    case terminalNotification(title: String, body: String)
    case registryStatus(String)
    case childExited(Int)
    case processStarted
}

/// Pure state transition. Evidence strength: hooks > terminal notifications > registry > keystrokes.
func reduceState(_ state: AgentState, kind: SessionKind, event: StatusEvent) -> AgentState {
    if case .childExited(let code) = event { return .exited(code) }
    if !kind.isAgent { return reduceProcessState(state, event: event) }

    switch event {
    case .processStarted:
        return state == .starting ? .idle : state
    case .userSubmitted:
        // A keystroke at a permission prompt answers it; either way the agent is now busy. An
        // exited agent's terminal is a plain shell, so Return there means nothing.
        if case .exited = state { return state }
        return .working
    case .claudeHook(let name, let type, let message):
        return reduceClaudeHook(state, name: name, notificationType: type, message: message)
    case .codexTurnComplete:
        return .idle
    case .terminalNotification(let title, let body):
        return reduceTerminalNotification(state, kind: kind, title: title, body: body)
    case .registryStatus(let status):
        return reduceRegistry(state, status: status)
    case .childExited:
        return state
    }
}

private func reduceProcessState(_ state: AgentState, event: StatusEvent) -> AgentState {
    switch event {
    case .processStarted, .userSubmitted: return .running
    default: return state == .starting ? .running : state
    }
}

private func reduceClaudeHook(_ state: AgentState, name: String, notificationType: String?, message: String?) -> AgentState {
    switch name {
    case "SessionStart":
        return state.needsAttention ? state : .idle
    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStop", "PreCompact":
        return .working
    case "Notification":
        // "Claude is waiting for your input" is the 60s idle reminder, not a blocking prompt.
        let text = (message ?? "").lowercased()
        let isIdleReminder = notificationType == "idle_prompt" || text.contains("waiting for your input")
        let isPrompt = ["permission_prompt", "agent_needs_input", "elicitation_dialog"].contains(notificationType ?? "")
            || (notificationType == nil && text.contains("permission"))
        if isPrompt && !isIdleReminder { return .needsInput(message ?? "Waiting for your approval") }
        if isIdleReminder { return state.needsAttention || state == .working ? state : .idle }
        return state
    case "Stop", "Interrupt":
        // Codex sends Interrupt when the user stops a turn (Esc); Claude sends nothing then.
        return .idle
    case "StopFailure":
        return .failed(message ?? "Turn ended with an API error")
    case "SessionEnd":
        // /clear and resume also end a conversation; the process poll decides real exits.
        return state
    default:
        return state
    }
}

/// Codex (tui.notification_method=osc9) and other CLIs emit OSC 9/777. Approval requests mean
/// the agent is blocked; anything else from an agent marks the end of a turn.
private func reduceTerminalNotification(_ state: AgentState, kind: SessionKind, title: String, body: String) -> AgentState {
    let text = (title + " " + body).lowercased()
    // Explicit approval phrasing only: an agent's reply can mention "permission" in passing.
    let approvalWords = ["approval requested", "needs your approval", "requires approval", "wants to run", "approve this", "allow command"]
    if approvalWords.contains(where: text.contains) {
        return .needsInput(body.isEmpty ? title : body)
    }
    // Claude's own notifications duplicate its hooks, which are more precise.
    if kind == .claude { return state }
    return .idle
}

/// ~/.claude/sessions/<pid>.json status is coarse but always present, so it only corrects drift:
/// a stale "working" when Claude reports idle, or missed activity.
private func reduceRegistry(_ state: AgentState, status: String) -> AgentState {
    switch (state, status) {
    case (.starting, "idle"): return .idle
    case (.starting, "busy"), (.idle, "busy"): return .working
    default: return state
    }
}

/// Claude rewrites its registry file on its own schedule, so a "busy" written before the newest
/// hook, or read within a few seconds of one (a Stop that just ended the turn), is older news
/// than the hook and must not reopen the turn.
func registryBusyIsStale(writtenAt: Date?, lastHookAt: Date, now: Date = Date()) -> Bool {
    if let writtenAt, writtenAt <= lastHookAt { return true }
    return now.timeIntervalSince(lastHookAt) < 3
}

/// First meaningful line of an agent's last message, used as the row summary.
func summarize(_ text: String, limit: Int = 140) -> String? {
    let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
    let lines = plain.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#*`>-• ")) }
        .filter { !$0.isEmpty }
    guard let first = lines.first else { return nil }
    return first.count > limit ? String(first.prefix(limit - 1)) + "…" : first
}

/// Terminal titles from agents carry spinner glyphs; keep the words.
func cleanTitle(_ title: String) -> String {
    let trimmed = title.trimmingCharacters(in: .whitespaces)
    let dropped = trimmed.drop { scalar in
        !(scalar.isLetter || scalar.isNumber || scalar == "~" || scalar == "/" || scalar == "@")
    }
    return String(dropped).trimmingCharacters(in: .whitespaces)
}
