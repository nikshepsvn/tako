import Foundation

/// Human-readable lines from agent hook payloads and terminal screens.
enum AgentText {
    /// "Bash: pnpm test", "Edit: src/auth/refresh.ts", "hyperterm: send_message".
    static func describeTool(name: String, input: [String: Any], cwd: String?) -> String {
        func path(_ key: String) -> String? {
            guard let raw = input[key] as? String else { return nil }
            if let cwd, raw.hasPrefix(cwd + "/") { return String(raw.dropFirst(cwd.count + 1)) }
            return abbreviateHome(raw)
        }
        func firstLine(_ text: String?) -> String? {
            text?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        let detail: String?
        switch name {
        case "Bash": detail = firstLine(input["command"] as? String)
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit": detail = path("file_path") ?? path("notebook_path")
        case "Grep", "Glob": detail = input["pattern"] as? String
        case "WebFetch": detail = (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch": detail = input["query"] as? String
        case "Task", "Agent": detail = input["description"] as? String
        default: detail = nil
        }
        let label: String
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            label = parts.count >= 3 ? "\(parts[1]): \(parts.dropFirst(2).joined(separator: "_"))" : name
        } else {
            label = name
        }
        guard let detail, !detail.isEmpty else { return label }
        return "\(label): \(detail.count > 120 ? String(detail.prefix(119)) + "…" : detail)"
    }

    private static let chromeMarkers = [
        "? for shortcuts", "shift+tab", "auto mode", "manual mode", "bypass permissions", "accept edits",
        "/effort", "ctx ", "esc to interrupt", "Tip:", "← ", "context left", "⏵⏵", "⏸",
        "needs authentication", "Claude Code v", "Claude Max", "Claude Pro", "Try \"",
    ]

    /// The last few meaningful lines of an agent's screen, skipping its input box and footer.
    static func preview(from screen: String, limit: Int = 3) -> [String] {
        var lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        // Claude draws its prompt between two ─── rules; everything below the upper rule is chrome.
        let rules = lines.indices.filter { isRule(lines[$0]) }
        if rules.count >= 2 { lines = Array(lines[..<rules[rules.count - 2]]) }
        let kept = lines.filter { line in
            guard !line.isEmpty, !isRule(line) else { return false }
            if line.hasPrefix("❯") || line.hasPrefix("›") && line.count < 3 { return false }
            if isArt(line) { return false }
            return !chromeMarkers.contains { line.contains($0) }
        }
        return Array(kept.suffix(limit)).map { $0.count > 160 ? String($0.prefix(159)) + "…" : $0 }
    }

    /// Logo art made of block elements (U+2580–259F).
    private static func isArt(_ line: String) -> Bool {
        let blocks = line.unicodeScalars.filter { (0x2580...0x259F).contains($0.value) }.count
        return blocks >= 3
    }

    private static func isRule(_ line: String) -> Bool {
        let boxChars = line.filter { "─━═╌┄-".contains($0) }.count
        return boxChars >= 20 && Double(boxChars) / Double(max(line.count, 1)) > 0.6
    }
}
