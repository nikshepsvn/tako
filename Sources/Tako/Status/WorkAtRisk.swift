import Foundation

/// What closing or archiving an agent's worktree would put at risk: files that aren't committed
/// and commits that aren't in the base branch yet. Measured against the base branch (not the
/// moment the worktree was made), so work that already landed, squash-merged included, never
/// counts. Calls block; run them off the main thread.
struct WorkAtRisk: Equatable {
    var uncommitted: Int
    var unmerged: Int
    /// No base branch to compare with (it was deleted, and there's no main or master) and HEAD
    /// has commits no other branch or remote has, so
    /// `unmerged` is 0 only because nothing could be counted. Never treat that as safe.
    var baseUnknown = false

    var isEmpty: Bool { uncommitted == 0 && unmerged == 0 && !baseUnknown }

    /// "3 files aren't committed", "1 commit isn't in main yet", or both joined.
    func headline(base: String?) -> String {
        var parts: [String] = []
        if uncommitted > 0 { parts.append("\(uncommitted) file\(uncommitted == 1 ? " isn't" : "s aren't") committed") }
        if unmerged > 0 { parts.append("\(unmerged) commit\(unmerged == 1 ? " isn't" : "s aren't") in \(base ?? "the base branch") yet") }
        if baseUnknown { parts.append("its commits couldn't be compared with \(base.map { "\($0), which is gone" } ?? "a base branch")") }
        let text = parts.joined(separator: " and ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Nil when git can't tell (no such folder, not a repository).
    static func evaluate(at path: String, base: String?) -> WorkAtRisk? {
        guard FileManager.default.fileExists(atPath: path),
              let status = runGit(["-C", path, "status", "--porcelain"]) else { return nil }
        let uncommitted = status.split(separator: "\n").count
        return WorkAtRisk(uncommitted: uncommitted, unmerged: unmergedCommits(at: path, base: base),
                          baseUnknown: resolvedBase(at: path, base) == nil && !headIsElsewhere(at: path))
    }

    /// Whether another branch or a remote already has every commit on HEAD, so removing this
    /// worktree's branch loses nothing even without a base to compare with.
    private static func headIsElsewhere(at path: String) -> Bool {
        guard let refs = runGit(["-C", path, "for-each-ref", "--contains", "HEAD", "--format=%(refname)",
                                 "refs/heads", "refs/remotes"]) else { return false }
        let own = runGit(["-C", path, "symbolic-ref", "-q", "HEAD"])
        return refs.split(separator: "\n").contains { String($0) != own }
    }

    /// Commits on HEAD that the base doesn't have. `git cherry` skips ones the base has under
    /// another hash (cherry-picks, rebases). A squash merge leaves no matching commits, so a
    /// branch whose merge into the base would change nothing counts as landed.
    static func unmergedCommits(at path: String, base: String?) -> Int {
        guard let base = resolvedBase(at: path, base) else { return 0 }
        let cherry = runGit(["-C", path, "cherry", base, "HEAD"]) ?? ""
        let ahead = cherry.split(separator: "\n").filter { $0.hasPrefix("+") }.count
        guard ahead > 0 else { return 0 }
        if let merged = runGit(["-C", path, "merge-tree", "--write-tree", "--no-messages", base, "HEAD"])?
            .split(separator: "\n").first,
           let baseTree = runGit(["-C", path, "rev-parse", "\(base)^{tree}"]),
           String(merged) == baseTree {
            return 0
        }
        return ahead
    }

    /// The base to compare with: the one the agent was started from, else main or master.
    private static func resolvedBase(at path: String, _ base: String?) -> String? {
        for candidate in [base, "main", "master"].compactMap({ $0 }) where
            runGit(["-C", path, "rev-parse", "--verify", "--quiet", "refs/heads/\(candidate)"]) != nil {
            return candidate
        }
        return nil
    }
}
