import Darwin
import Foundation

/// A process left running by a terminal that's gone: Sumi's `orphans` tool lists and stops them.
/// The user asked Sumi 13 times to kill stale Chromes and dev servers; it went at them with
/// ps, lsof and pkill, and the user's guard hook blocked broad kills 97 times. This finds only
/// what Tako itself started, so a kill can't reach the user's own processes.
///
/// The quit sweep (SessionReaper) stops everything at quit and launch; this is the on-demand
/// version for while Tako runs.
struct OrphanProcess: Equatable {
    let pid: pid_t
    let pgid: pid_t
    /// Microseconds since the epoch: a pid reused since the list is never signalled.
    let start: UInt64
    let command: String
    /// Bytes, its folded children included.
    var memory: UInt64?
    /// Processes below it that are orphaned too, stopped with it.
    var children: [TrackedProcess] = []
    let why: String
}

/// One process as the scan sees it.
struct ProcessRecord: Equatable {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let start: UInt64
    let name: String
    var command: String
    /// HT_SESSION_ID from its environment: the terminal it was started in.
    var session: String?
    /// macOS holds Tako responsible for it: Tako or something Tako ran started it.
    var fromTako: Bool
}

enum Orphans {
    /// Programs that pile up when their owner goes: browsers agents drive, and dev servers.
    static let strayPrograms = ["chrome", "chromium", "cef", "headless_shell", "node", "bun", "deno", "vite", "next-server",
                                "webpack", "esbuild", "turbo", "python", "uvicorn", "ruby", "puma", "rails", "playwright"]

    /// Orphans among `processes`: what a terminal that's no longer open started (from its
    /// environment, or the ledger of what each terminal ran), plus browsers and dev servers Tako
    /// is responsible for that launchd adopted. A child of an orphan is folded into its parent.
    static func find(_ processes: [ProcessRecord], ledger: [TrackedProcess], live: Set<String>, mine: pid_t) -> [OrphanProcess] {
        let ledgered = Dictionary(ledger.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        func reason(_ process: ProcessRecord) -> String? {
            // Only what macOS holds this Tako responsible for: never the user's own processes, nor
            // another Tako's (a dev build running beside the installed app).
            guard process.fromTako, process.pid > 1, process.pid != mine, process.ppid != mine else { return nil }
            if let session = process.session {
                return live.contains(session) ? nil : "its terminal closed"
            }
            if let recorded = ledgered[process.pid], recorded.start == process.start, !live.contains(recorded.session) {
                return "its terminal closed"
            }
            let program = (process.name + " " + process.command).lowercased()
            if process.ppid == 1, strayPrograms.contains(where: program.contains) {
                return "started from Tako, no terminal owns it"
            }
            return nil
        }
        let flagged = Dictionary(processes.compactMap { process in reason(process).map { (process.pid, (process, $0)) } },
                                 uniquingKeysWith: { first, _ in first })
        var roots: [pid_t: OrphanProcess] = [:]
        // The topmost flagged ancestor of each flagged process.
        func root(of pid: pid_t) -> pid_t {
            var current = pid
            var hops = 0
            while let parent = flagged[current]?.0.ppid, flagged[parent] != nil, hops < 64 {
                current = parent
                hops += 1
            }
            return current
        }
        for (pid, (process, why)) in flagged where root(of: pid) == pid {
            roots[pid] = OrphanProcess(pid: pid, pgid: process.pgid, start: process.start, command: process.command, why: why)
        }
        for (pid, (process, _)) in flagged where root(of: pid) != pid {
            roots[root(of: pid)]?.children.append(TrackedProcess(pid: pid, start: process.start, session: process.session ?? ""))
        }
        return roots.values.sorted { $0.start < $1.start }
    }

    /// The machine's processes, with each one's environment read only when Tako is responsible
    /// for it (the rest can't be Tako's orphans).
    static func snapshot() -> [ProcessRecord] {
        let mine = getpid()
        return listProcesses().map { entry in
            var record = entry
            record.fromTako = responsible(entry.pid) == mine
            if record.fromTako, let read = arguments(entry.pid) {
                record.command = read.argv.joined(separator: " ")
                record.session = read.env["HT_SESSION_ID"]
            }
            return record
        }
    }

    /// What `find` returns on this machine now, with each one's memory.
    static func scan(live: Set<String>, ledger url: URL = ProcessLedger.url) -> [OrphanProcess] {
        let mine = getpid()
        // Another Tako's ledger (the installed app's, seen from a dev build) names its own sessions.
        let ledger = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ProcessLedger.self, from: $0) }
            .flatMap { $0.ownerPID == mine ? $0.processes : nil } ?? []
        return find(snapshot(), ledger: ledger, live: live, mine: mine).map { orphan in
            var counted = orphan
            let pids = [orphan.pid] + orphan.children.map(\.pid)
            let sizes = pids.compactMap { ProcessUsage.read($0)?.footprint }
            counted.memory = sizes.isEmpty ? nil : sizes.reduce(0, +)
            return counted
        }
    }

    /// TERM, then KILL after `grace`, to each orphan's group when it leads one (what it forked
    /// since stays in it) and to each process the list named. SessionReaper re-checks every pid's
    /// start time first and never signals Tako or its direct children.
    static func stop(_ orphans: [OrphanProcess], grace: TimeInterval = 2, completion: (@Sendable () -> Void)? = nil) {
        let processes = orphans.flatMap { orphan in
            [TrackedProcess(pid: orphan.pid, start: orphan.start, session: "orphans")] + orphan.children
        }
        SessionReaper.stop(processes, grace: grace, completion: completion)
    }

    static func describe(_ orphans: [OrphanProcess], now: Date = Date()) -> String {
        guard !orphans.isEmpty else { return "No stray processes: everything Tako started belongs to an open terminal." }
        let lines = orphans.map { orphan -> String in
            let started = Date(timeIntervalSince1970: TimeInterval(orphan.start) / 1_000_000)
            var line = "pid \(orphan.pid) (group \(orphan.pgid)) · \(age(now.timeIntervalSince(started)))"
            if let memory = orphan.memory { line += " · " + String(format: "%.0f MB", Double(memory) / 1_048_576) }
            if !orphan.children.isEmpty { line += " · +\(orphan.children.count) child process\(orphan.children.count == 1 ? "" : "es")" }
            let command = orphan.command.count > 140 ? String(orphan.command.prefix(139)) + "…" : orphan.command
            return line + " · \(orphan.why)\n    \(command)"
        }
        return "\(orphans.count) stray process\(orphans.count == 1 ? "" : "es") Tako started:\n" + lines.joined(separator: "\n")
            + "\nTo stop some, ask the user, then orphans kill with their ids and user_requested true."
    }

    static func age(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<120: return "\(Int(seconds)) s old"
        case ..<7200: return "\(Int(seconds / 60)) min old"
        case ..<172_800: return "\(Int(seconds / 3600)) h old"
        default: return "\(Int(seconds / 86400)) days old"
        }
    }

    // MARK: - Process table

    private static func listProcesses() -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride
        for attempt in 0..<4 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { continue }
            let count = size / stride + 16 + (size / stride / 4) * attempt
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
            size = count * stride
            guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0, size > 0 else { continue }
            return procs.prefix(size / stride).map { proc in
                var info = proc
                let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                let start = proc.kp_proc.p_starttime
                return ProcessRecord(pid: proc.kp_proc.p_pid, ppid: proc.kp_eproc.e_ppid, pgid: proc.kp_eproc.e_pgid,
                                     start: UInt64(start.tv_sec) * 1_000_000 + UInt64(start.tv_usec),
                                     name: name, command: name, session: nil, fromTako: false)
            }
        }
        return []
    }

    private static let responsibleFor: (@convention(c) (pid_t) -> pid_t)? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    private static func responsible(_ pid: pid_t) -> pid_t? { responsibleFor?(pid) }

    /// argv and environment from KERN_PROCARGS2; nil for processes we may not read.
    private static func arguments(_ pid: pid_t) -> (argv: [String], env: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }
        while index < size && buffer[index] == 0 { index += 1 }
        func next() -> String? {
            guard index < size else { return nil }
            let start = index
            while index < size && buffer[index] != 0 { index += 1 }
            defer { index += 1 }
            return String(decoding: buffer[start..<index], as: UTF8.self)
        }
        var argv: [String] = []
        for _ in 0..<max(0, Int(argc)) { guard let value = next() else { break }; argv.append(value) }
        while index < size && buffer[index] == 0 { index += 1 }
        var env: [String: String] = [:]
        while let entry = next(), !entry.isEmpty {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return (argv, env)
    }
}
