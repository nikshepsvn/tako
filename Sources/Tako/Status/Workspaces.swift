import Foundation

/// Per-project settings in `.hyperterm.json` at the repository root:
/// `{"setup": "pnpm i", "dev": "pnpm dev --port $PORT", "ports": [4100, 4199]}`.
struct ProjectConfig: Decodable {
    var setup: String?
    var dev: String?
    var ports: [Int]?
    /// One-click commands shown in the toolbar's Actions menu.
    var actions: [ProjectAction]?

    static func load(for path: String) -> ProjectConfig? {
        guard let root = GitInspector.query(path).map({ mainRoot(of: $0) }) ?? Optional(path) else { return nil }
        for dir in [path, root] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(".hyperterm.json")
            if let data = try? Data(contentsOf: url), let config = try? JSONDecoder().decode(ProjectConfig.self, from: data) {
                return config
            }
        }
        return nil
    }

    private static func mainRoot(of info: GitInfo) -> String {
        info.isWorktree ? (runGit(["-C", info.root, "rev-parse", "--path-format=absolute", "--git-common-dir"]).map { ($0 as NSString).deletingLastPathComponent } ?? info.root) : info.root
    }
}

enum Ports {
    /// First port in the project's range that no session holds and nothing is listening on.
    static func allocate(config: ProjectConfig, taken: Set<Int>) -> Int? {
        let range = config.ports.flatMap { $0.count == 2 ? $0[0]...$0[1] : nil } ?? 4100...4199
        return range.first { !taken.contains($0) && isFree($0) }
    }

    private static func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }
}

/// Isolated workspaces for agents.
enum Workspaces {
    /// Claude gets its native `--worktree` (Claude Code then blocks writes back into the main
    /// checkout and copies `.worktreeinclude` files itself). Codex gets a git worktree under
    /// ~/.hyperterm/worktrees; the store clones the same `.worktreeinclude` files in after launch.
    static func prepare(spec: LaunchSpec) -> Result<LaunchSpec, WorktreeError> {
        guard let info = GitInspector.query(expandTilde(spec.cwd)) else { return .failure(.notARepo(spec.cwd)) }
        var spec = spec
        // A detached HEAD has no branch to merge back into; "HEAD" would read as one.
        spec.baseBranch = info.branch == "HEAD" ? nil : info.branch
        switch spec.kind {
        case .claude:
            spec.cwd = info.root
            spec.worktreeName = spec.label
            spec.worktreeBranch = "worktree-\(spec.label)"
            excludeFromStatus(".claude/worktrees/", repo: info.root)
            return .success(spec)
        default:
            switch createGitWorktree(info: info, label: spec.label) {
            case .success(let created):
                spec.cwd = created.path
                spec.worktreeBranch = created.branch
                return .success(spec)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    /// Calls `then` on the main queue once `path` exists (Claude creates its worktree on launch).
    static func whenReady(_ path: String, attempts: Int = 60, then: @escaping @MainActor () -> Void) {
        if FileManager.default.fileExists(atPath: path) {
            DispatchQueue.main.async { MainActor.assumeIsolated { then() } }
        } else if attempts > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { whenReady(path, attempts: attempts - 1, then: then) }
        }
    }

    private static func createGitWorktree(info: GitInfo, label: String) -> Result<(path: String, branch: String), WorktreeError> {
        let base = ControlPaths.supportDirectory.appendingPathComponent("worktrees/\(info.project)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var name = label
        var suffix = 2
        while FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path) || branchExists(info.root, "ht/\(name)") {
            name = "\(label)-\(suffix)"
            suffix += 1
        }
        let path = base.appendingPathComponent(name).path
        let branch = "ht/\(name)"
        guard runGit(["-C", info.root, "worktree", "add", "-b", branch, path, "HEAD"]) != nil else {
            return .failure(.gitFailed("git worktree add failed in \(abbreviateHome(info.root)) (does the repo have a commit?)"))
        }
        return .success((path, branch))
    }

    private static func branchExists(_ root: String, _ branch: String) -> Bool {
        runGit(["-C", root, "rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"]) != nil
    }

    /// Keeps worktree folders out of the main checkout's `git status` without touching tracked
    /// files: `.git/info/exclude` is local to this clone.
    private static func excludeFromStatus(_ pattern: String, repo: String) {
        guard let common = runGit(["-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"]) else { return }
        let exclude = (common as NSString).appendingPathComponent("info/exclude")
        let existing = (try? String(contentsOfFile: exclude, encoding: .utf8)) ?? ""
        guard !existing.split(separator: "\n").contains(where: { $0 == pattern }) else { return }
        try? FileManager.default.createDirectory(atPath: (exclude as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? (existing + (existing.hasSuffix("\n") || existing.isEmpty ? "" : "\n") + pattern + "\n").write(toFile: exclude, atomically: true, encoding: .utf8)
    }
}

enum WorktreeError: Error, CustomStringConvertible {
    case notARepo(String)
    case gitFailed(String)

    var description: String {
        switch self {
        case .notARepo(let dir): return "\(abbreviateHome(dir)) isn't a git repository"
        case .gitFailed(let message): return message
        }
    }
}
