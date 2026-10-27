import Darwin
import Foundation

/// A counting semaphore for builds and test runs, leased by process: a slot frees when its
/// holder releases it or exits. Waiters are granted in arrival order. Lowering the capacity
/// never revokes a slot; it only holds back the next grant.
struct HeavyQueue {
    private(set) var capacity: Int
    private(set) var holders: [pid_t] = []
    private var waiters: [(pid: pid_t, grant: () -> Void)] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var waiting: Int { waiters.count }

    /// One lease per pid: asking again while holding is granted at once, and asking again while
    /// waiting answers both asks on the one grant. A process whose ancestor holds a slot is part
    /// of that job (`ht heavy make` running `ht heavy cc`), so it's granted without another slot;
    /// waiting for one would deadlock the holder on its own child.
    mutating func acquire(_ pid: pid_t, ancestors: [pid_t] = [], grant: @escaping () -> Void) {
        if holders.contains(pid) || !Set(ancestors).isDisjoint(with: holders) {
            grant()
            return
        }
        if let index = waiters.firstIndex(where: { $0.pid == pid }) {
            let earlier = waiters[index].grant
            waiters[index].grant = { earlier(); grant() }
            return
        }
        waiters.append((pid, grant))
        pump()
    }

    /// Drops one lease (or a wait) held by `pid`.
    mutating func release(_ pid: pid_t) {
        if let index = holders.firstIndex(of: pid) {
            holders.remove(at: index)
        } else if let index = waiters.firstIndex(where: { $0.pid == pid }) {
            waiters.remove(at: index)
        }
        pump()
    }

    mutating func setCapacity(_ capacity: Int) {
        self.capacity = max(1, capacity)
        pump()
    }

    /// Frees the slots and waits of processes that are gone.
    mutating func reap(isAlive: (pid_t) -> Bool = HeavyQueue.isAlive) {
        holders.removeAll { !isAlive($0) }
        waiters.removeAll { !isAlive($0.pid) }
        pump()
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// `pid`'s parent, grandparent, … up to (not including) launchd.
    static func ancestors(of pid: pid_t) -> [pid_t] {
        var chain: [pid_t] = []
        var current = pid
        for _ in 0..<64 {
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, current]
            guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == current else { break }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1, parent != current else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    private mutating func pump() {
        while holders.count < capacity, !waiters.isEmpty {
            let next = waiters.removeFirst()
            holders.append(next.pid)
            next.grant()
        }
    }
}
