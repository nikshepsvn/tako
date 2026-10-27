import Darwin
import Foundation

/// One process a session started. The start time tells it apart from a later process that
/// reuses the pid.
struct TrackedProcess: Codable, Hashable, Sendable {
    let pid: pid_t
    /// Microseconds since the epoch.
    let start: UInt64
    let session: String
}

/// Kernel facts about a live process, from proc_pidinfo.
struct ProcessFacts: Equatable, Sendable {
    let start: UInt64
    let ppid: pid_t
    let pgid: pid_t
    let name: String
}

/// The processes recorded by the run that wrote it, so the next launch can sweep what it left.
struct ProcessLedger: Codable {
    let ownerPID: pid_t
    let ownerStart: UInt64
    let processes: [TrackedProcess]

    static let url = ControlPaths.supportDirectory.appendingPathComponent("processes.json")
}

/// Stops what sessions started. Closing a terminal hangs up its shell, but jobs that left it
/// (nohup, setsid, double-forked daemons) would otherwise run on under launchd.
enum SessionReaper {
    private static let queue = DispatchQueue(label: "dev.tako.reaper", qos: .utility)

    static func facts(_ pid: pid_t) -> ProcessFacts? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_pid == UInt32(pid) else { return nil }
        let name = withUnsafeBytes(of: &info.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return ProcessFacts(start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                            ppid: pid_t(info.pbi_ppid), pgid: pid_t(info.pbi_pgid), name: name)
    }

    /// Recorded processes that are still running and orphaned to launchd, with their recorded
    /// descendants (they'd be orphaned the moment their parent stops).
    static func leftovers(_ recorded: [TrackedProcess], facts: (pid_t) -> ProcessFacts?) -> [TrackedProcess] {
        let alive = recorded.compactMap { process in
            facts(process.pid).flatMap { $0.start == process.start ? (process, $0) : nil }
        }
        var orphaned = Set(alive.filter { $0.1.ppid == 1 }.map(\.0.pid))
        var grew = true
        while grew {
            grew = false
            for (process, info) in alive where !orphaned.contains(process.pid) && orphaned.contains(info.ppid) {
                orphaned.insert(process.pid)
                grew = true
            }
        }
        return alive.map(\.0).filter { orphaned.contains($0.pid) }
    }

    /// Whether a signal may go to `process`: the same process that was recorded, and never
    /// Tako or its direct children (terminal roots, Chromium helpers).
    static func maySignal(_ process: TrackedProcess, _ info: ProcessFacts?, mine: pid_t) -> Bool {
        guard let info, process.pid > 1, process.pid != mine else { return false }
        return info.start == process.start && info.ppid != mine
    }

    /// SIGTERM now and SIGKILL whatever is left after `grace`, off the main thread.
    static func stop(_ processes: [TrackedProcess], grace: TimeInterval = 2, completion: (@Sendable () -> Void)? = nil) {
        guard !processes.isEmpty else { completion?(); return }
        let sessions = Set(processes.map(\.session))
        queue.async {
            for session in sessions { stopping[session, default: 0] += 1 }
            signal(processes, SIGTERM)
            queue.asyncAfter(deadline: .now() + grace) {
                signal(processes, SIGKILL)
                completion?()
                for session in sessions {
                    stopping[session, default: 1] -= 1
                    guard stopping[session] == 0 else { continue }
                    stopping[session] = nil
                    stopped.removeValue(forKey: session)?.forEach { $0() }
                }
            }
        }
    }

    /// Stops under way per session, and what waits for them to finish. Only touched on `queue`.
    nonisolated(unsafe) private static var stopping: [String: Int] = [:]
    nonisolated(unsafe) private static var stopped: [String: [@Sendable () -> Void]] = [:]

    /// Runs `body` (on the reaper's queue) once the stop a session's close began has sent its
    /// last signal, or right away when none is under way. Call after the close.
    static func whenStopped(session: String, _ body: @escaping @Sendable () -> Void) {
        queue.async {
            guard stopping[session] != nil else { body(); return }
            stopped[session, default: []].append(body)
        }
    }

    /// Each signal re-checks the start time first, so a pid reused since is never touched.
    private static func signal(_ processes: [TrackedProcess], _ signal: Int32) {
        let mine = getpid()
        for process in processes {
            let info = facts(process.pid)
            guard maySignal(process, info, mine: mine), let info else { continue }
            // A group led by a recorded process also holds what it forked since the walk.
            if info.pgid == process.pid { killpg(process.pid, signal) }
            kill(process.pid, signal)
        }
    }

    /// SIGHUP and SIGTERM now, then SIGKILL whatever is still running once `grace` runs out,
    /// returning as soon as everything has gone. Blocks the caller for at most `grace` plus a
    /// moment for the kills to land, so quitting and launching wait only as long as the slowest
    /// process needs. The hangup is what a closed terminal sends: interactive shells ignore
    /// SIGTERM, and would otherwise hold every quit for the whole grace period.
    static func stopAndWait(_ processes: [TrackedProcess], grace: TimeInterval) {
        guard !processes.isEmpty else { return }
        signal(processes, SIGHUP)
        signal(processes, SIGTERM)
        guard !waitUntilGone(processes, timeout: grace) else { return }
        signal(processes, SIGKILL)
        _ = waitUntilGone(processes, timeout: 0.2)
    }

    /// Quitting: gathers every process the sessions started (`take` hands over one session's,
    /// as `ProcessInspector.takeProcesses` does) for at most `collectFor`, then stops them all
    /// and waits for them. Without this they'd outlive Tako under launchd until the next launch
    /// swept them, and an agent killed then can't release its worktree lock cleanly.
    static func stopAllForQuit(sessions: [String], collectFor: TimeInterval = 0.5, grace: TimeInterval = 1.5,
                               take: (String, @escaping @Sendable ([TrackedProcess]) -> Void) -> Void) {
        guard !sessions.isEmpty else { return }
        let collected = Collected()
        let group = DispatchGroup()
        for session in sessions {
            group.enter()
            take(session) { processes in
                collected.add(processes)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + collectFor)
        stopAndWait(collected.processes, grace: grace)
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [TrackedProcess] = []
        func add(_ processes: [TrackedProcess]) { lock.lock(); all += processes; lock.unlock() }
        var processes: [TrackedProcess] { lock.lock(); defer { lock.unlock() }; return Array(Set(all)) }
    }

    /// The same process (pid and start time) is still running. One on its way out counts (it
    /// can be stuck there, draining its terminal) though proc_pidinfo no longer reports it; a
    /// zombie doesn't, as it has exited and only waits for its parent to collect it.
    static func isRunning(_ process: TrackedProcess) -> Bool {
        guard let info = kernelEntry(process.pid) else { return false }
        return startTime(info) == process.start && info.kp_proc.p_stat != SZOMB
    }

    /// The process table's entry, which (unlike proc_pidinfo) is readable for setuid processes
    /// such as `login` and for processes on their way out.
    private static func kernelEntry(_ pid: pid_t) -> kinfo_proc? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    private static func startTime(_ info: kinfo_proc) -> UInt64 {
        UInt64(info.kp_proc.p_starttime.tv_sec) * 1_000_000 + UInt64(info.kp_proc.p_starttime.tv_usec)
    }

    // MARK: - Closing a terminal

    /// What runs on a terminal: its root (the `login` libghostty spawned, our own child) and
    /// every other process whose controlling terminal it is.
    struct Terminal: Sendable, Equatable {
        var root: TrackedProcess?
        var others: [TrackedProcess] = []
    }

    static func terminal(onTTY tty: dev_t) -> Terminal {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: UInt32(truncatingIfNeeded: tty))]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return Terminal() }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return Terminal() }
        let mine = getpid()
        var terminal = Terminal()
        for info in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = info.kp_proc.p_pid
            guard pid > 1, pid != mine, info.kp_proc.p_stat != SZOMB else { continue }
            let process = TrackedProcess(pid: pid, start: startTime(info), session: "")
            if info.kp_eproc.e_ppid == mine { terminal.root = process } else { terminal.others.append(process) }
        }
        return terminal
    }

    /// Signals what is still the same process. The root is our own child, which `signal`
    /// (for good reason) never touches, and setuid `login` hides from proc_pidinfo.
    private static func signalTerminal(_ processes: [TrackedProcess], _ signal: Int32) {
        for process in processes where process.pid > 1 && process.pid != getpid() && isRunning(process) {
            kill(process.pid, signal)
        }
    }

    /// Ends a closing terminal's processes before libghostty frees it, then calls `completion`
    /// on another queue, within about `2 * grace` plus a second. Freeing a surface joins its IO
    /// thread, which hangs up the child `login` and loops until it has exited, then joins the
    /// reader. A session leader on its way out first waits for its terminal's output to drain,
    /// and the reader stalls on a mailbox only the joined threads empty, so with a busy program
    /// on the terminal the free hung the app for good. Ended here, while libghostty still reads
    /// the terminal, the free has nothing left to wait for.
    ///
    /// The root gets the hangup a closed terminal gives it (what libghostty would send), the
    /// rest a hangup and SIGTERM like any other stop. If the root hasn't gone after `grace`,
    /// what keeps the terminal busy is killed (ignoring the hangup, or refilling the output the
    /// root drains on its way out), then after another `grace` the root itself. Whatever else
    /// on the terminal outlives the first `grace` is killed too: anything still writing to it
    /// could stall the reader again.
    static func endTerminal(tty: dev_t, grace: TimeInterval = 1,
                            log: @escaping @Sendable (String) -> Void = { EventLog.record("teardown", $0) },
                            completion: @escaping @Sendable () -> Void) {
        // Not `queue`: these waits would hold up every other stop behind them.
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let terminal = terminal(onTTY: tty)
            if let root = terminal.root { signalTerminal([root], SIGHUP) }
            signalTerminal(terminal.others, SIGHUP)
            signalTerminal(terminal.others, SIGTERM)
            var others = terminal.others
            if let root = terminal.root, !waitUntilGone([root], timeout: grace) {
                // Listed again: a loop may have started more since. The root still holds the
                // terminal, so whatever is on it is still this terminal's.
                if isRunning(root) { others += self.terminal(onTTY: tty).others }
                signalTerminal(others, SIGKILL)
                if !waitUntilGone([root], timeout: grace) {
                    signalTerminal([root], SIGKILL)
                    log("killed a terminal's login \(Int(grace * 2)) s after its hangup")
                    _ = waitUntilGone([root], timeout: 0.5)
                }
            }
            if !waitUntilGone(others, timeout: max(0, grace - Date().timeIntervalSince(started))) {
                signalTerminal(others, SIGKILL)
                _ = waitUntilGone(others, timeout: 0.5)
            }
            completion()
        }
    }

    private static func waitUntilGone(_ processes: [TrackedProcess], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while processes.contains(where: isRunning) {
            guard Date() < deadline else { return false }
            usleep(20_000)
        }
        return true
    }

    /// At launch, before sessions restore: stops what an earlier run that quit or crashed left
    /// running, notes each in events.jsonl, and calls `completion` on the main queue once they are
    /// gone. Restoring only then means a resumed agent never shares its conversation, worktree
    /// lock or dev-server port with the copy it replaces. With nothing to stop, `completion`
    /// runs at once.
    static func sweepLeftovers(ledger url: URL = ProcessLedger.url, grace: TimeInterval = 2,
                               log: (String, String) -> Void = { EventLog.record("sweep", session: $1, $0) },
                               completion: @escaping @MainActor () -> Void = {}) {
        let found = leftovers(inLedger: url)
        guard !found.isEmpty else { MainActor.assumeIsolated { completion() }; return }
        for process in found {
            log("stopped leftover \(facts(process.pid)?.name ?? "?") pid \(process.pid)", process.session)
        }
        queue.async {
            stopAndWait(found, grace: grace)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion() } }
        }
    }

    /// What the ledger's run left behind, once that run is over (removing the ledger).
    static func leftovers(inLedger url: URL) -> [TrackedProcess] {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(ProcessLedger.self, from: data) else { return [] }
        if let owner = facts(ledger.ownerPID), owner.start == ledger.ownerStart { return [] }
        try? FileManager.default.removeItem(at: url)
        return leftovers(ledger.processes, facts: facts)
    }
}
