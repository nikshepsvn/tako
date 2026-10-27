import Darwin
import Foundation
import os

/// A pty master libghostty holds in this process, and the terminal device on its other end
/// (the `e_tdev` every process on that terminal reports).
struct PtyMaster: Hashable, Sendable {
    let fd: Int32
    let tty: dev_t

    /// Every pty master open in this process. Only character devices are asked for a slave
    /// name, so no other descriptor is touched.
    static func all() -> Set<PtyMaster> {
        let pid = getpid()
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        // Room for descriptors opened between the two calls.
        let capacity = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 32
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(capacity * MemoryLayout<proc_fdinfo>.stride))
        guard filled > 0 else { return [] }
        return Set(fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride).compactMap { info in
            info.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) ? master(info.proc_fd) : nil
        })
    }

    /// Waits until no process holds the terminal any more (the master reports a hangup), then
    /// a little longer for libghostty's reader to take in what they wrote last. Bounded.
    func waitForHangup(timeout: TimeInterval = 1, settle: TimeInterval = 0.15) {
        let deadline = Date().addingTimeInterval(timeout)
        var poll = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while Date() < deadline {
            poll.revents = 0
            guard Darwin.poll(&poll, 1, 0) >= 0, poll.revents & Int16(POLLHUP) == 0 else { break }
            usleep(10_000)
        }
        usleep(useconds_t(settle * 1_000_000))
    }

    static func master(_ fd: Int32) -> PtyMaster? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { return nil }
        var name = [CChar](repeating: 0, count: 128)
        guard ptsname_r(fd, &name, name.count) == 0 else { return nil }
        var slave = stat()
        guard stat(name, &slave) == 0 else { return nil }
        return PtyMaster(fd: fd, tty: slave.st_rdev)
    }
}

/// Which pty belongs to which surface. libghostty exposes neither the pty nor the child's pid,
/// and opens the pty on the surface's IO thread just after `ghostty_surface_new` returns.
/// Surfaces are only made on the main thread, so a master that appears after one surface is
/// made belongs to it, provided the next is made only once it has appeared: `willCreate`
/// waits for that (briefly, and only when two surfaces are made back to back).
@MainActor
enum SurfacePtys {
    private struct Pending {
        weak var view: TerminalSurfaceView?
        var before: Set<PtyMaster>
    }

    private struct Assigned {
        weak var view: TerminalSurfaceView?
        let master: PtyMaster
    }

    private static var pending: Pending?
    private static var assigned: [ObjectIdentifier: Assigned] = [:]
    /// How long a surface's pty may take to appear before it's treated as unknown.
    static var settleTimeout: TimeInterval = 0.5

    /// Call right before `ghostty_surface_new`; pass the result to `didCreate`.
    static func willCreate() -> Set<PtyMaster> {
        settle()
        return PtyMaster.all()
    }

    static func didCreate(_ view: TerminalSurfaceView, before: Set<PtyMaster>) {
        pending = Pending(view: view, before: before)
    }

    /// The surface's pty, while the surface is alive; forgets it. Nil when it never appeared
    /// (the child failed to start) or couldn't be told apart.
    static func take(for view: TerminalSurfaceView) -> PtyMaster? {
        defer { assigned[ObjectIdentifier(view)] = nil }
        return pty(for: view)
    }

    /// The surface's pty, while the surface is alive.
    static func pty(for view: TerminalSurfaceView) -> PtyMaster? {
        if pending?.view === view { settle() }
        guard let entry = assigned[ObjectIdentifier(view)], entry.view === view else { return nil }
        let master = entry.master
        // libghostty closes the master only when the surface is freed, so it is still this one.
        return PtyMaster.master(master.fd) == master ? master : nil
    }

    /// Call once the surface is freed: a surface pending now may reopen the same descriptor and
    /// device, and that one is new.
    static func didFree(_ master: PtyMaster) {
        pending?.before.remove(master)
    }

    /// Assigns the pending surface its master, waiting up to `settleTimeout` for it to appear.
    private static func settle() {
        guard let current = pending else { return }
        pending = nil
        guard let view = current.view else { return }
        // A view that went without `destroy` leaves its entry behind.
        assigned = assigned.filter { $0.value.view != nil }
        let deadline = Date().addingTimeInterval(settleTimeout)
        repeat {
            // Masters made before this surface were in `before`, so a new one is its own.
            let fresh = PtyMaster.all().subtracting(current.before)
            if fresh.count == 1, let master = fresh.first {
                assigned[ObjectIdentifier(view)] = Assigned(view: view, master: master)
                return
            }
            // More than one can't be told apart; better unknown than another terminal's.
            if fresh.count > 1 { return }
            usleep(1_000)
        } while Date() < deadline
    }
}

/// Notes in events.jsonl (kind "teardown", shown by `ht doctor`) a surface free that holds the
/// main thread past `limit`: once while it is still stuck, from another thread (so a free that
/// never returns is on record), and again with how long it took if it does return.
enum FreeWatchdog {
    static let limit: TimeInterval = 3

    static func guarding(limit: TimeInterval = limit, log: @escaping @Sendable (String, [String: Any]) -> Void = record,
                         _ free: () -> Void) {
        let started = Date()
        let finished = OSAllocatedUnfairLock(initialState: false)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limit) {
            guard !finished.withLock({ $0 }) else { return }
            log("freeing a terminal has held the main thread for \(Int(limit)) s", ["stalled": true])
        }
        free()
        finished.withLock { $0 = true }
        let took = Date().timeIntervalSince(started)
        if took >= limit {
            log(String(format: "freeing a terminal held the main thread for %.1f s", took), ["stalled_for": took])
        }
    }

    private static func record(_ text: String, _ fields: [String: Any]) {
        EventLog.record("teardown", text, fields: fields)
    }
}

