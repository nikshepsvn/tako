import Foundation

/// Untracked folders a new worktree starts with (node_modules, build caches, `.env`), listed in
/// `.worktreeinclude` at the main checkout's root, gitignore-style, as Claude Code reads it.
/// Copies are APFS clones: instant, and no disk is used until a side changes a file.
/// Calls block; run them off the main thread.
enum WorktreeInclude {
    /// Repository-relative paths in `root` that match `.worktreeinclude` and that Git doesn't
    /// track; a directory whose contents all match is one entry ("node_modules/"). Empty
    /// without the file.
    static func entries(root: String) -> [String] {
        let include = (root as NSString).appendingPathComponent(".worktreeinclude")
        guard FileManager.default.fileExists(atPath: include),
              let listing = Git.run(["ls-files", "-z", "--others", "--ignored", "--directory", "--exclude-from=" + include],
                                    at: root, trim: false) else { return [] }
        let paths = listing.split(separator: "\0").map(String.init).filter { !$0.split(separator: "/").contains("..") }
        // An untracked folder is listed alongside the matches inside it; only the matches count.
        return paths.filter { path in
            !path.hasSuffix("/") || !paths.contains { $0 != path && $0.hasPrefix(path) }
        }
    }

    /// Clones every entry of the main checkout into `worktree`, skipping what's already there.
    /// Falls back to a plain copy where cloning isn't possible (another volume).
    static func warm(_ worktree: String) -> (copied: [String], failed: [String]) {
        guard let common = Git.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], at: worktree) else { return ([], []) }
        let root = (common as NSString).deletingLastPathComponent
        var copied: [String] = []
        var failed: [String] = []
        for entry in entries(root: root) {
            let relative = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            let source = (root as NSString).appendingPathComponent(relative)
            let target = (worktree as NSString).appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: target) else { continue }
            try? FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if clonefile(source, target, UInt32(CLONE_NOFOLLOW)) == 0
                || (errno != EEXIST && copyfile(source, target, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)) == 0) {
                copied.append(relative)
            } else {
                failed.append(relative)
            }
        }
        return (copied, failed)
    }
}

/// Each worktree-backed agent owns ten ports from `4100 + 10 × slot`, exported as
/// `KURONAMI_PORT` (and `PORT` when nothing else set it), so parallel dev servers never collide.
enum PortSlots {
    static let first = 4100
    static let width = 10

    static func base(_ slot: Int) -> Int { first + width * slot }

    static func range(_ slot: Int) -> ClosedRange<Int> { base(slot)...(base(slot) + width - 1) }

    /// Keeps `current` unless another session holds it; otherwise the lowest free slot.
    static func assign(current: Int?, taken: Set<Int>) -> Int {
        if let current, current >= 0, !taken.contains(current) { return current }
        return (0...).first { !taken.contains($0) }!
    }

    static func environment(for spec: LaunchSpec) -> [String: String] {
        guard let slot = spec.portSlot else { return [:] }
        return ["KURONAMI_PORT": String(base(slot)), "PORT": String(base(slot))]
    }
}
