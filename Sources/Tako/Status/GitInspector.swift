import Foundation

struct GitInfo: Equatable {
    /// The main checkout's root (a worktree's parent repository).
    static func mainRoot(_ info: GitInfo) -> String { info.mainRoot }

    /// Main repository name, shared by its worktrees, used to group sessions by project.
    var project: String
    var branch: String
    var root: String
    var isWorktree: Bool
    var mainRoot: String
}

/// Reuses stable repository metadata; changing HEAD or a repository boundary invalidates it.
/// Calls block, so run them off the main thread.
final class GitInspector: @unchecked Sendable {
    private struct FileStamp: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: FileAttributeType
        let modified: Date?
        let size: UInt64?
    }

    private struct WatchPath {
        let path: String
        let directoryOnly: Bool
    }

    private struct CacheEntry {
        let info: GitInfo?
        var checkedAt: TimeInterval
        let queriedAt: TimeInterval
        let paths: [WatchPath]?
        let stamps: [FileStamp?]?
    }

    private struct Probe {
        let info: GitInfo
        let gitDirectory: String
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: Set<String> = []
    private var prunedAt: TimeInterval = -.infinity
    private let condition = NSCondition()
    private let clock: () -> TimeInterval
    private let git: ([String]) -> String?
    private static let checkInterval: TimeInterval = 8
    private static let queryInterval: TimeInterval = 60

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         git: @escaping ([String]) -> String? = runGit) {
        self.clock = clock
        self.git = git
    }

    func info(for directory: String) -> GitInfo? {
        condition.lock()
        // Concurrent requests for one checkout share the probe instead of spawning more git.
        while inFlight.contains(directory) { condition.wait() }
        let now = clock()
        let cached = cache[directory]
        if let cached, now - cached.checkedAt < Self.checkInterval {
            condition.unlock()
            return cached.info
        }
        inFlight.insert(directory)
        condition.unlock()

        let updated: CacheEntry
        if let cached, now - cached.queriedAt < Self.queryInterval,
           let paths = cached.paths, let stamps = cached.stamps,
           Self.fingerprint(paths) == stamps {
            var unchanged = cached
            unchanged.checkedAt = clock()
            updated = unchanged
        } else {
            let probe = Self.probe(directory, git: git)
            let paths = probe.flatMap { Self.watchPaths(directory: directory, probe: $0) }
            // Verify HEAD against the query before trusting its signature: a checkout racing
            // the subprocess must get another probe rather than caching the earlier branch.
            let stamps = paths.flatMap { paths -> [FileStamp?]? in
                guard let before = Self.fingerprint(paths), let info = probe?.info,
                      Self.headMatches(info, path: paths[0].path), Self.fingerprint(paths) == before else { return nil }
                return before
            }
            let finished = clock()
            updated = CacheEntry(info: probe?.info, checkedAt: finished, queriedAt: finished,
                                 paths: paths, stamps: stamps)
        }

        condition.lock()
        let finished = clock()
        // Prune once per minute rather than rebuilding the whole dictionary per cache miss.
        if finished - prunedAt >= 60 {
            cache = cache.filter { finished - $0.value.checkedAt < 120 }
            prunedAt = finished
        }
        cache[directory] = updated
        inFlight.remove(directory)
        condition.broadcast()
        condition.unlock()
        return updated.info
    }

    static func query(_ directory: String) -> GitInfo? {
        probe(directory, git: runGit)?.info
    }

    private static func probe(_ directory: String, git: ([String]) -> String?) -> Probe? {
        let output = git(["-C", directory, "rev-parse", "--path-format=absolute", "--show-toplevel",
                          "--abbrev-ref", "HEAD", "--git-common-dir", "--absolute-git-dir"])
        let lines = output?.split(separator: "\n").map(String.init) ?? []
        guard lines.count >= 4 else { return nil }
        let root = lines[0]
        // Absolute output also handles nested working directories, where a relative common
        // directory is relative to the cwd rather than to --show-toplevel.
        let mainRoot = (lines[2] as NSString).deletingLastPathComponent
        let isWorktree = URL(fileURLWithPath: mainRoot).standardized.path != URL(fileURLWithPath: root).standardized.path
        let info = GitInfo(project: URL(fileURLWithPath: mainRoot).lastPathComponent, branch: lines[1], root: root,
                           isWorktree: isWorktree, mainRoot: isWorktree ? mainRoot : root)
        return Probe(info: info, gitDirectory: lines[3])
    }

    private static func watchPaths(directory: String, probe: Probe) -> [WatchPath]? {
        // Keep symlink/relative/parent traversal lookups on the regular query path. A lexical
        // normalization could merge distinct checkouts across a symlink boundary.
        guard directory.hasPrefix("/") else { return nil }
        var current = directory
        while current.count > 1 && current.hasSuffix("/") { current.removeLast() }
        guard !current.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              current == probe.info.root || current.hasPrefix(probe.info.root + "/") else { return nil }
        var paths = [WatchPath(path: (probe.gitDirectory as NSString).appendingPathComponent("HEAD"), directoryOnly: false)]
        while true {
            paths.append(WatchPath(path: current, directoryOnly: true))
            // Observe every intervening marker so a nested repo never inherits its parent's
            // cache, including a new repo created above a session's working directory.
            paths.append(WatchPath(path: (current as NSString).appendingPathComponent(".git"), directoryOnly: false))
            if current == probe.info.root { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return paths
    }

    private static func fingerprint(_ paths: [WatchPath]) -> [FileStamp?]? {
        var result: [FileStamp?] = []
        result.reserveCapacity(paths.count)
        for item in paths {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.path),
                  let type = attributes[.type] as? FileAttributeType,
                  let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                if item.directoryOnly || result.isEmpty { return nil }
                result.append(nil)
                continue
            }
            if item.directoryOnly && type != .typeDirectory { return nil }
            result.append(FileStamp(device: device.uint64Value, inode: inode.uint64Value, type: type,
                                    modified: item.directoryOnly ? nil : attributes[.modificationDate] as? Date,
                                    size: item.directoryOnly ? nil : (attributes[.size] as? NSNumber)?.uint64Value))
        }
        return result
    }

    private static func headMatches(_ info: GitInfo, path: String) -> Bool {
        guard let head = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) == info.branch }
        return info.branch == "HEAD" && !head.hasPrefix("ref:")
    }
}

/// Runs git with repo-supplied hooks and fsmonitor disabled: Tako runs git inside
/// agent-controlled repos and must not execute their config. It runs at utility priority and
/// takes no optional locks, so polling never slows or blocks the agents' own git.
func runGit(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + arguments
    process.qualityOfService = .utility
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    process.environment = environment
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}
