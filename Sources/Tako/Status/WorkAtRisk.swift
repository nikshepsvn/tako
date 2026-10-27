import Foundation

/// What closing or archiving an agent's worktree would put at risk: files that aren't committed
/// and commits that exist nowhere else yet. Measured against the base branch, the repository's
/// default branch and the branch's own upstream (not the moment the worktree was made), so work
/// that already landed or was pushed, squash-merged included, never counts. Calls block; run
/// them off the main thread.
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
        if unmerged > 0 {
            let place = base.map { $0 == "main" || $0 == "master" ? $0 : "\($0) or the default branch" } ?? "the base branch"
            parts.append("\(unmerged) commit\(unmerged == 1 ? " isn't" : "s aren't") in \(place) or pushed yet")
        }
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
                          baseUnknown: safeRefs(at: path, base).isEmpty && !headIsElsewhere(at: path))
    }

    /// Whether another branch or a remote already has every commit on HEAD, so removing this
    /// worktree's branch loses nothing even without a base to compare with.
    private static func headIsElsewhere(at path: String) -> Bool {
        guard let refs = runGit(["-C", path, "for-each-ref", "--contains", "HEAD", "--format=%(refname)",
                                 "refs/heads", "refs/remotes"]) else { return false }
        let own = runGit(["-C", path, "symbolic-ref", "-q", "HEAD"])
        return refs.split(separator: "\n").contains { String($0) != own }
    }

    /// Commits on HEAD that exist nowhere else: not in the recorded base, not in the default
    /// branch, and not pushed to the branch's own upstream. The recorded base is only what the
    /// main checkout happened to be on when the agent started, so work that landed on main, or
    /// was pushed for review, must not count just because that stale branch lacks it. Only a
    /// commit every safe ref lacks is at risk.
    static func unmergedCommits(at path: String, base: String?) -> Int {
        var onlyHere: Set<Substring>?
        for ref in safeRefs(at: path, base) {
            let missing = commitsMissing(from: ref, at: path)
            onlyHere = onlyHere.map { $0.intersection(missing) } ?? missing
            if onlyHere?.isEmpty == true { return 0 }
        }
        return onlyHere?.count ?? 0
    }

    /// HEAD's commits `ref` lacks, by hash. `git cherry` skips ones `ref` has under another hash
    /// (cherry-picks, rebases). A squash merge leaves no matching commits, so a branch whose
    /// merge into `ref` would change nothing counts as landed there.
    private static func commitsMissing(from ref: String, at path: String) -> Set<Substring> {
        let cherry = runGit(["-C", path, "cherry", ref, "HEAD"]) ?? ""
        let ahead = Set(cherry.split(separator: "\n").filter { $0.hasPrefix("+") }.map { $0.dropFirst(2) })
        guard !ahead.isEmpty else { return [] }
        if let merged = runGit(["-C", path, "merge-tree", "--write-tree", "--no-messages", ref, "HEAD"])?
            .split(separator: "\n").first,
           let refTree = runGit(["-C", path, "rev-parse", "\(ref)^{tree}"]),
           String(merged) == refTree {
            return []
        }
        return ahead
    }

    /// Every ref that keeps work safe once it holds it, as full ref names: the branch the agent
    /// was started from, the default branch (origin/HEAD, local main, master), and HEAD's upstream.
    static func safeRefs(at path: String, _ base: String?) -> [String] {
        var refs: [String] = []
        func add(_ ref: String?) {
            guard let ref, !ref.isEmpty, !refs.contains(ref),
                  runGit(["-C", path, "rev-parse", "--verify", "--quiet", ref]) != nil else { return }
            refs.append(ref)
        }
        if let base, !base.isEmpty { add("refs/heads/\(base)") }
        add(runGit(["-C", path, "symbolic-ref", "-q", "refs/remotes/origin/HEAD"]))
        add("refs/heads/main")
        add("refs/heads/master")
        add(runGit(["-C", path, "rev-parse", "--symbolic-full-name", "@{upstream}"]))
        return refs
    }
}
