import Foundation

/// Agents name a tool's target terminal however the last tool they used did: `label` for
/// read_terminal, `terminal` for send_message. A miss used to come back as "no terminal named
/// (none)", so every name an agent reaches for is read as the target.
let terminalArgumentAliases = ["terminal", "target", "to", "label", "name"]

/// Each tool that acts on one terminal, with the key its schema documents for it.
let terminalArgumentKey: [String: String] = {
    var keys = ["send_message": "to"]
    for tool in ["read_terminal", "restart_server", "close_terminal", "watch_terminal", "handle_waiting", "stop_handling",
                 "answer_prompt", "choose_option", "press_keys", "type_text", "set_mode", "restart_agent", "trust_folder",
                 "sign_in", "interrupt_agent", "wait_for", "agent_changes", "server_logs"] {
        keys[tool] = "terminal"
    }
    return keys
}()

/// Other arguments agents misname often enough to forgive: the new name for rename_terminal,
/// and a message's text.
private let otherAliases: [String: [String: [String]]] = [
    "rename_terminal": ["label": ["name", "new_label", "new_name", "to", "terminal"]],
    "send_message": ["message": ["text", "content", "body"]],
]

/// `arguments` with each documented key filled from an alias when the agent left it out. A key
/// that is present, even empty, is never overwritten. Tools without a target pass through,
/// since `label` or `name` mean something else there (start_agent's label, save_layout's name).
func normalizeToolArguments(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
    var result = arguments
    func fill(_ key: String, from aliases: [String]) {
        guard isBlank(result[key]) else { return }
        if let value = aliases.lazy.compactMap({ result[$0] }).first(where: { !isBlank($0) }) { result[key] = value }
    }
    if let key = terminalArgumentKey[tool] {
        fill(key, from: terminalArgumentAliases.filter { $0 != key })
    }
    for (key, aliases) in otherAliases[tool] ?? [:] { fill(key, from: aliases) }
    return result
}

private func isBlank(_ value: Any?) -> Bool {
    guard let value else { return true }
    if let text = value as? String { return text.trimmingCharacters(in: .whitespaces).isEmpty }
    return false
}

/// Claude Code defers MCP tools behind ToolSearch; agents spent hundreds of calls loading the
/// handful they use every turn. `_meta["anthropic/alwaysLoad"]` asks it to load these up front.
let alwaysLoadedWorkerTools: Set<String> = ["list_terminals", "send_message", "read_terminal", "set_status"]
let alwaysLoadedSumiTools: Set<String> = ["standup", "list_terminals", "read_terminal", "send_message", "start_agent"]

func markingAlwaysLoaded(_ tools: [[String: Any]], _ names: Set<String>) -> [[String: Any]] {
    tools.map { tool in
        guard let name = tool["name"] as? String, names.contains(name) else { return tool }
        var marked = tool
        var meta = tool["_meta"] as? [String: Any] ?? [:]
        meta["anthropic/alwaysLoad"] = true
        marked["_meta"] = meta
        return marked
    }
}
