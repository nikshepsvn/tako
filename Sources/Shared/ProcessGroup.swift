import Darwin
import Foundation

/// Stops a child together with everything it started. Foundation's `Process` puts each child in
/// a process group of its own (pgid = its pid), and what it forks stays in that group: `npx`
/// runs `npm exec`, which runs the node server as a grandchild that killing `npx` alone leaves
/// running under launchd.
enum ProcessGroup {
    /// The group led by `pid`, or nil when there is none to signal: it is gone, or `pid` doesn't
    /// lead a group (so signalling the group would reach processes it didn't start), or the group
    /// is the caller's own.
    static func led(by pid: pid_t) -> pid_t? {
        guard pid > 1, pid != getpid(), pid != getpgrp() else { return nil }
        // A leader that exited leaves its group behind while members remain, and its pid can't
        // be reused until they're all gone, so the group still names what it started.
        let group = getpgid(pid)
        if group == pid || (group == -1 && errno == ESRCH && killpg(pid, 0) == 0) { return pid }
        return nil
    }

    static func isEmpty(_ group: pid_t) -> Bool {
        killpg(group, 0) != 0 && errno == ESRCH
    }

    /// SIGTERM to the group, then SIGKILL to whatever is still in it after `grace`. Blocks the
    /// caller for at most `grace`; returns early once the group is empty. A pid that leads no
    /// group gets the same two signals on its own.
    static func terminate(leader pid: pid_t, grace: TimeInterval) {
        guard let group = led(by: pid) else {
            if pid > 1, pid != getpid() { kill(pid, SIGTERM) }
            return
        }
        killpg(group, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while !isEmpty(group), Date() < deadline { usleep(25_000) }
        if !isEmpty(group) { killpg(group, SIGKILL) }
    }

    /// `terminate` without blocking: the SIGKILL follows on a background queue.
    static func terminateSoon(leader pid: pid_t, grace: TimeInterval) {
        guard let group = led(by: pid) else {
            if pid > 1, pid != getpid() { kill(pid, SIGTERM) }
            return
        }
        killpg(group, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
            if !isEmpty(group) { killpg(group, SIGKILL) }
        }
    }
}

/// Notices when the process that started this one is gone. A stdio MCP server normally ends on
/// stdin's EOF, but a parent killed with SIGKILL (or a pipe some grandchild still holds open)
/// can leave it waiting forever under launchd.
enum ParentWatch {
    /// Whether a process started by `original` has been orphaned: re-parented to launchd, or to
    /// anyone other than the parent it started with.
    static func isOrphaned(original: pid_t, current: pid_t) -> Bool {
        current <= 1 || current != original
    }

    /// Checks every `interval` seconds and calls `onOrphaned` once, on a background queue. Keep
    /// the returned timer alive for as long as the watch should run.
    static func start(interval: TimeInterval = 2, onOrphaned: @escaping @Sendable () -> Void) -> DispatchSourceTimer {
        let original = getppid()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(500))
        timer.setEventHandler { [weak timer] in
            guard isOrphaned(original: original, current: getppid()) else { return }
            timer?.cancel()
            onOrphaned()
        }
        timer.resume()
        return timer
    }
}
