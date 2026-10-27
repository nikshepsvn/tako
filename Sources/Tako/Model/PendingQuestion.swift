import Foundation

/// What an agent asked with AskUserQuestion, from the tool's input (`questions[]`), so the sidebar
/// card can show the real options instead of Allow / Deny.
struct PendingQuestion: Equatable {
    struct Option: Equatable {
        var label: String
        var description: String?
    }

    struct Item: Equatable {
        var question: String
        var header: String?
        var options: [Option]
        var multiSelect: Bool
    }

    /// Empty when the payload was missing or malformed: the card then only offers the terminal.
    var items: [Item]

    /// Read off the screen (Codex's sign-in menu) rather than from a hook. Such menus pick an
    /// option by its number, not by walking the cursor to it.
    var selectsByNumber = false

    /// How the card should present this question.
    enum Mode: Equatable {
        /// One single-select question: its options are buttons that press keys.
        case options
        /// Several questions, or a multi-select one: the terminal drives these reliably, the card
        /// shows the text and a button to open it.
        case terminalOnly
        /// Nothing usable in the payload.
        case unavailable
    }

    var mode: Mode {
        guard let only = items.first else { return .unavailable }
        return items.count == 1 && !only.multiSelect && !only.options.isEmpty ? .options : .terminalOnly
    }

    /// Reads `tool_input` of an AskUserQuestion call. Items without question text are dropped;
    /// options without a label are dropped.
    static func parse(toolInput input: [String: Any]) -> PendingQuestion {
        let raw = input["questions"] as? [[String: Any]] ?? []
        let items: [Item] = raw.compactMap { entry in
            guard let question = (entry["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty else { return nil }
            let options: [Option] = (entry["options"] as? [[String: Any]] ?? []).compactMap { option in
                guard let label = (option["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
                let description = (option["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Option(label: label, description: description?.isEmpty == false ? description : nil)
            }
            return Item(question: question, header: entry["header"] as? String,
                        options: options, multiSelect: entry["multiSelect"] as? Bool ?? false)
        }
        return PendingQuestion(items: items)
    }

    /// The keys that pick option `index` (0-based) of a single-select question in the CLI's list,
    /// where the cursor starts on the first option: arrow down that many times, then enter.
    static func keys(forOption index: Int) -> [String] {
        Array(repeating: "down", count: max(0, index)) + ["enter"]
    }

    /// The keys that pick option `index` (0-based) of this question: its number for a menu read off
    /// the screen, the arrow walk otherwise.
    func keysToPick(option index: Int) -> [String] {
        selectsByNumber ? [String(index + 1)] : Self.keys(forOption: index)
    }

    /// A single-select question from a numbered menu on screen: each "1. Label" line is an option,
    /// and the line under it, when it isn't another option, is its description. Only the run
    /// numbered 1, 2, 3… counts, so option `i` is the one picked by pressing `i + 1`.
    static func fromScreen(_ screen: String, question: String) -> PendingQuestion {
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var options: [Option] = []
        for (index, line) in lines.enumerated() {
            guard let parsed = PromptScreen.options(line).first, parsed.number == options.count + 1 else { continue }
            var description: String?
            if index + 1 < lines.count, PromptScreen.options(lines[index + 1]).isEmpty {
                let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
                description = next.isEmpty ? nil : next
            }
            options.append(Option(label: parsed.text, description: description))
        }
        return PendingQuestion(items: [Item(question: question, header: nil, options: options, multiSelect: false)], selectsByNumber: true)
    }
}
