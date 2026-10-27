import Foundation

/// Writes commit messages and pull request descriptions from a diff, using the Claude Code (or
/// Codex) CLI the user already has, in a one-shot non-interactive call. Nothing leaves the
/// machine that the user's own agent wouldn't send anyway. Blocks; run it off the main thread.
enum CommitWriter {
    struct PullRequest: Equatable {
        var title: String
        var body: String
    }

    /// Largest diff sent; a longer one is cut, which still gives the gist.
    private static let diffBudget = 60_000

    static func commitMessage(diff: String, context: String?, at path: String) -> String? {
        let prompt = """
        Write a Git commit message for the diff on stdin. Follow the repository's existing style \
        if the recent log below shows one. Otherwise use a short imperative subject line \
        (at most 72 characters), then a blank line and a brief body only if the change needs \
        explaining. Reply with the message only: no quotes, no code fences, no commentary.

        Recent log:
        \(recentLog(at: path))
        \(context.map { "\nWhat the agent was asked to do: \($0)" } ?? "")
        """
        return clean(run(prompt: prompt, input: String(diff.prefix(diffBudget)), at: path))
    }

    static func pullRequest(diff: String, context: String?, at path: String) -> PullRequest? {
        let prompt = """
        Write a pull request for the diff on stdin. The first line is the title (at most 72 \
        characters, no prefix like "Title:"). After a blank line comes the description in \
        Markdown: a short summary of what changed and why, then a "Testing" section if the diff \
        shows tests. Reply with the title and description only.
        \(context.map { "\nWhat the agent was asked to do: \($0)" } ?? "")
        """
        guard let text = clean(run(prompt: prompt, input: String(diff.prefix(diffBudget)), at: path)) else { return nil }
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = lines.first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "# ")) } ?? ""
        guard !title.isEmpty else { return nil }
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return PullRequest(title: String(title.prefix(120)), body: body.isEmpty ? "Opened from Tako." : body)
    }

    private static func recentLog(at path: String) -> String {
        Git.run(["log", "--format=%s", "-n", "8"], at: path) ?? ""
    }

    /// Strips fences and quotes models sometimes add despite being asked not to.
    static func clean(_ text: String?) -> String? {
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("```") {
            text = text.split(separator: "\n").dropFirst().filter { !$0.hasPrefix("```") }.joined(separator: "\n")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`").union(.whitespacesAndNewlines))
        return text.isEmpty ? nil : text
    }

    /// Runs the first available CLI through a login shell so the user's PATH applies, with
    /// Tako's own wrappers taken off PATH so no hooks or MCP servers attach.
    private static func run(prompt: String, input: String, at path: String) -> String? {
        let strip = #"PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/.hyperterm/bin$' | paste -sd: -); export PATH;"#
        let quotedPrompt = "'" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        \(strip)
        if command -v claude >/dev/null 2>&1; then
          exec claude -p --model haiku --output-format text \(quotedPrompt)
        elif command -v codex >/dev/null 2>&1; then
          exec codex exec --skip-git-repo-check "$(printf '%s\n\nDiff:\n' \(quotedPrompt); cat)"
        else
          exit 127
        fi
        """
        let process = Process()
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        // Interactive login shell: PATH set in .zshrc (nvm, the ~/.claude/local alias) applies.
        process.arguments = ["-lic", script]
        process.currentDirectoryURL = URL(fileURLWithPath: path)
        var environment = ProcessInfo.processInfo.environment
        // Never inherit a session's identity: this isn't a Tako terminal.
        for key in ["HT_SESSION_ID", "HT_LABEL", "HT_SOCKET", "HT_CHANNELS"] { environment[key] = nil }
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: killer)
        // A CLI that exits without reading all of stdin (none installed, a failed sign-in, the
        // timeout) must not take the app down: no SIGPIPE, and a write error is just ignored.
        let writer = stdin.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(input.utf8))
            try? writer.close()
        }
        // Read on another thread with a deadline: a helper the CLI spawned can keep the pipe open
        // after the CLI itself is gone, and that must not hang the caller.
        let output = Output()
        let reader = stdout.fileHandleForReading
        DispatchQueue.global().async {
            output.finish(reader.readDataToEndOfFile())
        }
        guard output.done.wait(timeout: .now() + 95) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.data, as: UTF8.self)
    }

    private final class Output: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private(set) var data = Data()

        func finish(_ data: Data) {
            self.data = data
            done.signal()
        }
    }
}
