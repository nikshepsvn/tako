import Foundation

/// Which files two agents' workspaces would conflict on if merged, as they stand right now:
/// uncommitted work included. Each workspace is snapshotted (as checkpoints are) into a scratch
/// object store, then `git merge-tree` merges the snapshots against their merge base without
/// touching any worktree, index or ref. Calls block; run them off the main thread.
enum Overlaps {
    /// Two workspaces, by path, and the files they'd conflict on.
    struct Pair: Equatable {
        let a: String
        let b: String
        let files: [String]
    }

    /// Generated files that never count, ignored or not: excluded from each snapshot so the
    /// merge doesn't see them at all.
    static let generated: [String] = {
        let folders = ["__pycache__", "node_modules", ".build", "build", "dist", "target", ".next", ".venv"]
        let paths = folders.flatMap { [$0, "*/\($0)/*"] } + ["*.pyc", "*.log", ".DS_Store", "*/.DS_Store", ".claude/worktrees"]
        return paths.map { ":(top,exclude)" + $0 }
    }()

    /// Every pair of distinct workspace paths that includes one in `focus`, with its conflicting
    /// files (empty when the two merge cleanly). All workspaces must belong to one repository.
    static func scan(_ workspaces: [String], focus: Set<String>) -> [Pair] {
        var seen: Set<String> = []
        let workspaces = workspaces.filter { seen.insert($0).inserted }
        guard let first = workspaces.first else { return [] }
        return Checkpoints.withScratchObjects(at: first) { environment in
            var snapshots: [String: String] = [:]
            for path in workspaces {
                snapshots[path] = Checkpoints.snapshot(at: path, message: "Tako: overlap", environment: environment, excluding: generated)
            }
            var pairs: [Pair] = []
            for (index, a) in workspaces.enumerated() {
                for b in workspaces[(index + 1)...] where focus.contains(a) || focus.contains(b) {
                    guard let left = snapshots[a], let right = snapshots[b],
                          let files = conflicts(left, right, at: a, environment: environment) else { continue }
                    pairs.append(Pair(a: a, b: b, files: files))
                }
            }
            return pairs
        }
    }

    /// Files a merge of two commits would leave conflicted, or nil when Git can't tell (no
    /// common history). merge-tree exits 1 on conflicts, which `Git.run` would report as failure.
    static func conflicts(_ left: String, _ right: String, at path: String, environment extra: [String: String]) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = ["-C", path, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.quotePath=false",
                             "merge-tree", "--write-tree", "--name-only", "--no-messages", left, right]
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
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return []
        case 1:
            // The merged tree's id, then one conflicted path per line.
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            return lines.dropFirst().prefix { !$0.isEmpty }.map(String.init)
        default: return nil
        }
    }
}

/// Which overlaps a pair of workspaces has already been told about, so a note goes out only
/// when the pair starts conflicting on a file it hadn't before.
struct OverlapNotes {
    private var told: [Set<String>: Set<String>] = [:]

    mutating func shouldTell(_ a: String, _ b: String, files: [String]) -> Bool {
        let pair: Set<String> = [a, b]
        let fresh = Set(files).subtracting(told[pair, default: []])
        guard !fresh.isEmpty else { return false }
        told[pair, default: []].formUnion(fresh)
        return true
    }
}
