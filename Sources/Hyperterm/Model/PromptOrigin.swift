import Foundation

/// Who a submitted prompt came from. Claude Code reports every turn as UserPromptSubmit,
/// including ones the harness starts itself: a channel push from Tako, a background task
/// finishing, a message from another Claude session. Treating those as the user's own turns
/// took a checkpoint for each and replaced the card's summary with raw XML
/// (`› <channel source="hyperterm" …`), which then showed up on cards and in closed.json.
enum PromptOrigin: Equatable {
    /// Typed (or pasted) by the user.
    case user
    /// Typed by Tako on another agent's behalf ("Message from @…").
    case agent
    /// A wrapper the agent's harness injected; the tag name, e.g. "task-notification".
    case harness(String)

    /// Tags Claude Code and Codex wrap injected turns in. A user pasting such a tag first
    /// thing in a prompt is rare enough to accept; `<pasted_content>` is the user's own.
    static let harnessTags = [
        "channel", "task-notification", "cross-session-message", "system-reminder",
        "local-command-caveat", "local-command-stdout", "local-command-stderr", "bash-notification",
        "user-prompt-submit-hook", "agent-message",
    ]

    init(_ prompt: String) {
        let text = prompt.drop { $0.isWhitespace }
        if text.hasPrefix(agentMessagePrefix) { self = .agent; return }
        guard text.hasPrefix("<") else { self = .user; return }
        let name = text.dropFirst().prefix { $0.isLetter || $0 == "-" || $0 == "_" }
        let next = text.dropFirst(1 + name.count).first
        if Self.harnessTags.contains(String(name)), next == nil || next == ">" || next == " " || next == "\n" {
            self = .harness(String(name))
        } else {
            self = .user
        }
    }

    var isUser: Bool { self == .user }

    /// One readable line for the timeline: the wrapper's text without its markup.
    static func describe(_ prompt: String) -> String {
        guard case .harness(let tag) = PromptOrigin(prompt) else { return prompt }
        // A task notification's own summary says what finished.
        let inner = Self.element("summary", in: prompt) ?? prompt
        let text = inner.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let name = tag.replacingOccurrences(of: "-", with: " ")
        return text.isEmpty ? name : name + ": " + text
    }

    private static func element(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }
}
