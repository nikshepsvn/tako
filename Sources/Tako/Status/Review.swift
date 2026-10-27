import Foundation

/// Git facts and actions behind the review queue. All calls block; run them off the main thread.
enum Review {
    struct FileDiff: Identifiable, Equatable {
        var id: String { path }
        let path: String
        let added: Int
        let removed: Int
        let patch: String
    }

    /// The commit the agent's work is measured against: the merge-base with its base branch for
    /// worktrees, otherwise HEAD (uncommitted changes only).
    static func baseCommit(at path: String, base: String?) -> String? {
        if let base, base != "HEAD", let mergeBase = runGit(["-C", path, "merge-base", "HEAD", base]), !mergeBase.isEmpty { return mergeBase }
        return runGit(["-C", path, "rev-parse", "HEAD"])
    }

    static func diffStat(at path: String, base: String?) -> DiffStat? {
        guard FileManager.default.fileExists(atPath: path), let commit = baseCommit(at: path, base: base) else { return nil }
        let numstat = runGit(["-C", path, "diff", "--numstat", commit]) ?? ""
        var added = 0, removed = 0, files = 0
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t")
            guard parts.count >= 3 else { continue }
            added += Int(parts[0]) ?? 0
            removed += Int(parts[1]) ?? 0
            files += 1
        }
        let untracked = untrackedFiles(at: path)
        files += untracked.count
        added += untrackedLines(untracked, at: path)
        return DiffStat(added: added, removed: removed, files: files)
    }

    /// Lines in new files, for the ~10 s poll: only the first `maxFiles` files under `maxBytes`
    /// are read; the rest still count as added files, with 0 lines.
    static func untrackedLines(_ files: [String], at path: String, maxFiles: Int = 50, maxBytes: Int = 256 * 1024) -> Int {
        files.prefix(maxFiles).reduce(0) { total, file in
            total + lineCount((path as NSString).appendingPathComponent(file), maxBytes: maxBytes)
        }
    }

    /// What a diff is measured against.
    enum Scope: Hashable {
        /// Everything since the branch left its base (or since HEAD outside a worktree).
        case branch
        /// Only what isn't committed yet.
        case uncommitted
        /// One turn, between two checkpoints (`to` nil: up to the live workspace).
        case turn(from: String, to: String?)
    }

    static func fileDiffs(at path: String, base: String?, scope: Scope = .branch, ignoreWhitespace: Bool = false) -> [FileDiff] {
        if case .turn(let from, let to) = scope {
            return files(fromPatch: Checkpoints.diff(at: path, from: from, to: to, ignoreWhitespace: ignoreWhitespace))
        }
        let commit = scope == .uncommitted ? runGit(["-C", path, "rev-parse", "HEAD"]) : baseCommit(at: path, base: base)
        guard let commit else { return [] }
        // Renames off: each side is its own file, so every numstat path names a real file.
        var diff = ["-c", "core.quotePath=false", "-C", path, "diff", "--no-renames"]
        if ignoreWhitespace { diff.append("-w") }
        let numstat = runGit(diff + ["--numstat", commit]) ?? ""
        // One process for every patch, split per file, instead of one `git diff` per file.
        let patches = splitPatch(runGit(diff + [commit]) ?? "")
        var result: [FileDiff] = numstat.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { return nil }
            let file = String(parts[2])
            let patch = patches[file] ?? runGit(diff + [commit, "--", file]) ?? ""
            return FileDiff(path: file, added: Int(parts[0]) ?? 0, removed: Int(parts[1]) ?? 0, patch: patch)
        }
        for file in untrackedFiles(at: path).prefix(200) {
            let full = (path as NSString).appendingPathComponent(file)
            let size = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int ?? 0
            let content = size > 1_000_000 ? "(file too large to show)"
                : (try? String(contentsOfFile: full, encoding: .utf8)) ?? "(binary or unreadable file)"
            // A final newline ends the last line; it doesn't start another (as `lineCount` counts).
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }
            if content.isEmpty || content.hasSuffix("\n") { lines.removeLast() }
            result.append(FileDiff(path: file, added: lines.count, removed: 0, patch: "new file\n@@ -0,0 +1,\(lines.count) @@\n" + lines.joined(separator: "\n")))
        }
        return result
    }

    /// Per-file diffs from one multi-file patch, counting lines as Git's numstat would.
    static func files(fromPatch patch: String) -> [FileDiff] {
        splitPatch(patch).map { path, text in
            var added = 0, removed = 0
            // Lines still to come in the current hunk: inside one, a removed "---" or an added
            // "+++" is content, not a file header.
            var oldLeft = 0, newLeft = 0
            // Empty lines are kept: with `diff.suppressBlankEmpty` a blank context line is "".
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                // No content line starts with "@@", so a hunk header always starts a new hunk.
                if line.hasPrefix("@@"), let lengths = hunkLengths(line) {
                    oldLeft = lengths.old
                    newLeft = lengths.new
                } else if oldLeft > 0 || newLeft > 0 {
                    if line.hasPrefix("+") { added += 1; newLeft -= 1 }
                    else if line.hasPrefix("-") { removed += 1; oldLeft -= 1 }
                    else if !line.hasPrefix("\\") { oldLeft -= 1; newLeft -= 1 }
                }
            }
            return FileDiff(path: path, added: added, removed: removed, patch: text)
        }
        .sorted { $0.path < $1.path }
    }

    /// "@@ -a,b +c,d @@" → (b, d), the old and new lines the hunk spans (a missing count is 1).
    static func hunkLengths(_ header: Substring) -> (old: Int, new: Int)? {
        let fields = header.split(separator: " ")
        guard fields.count >= 3, fields[0] == "@@", fields[1].hasPrefix("-"), fields[2].hasPrefix("+") else { return nil }
        func length(_ field: Substring) -> Int? {
            let parts = field.dropFirst().split(separator: ",", omittingEmptySubsequences: false)
            guard let start = parts.first, Int(start) != nil else { return nil }
            return parts.count > 1 ? Int(parts[1]) : 1
        }
        guard let old = length(fields[1]), let new = length(fields[2]) else { return nil }
        return (old, new)
    }

    /// The whole diff as text, for writing commit messages and PR descriptions.
    static func patchText(at path: String, base: String?, scope: Scope) -> String {
        fileDiffs(at: path, base: base, scope: scope).map(\.patch).joined(separator: "\n")
    }

    /// Pushes the current branch, setting its upstream the first time.
    static func push(at path: String) -> Result<String, ReviewError> {
        guard let branch = currentBranch(at: path), branch != "HEAD" else { return .failure(.git("not on a branch")) }
        guard runGit(["-C", path, "push", "-u", "origin", branch]) != nil else {
            return .failure(.git("git push failed (is there an origin remote?)"))
        }
        return .success("pushed \(branch)")
    }

    /// Splits a multi-file unified diff into per-file patches keyed by path. A path git had to
    /// quote (tabs, newlines, quotes) is left out; callers fall back to diffing that file alone.
    static func splitPatch(_ patch: String) -> [String: String] {
        var result: [String: String] = [:]
        var current: [Substring] = []
        func flush() {
            guard !current.isEmpty else { return }
            defer { current = [] }
            guard let file = headerPath(current[0]), !file.hasPrefix("\"") else { return }
            result[file] = current.joined(separator: "\n")
        }
        for line in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { flush() }
            current.append(line)
        }
        flush()
        return result
    }

    /// "diff --git a/P b/P" → P. Without renames both sides are the same path, which makes the
    /// split unambiguous even when P contains " b/". Covers binary and mode-only entries, which
    /// have no ---/+++ lines.
    private static func headerPath(_ line: Substring) -> String? {
        let rest = line.dropFirst("diff --git ".count)
        guard rest.hasPrefix("a/"), (rest.count - 5) % 2 == 0, rest.count > 5 else { return nil }
        let length = (rest.count - 5) / 2
        let path = rest.dropFirst(2).prefix(length)
        guard rest.dropFirst(2 + length) == " b/" + path else { return nil }
        return String(path)
    }

    static func currentBranch(at path: String) -> String? {
        runGit(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"])
    }

    /// Commits everything in the workspace. Returns the short hash.
    static func commit(at path: String, message: String) -> Result<String, ReviewError> {
        guard runGit(["-C", path, "add", "-A"]) != nil else { return .failure(.git("git add failed")) }
        guard commitStaged(at: path, message: message) else {
            return .failure(.git("nothing to commit, or git commit failed"))
        }
        return .success(runGit(["-C", path, "rev-parse", "--short", "HEAD"]) ?? "")
    }

    /// Pushes the branch and opens a PR with `gh`. Returns the PR URL.
    static func openPullRequest(at path: String, base: String?, title: String,
                                body: String = "Opened from Tako.") -> Result<String, ReviewError> {
        guard let branch = currentBranch(at: path), branch != "HEAD" else { return .failure(.git("not on a branch")) }
        guard runGit(["-C", path, "push", "-u", "origin", branch]) != nil else { return .failure(.git("git push failed (is there an origin remote?)")) }
        let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let gh else { return .failure(.git("GitHub CLI (gh) not found")) }
        var args = ["pr", "create", "--title", title, "--body", body, "--head", branch]
        if let base { args += ["--base", base] }
        guard let url = runProcess(gh, args, timeout: 60, environment: ProcessInfo.processInfo.environment.merging(["GIT_DIR": ""]) { a, _ in a }),
              let line = url.split(separator: "\n").last else {
            return .failure(.git("gh pr create failed"))
        }
        return .success(String(line))
    }

    /// Commits what's staged as the user, or, when Git has no identity for them, as Tako (the
    /// identity checkpoints use), so a machine without user.email can still commit.
    private static func commitStaged(at path: String, message: String) -> Bool {
        Git.run(["commit", "-m", message], at: path) != nil
            || Git.run(["commit", "-m", message], at: path, environment: Git.identity) != nil
    }

    /// Merges the agent's branch into its base in the main checkout. Refuses when the main
    /// checkout is on another branch or has uncommitted work.
    static func merge(branch: String, into base: String, mainRoot: String) -> Result<String, ReviewError> {
        // A detached HEAD isn't a branch: "merging into HEAD" would land on whatever is checked out.
        guard base != "HEAD" else { return .failure(.git("there's no base branch to merge into")) }
        guard currentBranch(at: mainRoot) == base else { return .failure(.git("the main checkout isn't on \(base)")) }
        guard (runGit(["-C", mainRoot, "status", "--porcelain"]) ?? "x").isEmpty else {
            return .failure(.git("the main checkout has uncommitted changes"))
        }
        guard runGit(["-C", mainRoot, "merge", "--no-ff", "-m", "Merge \(branch) (Tako)", branch]) != nil else {
            _ = runGit(["-C", mainRoot, "merge", "--abort"])
            return .failure(.git("merge conflicts; resolve them in the main checkout"))
        }
        return .success("merged \(branch) into \(base)")
    }

    /// Snapshots any work as a commit on the workspace branch, then removes the worktree. The
    /// branch stays, so nothing is lost. Git's own check stays on: no `--force`.
    static func archive(worktree path: String, mainRoot: String) -> Result<String, ReviewError> {
        if !(runGit(["-C", path, "status", "--porcelain"]) ?? "").isEmpty {
            // A failed snapshot stops here with the reason, instead of a vague "worktree remove failed".
            guard runGit(["-C", path, "add", "-A"]) != nil,
                  commitStaged(at: path, message: "Tako snapshot before archiving") else {
                return .failure(.git("couldn't commit the leftover work, so the worktree was kept"))
            }
        }
        let branch = currentBranch(at: path) ?? "?"
        // Claude locks its worktrees while a session uses them; a lock whose process is gone is
        // stale. A live session keeps its lock, and removal is refused.
        if let reason = lockReason(path: path, mainRoot: mainRoot) {
            if let pid = reason.split(separator: " ").firstIndex(of: "(pid").flatMap({ index -> Int32? in
                let parts = reason.split(separator: " ")
                return index + 1 < parts.count ? Int32(parts[index + 1]) : nil
            }), kill(pid, 0) == 0 {
                return .failure(.git("a Claude session (pid \(pid)) is still using this worktree"))
            }
            _ = runGit(["-C", mainRoot, "worktree", "unlock", path])
        }
        guard runGit(["-C", mainRoot, "worktree", "remove", path]) != nil else {
            return .failure(.git("git worktree remove failed"))
        }
        return .success("archived; work kept on branch \(branch)")
    }

    private static func lockReason(path: String, mainRoot: String) -> String? {
        let listing = runGit(["-C", mainRoot, "worktree", "list", "--porcelain"]) ?? ""
        // The whole line: "…/worktrees/api" is also a prefix of "…/worktrees/api-2".
        for block in listing.components(separatedBy: "\n\n") where block.split(separator: "\n").contains(Substring("worktree \(path)")) {
            if let line = block.split(separator: "\n").first(where: { $0.hasPrefix("locked") }) {
                return String(line.dropFirst("locked".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func mainRoot(of path: String) -> String? {
        runGit(["-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"]).map { ($0 as NSString).deletingLastPathComponent }
    }

    private static func untrackedFiles(at path: String) -> [String] {
        (runGit(["-C", path, "ls-files", "--others", "--exclude-standard"]) ?? "").split(separator: "\n").map(String.init)
    }

    private static func lineCount(_ file: String, maxBytes: Int) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: file))?[.size] as? Int ?? 0
        guard size > 0, size <= maxBytes, let data = FileManager.default.contents(atPath: file), !data.isEmpty else { return 0 }
        let newlines = data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        return data.last == 0x0A ? newlines : newlines + 1
    }
}

enum ReviewError: Error, CustomStringConvertible {
    case git(String)
    var description: String {
        switch self { case .git(let message): return message }
    }
}
