import Foundation

/// An agent's conversation as plain text, from the CLI's own transcript. Fullscreen TUIs keep
/// only one screen in the terminal, so reads that ask for more reach back through this.
/// Both formats are internal to the CLIs: unknown or unparseable lines are skipped.
enum AgentTranscript {
    static let separator = "── screen ──"

    /// The conversation's tail followed by the screen, in at most `lines` lines. The screen comes
    /// first: the conversation only fills the room it leaves.
    static func compose(conversation: [String], screen: String, lines: Int) -> String {
        let shown = screen.split(separator: "\n", omittingEmptySubsequences: false)
        let room = lines - shown.count - 1
        guard room > 0, !conversation.isEmpty else { return screen }
        return (Array(conversation.suffix(room)) + [separator] + shown.map(String.init)).joined(separator: "\n")
    }

    /// Rendered lines from the end of the conversation's transcript; empty when it can't be found.
    static func conversation(kind: SessionKind, id: String, cwds: [String], root: URL) -> [String] {
        guard isSafeIdentifier(id), let adapter = kind.adapter else { return [] }
        return adapter.transcriptFile(id: id, cwds: cwds, root: root)
            .flatMap { CodexUsage.tail(of: $0, bytes: 512 * 1024) }.map(adapter.renderTranscript) ?? []
    }

    /// `projects/<cwd with non-alphanumerics as '-'>/<id>.jsonl`, else any project holding the id
    /// (worktrees, and long paths Claude shortens).
    static func claudeFile(session: String, cwds: [String], root: URL) -> URL? {
        let fm = FileManager.default
        let projects = root.appendingPathComponent("projects", isDirectory: true)
        for cwd in cwds {
            let file = projects.appendingPathComponent(projectFolder(cwd)).appendingPathComponent("\(session).jsonl")
            if fm.fileExists(atPath: file.path) { return file }
        }
        for folder in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let file = projects.appendingPathComponent(folder).appendingPathComponent("\(session).jsonl")
            if fm.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    static func projectFolder(_ cwd: String) -> String {
        String(cwd.unicodeScalars.map { $0.isASCII && CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" })
    }

    // MARK: - Claude

    /// Prompts as `› text`, replies as written, tool calls as one `[tool]` line. Tool results,
    /// thinking, meta and subagent lines are left out.
    static func renderClaude(_ text: Substring) -> [String] {
        var out: [String] = []
        for json in records(text) where json["isSidechain"] as? Bool != true && json["isMeta"] as? Bool != true {
            guard let message = json["message"] as? [String: Any] else { continue }
            let content = message["content"]
            switch json["type"] as? String {
            case "user":
                if let string = content as? String {
                    out += prompt(string)
                } else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    out += prompt(blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n"))
                }
            case "assistant":
                if let string = content as? String { out += reply(string) }
                for block in content as? [[String: Any]] ?? [] {
                    switch block["type"] as? String {
                    case "text": out += reply(block["text"] as? String ?? "")
                    case "tool_use": out.append(tool(block["name"] as? String, block["input"]))
                    default: break
                    }
                }
            default: break
            }
        }
        return out
    }

    // MARK: - Codex

    /// User and agent messages come from the `event_msg` records; older logs without them fall
    /// back to the `response_item` messages, minus the injected context blocks.
    static func renderCodex(_ text: Substring) -> [String] {
        var out: [(line: String, fallback: Bool)] = []
        var hasEvents = false
        for json in records(text) {
            guard let payload = json["payload"] as? [String: Any] else { continue }
            switch (json["type"] as? String, payload["type"] as? String) {
            case ("event_msg", "user_message"):
                hasEvents = true
                out += prompt(payload["message"] as? String ?? "").map { ($0, false) }
            case ("event_msg", "agent_message"):
                hasEvents = true
                out += reply(payload["message"] as? String ?? "").map { ($0, false) }
            case ("event_msg", "item_completed"):
                // Codex 0.160: messages arrive as completed items instead.
                let item = payload["item"] as? [String: Any] ?? [:]
                let text = (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                switch item["type"] as? String {
                case "UserMessage":
                    hasEvents = true
                    out += prompt(text).map { ($0, false) }
                case "AgentMessage":
                    hasEvents = true
                    out += reply(text).map { ($0, false) }
                default: break
                }
            case ("response_item", "message"):
                let text = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                switch payload["role"] as? String {
                case "user" where !text.hasPrefix("<"): out += prompt(text).map { ($0, true) }
                case "assistant": out += reply(text).map { ($0, true) }
                default: break
                }
            case ("response_item", "function_call"):
                let arguments = (payload["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
                out.append((tool(payload["name"] as? String, arguments ?? payload["arguments"]), false))
            case ("response_item", "custom_tool_call"):
                out.append((tool(payload["name"] as? String, payload["input"]), false))
            case ("response_item", "local_shell_call"):
                out.append((tool("shell", (payload["action"] as? [String: Any])?["command"]), false))
            default: break
            }
        }
        return out.filter { !(hasEvents && $0.fallback) }.map(\.line)
    }

    // MARK: - Rendering

    private static func records(_ text: Substring) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    private static func prompt(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Slash commands and their output are recorded as tagged user lines.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<command-"), !trimmed.hasPrefix("<local-command-") else { return [] }
        return trimmed.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { ($0.offset == 0 ? "› " : "  ") + $0.element }
    }

    private static func reply(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// `[tool] Name: <the input's most telling field>`, on one line.
    static func tool(_ name: String?, _ input: Any?) -> String {
        let head = "[tool] \(name ?? "?")"
        var summary: String?
        if let input = input as? [String: Any] {
            let keys = ["command", "cmd", "file_path", "path", "pattern", "url", "query", "description", "prompt"]
            let key = keys.first { input[$0] != nil } ?? input.keys.sorted().first { input[$0] is String }
            summary = key.flatMap { flatten(input[$0]) }
        } else {
            summary = flatten(input)
        }
        guard let summary, !summary.isEmpty else { return head }
        return "\(head): " + (summary.count > 120 ? String(summary.prefix(119)) + "…" : summary)
    }

    private static func flatten(_ value: Any?) -> String? {
        let text: String
        switch value {
        case let string as String: text = string
        case let parts as [String]: text = parts.joined(separator: " ")
        default: return nil
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
