import Foundation

/// A worktree Tako made for an agent, remembered so it can be found again after the session is
/// gone: closed with `ht close`, its shell exited, or Tako crashed.
struct WorktreeRecord: Codable, Equatable {
    let path: String
    let session: String
    /// The repository's main checkout, to find the worktree by once its folder is gone.
    var root: String?
    var base: String?
    let created: Date
}

/// Every agent worktree Tako made and hasn't seen removed yet, in ~/.tako.
enum WorktreeLedger {
    static var url: URL { ControlPaths.supportDirectory.appendingPathComponent("worktree-ledger.json") }

    static func load(from url: URL = url) -> [WorktreeRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([WorktreeRecord].self, from: data)) ?? []
    }

    static func save(_ records: [WorktreeRecord], to url: URL = url) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) { try? data.write(to: url, options: .atomic) }
    }

    /// Adds `record` unless its path is already there.
    static func adding(_ record: WorktreeRecord, to records: [WorktreeRecord]) -> [WorktreeRecord] {
        records.contains { $0.path == record.path } ? records : records + [record]
    }
}

/// Archives agent worktrees nobody can use any more, conservatively: only worktrees Tako made,
/// never one an open session or a running process uses, never one with uncommitted work or a
/// detached HEAD, and only through `Review.archive`, which keeps the branch and never forces.
/// Work that isn't in the base branch yet is kept in its folder for `keepFor` after the agent
/// closed (the user may reopen it). Everything it does goes to events.jsonl.
enum WorktreeJanitor {
    static let queue = DispatchQueue(label: "dev.tako.worktree-janitor", qos: .utility)
    static let keepFor: TimeInterval = 7 * 24 * 3600

    /// What the store knows, captured on the main actor.
    struct Known: Sendable {
        /// Folders open sessions work in, and every running process's working directory.
        var live: Set<String>
        /// Folder → when its agent was closed, for agents that can still be reopened.
        var closed: [String: Date]
        /// Folder → the sessions that worked there, whose checkpoints go with it.
        var sessions: [String: [String]]
        /// Folder → base branch, for agents the ledger doesn't know.
        var bases: [String: String]
    }

    enum LockState: Equatable {
        case unlocked
        /// Locked by a process that is still running.
        case held(pid_t)
        /// Locked by a process that is gone.
        case stale(pid_t)
        /// Locked by hand, or by something whose lock Tako can't read: never touched.
        case foreign(String)
    }

    /// What one worktree looks like, gathered from git.
    struct Facts: Equatable {
        var inUse = false
        var lock = LockState.unlocked
        var dirty = false
        var detached = false
        /// Nil when git can't tell.
        var risk: WorkAtRisk?
        /// When it stopped being used: its agent's close, else when Tako made it.
        var idleSince: Date?
    }

    struct Plan: Equatable {
        var unlock = false
        var archive = false
        var reason: String
    }

    static func plan(_ facts: Facts, now: Date = Date(), keepFor: TimeInterval = keepFor) -> Plan {
        if facts.inUse { return Plan(reason: "an open session uses it") }
        var plan = Plan(reason: "")
        switch facts.lock {
        case .held(let pid): return Plan(reason: "pid \(pid) holds its lock")
        case .foreign(let reason): return Plan(reason: "locked (\(reason))")
        case .stale: plan.unlock = true
        case .unlocked: break
        }
        if facts.dirty { plan.reason = "it has uncommitted work"; return plan }
        if facts.detached { plan.reason = "its HEAD is detached, so no branch would keep it"; return plan }
        guard let risk = facts.risk else { plan.reason = "git couldn't read it"; return plan }
        // Nothing left to lose: what a clean close in the window already does.
        if risk.isEmpty { plan.archive = true; plan.reason = "nothing left to lose"; return plan }
        if let since = facts.idleSince, now.timeIntervalSince(since) < keepFor {
            plan.reason = "its unmerged work stays for \(Int(keepFor / 86400)) days after closing"
            return plan
        }
        plan.archive = true
        plan.reason = "unused since \(facts.idleSince.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"); its branch keeps the work"
        return plan
    }

    // MARK: - Locks

    /// Claude's lock reason: "claude session <name> (pid 123 start Sat Oct 24 18:54:24 2026)".
    static func lockState(reason: String?, isRunning: (pid_t, Date?) -> Bool) -> LockState {
        guard let reason else { return .unlocked }
        let words = reason.split(separator: " ")
        guard let index = words.firstIndex(of: "(pid"), index + 1 < words.count,
              let pid = pid_t(words[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: ")"))), pid > 1 else {
            return .foreign(reason.isEmpty ? "no reason given" : reason)
        }
        var started: Date?
        if let start = words.firstIndex(of: "start"), start > index {
            started = lockDateFormatter.date(from: words[(start + 1)...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ")")))
        }
        return isRunning(pid, started) ? .held(pid) : .stale(pid)
    }

    private static let lockDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    /// A pid holds its lock while it runs and, when the lock says when it started, is the same
    /// process (a reused pid isn't).
    static func isRunning(_ pid: pid_t, started: Date?) -> Bool {
        guard let facts = SessionReaper.facts(pid) else { return false }
        guard let started else { return true }
        let actual = Double(facts.start) / 1_000_000
        return abs(actual - started.timeIntervalSince1970) < 3
    }

    // MARK: - Git

    struct Listed: Equatable {
        let path: String
        var detached = false
        var lockReason: String?
    }

    /// `git worktree list --porcelain`, every worktree but the main checkout.
    static func parseWorktrees(_ porcelain: String) -> [Listed] {
        var result: [Listed] = []
        for block in porcelain.components(separatedBy: "\n\n") {
            var entry: Listed?
            for line in block.split(separator: "\n", omittingEmptySubsequences: true) {
                if line.hasPrefix("worktree ") { entry = Listed(path: String(line.dropFirst("worktree ".count))) }
                if line == "detached" { entry?.detached = true }
                if line == "locked" { entry?.lockReason = "" }
                if line.hasPrefix("locked ") { entry?.lockReason = String(line.dropFirst("locked ".count)) }
            }
            if let entry { result.append(entry) }
        }
        return Array(result.dropFirst())
    }

    /// Folders Tako makes worktrees in: Claude's in the repository, Codex's in ~/.tako. Ones made
    /// before the rename are recorded (and known to git) by their ~/.hyperterm path.
    static func isAgentWorktree(_ path: String, support: String = ControlPaths.supportDirectory.path,
                                legacySupport: String = ControlPaths.legacySupportDirectory.path) -> Bool {
        path.contains("/.claude/worktrees/") || path.hasPrefix(support + "/worktrees/") || path.hasPrefix(legacySupport + "/worktrees/")
    }

    // MARK: - Collecting

    /// One pass over the repositories of `records` and `known`, on `queue`. `only` limits it to
    /// those folders (a close); nil looks at everything (launch). Returns the ledger without the
    /// worktrees that are gone.
    @discardableResult
    static func collect(records: [WorktreeRecord], known: Known, only: Set<String>? = nil, now: Date = Date(),
                        log: (String, String?) -> Void = { EventLog.record("gc", session: $1, $0) }) -> [WorktreeRecord] {
        let recorded = Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = Set(records.map(\.path)).union(known.closed.keys)
            .filter { isAgentWorktree($0) && (only?.contains($0) ?? true) }
        var gone = Set<String>()
        let byRoot = Dictionary(grouping: candidates) { repositoryRoot(of: $0, recorded: recorded[$0]?.root) ?? "" }
        // Neither the folder nor its repository can be found: nothing is left to collect.
        gone.formUnion(byRoot[""] ?? [])
        for (root, paths) in byRoot where !root.isEmpty {
            guard let porcelain = runGit(["-C", root, "worktree", "list", "--porcelain"]) else { continue }
            // Git names folders by their real path (/private/var for /var).
            let listed = Dictionary(parseWorktrees(porcelain).map { (canonical($0.path), $0) }, uniquingKeysWith: { first, _ in first })
            for path in paths {
                // lsof reports real paths, sessions the ones they were given.
                let forms = Set([path, canonical(path)] + (listed[canonical(path)].map { [$0.path] } ?? []))
                let inUse = known.live.contains { live in forms.contains { live == $0 || live.hasPrefix($0 + "/") } }
                // Not made yet (Claude makes its worktree as it starts) or removed since.
                guard let entry = listed[canonical(path)] else {
                    if !inUse { gone.insert(path) }
                    continue
                }
                let sessions = known.sessions[path] ?? recorded[path].map { [$0.session] } ?? []
                var facts = Facts(inUse: inUse,
                                  lock: lockState(reason: entry.lockReason, isRunning: isRunning),
                                  detached: entry.detached,
                                  idleSince: known.closed[path] ?? recorded[path]?.created)
                if !facts.inUse {
                    facts.dirty = !(runGit(["-C", path, "status", "--porcelain"]) ?? "x").isEmpty
                    facts.risk = WorkAtRisk.evaluate(at: path, base: recorded[path]?.base ?? known.bases[path])
                }
                let plan = plan(facts, now: now)
                if plan.unlock, case .stale(let pid) = facts.lock, runGit(["-C", root, "worktree", "unlock", entry.path]) != nil {
                    log("unlocked \(abbreviateHome(path)): its lock's pid \(pid) is gone", sessions.first)
                }
                guard plan.archive else {
                    if !facts.inUse { log("kept \(abbreviateHome(path)): \(plan.reason)", sessions.first) }
                    continue
                }
                switch Review.archive(worktree: entry.path, mainRoot: root) {
                case .success(let text):
                    gone.insert(path)
                    for session in sessions { Checkpoints.prune(at: root, session: session) }
                    log("archived \(abbreviateHome(path)) (\(plan.reason)): \(text)", sessions.first)
                case .failure(let error):
                    log("couldn't archive \(abbreviateHome(path)): \(error.description)", sessions.first)
                }
            }
        }
        return records.filter { !gone.contains($0.path) }
    }

    /// The main checkout of the repository a worktree belongs to, also once its folder is gone
    /// (Claude's live inside the repository; Codex's are named in the ledger only by path).
    static func repositoryRoot(of path: String, recorded: String? = nil) -> String? {
        if let recorded, FileManager.default.fileExists(atPath: recorded) { return recorded }
        if FileManager.default.fileExists(atPath: path), let root = Review.mainRoot(of: path) { return root }
        if let range = path.range(of: "/.claude/worktrees/") {
            let root = String(path[..<range.lowerBound])
            return FileManager.default.fileExists(atPath: root) ? root : nil
        }
        return nil
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Every running process's working directory (one `lsof`), so a worktree a shell outside
    /// Tako sits in is never removed from under it. Nil when lsof fails: then nothing is safe.
    static func processDirectories() -> Set<String>? {
        guard let output = runProcess("/usr/sbin/lsof", ["-w", "-a", "-d", "cwd", "-F", "n"], timeout: 15) else { return nil }
        return Set(output.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) })
    }
}
