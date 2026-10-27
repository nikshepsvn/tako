import Foundation

/// What the worktree janitor would do with one worktree on its next pass, and why, in the
/// cleanup sheet's words: "kept: unmerged work (archives after 7 days, on Nov 3)". Read-only:
/// it runs the janitor's own `plan` on facts gathered the same way, and never acts.
struct WorktreeDecision: Equatable {
    enum Kind: Equatable { case kept, archives, blocked }
    let kind: Kind
    let text: String
}

extension WorktreeJanitor {
    static func decision(_ facts: Facts, usedBy: String? = nil, now: Date = Date(), keepFor: TimeInterval = keepFor) -> WorktreeDecision {
        let plan = plan(facts, now: now, keepFor: keepFor)
        var lockNote = ""
        if plan.unlock, case .stale(let pid) = facts.lock { lockNote = "; stale lock (pid \(pid) gone) is cleared next pass" }
        if facts.inUse {
            return WorktreeDecision(kind: .kept, text: "kept: in use" + (usedBy.map { " by @" + $0 } ?? ""))
        }
        switch facts.lock {
        case .held(let pid): return WorktreeDecision(kind: .blocked, text: "kept: locked by running pid \(pid)")
        case .foreign(let why): return WorktreeDecision(kind: .blocked, text: "kept: locked (\(why))")
        case .stale, .unlocked: break
        }
        if facts.dirty { return WorktreeDecision(kind: .kept, text: "kept: uncommitted changes" + lockNote) }
        if facts.detached { return WorktreeDecision(kind: .blocked, text: "kept: detached HEAD, no branch would keep its work" + lockNote) }
        guard let risk = facts.risk else { return WorktreeDecision(kind: .blocked, text: "kept: git couldn't read it" + lockNote) }
        if plan.archive {
            let why = risk.isEmpty ? "nothing left to lose" : "unused over \(Int(keepFor / 86400)) days; its branch keeps the work"
            return WorktreeDecision(kind: .archives, text: "archives next pass: " + why + lockNote)
        }
        let until = facts.idleSince.map { $0.addingTimeInterval(keepFor) }
        let on = until.map { ", on " + Self.dayFormatter.string(from: $0) } ?? ""
        return WorktreeDecision(kind: .kept, text: "kept: unmerged work (archives after \(Int(keepFor / 86400)) days\(on))" + lockNote)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    /// What the janitor did lately, from events.jsonl's "gc" lines: archives and cleared locks,
    /// newest first. Blocking: call it off the main thread.
    static func recentActions(since: Date, limit: Int = 6, events: [LoggedEvent]? = nil) -> [(date: Date, text: String)] {
        let all = events ?? EventLog.read(since: since)
        return all.filter { $0.kind == "gc" && ($0.text.hasPrefix("archived ") || $0.text.hasPrefix("unlocked ")) }
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map { (date: $0.date, text: $0.text.hasPrefix("unlocked ") ? "lock cleared: " + $0.text.dropFirst("unlocked ".count) : $0.text) }
    }
}
