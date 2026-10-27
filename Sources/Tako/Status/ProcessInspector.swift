import Darwin
import Foundation

struct ProcessSnapshot: Equatable {
    var ports: [Int] = []
    var foreground: String?
    /// Program names (process name and argv[0]) of every process in the session's tree.
    var programs: Set<String> = []
    var claudeStatus: String?
    /// When Claude last wrote that status (its registry file's modification date).
    var claudeStatusAt: Date?
    var claudeSessionId: String?
    /// Commands of the agent CLIs running in the tree ("claude", "codex"), by each adapter's
    /// `isCLIProcess`, so an npm install (`node …/cli.js`) counts.
    var agentCLIs: Set<String> = []
    /// Every process in the session's tree, for the steward's resource sampling.
    var pids: Set<pid_t> = []
    /// Shells started by a program rather than by the terminal: an agent's background Bash tasks
    /// and Monitor watchers, which quitting the agent would end.
    var backgroundShells = 0
    /// Shells whose parent is a shell: a script running in the terminal (`bash deploy.sh`), which
    /// may be waiting on a builtin with no other process to show for it.
    var nestedShells = 0
}

/// Who is on the other end of a control-socket connection, decided from kernel facts only.
enum CallerIdentity: Sendable, Equatable {
    /// Traced by process ancestry to a Tako session.
    case session(String)
    /// Started from inside Tako (macOS "responsible process" is Tako) but no longer
    /// under any session: a backgrounded or double-forked child. Untrusted.
    case detachedInside
    /// A process outside Tako, e.g. the user's own terminal app.
    case external
    /// The peer is gone or unreadable. Untrusted.
    case unknown
}

/// Maps OS processes to sessions and finds what each one is running and listening on.
///
/// Every process a surface spawns inherits HT_SESSION_ID, so the environment of a session's
/// process tree identifies it without tty or title heuristics.
final class ProcessInspector: @unchecked Sendable {
    static let shared = ProcessInspector()

    private let queue = DispatchQueue(label: "dev.tako.process-inspector", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var rootCache: [pid_t: String] = [:]
    private var argvCache: [ArgvKey: [String]] = [:]
    /// Parsed registry files keyed by pid, reused while the file's modification date is unchanged.
    private var registryCache: [pid_t: (modified: Date, entry: RegistryEntry?)] = [:]
    /// Every process each session started that is still running, including jobs that have left
    /// the session's tree. Only touched on `queue`.
    private var recorded: [String: [TrackedProcess]] = [:]
    /// Each session's terminal devices. Jobs that leave its tree (nohup, a subshell's `&`) keep
    /// the terminal, and built-in programs like /bin/sleep hide their environment, so this is
    /// how such orphans are still found. Only touched on `queue`.
    private var sessionTTYs: [String: Set<dev_t>] = [:]
    private var ledgerWritten: Set<TrackedProcess> = []
    private let shells: Set<String> = ["login", "zsh", "bash", "sh", "fish", "-zsh", "-bash", "-sh", "-fish", "nu"]
    private let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private struct ArgvKey: Hashable {
        let pid: pid_t
        let start: Int
    }

    func start(interval: TimeInterval = 2.5, onUpdate: @escaping @Sendable ([String: ProcessSnapshot]) -> Void) {
        self.timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            // An unreadable process table is no news: nobody's agent exited, so this poll is skipped.
            guard let self, let snapshots = self.snapshot() else { return }
            onUpdate(snapshots)
        }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    /// Reschedules polling; the first poll at the new rate runs right away.
    func setInterval(_ interval: TimeInterval) {
        timer?.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 200)))
    }

    // MARK: - Caller identity

    /// Fail closed: only ancestry proves a session, and only processes Tako did not spawn
    /// count as the user. Callable from any thread; never waits on the polling queue.
    func identify(pid: pid_t) -> CallerIdentity {
        let mine = getpid()
        var current = pid
        var root: pid_t?
        for _ in 0..<64 {
            guard let parent = parentPID(of: current) else { return .unknown }
            if parent == mine { root = current; break }
            if parent <= 1 { break }
            current = parent
        }
        if let root, let session = sessionID(forRoot: root) { return .session(session) }
        if root != nil { return .detachedInside }
        if let responsibleFor, responsibleFor(pid) == mine { return .detachedInside }
        return parentPID(of: pid) == nil ? .unknown : .external
    }

    private func sessionID(forRoot root: pid_t) -> String? {
        lock.lock()
        let cached = rootCache[root]
        lock.unlock()
        if let cached { return cached }
        let children = Dictionary(grouping: listProcesses() ?? [], by: \.ppid)
        let candidates = [root] + descendants(of: root, children: children).prefix(40).map(\.pid)
        let found = candidates.lazy.compactMap { self.processEnvironment($0)?["HT_SESSION_ID"] }.first
        if let found {
            lock.lock()
            rootCache[root] = found
            lock.unlock()
        }
        return found
    }

    private func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info.kp_eproc.e_ppid
    }

    // MARK: - Snapshot

    /// Nil when the process table couldn't be read.
    func snapshot() -> [String: ProcessSnapshot]? {
        guard let processes = listProcesses() else { return nil }
        let children = Dictionary(grouping: processes, by: \.ppid)
        let trees = sessionTrees(children: children)
        pruneArgvCache(alive: Set(processes.map { ArgvKey(pid: $0.pid, start: $0.startSeconds) }))
        let registry = claudeRegistry(pids: Set(trees.values.joined().map(\.pid)))
        record(trees, processes: processes, children: children)

        var result: [String: ProcessSnapshot] = [:]
        for (sessionID, tree) in trees {
            var pids: Set<pid_t> = []
            var ports: Set<Int> = []
            var snapshot = ProcessSnapshot()
            // Claude's binary is named after its version (…/claude/versions/2.1.287), so the
            // process name alone isn't enough; include argv[0].
            for entry in tree {
                pids.insert(entry.pid)
                ports.formUnion(listeningPorts(pid: entry.pid))
                snapshot.programs.insert(entry.name.lowercased())
                let argv = arguments(of: entry)
                if let program = argv?.first { snapshot.programs.insert(program.lowercased()) }
                snapshot.agentCLIs.formUnion(Self.agentCLIs(entry: entry, argv: argv))
            }
            snapshot.ports = ports.sorted()
            snapshot.pids = pids
            snapshot.backgroundShells = Self.backgroundShellCount(in: tree)
            snapshot.nestedShells = Self.nestedShellCount(in: tree)
            snapshot.foreground = foregroundCommand(tree)
            if let entry = registry.first(where: { pids.contains($0.pid) }) {
                snapshot.claudeStatus = entry.status
                snapshot.claudeStatusAt = entry.modified
                snapshot.claudeSessionId = entry.sessionId
            }
            result[sessionID] = snapshot
        }
        return result
    }

    // MARK: - Process table

    struct ProcessEntry {
        let pid: pid_t
        let ppid: pid_t
        let name: String
        let startSeconds: Int
        /// Microseconds since the epoch, as `SessionReaper.facts` reports it.
        let start: UInt64
        /// The controlling terminal, or -1 (NODEV) for none.
        var tty: dev_t = -1
    }

    /// The whole process table, or nil when it couldn't be read. Processes started between
    /// sizing and reading make the read fail (ENOMEM), so it retries with more room.
    private func listProcesses() -> [ProcessEntry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs: [kinfo_proc] = []
        var actual = 0
        for attempt in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { continue }
            let count = size / stride + 16 + (size / stride / 4) * attempt
            procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            size = count * stride
            guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { continue }
            actual = size / stride
            if actual > 0 { break }
        }
        // There's always at least Tako itself; none means the read failed.
        guard actual > 0 else { return nil }
        return procs.prefix(actual).map { proc in
            var info = proc
            let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let start = proc.kp_proc.p_starttime
            return ProcessEntry(pid: proc.kp_proc.p_pid, ppid: proc.kp_eproc.e_ppid, name: name,
                                startSeconds: Int(start.tv_sec),
                                start: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec),
                                tty: proc.kp_eproc.e_tdev)
        }
    }

    /// Our direct children are libghostty's spawned `login` processes, one per surface. `login`
    /// is setuid root and login shells don't expose their environment, so we search the subtree
    /// for the first process that does. An idle shell with no children stays unmapped, which is
    /// fine: it has no ports or foreground command to report.
    private func sessionTrees(children: [pid_t: [ProcessEntry]]) -> [String: [ProcessEntry]] {
        let mine = getpid()
        var trees: [String: [ProcessEntry]] = [:]
        var alive = Set<pid_t>()
        for child in children[mine] ?? [] {
            // Chromium's helper processes (renderer, GPU, …) are our children too, but never
            // sessions; without this they'd be re-scanned for HT_SESSION_ID every poll.
            if arguments(of: child)?.first?.contains(".app/Contents/Frameworks/") == true { continue }
            alive.insert(child.pid)
            lock.lock()
            var sessionID = rootCache[child.pid]
            lock.unlock()
            // Discovery and the eventual snapshot share the same traversal.
            let tree = descendants(of: child.pid, children: children)
            if sessionID == nil {
                let candidates = [child.pid] + tree.prefix(40).map(\.pid)
                sessionID = candidates.lazy.compactMap { self.processEnvironment($0)?["HT_SESSION_ID"] }.first
                if let sessionID {
                    lock.lock()
                    rootCache[child.pid] = sessionID
                    lock.unlock()
                }
            }
            if let sessionID { trees[sessionID, default: []].append(contentsOf: tree) }
        }
        lock.lock()
        rootCache = rootCache.filter { alive.contains($0.key) }
        lock.unlock()
        return trees
    }

    private static let terminalChain: Set<String> = ["login", "zsh", "bash", "sh", "fish", "dash", "tcsh"]
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh"]

    /// Shells with something other than the terminal's own login and shell chain above them in
    /// the tree, such as the agent CLI. The terminal's login shell, and a wrapper script that
    /// execs the CLI, have only that chain above them, so they don't count.
    static func nestedShellCount(in tree: [ProcessEntry]) -> Int {
        let names = Dictionary(tree.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        return tree.filter { shells.contains($0.name) && names[$0.ppid].map(shells.contains) == true }.count
    }

    static func backgroundShellCount(in tree: [ProcessEntry]) -> Int {
        let byPID = Dictionary(tree.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return tree.filter { entry in
            guard shells.contains(entry.name) else { return false }
            var parent = byPID[entry.ppid]
            var hops = 0
            while let current = parent, hops < 64 {
                if !terminalChain.contains(current.name) { return true }
                parent = byPID[current.ppid]
                hops += 1
            }
            return false
        }.count
    }

    private func descendants(of pid: pid_t, children: [pid_t: [ProcessEntry]]) -> [ProcessEntry] {
        var result: [ProcessEntry] = []
        var stack = children[pid] ?? []
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: children[next.pid] ?? [])
        }
        return result
    }

    /// The newest non-shell process: what the session is actually running right now.
    private func foregroundCommand(_ tree: [ProcessEntry]) -> String? {
        let candidates = tree.lazy.filter { !self.shells.contains($0.name) }
        guard let newest = candidates.max(by: { ($0.startSeconds, $0.pid) < ($1.startSeconds, $1.pid) }) else { return nil }
        guard let argv = arguments(of: newest), !argv.isEmpty else { return newest.name }
        return Self.commandLabel(argv: argv)
    }

    /// The program and its first few arguments, each shortened to its last path component.
    /// String path math, not `URL(fileURLWithPath:)`: an argument like `https://host/sse` (from
    /// `mcp-remote`) made Foundation log an API-misuse fault on every poll and shortened the URL
    /// to "sse". URLs say nothing about what's running, so they are left out.
    static func commandLabel(argv: [String]) -> String {
        guard let first = argv.first else { return "" }
        let program = (first as NSString).lastPathComponent
        let rest = argv.dropFirst().lazy.filter { !$0.contains("://") }.prefix(3).map { ($0 as NSString).lastPathComponent }
        return ([program] + rest).joined(separator: " ")
    }

    /// The agent CLIs a process is: by kernel name or argv[0], else by executable path, and for
    /// node by the script it runs (argv[1]).
    static func agentCLIs(entry: ProcessEntry, argv: [String]?) -> Set<String> {
        let program = argv?.first.map { ($0 as NSString).lastPathComponent }
        let script = entry.name == "node" ? argv?.dropFirst().first : nil
        var path: String?
        var pathRead = false
        var found = Set<String>()
        for adapter in SessionKind.agentAdapters {
            if program == adapter.command || adapter.isCLIProcess(name: entry.name, path: nil, script: script) {
                found.insert(adapter.command)
                continue
            }
            // The executable path is only looked up when name and argv don't decide it.
            if !pathRead {
                path = ProcessUsage.path(entry.pid)
                pathRead = true
            }
            if adapter.isCLIProcess(name: entry.name, path: path, script: script) { found.insert(adapter.command) }
        }
        return found
    }

    // MARK: - Session trees for stopping

    /// Removes a session from the record and hands `completion` everything it started that
    /// still runs: what earlier polls saw, a fresh walk of its terminal, and orphans carrying
    /// its id. Call before the surface is destroyed, while the terminal's tree is still
    /// attached. Only that walk happens on the caller's thread; the rest waits its turn on
    /// `queue` and calls `completion` there, so closing never waits on a poll in flight.
    func takeProcesses(ofSession id: String, completion: @escaping @Sendable ([TrackedProcess]) -> Void) {
        // Listed now, not on `queue`: after a restart the new surface's shell has the same id.
        let processes = listProcesses() ?? []
        let children = Dictionary(grouping: processes, by: \.ppid)
        let fresh = sessionTrees(children: children)[id] ?? []
        queue.async { [self] in
            let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
            // Double-forked daemons are launchd's children, but macOS still holds Tako
            // responsible for them and they keep the session's environment.
            let mine = getpid()
            sessionTTYs[id, default: []].formUnion(fresh.map(\.tty).filter { $0 != -1 })
            let orphans = processes.filter { entry in
                entry.ppid == 1 && responsibleFor?(entry.pid) == mine
                    && processEnvironment(entry.pid)?["HT_SESSION_ID"] == id
            } + ttyOrphans(of: id, in: processes, mine: mine)
            sessionTTYs[id] = nil
            let previous = recorded.removeValue(forKey: id) ?? []
            completion(Self.selectTree(session: id, seeds: (fresh + orphans).map(\.pid), recorded: previous,
                                       byPID: byPID, children: children, mine: mine))
        }
    }

    /// The seeds, recorded processes that are still the same process, and everything below
    /// them. Never Tako or its direct children (terminal roots, Chromium helpers), and
    /// never below them.
    static func selectTree(session: String, seeds: [pid_t], recorded: [TrackedProcess], byPID: [pid_t: ProcessEntry],
                           children: [pid_t: [ProcessEntry]], mine: pid_t) -> [TrackedProcess] {
        var stack = seeds.compactMap { byPID[$0] }
            + recorded.compactMap { process in byPID[process.pid].flatMap { $0.start == process.start ? $0 : nil } }
        var seen = Set<pid_t>()
        var result: [TrackedProcess] = []
        while let next = stack.popLast() {
            guard next.pid > 1, next.pid != mine, next.ppid != mine, seen.insert(next.pid).inserted else { continue }
            result.append(TrackedProcess(pid: next.pid, start: next.start, session: session))
            stack.append(contentsOf: children[next.pid] ?? [])
        }
        return result
    }

    /// Processes launchd adopted that still hold one of the session's terminals and that macOS
    /// still holds Tako responsible for.
    private func ttyOrphans(of session: String, in processes: [ProcessEntry], mine: pid_t) -> [ProcessEntry] {
        guard let ttys = sessionTTYs[session], !ttys.isEmpty else { return [] }
        return processes.filter { $0.ppid == 1 && ttys.contains($0.tty) && responsibleFor?($0.pid) == mine }
    }

    /// Keeps each session's processes, including ones that left its tree, and rewrites the
    /// ledger only when they changed. Runs on `queue`.
    private func record(_ trees: [String: [ProcessEntry]], processes: [ProcessEntry], children: [pid_t: [ProcessEntry]]) {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = getpid()
        var next: [String: [TrackedProcess]] = [:]
        for (session, tree) in trees {
            sessionTTYs[session, default: []].formUnion(tree.map(\.tty).filter { $0 != -1 })
        }
        let sessions = Set(trees.keys).union(recorded.keys)
        sessionTTYs = sessionTTYs.filter { sessions.contains($0.key) }
        for session in sessions {
            let orphans = ttyOrphans(of: session, in: processes, mine: mine)
            let tree = Self.selectTree(session: session, seeds: ((trees[session] ?? []) + orphans).map(\.pid),
                                       recorded: recorded[session] ?? [], byPID: byPID, children: children, mine: mine)
            if !tree.isEmpty { next[session] = tree }
        }
        recorded = next
        let all = Set(next.values.joined())
        guard all != ledgerWritten, let owner = SessionReaper.facts(mine) else { return }
        ledgerWritten = all
        let ledger = ProcessLedger(ownerPID: mine, ownerStart: owner.start, processes: Array(all))
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: ProcessLedger.url, options: .atomic)
    }

    // MARK: - KERN_PROCARGS2

    /// argv rarely changes after exec, so it's cached per (pid, start time).
    private func arguments(of entry: ProcessEntry) -> [String]? {
        let key = ArgvKey(pid: entry.pid, start: entry.startSeconds)
        lock.lock()
        let cached = argvCache[key]
        lock.unlock()
        if let cached { return cached }
        guard let argv = rawArguments(entry.pid, includeEnvironment: false)?.argv else { return nil }
        lock.lock()
        argvCache[key] = argv
        lock.unlock()
        return argv
    }

    /// A process's argv, read fresh.
    func arguments(_ pid: pid_t) -> [String]? {
        rawArguments(pid, includeEnvironment: false)?.argv
    }

    private func pruneArgvCache(alive: Set<ArgvKey>) {
        lock.lock()
        argvCache = argvCache.filter { alive.contains($0.key) }
        lock.unlock()
    }

    private func rawArguments(_ pid: pid_t, includeEnvironment: Bool = true) -> (argv: [String], env: [String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // exec path
        while index < size && buffer[index] == 0 { index += 1 }   // padding
        func nextString() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            let value = String(decoding: buffer[start..<index], as: UTF8.self)
            index += 1
            return value
        }
        var argv: [String] = []
        for _ in 0..<max(0, Int(argc)) {
            guard let value = nextString() else { break }
            argv.append(value)
        }
        // Snapshot argv lookups do not need to decode and allocate every environment value.
        // Identity lookups keep the complete environment and their existing behavior.
        guard includeEnvironment else { return (argv, []) }
        // Padding NULs can separate argv from the environment.
        while index < size && buffer[index] == 0 { index += 1 }
        var env: [String] = []
        while let value = nextString(), !value.isEmpty { env.append(value) }
        return (argv, env)
    }

    private func processEnvironment(_ pid: pid_t) -> [String: String]? {
        guard let env = rawArguments(pid)?.env else { return nil }
        var result: [String: String] = [:]
        for entry in env {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            result[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return result
    }

    // MARK: - Ports

    /// TCP sockets in LISTEN state for one process, via libproc: no `lsof` subprocess.
    private func listeningPorts(pid: pid_t) -> [Int] {
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bufferSize)
        guard filled > 0 else { return [] }
        var ports: [Int] = []
        for fd in fds.prefix(Int(filled) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size else { continue }
            guard info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.append(port) }
        }
        return ports
    }

    // MARK: - Claude registry

    struct RegistryEntry {
        let pid: pid_t
        let status: String
        let sessionId: String?
        /// The file's modification date: when Claude wrote this status.
        var modified: Date?
    }

    private static let registryDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")

    /// ~/.claude/sessions, then each extra Claude account's (its CLAUDE_CONFIG_DIR/sessions).
    /// Files are named for pids, which are unique, so every directory can be searched.
    private static func registryDirectories() -> [URL] {
        let accounts = AccountStore.root.appendingPathComponent(SessionKind.claude.rawValue, isDirectory: true)
        let extra = (try? FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? []
        return [registryDirectory] + extra.map { $0.appendingPathComponent("sessions", isDirectory: true) }
    }

    /// ~/.claude/sessions/<pid>.json, maintained by Claude Code for cross-session messaging. The
    /// directory holds every Claude on the machine; only files named for `pids` (processes in our
    /// sessions) are read, and only when they changed since the last poll.
    private func claudeRegistry(pids: Set<pid_t>) -> [RegistryEntry] {
        guard !pids.isEmpty else {
            lock.lock()
            registryCache.removeAll(keepingCapacity: true)
            lock.unlock()
            return []
        }
        // One directory read replaces a failed file-stat syscall for every non-Claude
        // process. If enumeration of the default directory fails, retain the previous per-pid
        // lookup behavior there; an account's that can't be listed has no sessions yet.
        var listings: [(directory: URL, filenames: Set<String>?)] = []
        for (index, directory) in Self.registryDirectories().enumerated() {
            let filenames = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)).map { Set($0) }
            if filenames != nil || index == 0 { listings.append((directory: directory, filenames: filenames)) }
        }
        var entries: [RegistryEntry] = []
        var seen = Set<pid_t>()
        for pid in pids {
            let filename = "\(pid).json"
            let listing = listings.first(where: { $0.filenames?.contains(filename) == true })
                ?? listings.first(where: { $0.filenames == nil })
            guard let directory = listing?.directory else { continue }
            let url = directory.appendingPathComponent(filename)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            seen.insert(pid)
            lock.lock()
            let cached = registryCache[pid]
            lock.unlock()
            let entry: RegistryEntry?
            if let cached, cached.modified == modified {
                entry = cached.entry
            } else {
                entry = Self.parseRegistry(url)
                lock.lock()
                registryCache[pid] = (modified, entry)
                lock.unlock()
            }
            if var entry {
                entry.modified = modified
                entries.append(entry)
            }
        }
        lock.lock()
        registryCache = registryCache.filter { seen.contains($0.key) }
        lock.unlock()
        return entries
    }

    private static func parseRegistry(_ url: URL) -> RegistryEntry? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int else { return nil }
        return RegistryEntry(pid: pid_t(pid), status: json["status"] as? String ?? "", sessionId: json["sessionId"] as? String)
    }
}

/// Runs a program with a deadline; returns stdout, or nil on failure, non-zero exit, or timeout.
func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval = 5, environment: [String: String]? = nil) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let environment { process.environment = environment }
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
    return String(decoding: data, as: UTF8.self)
}
