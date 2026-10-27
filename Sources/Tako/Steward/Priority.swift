import Darwin
import Foundation

/// Lowers and restores another process's scheduling, as a same-user, non-root app may.
///
/// Measured on macOS 26 (StewardTests.testPriorityExperiment): PRIO_DARWIN_BG on another of the
/// user's processes takes and clears without root (scheduler priority 31 → 4 → 31). Raising nice
/// works, but lowering it again fails with EACCES, so nice is a one-way door and isn't used.
/// There is no call to give another process a utility-level clamp, so background is the only
/// reversible lever; the steward keeps it for sessions nobody is waiting on.
enum Priority {
    @discardableResult
    static func lower(_ pid: pid_t) -> Bool {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), PRIO_DARWIN_BG) == 0
    }

    @discardableResult
    static func restore(_ pid: pid_t) -> Bool {
        setpriority(PRIO_DARWIN_PROCESS, id_t(pid), 0) == 0
    }

    /// The scheduler priority the kernel is using for a process (4 when backgrounded).
    static func schedulerPriority(_ pid: pid_t) -> Int32? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_priority
    }

    /// Chromium's helpers draw pages; backgrounding them makes the browser pane stutter.
    static func isExempt(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        let name = String(cString: buffer).lowercased()
        return name.contains("helper") || name.contains("chrom")
    }
}
