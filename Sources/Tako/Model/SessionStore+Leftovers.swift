import Foundation

/// What agents leave behind once they're gone: worktrees and checkpoint refs. A clean close in
/// the window archives its own worktree, but `ht close`, a shell that exits, "leave work in
/// folder" and crashes don't, so leftovers are collected at launch and after each close.
extension SessionStore {
    /// How long after a close its worktree is looked at again: the reaper has stopped the agent
    /// by then (releasing Claude's lock), and a clean close in the window has archived it itself.
    static let closeCollectionDelay: TimeInterval = 5

    /// At launch, once sessions are restored: worktrees and checkpoints nobody can use any more.
    func collectLeftoverWork() {
        guard persists else { return }
        let known = leftoverKnowledge()
        let specs = sessions.map(\.spec) + recentlyClosed
        let keep = Set(specs.map(\.id.uuidString))
        WorktreeJanitor.queue.async {
            var records = WorktreeLedger.load()
            for spec in specs where spec.isWorktree { records = WorktreeLedger.adding(Self.worktreeRecord(spec), to: records) }
            var roots = Set(records.compactMap(\.root))
            for spec in specs where !roots.contains(expandTilde(spec.cwd)) {
                if let root = Self.repositoryRoot(of: spec) { roots.insert(root) }
            }
            if let known = known.withProcessDirectories() {
                records = WorktreeJanitor.collect(records: records, known: known)
            } else {
                HookLog.append(source: "gc", sessionID: nil, payload: "skipped worktrees: couldn't list processes' folders")
            }
            WorktreeLedger.save(records)
            CheckpointJanitor.collect(roots: roots, keep: keep)
        }
    }

    /// Remembers a worktree made for `spec`, so it is found again however the session ends.
    func recordWorktree(_ spec: LaunchSpec) {
        guard persists, spec.isWorktree else { return }
        WorktreeJanitor.queue.async {
            let records = WorktreeLedger.load()
            let updated = WorktreeLedger.adding(Self.worktreeRecord(spec), to: records)
            if updated != records { WorktreeLedger.save(updated) }
        }
    }

    /// After an agent with its own worktree closes, however it closed: archives the worktree if
    /// nothing in it is left to lose (unmerged work stays for `WorktreeJanitor.keepFor`).
    func collectWorktree(afterClosing spec: LaunchSpec) {
        guard persists, spec.isWorktree else { return }
        let path = spec.workPath
        SessionReaper.whenStopped(session: spec.id.uuidString) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeCollectionDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let known = self?.leftoverKnowledge() else { return }
                    WorktreeJanitor.queue.async {
                        guard let known = known.withProcessDirectories() else { return }
                        let records = WorktreeLedger.load()
                        let kept = WorktreeJanitor.collect(records: records, known: known, only: [path])
                        if kept != records { WorktreeLedger.save(kept) }
                    }
                }
            }
        }
    }

    /// What the janitor needs from the store, captured on the main actor.
    func leftoverKnowledge() -> WorktreeJanitor.Known {
        let worktrees = recentlyClosed.filter(\.isWorktree)
        var closed: [String: Date] = [:]
        for spec in worktrees { closed[spec.workPath] = max(closed[spec.workPath] ?? .distantPast, spec.memory?.closedAt ?? spec.createdAt) }
        let all = sessions.map(\.spec) + recentlyClosed
        return WorktreeJanitor.Known(
            live: Set(sessions.map(\.spec.workPath)),
            closed: closed,
            sessions: Dictionary(grouping: all.filter(\.isWorktree), by: \.workPath).mapValues { $0.map(\.id.uuidString) },
            bases: Dictionary(all.compactMap { spec in spec.baseBranch.map { (spec.workPath, $0) } }, uniquingKeysWith: { first, _ in first }))
    }

    nonisolated static func worktreeRecord(_ spec: LaunchSpec) -> WorktreeRecord {
        WorktreeRecord(path: spec.workPath, session: spec.id.uuidString, root: repositoryRoot(of: spec),
                       base: spec.baseBranch, created: spec.createdAt)
    }

    /// Claude's worktrees live in the repository its `cwd` names; Codex's know theirs.
    nonisolated static func repositoryRoot(of spec: LaunchSpec) -> String? {
        if spec.worktreeName != nil { return expandTilde(spec.cwd) }
        return [spec.workPath, expandTilde(spec.cwd)].lazy.compactMap { path in
            FileManager.default.fileExists(atPath: path) ? Review.mainRoot(of: path) : nil
        }.first
    }
}

extension WorktreeJanitor.Known {
    /// With every running process's folder counted as in use; nil when they can't be listed.
    func withProcessDirectories() -> Self? {
        guard let directories = WorktreeJanitor.processDirectories() else { return nil }
        var known = self
        known.live.formUnion(directories)
        return known
    }
}
