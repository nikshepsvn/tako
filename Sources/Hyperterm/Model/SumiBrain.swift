import Foundation

/// What Sumi keeps beyond its own conversation, which it loses on every clear: the plan it is
/// running, what it learned about projects and the user, the user's past approval answers, and
/// the bookkeeping that keeps its event feed quiet. Each part lives in its own small JSON file
/// next to the session list, so a restart (of Tako or of Sumi) picks up where it was.
@MainActor
final class SumiBrain {
    var plan: SumiPlan { didSet { save(plan, "organizer-plan.json") } }
    var memory: SumiMemory { didSet { save(memory, "organizer-memory.json") } }
    var approvals: ApprovalMemory { didSet { save(approvals, "organizer-approvals.json") } }

    /// Watches that re-arm after each report (watch_terminal repeat): by session, with the note.
    var repeatWatches: [UUID: String] = [:]
    /// The last steward warning told to Sumi per session and kind, so a memory reading hovering
    /// around the limit doesn't wake it every few minutes.
    var stewardTold: [String: (at: Date, bytes: UInt64)] = [:]
    /// Waits Sumi was already told have gone on too long, by session and reason.
    var longWaitsTold: [UUID: String] = [:]
    /// Sumi is answering a prompt itself; its answers aren't the user's to learn from.
    var sumiAnswering = false

    private let directory: URL?
    private static let queue = DispatchQueue(label: "dev.hyperterm.sumi-brain", qos: .utility)

    /// `directory` nil keeps everything in memory (tests and previews).
    init(directory: URL?) {
        self.directory = directory
        plan = Self.load("organizer-plan.json", in: directory) ?? SumiPlan()
        memory = Self.load("organizer-memory.json", in: directory) ?? SumiMemory()
        approvals = Self.load("organizer-approvals.json", in: directory) ?? ApprovalMemory()
    }

    private static func load<T: Decodable>(_ name: String, in directory: URL?) -> T? {
        guard let url = directory?.appendingPathComponent(name), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard let url = directory?.appendingPathComponent(name) else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        Self.queue.async { try? data.write(to: url, options: .atomic) }
    }
}

// MARK: - Plan

/// Sumi's task board: who does what, after what. Tako advances it by itself: when a task's
/// dependencies are done it briefs the owner (or starts one), and when an owner finishes the turn
/// its task was running in, the task is done. Sumi hears each step in its event feed.
struct SumiPlan: Codable, Equatable {
    var goal: String?
    var tasks: [PlanTask] = []

    static let taskCap = 40

    func task(_ id: String) -> PlanTask? { tasks.first { $0.id == id } }

    /// Todo tasks whose dependencies are all done.
    var ready: [PlanTask] {
        tasks.filter { task in
            task.status == .todo && task.deps.allSatisfy { dep in self.task(dep)?.status == .done }
        }
    }

    /// Adds or replaces tasks by id. Rejects unknown dependencies and cycles, so the plan can
    /// always finish.
    mutating func upsert(_ incoming: [PlanTask]) -> Result<[String], PlanError> {
        var next = self
        var ids: [String] = []
        for var task in incoming {
            if task.id.isEmpty { task.id = next.freshID() }
            if let index = next.tasks.firstIndex(where: { $0.id == task.id }) {
                task.status = task.status == .todo ? next.tasks[index].status : task.status
                next.tasks[index] = task
            } else {
                next.tasks.append(task)
            }
            ids.append(task.id)
        }
        guard next.tasks.count <= Self.taskCap else { return .failure(PlanError("a plan holds at most \(Self.taskCap) tasks; remove done ones first")) }
        for task in next.tasks {
            if let missing = task.deps.first(where: { next.task($0) == nil }) {
                return .failure(PlanError("\(task.id) depends on \(missing), which isn't in the plan"))
            }
        }
        if let cycle = next.cycle() { return .failure(PlanError("dependencies loop through \(cycle)")) }
        self = next
        return .success(ids)
    }

    /// A task in a dependency loop, if any.
    func cycle() -> String? {
        var state: [String: Int] = [:]  // 1 visiting, 2 done
        func visit(_ id: String) -> Bool {
            if state[id] == 2 { return false }
            if state[id] == 1 { return true }
            state[id] = 1
            for dep in task(id)?.deps ?? [] where visit(dep) { return true }
            state[id] = 2
            return false
        }
        return tasks.first { visit($0.id) }?.id
    }

    mutating func remove(_ id: String) -> Bool {
        guard tasks.contains(where: { $0.id == id }) else { return false }
        tasks.removeAll { $0.id == id }
        for index in tasks.indices { tasks[index].deps.removeAll { $0 == id } }
        return true
    }

    private func freshID() -> String {
        var number = tasks.count + 1
        while task("t\(number)") != nil { number += 1 }
        return "t\(number)"
    }

    /// The board, one line per task, for standup and the plan tool.
    func describe(now: Date = Date()) -> String {
        guard !tasks.isEmpty else { return "No plan yet." }
        let done = tasks.filter { $0.status == .done }.count
        var lines = ["Plan" + (goal.map { ": \($0)" } ?? "") + " (\(done)/\(tasks.count) done)"]
        let readyIDs = Set(ready.map(\.id))
        for task in tasks {
            var line = "  \(task.id) [\(readyIDs.contains(task.id) ? "ready" : task.status.rawValue)] \(task.title)"
            if let owner = task.owner { line += " · @\(owner)" } else if let folder = task.folder { line += " · new agent in \(abbreviateHome(folder))" }
            let open = task.deps.filter { self.task($0)?.status != .done }
            if !open.isEmpty { line += " · after " + open.joined(separator: ", ") }
            if let note = task.note { line += " · " + note }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

struct PlanTask: Codable, Equatable {
    enum Status: String, Codable, CaseIterable { case todo, running, done, failed, blocked }

    var id: String
    var title: String
    /// The agent doing it, by label; `ownerID` follows it through renames.
    var owner: String?
    var ownerID: UUID?
    var deps: [String] = []
    var status: Status = .todo
    /// Sent to the owner (or a new agent's task) when the task becomes ready. Without one, Tako
    /// only marks it running: the owner was already briefed.
    var brief: String?
    /// Where to start a new agent for it when it has no live owner.
    var folder: String?
    /// claude or codex, for a new agent.
    var kind: String?
    /// The last thing that happened to it: "finished: …", "owner exited".
    var note: String?
    /// The owner has started a turn since the task began, so its next finish completes it.
    var ownerWorked = false
    /// Told Sumi it's ready with no one to do it, once.
    var announced = false
}

struct PlanError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Memory

/// What Sumi knows that outlives its conversation, in three bounded sections: facts per project
/// (stack, commands, conventions), the user's preferences, and lessons from past runs. Old
/// entries are pruned past each cap, so it stays cheap to read in full.
struct SumiMemory: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var text: String
        /// For project facts: stack, test, build, run, convention, note. One of each of the first
        /// four is kept: a new test command replaces the old one.
        var topic: String?
        var at: Date
    }

    var projects: [String: [Entry]] = [:]
    var preferences: [Entry] = []
    var lessons: [Entry] = []

    static let projectCap = 15, sectionCap = 30, projectsCap = 40
    static let singleTopics: Set<String> = ["stack", "test", "build", "run"]
    static let topics = ["stack", "test", "build", "run", "convention", "note"]

    enum Section: String, CaseIterable { case project, preference, lesson }

    /// Keeps one copy of each fact, newest first, within the caps.
    mutating func remember(_ text: String, section: Section, project: String?, topic: String?, now: Date = Date()) {
        let text = Self.clean(text)
        guard !text.isEmpty else { return }
        let entry = Entry(text: text, topic: section == .project ? topic : nil, at: now)
        func insert(_ list: inout [Entry], cap: Int) {
            list.removeAll { Self.same($0.text, text) || (entry.topic.map(Self.singleTopics.contains) == true && $0.topic == entry.topic) }
            list.insert(entry, at: 0)
            if list.count > cap { list.removeLast(list.count - cap) }
        }
        switch section {
        case .preference: insert(&preferences, cap: Self.sectionCap)
        case .lesson: insert(&lessons, cap: Self.sectionCap)
        case .project:
            guard let project else { return }
            insert(&projects[project, default: []], cap: Self.projectCap)
            if projects.count > Self.projectsCap,
               let stalest = projects.min(by: { ($0.value.first?.at ?? .distantPast) < ($1.value.first?.at ?? .distantPast) })?.key {
                projects[stalest] = nil
            }
        }
    }

    /// Drops entries containing `text` (case-insensitive); returns how many went.
    mutating func forget(_ text: String, section: Section, project: String?) -> Int {
        let needle = text.lowercased()
        func drop(_ list: inout [Entry]) -> Int {
            let before = list.count
            list.removeAll { $0.text.lowercased().contains(needle) }
            return before - list.count
        }
        switch section {
        case .preference: return drop(&preferences)
        case .lesson: return drop(&lessons)
        case .project:
            guard let project, var list = projects[project] else { return 0 }
            let gone = drop(&list)
            projects[project] = list.isEmpty ? nil : list
            return gone
        }
    }

    /// The remembered project `folder` belongs to: the longest known path that contains it.
    func projectKey(for folder: String) -> String? {
        projects.keys.filter { folder == $0 || folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }.max { $0.count < $1.count }
    }

    func describeProject(_ key: String) -> String? {
        guard let entries = projects[key], !entries.isEmpty else { return nil }
        let ordered = entries.sorted { (Self.topics.firstIndex(of: $0.topic ?? "note") ?? 9) < (Self.topics.firstIndex(of: $1.topic ?? "note") ?? 9) }
        return ordered.map { entry in "  - " + (entry.topic.map { "\($0): " } ?? "") + entry.text }.joined(separator: "\n")
    }

    static func describe(_ entries: [Entry]) -> String {
        entries.map { "  - " + $0.text }.joined(separator: "\n")
    }

    private static func clean(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return line.count > 300 ? String(line.prefix(299)) + "…" : line
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return norm(a) == norm(b)
    }
}

// MARK: - Approvals

/// The user's own answers to agents' permission requests, per project (a repository's main
/// checkout, so every worktree of it shares them). Claude saves an "always" in the worktree it
/// was given in, so a new worktree asks again; Tako remembers it for the project instead and, for
/// sessions handed to Sumi, answers the same request the same way. Risky requests are never
/// learned: those stay the user's call every time.
struct ApprovalMemory: Codable, Equatable {
    struct Record: Codable, Equatable {
        var approved = 0
        var denied = 0
        /// The user chose "always" and hasn't denied it since.
        var always = false
        var lastAt: Date
    }

    var projects: [String: [String: Record]] = [:]

    static let keysPerProject = 80, projectCap = 40

    /// The exact request a remembered answer covers: `Bash(pnpm test --filter api)`, `Edit`,
    /// `mcp__linear__search`. A shell command is keyed on its whole argv, never a prefix: one
    /// approved `npm run test` must not approve `npm run deploy`. Anything whose meaning can hide
    /// behind its text has no key at all, so it is never learned or answered automatically:
    /// leading `VAR=value` (LD_PRELOAD, PATH), a program given by path, shell operators, quoting
    /// or expansion, and programs that run arbitrary code (interpreters, wrappers, package
    /// runners). RiskyRequest is checked separately on top of this, so a key never covers it.
    static func key(tool: String, request: String) -> String? {
        guard tool == "Bash" || tool == "exec_command" || tool == "shell" else {
            return tool.isEmpty || tool == "tool" ? nil : tool
        }
        let command = request.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, command.rangeOfCharacter(from: unsafeCharacters) == nil else { return nil }
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let program = words.first, !program.contains("="), !program.contains("/"),
              !runsArbitraryCode.contains(program) else { return nil }
        if let sub = words.dropFirst().first, runsArbitraryCode.contains(program + " " + sub) { return nil }
        return "Bash(" + words.joined(separator: " ") + ")"
    }

    /// Chaining, pipes, redirection, background jobs, substitution, expansion, quoting, escapes,
    /// globs and newlines: any of them and the text no longer says exactly what runs.
    private static let unsafeCharacters = CharacterSet(charactersIn: ";&|`$<>()\n\r'\"\\*?[]{}~!#")

    /// Programs (and program + subcommand) that execute whatever they are handed.
    static let runsArbitraryCode: Set<String> = [
        "bash", "sh", "zsh", "fish", "dash", "ksh", "csh", "tcsh", "python", "python3", "python2", "node", "ruby",
        "perl", "php", "lua", "osascript", "env", "xargs", "eval", "exec", "source", ".", "sudo", "doas", "su",
        "command", "builtin", "nohup", "time", "timeout", "nice", "watch", "npx", "bunx", "pnpx", "uvx", "deno",
        "pnpm dlx", "yarn dlx", "npm exec", "pnpm exec", "yarn exec", "bun x", "bun exec", "uv tool", "pipx",
        "find", "awk", "sed", "open",
    ]

    mutating func learn(project: String, key: String, answer: PromptAnswer, now: Date = Date()) {
        var keys = projects[project] ?? [:]
        var record = keys[key] ?? Record(lastAt: now)
        switch answer {
        case .approve: record.approved += 1
        case .always: record.approved += 1; record.always = true
        case .deny: record.denied += 1; record.always = false
        }
        record.lastAt = now
        keys[key] = record
        if keys.count > Self.keysPerProject, let stalest = keys.min(by: { $0.value.lastAt < $1.value.lastAt })?.key {
            keys[stalest] = nil
        }
        projects[project] = keys
        if projects.count > Self.projectCap,
           let stalest = projects.min(by: { ($0.value.values.map(\.lastAt).max() ?? .distantPast) < ($1.value.values.map(\.lastAt).max() ?? .distantPast) })?.key {
            projects[stalest] = nil
        }
    }

    func record(project: String, key: String) -> Record? { projects[project]?[key] }

    /// The user said "always" to this kind of request here.
    func allows(project: String, key: String) -> Bool { record(project: project, key: key)?.always == true }

    mutating func forget(project: String, key: String?) -> Int {
        guard let key else { return projects.removeValue(forKey: project)?.count ?? 0 }
        return projects[project]?.removeValue(forKey: key) == nil ? 0 : 1
    }

    /// "approved 4×, always" for a wait message; nil when the user never answered one.
    static func precedent(_ record: Record) -> String {
        var parts: [String] = []
        if record.always { parts.append("always allowed") } else if record.approved > 0 { parts.append("approved \(record.approved)×") }
        if record.denied > 0 { parts.append("denied \(record.denied)×") }
        return parts.joined(separator: ", ")
    }

    func describe(project: String) -> String? {
        guard let keys = projects[project], !keys.isEmpty else { return nil }
        return keys.sorted { $0.value.lastAt > $1.value.lastAt }.prefix(20)
            .map { "  - \($0.key): \(Self.precedent($0.value))" }.joined(separator: "\n")
    }
}
