import Darwin

/// libghostty forks and execs each terminal's shell without closing the parent's descriptors,
/// so every one Tako holds open without close-on-exec lands in every shell, agent and dev server.
/// Chromium opens a hundred or so that way (profile databases and their locks, pipes, the
/// DevTools listening socket): a terminal started after the browser carried all of them, kept
/// Chromium's port listening after Tako quit, and was reported as serving that port itself.
enum InheritedDescriptors {
    /// Marks every descriptor above stdio close-on-exec. Tako never hands a descriptor to a
    /// child by inheritance: Foundation's `Process` and libghostty map the ones a child gets
    /// onto its stdio, and Chromium launches its helpers with close-on-exec as the default.
    /// Returns how many descriptors it changed.
    @discardableResult
    static func closeOnExec() -> Int {
        var changed = 0
        for fd in openDescriptors() where fd > STDERR_FILENO {
            let flags = fcntl(fd, F_GETFD)
            guard flags >= 0, flags & FD_CLOEXEC == 0, fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0 else { continue }
            changed += 1
        }
        return changed
    }

    private static func openDescriptors() -> [Int32] {
        let pid = getpid()
        let bufferSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        // Room for descriptors opened between sizing and reading.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride + 32)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).map(\.proc_fd)
    }
}
