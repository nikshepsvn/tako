import Foundation

/// Snapshots of an agent's workspace at each turn boundary, kept as hidden Git commits under
/// `refs/kuronami/<session>/`. A snapshot is built in a throwaway index, so the user's index,
/// HEAD, branches and stash are never touched, and .gitignored files are left out.
///
/// That gives three things the agent CLIs don't: the diff of exactly one turn, reverting files to
/// how they were before any turn, and undoing that revert (every restore snapshots first).
/// All calls block; run them off the main thread.
enum Checkpoints {
    struct Turn: Equatable, Identifiable {
        /// 1-based, in the order turns started.
        let index: Int
        let prompt: String
        let date: Date
        /// The workspace when the turn began.
        let start: String
        /// The workspace when it ended; nil while it is still running.
        var end: String?

        var id: Int { index }
    }

    enum Phase: String { case start, end }

    static let namespace = "refs/kuronami"

    static func prefix(session: String) -> String { "\(namespace)/\(session)/" }

    static func ref(session: String, turn: Int, phase: Phase) -> String {
        // Zero-padded so refs sort in turn order.
        prefix(session: session) + String(format: "%04d-%@", turn, phase.rawValue)
    }

    // MARK: - Capture

    /// Snapshots the working tree (tracked and untracked, minus ignored files) as a commit whose
    /// parent is HEAD. Returns its hash, or nil outside a repository. `excluding` adds pathspecs.
    static func snapshot(at path: String, message: String, environment extra: [String: String] = [:], excluding: [String] = []) -> String? {
        guard let gitDir = Git.run(["rev-parse", "--absolute-git-dir"], at: path) else { return nil }
        let index = (gitDir as NSString).appendingPathComponent("kuronami-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: index) }
        let environment = extra.merging(["GIT_INDEX_FILE": index]) { _, new in new }
        let head = Git.run(["rev-parse", "--verify", "-q", "HEAD"], at: path)
        // Start from a copy of the real index: its stat cache lets `add -A` hash only files that
        // changed, instead of every file in the repository. Without one, start from HEAD.
        let realIndex = (gitDir as NSString).appendingPathComponent("index")
        let seeded = (try? FileManager.default.copyItem(atPath: realIndex, toPath: index)) != nil
        if !seeded, head != nil { _ = Git.run(["read-tree", "HEAD"], at: path, environment: environment) }
        func addAndWriteTree() -> String? {
            guard Git.run(["add", "-A", "--", ":/"] + excluding, at: path, environment: environment) != nil else { return nil }
            return Git.run(["write-tree"], at: path, environment: environment)
        }
        var written = addAndWriteTree()
        // A conflicted index (mid-merge) keeps unmerged entries `add` didn't reach, an excluded
        // path say, and write-tree refuses them. Start again from HEAD instead.
        if written == nil, seeded {
            try? FileManager.default.removeItem(atPath: index)
            if head != nil { _ = Git.run(["read-tree", "HEAD"], at: path, environment: environment) }
            written = addAndWriteTree()
        }
        guard let tree = written else { return nil }
        var args = ["commit-tree", tree, "-m", message.isEmpty ? "Tako checkpoint" : message]
        if let head { args += ["-p", head] }
        return Git.run(args, at: path, environment: extra.merging(Git.identity) { _, new in new })
    }

    /// Runs `body` with Git writing new objects to a scratch store layered over the repository's
    /// own, deleted afterwards, so comparing against the live workspace leaves nothing behind.
    static func withScratchObjects<T>(at path: String, _ body: ([String: String]) -> T) -> T {
        guard let objects = Git.run(["rev-parse", "--path-format=absolute", "--git-path", "objects"], at: path) else {
            return body([:])
        }
        let scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("kuronami-objects-" + UUID().uuidString)
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        return body(["GIT_OBJECT_DIRECTORY": scratch, "GIT_ALTERNATE_OBJECT_DIRECTORIES": objects])
    }

    /// Snapshots and records the snapshot as `turn`'s start or end.
    @discardableResult
    static func capture(at path: String, session: String, turn: Int, phase: Phase, prompt: String) -> String? {
        guard let commit = snapshot(at: path, message: prompt) else { return nil }
        let name = ref(session: session, turn: turn, phase: phase)
        return Git.run(["update-ref", name, commit], at: path) != nil ? commit : nil
    }

    // MARK: - Reading

    /// Every recorded turn, oldest first.
    static func turns(at path: String, session: String) -> [Turn] {
        let format = "%(refname)%09%(objectname)%09%(committerdate:unix)%09%(contents:subject)"
        guard let listing = Git.run(["for-each-ref", "--format=" + format, prefix(session: session)], at: path) else { return [] }
        var starts: [Int: (commit: String, date: Date, prompt: String)] = [:]
        var ends: [Int: String] = [:]
        for line in listing.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { continue }
            let name = (fields[0] as NSString).lastPathComponent
            let parts = name.split(separator: "-")
            guard parts.count == 2, let turn = Int(parts[0]) else { continue }
            if parts[1] == "start" {
                starts[turn] = (fields[1], Date(timeIntervalSince1970: Double(fields[2]) ?? 0), fields.count > 3 ? fields[3] : "")
            } else if parts[1] == "end" {
                ends[turn] = fields[1]
            }
        }
        return starts.keys.sorted().compactMap { index in
            guard let start = starts[index] else { return nil }
            return Turn(index: index, prompt: start.prompt, date: start.date, start: start.commit, end: ends[index])
        }
    }

    /// The next turn number for a session.
    static func nextTurn(at path: String, session: String) -> Int {
        (turns(at: path, session: session).last?.index ?? 0) + 1
    }

    /// Files changed between two snapshots, or between a snapshot and the live workspace.
    static func changedFiles(at path: String, from: String, to: String?) -> [String] {
        if let to { return paths(at: path, from: from, to: to, filter: nil) }
        return withScratchObjects(at: path) { environment in
            guard let live = snapshot(at: path, message: "Tako: compare", environment: environment) else { return [] }
            return paths(at: path, from: from, to: live, filter: nil, environment: environment)
        }
    }

    /// A unified diff between two snapshots, or between a snapshot and the live workspace.
    static func diff(at path: String, from: String, to: String?, ignoreWhitespace: Bool = false) -> String {
        let args = ["-c", "core.quotePath=false", "diff", "--no-renames"] + (ignoreWhitespace ? ["-w"] : [])
        if let to { return Git.run(args + [from, to], at: path, trim: false) ?? "" }
        return withScratchObjects(at: path) { environment in
            guard let live = snapshot(at: path, message: "Tako: compare", environment: environment) else { return "" }
            return Git.run(args + [from, live], at: path, environment: environment, trim: false) ?? ""
        }
    }

    // MARK: - Restoring

    /// Puts the workspace's files back the way they were in `commit`. Files that didn't exist
    /// then are removed; ignored files are left alone. The index, HEAD and branches aren't
    /// touched. Returns a snapshot of the workspace from just before, so the restore can itself
    /// be undone.
    /// `only` limits the restore to those repository-relative paths, so files other agents in the
    /// same folder changed are left alone; nil restores everything that differs.
    static func restore(at path: String, to commit: String, session: String, only: Set<String>? = nil) -> Result<String, CheckpointError> {
        guard let before = snapshot(at: path, message: "Before restoring a checkpoint") else {
            return .failure(.notARepository)
        }
        _ = Git.run(["update-ref", prefix(session: session) + "undo", before], at: path)
        func scoped(_ list: [String]) -> [String] { only.map { allowed in list.filter(allowed.contains) } ?? list }
        let added = scoped(paths(at: path, from: commit, to: before, filter: "A"))
        guard let gitDir = Git.run(["rev-parse", "--absolute-git-dir"], at: path) else { return .failure(.notARepository) }
        let index = (gitDir as NSString).appendingPathComponent("kuronami-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: index) }
        let environment = ["GIT_INDEX_FILE": index]
        // Only files that differ are written, so untouched files keep their modification times
        // and file watchers (dev servers, test runners) don't rebuild everything.
        let changed = scoped(paths(at: path, from: commit, to: before, filter: "DMT"))
        // Undoing this restore touches exactly these files.
        saveUndoScope(Set(changed + added), gitDir: gitDir, session: session)
        guard Git.run(["read-tree", commit], at: path, environment: environment) != nil else {
            return .failure(.git("couldn't read the checkpoint"))
        }
        let root = Git.run(["rev-parse", "--show-toplevel"], at: path) ?? path
        var start = 0
        while start < changed.count {
            let batch = Array(changed[start..<min(start + 200, changed.count)])
            guard Git.run(["checkout-index", "-f", "--"] + batch, at: root, environment: environment) != nil else {
                return .failure(.git("couldn't write the checkpoint's files"))
            }
            start += 200
        }
        for file in added {
            let full = (root as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: full)
            removeEmptyParents(of: full, upTo: root)
        }
        return .success(before)
    }

    /// Files a session's turns changed from turn `from` on: what reverting to before that turn
    /// should touch. Other sessions' edits in the same folder aren't in it.
    static func touched(at path: String, session: String, from turn: Int) -> Set<String> {
        withScratchObjects(at: path) { environment in
            var result = Set<String>()
            var live: String?
            for entry in turns(at: path, session: session) where entry.index >= turn {
                if entry.end == nil, live == nil { live = snapshot(at: path, message: "Tako: compare", environment: environment) }
                guard let end = entry.end ?? live else { continue }
                result.formUnion(paths(at: path, from: entry.start, to: end, filter: nil, environment: environment))
            }
            return result
        }
    }

    /// The files the last restore changed, so undoing it touches nothing else.
    static func undoScope(at path: String, session: String) -> Set<String>? {
        guard let gitDir = Git.run(["rev-parse", "--absolute-git-dir"], at: path),
              let data = FileManager.default.contents(atPath: undoScopeFile(gitDir: gitDir, session: session)) else { return nil }
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
    }

    private static func undoScopeFile(gitDir: String, session: String) -> String {
        (gitDir as NSString).appendingPathComponent("kuronami-undo-\(session)")
    }

    private static func saveUndoScope(_ files: Set<String>, gitDir: String, session: String) {
        let data = Data(files.sorted().joined(separator: "\0").utf8)
        FileManager.default.createFile(atPath: undoScopeFile(gitDir: gitDir, session: session), contents: data)
    }

    /// The snapshot taken before the most recent restore, if any.
    static func undoPoint(at path: String, session: String) -> String? {
        Git.run(["rev-parse", "--verify", "-q", prefix(session: session) + "undo"], at: path)
    }

    /// Deletes a session's checkpoints (when it's closed or its worktree archived).
    static func prune(at path: String, session: String) {
        // The undo scope sits in the git dir of whichever checkout restored: this one's, or
        // the main repository's when `path` is a worktree.
        for flag in ["--absolute-git-dir", "--git-common-dir"] {
            if let gitDir = Git.run(["rev-parse", "--path-format=absolute", flag], at: path) {
                try? FileManager.default.removeItem(atPath: undoScopeFile(gitDir: gitDir, session: session))
            }
        }
        guard let listing = Git.run(["for-each-ref", "--format=%(refname)", prefix(session: session)], at: path) else { return }
        for name in listing.split(separator: "\n") { _ = Git.run(["update-ref", "-d", String(name)], at: path) }
    }

    /// Paths (from the repository root) that differ between two commits. NUL-separated, so Git
    /// never quotes a name ("\303\251.txt" for "é.txt") into one that doesn't exist.
    private static func paths(at path: String, from: String, to: String, filter: String?,
                              environment: [String: String] = [:]) -> [String] {
        var args = ["diff", "--name-only", "-z", "--no-renames"]
        if let filter { args.append("--diff-filter=" + filter) }
        return (Git.run(args + [from, to], at: path, environment: environment, trim: false) ?? "").split(separator: "\0").map(String.init)
    }

    private static func removeEmptyParents(of file: String, upTo root: String) {
        var directory = (file as NSString).deletingLastPathComponent
        while directory.count > root.count, directory.hasPrefix(root),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: directory), contents.isEmpty {
            try? FileManager.default.removeItem(atPath: directory)
            directory = (directory as NSString).deletingLastPathComponent
        }
    }
}

enum CheckpointError: Error, Equatable, CustomStringConvertible {
    case notARepository
    case git(String)

    var description: String {
        switch self {
        case .notARepository: return "this folder isn't a Git repository"
        case .git(let message): return message
        }
    }
}

/// A small Git runner with its own environment, independent of AppKit so the logic built on it
/// is tested anywhere Git is installed.
enum Git {
    static let executable = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/git"

    /// Snapshots need an author even on machines with no Git identity configured.
    static let identity = [
        "GIT_AUTHOR_NAME": "Tako", "GIT_AUTHOR_EMAIL": "kuronami@localhost",
        "GIT_COMMITTER_NAME": "Tako", "GIT_COMMITTER_EMAIL": "kuronami@localhost",
    ]

    /// Output (trimmed unless `trim` is false), or nil when Git fails.
    static func run(_ arguments: [String], at path: String, environment extra: [String: String] = [:],
                    trim: Bool = true, timeout: TimeInterval = 30) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.qualityOfService = .utility
        // No hooks or fsmonitor: snapshots must never run repository code.
        process.arguments = ["-C", path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                             "-c", "commit.gpgsign=false"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment.merge(extra) { _, new in new }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return trim ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }
}
