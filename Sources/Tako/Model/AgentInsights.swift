import Foundation

/// One line in an agent's activity history, built from hooks. Powers the timeline and the
/// "since you left" recap.
struct TimelineEvent: Identifiable, Equatable {
    enum Kind: String { case prompt, tool, edit, approval, test, done, failure, message, note }
    let id = UUID()
    let date: Date
    let kind: Kind
    let text: String
}

/// Claude statusLine telemetry for one session.
struct UsageSnapshot: Equatable {
    var costUSD: Double?
    var contextPercent: Double?
    var model: String?
    var limits: RateLimits?
}

/// Account-wide rate-limit windows (shared by every agent on the account).
struct RateLimits: Equatable, Codable {
    var fiveHourPercent: Double?
    var fiveHourResets: Date?
    var sevenDayPercent: Double?
    var sevenDayResets: Date?

    var highest: Double { max(fiveHourPercent ?? 0, sevenDayPercent ?? 0) }

    /// A saved reading as of `now`: a window that has reset since is back to zero.
    func current(at now: Date = Date()) -> RateLimits {
        var limits = self
        if let reset = fiveHourResets, reset <= now { limits.fiveHourPercent = 0; limits.fiveHourResets = nil }
        if let reset = sevenDayResets, reset <= now { limits.sevenDayPercent = 0; limits.sevenDayResets = nil }
        return limits
    }
}

/// Claude's own todo list, from TaskCreated/TaskCompleted hooks.
struct TaskProgress: Equatable {
    var subjects: [String: String] = [:]
    var completed: Set<String> = []
    var order: [String] = []

    var total: Int { order.count }
    var done: Int { completed.count }
    var current: String? { order.first { !completed.contains($0) }.flatMap { subjects[$0] } }
}

/// A Claude subagent still running, from SubagentStart; SubagentStop removes it.
struct Subagent: Equatable {
    /// "Explore", "general-purpose", or a custom agent's name.
    var type: String
    var startedAt: Date
}

/// The last test run an agent did, from PostToolUse / PostToolUseFailure on test commands.
struct TestEvidence: Equatable {
    var passed: Bool
    var summary: String
    var date: Date
}

/// Size of an agent's uncommitted plus branch changes.
struct DiffStat: Equatable {
    var added: Int
    var removed: Int
    var files: Int

    var isEmpty: Bool { files == 0 }
    var text: String { "+\(added) −\(removed) · \(files) file\(files == 1 ? "" : "s")" }
}

enum PromptAnswer: String { case approve, always, deny }

/// A PermissionRequest hook held open until someone decides.
struct PendingApproval {
    let id = UUID()
    let source: String
    let toolName: String
    let summary: String
    /// The whole request (full command, absolute path), which Sumi's guard checks.
    var request = ""
    let suggestions: Any?
    let createdAt = Date()
    let reply: ControlServer.Reply
}

enum TestCommand {
    /// Programs that are test runners by themselves.
    private static let runners: Set<String> = ["pytest", "py.test", "jest", "vitest", "mocha", "phpunit", "rspec", "unittest", "ctest"]
    /// Tools whose `test` subcommand runs the tests.
    private static let testSubcommand: Set<String> = ["go", "cargo", "swift", "npm", "pnpm", "yarn", "bun", "make",
                                                      "gradle", "gradlew", "mvn", "mvnw", "dotnet", "deno", "mix", "rails",
                                                      "rake", "flutter", "dart", "bazel", "playwright", "manage.py"]
    /// Tools that start another program: `npx vitest`, `pnpm jest`, `python -m pytest`, `bundle exec rspec`.
    private static let launchers: Set<String> = ["npx", "pnpx", "bunx", "npm", "pnpm", "yarn", "bun", "python", "python3", "bundle", "uv", "poetry"]
    /// Flags (lowercased) whose value is the next word: `make -C dir test`, `pnpm --filter x test`.
    private static let valueFlags: Set<String> = ["-c", "-f", "--filter", "--prefix", "--cwd", "--dir", "-w", "--workspace"]

    /// Whether any command in a shell line runs tests. Matches runner programs, not the word
    /// "test" anywhere: `ls tests/`, `grep test` and `git commit -m "add tests"` aren't test runs.
    static func matches(_ command: String) -> Bool {
        segments(command.lowercased()).contains(where: runsTests)
    }

    private static func runsTests(_ segment: [String]) -> Bool {
        // Past `FOO=1`, `sudo`, `env`, `time` and `timeout 600`; `./node_modules/.bin/jest` is `jest`.
        var words = segment.drop {
            $0.contains("=") || $0.first?.isNumber == true
                || ["sudo", "env", "time", "command", "timeout", "nice", "nohup"].contains($0)
        }
        guard let first = words.popFirst() else { return false }
        let program = (first as NSString).lastPathComponent
        // `bash -c "npm test"`: the quoted command is one word.
        if ["bash", "sh", "zsh"].contains(program), words.first == "-c", let script = words.dropFirst().first {
            return matches(script)
        }
        if runners.contains(program) { return true }
        if program == "xcodebuild", words.contains(where: { $0 == "test" || $0 == "test-without-building" }) { return true }
        // Past flags before the subcommand: `pnpm -r test`, `make -C dir test`, `yarn workspace a test`.
        while let word = words.first, word.hasPrefix("-") || (program == "yarn" && word == "workspace") {
            words = words.dropFirst()
            if valueFlags.contains(word) || word == "workspace" { words = words.dropFirst() }
        }
        let next = words.first ?? ""
        if testSubcommand.contains(program), next == "test" || next.hasPrefix("test:") { return true }
        if program == "npm", next == "t" { return true }
        if ["npm", "pnpm", "yarn", "bun"].contains(program), next == "run", words.dropFirst().first?.hasPrefix("test") == true { return true }
        if program == "cargo", next == "nextest" { return true }
        // `npx playwright test`, `python -m unittest`, `python manage.py test`, `bundle exec rake test`.
        if launchers.contains(program) {
            if ["exec", "x", "dlx", "run"].contains(next) { words = words.dropFirst() }
            return runsTests(Array(words))
        }
        return false
    }

    /// The words of each command in a shell line, split at `;`, `&&`, `||`, `|`, `&` and newlines
    /// outside quotes. Quotes are dropped; parentheses and braces around a subshell too.
    private static func segments(_ line: String) -> [[String]] {
        var result: [[String]] = [], words: [String] = [], word = ""
        var quote: Character?
        func endWord() { if !word.isEmpty { words.append(word); word = "" } }
        func endSegment() { endWord(); if !words.isEmpty { result.append(words); words = [] } }
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ";" || character == "&" || character == "|" || character == "\n" {
                endSegment()
            } else if character.isWhitespace || "(){}".contains(character) {
                endWord()
            } else {
                word.append(character)
            }
        }
        endSegment()
        return result
    }

    /// "48 passed", "3 failed, 45 passed", "Tests: 2 failed" — the line a human would look for.
    static func summary(from output: String, passed: Bool) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let keywords = ["passed", "failed", "failing", "passing", "tests", "error"]
        if let line = lines.reversed().first(where: { line in keywords.contains { line.lowercased().contains($0) } && line.count < 140 }) {
            return line
        }
        return passed ? "tests passed" : "tests failed"
    }
}
